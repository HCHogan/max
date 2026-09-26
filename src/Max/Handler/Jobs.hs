module Max.Handler.Jobs
  ( shutdownJobs,
    jobsWorker,
  )
where

import Control.Concurrent.STM (atomically, check)
import Control.Monad (forever, void, when)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent, async, concurrently_)
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Conversation qualified as Conversation
import Max.DB.Monitor.Admission qualified as MonitorJob
import Max.Dispatch
  ( DispatchMessage (..),
  )
import Max.Effects.Agent (Agent)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (DeliverConversation),
    OutboundRequest (..),
    sendRecorded,
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.IR (Body (Body), Node (NText))
import Max.Jobs qualified as Jobs
import Max.MessageKind (MessageKind (KindChat))
import Max.ModelCatalog (ModelCatalog)
import Max.Node.Router qualified as Router
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Prompt (TriggerOrigin (OriginMonitor, OriginTask))
import Max.Task.State qualified as JobState
import Max.Task.Types
  ( JobMonitor (fireId),
    JobResult (JobResult),
    JobRun (jobId),
    JobSpec (group, monitor, source),
    JobView (..),
    jobReportText,
    taskHandle,
  )
import Max.ToolContext (toolAuthorPrincipalId, toolCanonicalId, toolGroupId)
import Max.Turn.Dispatch (dispatchLLMWith)
import Max.Turn.Start (TurnStart (AutomationTurn, CompletionNotice, JobTurn, MessageNotice, ReportNotice))
import Max.Util (catchSync)

shutdownJobs :: (WithConnection :> es, Outbound :> es, Log :> es, IOE :> es) => Jobs.Jobs -> Eff es ()
shutdownJobs registry = do
  jobs <- liftIO (Jobs.closeJobs registry)
  for_ jobs $ \job ->
    ( for_ job.result $ \result -> do
        -- An interrupted automation fire is recorded, not announced: its turn
        -- spoke for itself, and its creator's request may be days old.
        publish <- case job.spec.monitor of
          Nothing -> pure True
          Just monitor -> False <$ MonitorJob.recordMonitorResult monitor.fireId job.status result
        when publish $
          void $
            sendRecorded
              OutboundRequest
                { orKind = KindChat,
                  orGroupId = job.spec.group,
                  orBody = Body [NText (jobReportText job result)],
                  orReplyTo = Just job.spec.source,
                  orDeliveryScope = DeliverConversation,
                  orTurnOutput = Nothing,
                  orMonitorFireId = Nothing
                }
    )
      `catchSync` \err ->
        logAttention "job shutdown notice failed" (object ["job" .= taskHandle job.run.jobId, "error" .= show err])

jobsWorker ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Eff es ()
jobsWorker = do
  env :: BotEnv <- ask
  -- Independent consumers prevent a slow source lookup or monitor write from
  -- holding the other intake. Router receipts still own every terminal result.
  concurrently_ (launches env) (deliveries env)
  where
    launches env = forever $ do
      job <- liftIO (atomically (Jobs.claimReadyJob env.beJobs))
      let failed detail = liftIO (Jobs.completeJob env.beJobs job.run JobState.Failed (JobResult detail Nothing))
          start = if isJust job.spec.monitor then AutomationTurn job else JobTurn job
      dispatch job start failed `catchSync` (failed . T.pack . show)

    deliveries env = forever $ do
      work <- liftIO . atomically $ do
        Jobs.jobsAreOpen env.beJobs >>= check
        Jobs.flushJobEvents env.beJobs
        Router.takeDelivery env.beJobs.resultRouter
      case work of
        Router.ChildMessage relay -> do
          let release = liftIO (atomically (Router.releaseMessage env.beJobs.resultRouter relay))
              failed detail = release >> logAttention "child message relay failed" (object ["error" .= (detail :: T.Text)])
              deliver = do
                liftIO . atomically $ do
                  current <- Router.messageIsCurrent relay
                  capacity <- Conversation.canAdmit env.beConversations relay.job.spec.group
                  check (not current || capacity)
                current <- liftIO (atomically (Router.messageIsCurrent relay))
                if current then dispatch relay.job (MessageNotice relay) failed else release
          void . async $ deliver `catchSync` (failed . T.pack . show)
        Router.JobReport relay -> do
          let release = liftIO (atomically (Router.releaseReport env.beJobs.resultRouter relay))
              failed detail = release >> logAttention "job report relay failed" (object ["error" .= (detail :: T.Text)])
              deliver = do
                liftIO . atomically $ do
                  current <- Router.reportIsCurrent relay
                  capacity <- Conversation.canAdmit env.beConversations relay.job.spec.group
                  check (not current || capacity)
                current <- liftIO (atomically (Router.reportIsCurrent relay))
                if current then dispatch relay.job (ReportNotice relay) failed else release
          void . async $ deliver `catchSync` (failed . T.pack . show)
        Router.NativeResult relay -> do
          let context = relay.origin.context
              release = liftIO (atomically (Router.releaseRelay env.beJobs.resultRouter relay))
              relayResult = do
                liftIO . atomically $ do
                  current <- Router.relayIsCurrent relay
                  capacity <- Conversation.canAdmit env.beConversations (toolGroupId context)
                  check (not current || capacity)
                current <- liftIO (atomically (Router.relayIsCurrent relay))
                if not current
                  then release
                  else do
                    source <- loadDispatchMessage (toolCanonicalId context)
                    case source of
                      Just message
                        | message.groupId == toolGroupId context && message.authorPrincipalId == toolAuthorPrincipalId context ->
                            dispatchLLMWith (CompletionNotice relay) Nothing OriginTask message {body = Body [], replyTo = Nothing, mentionPrincipals = Map.empty}
                      _ -> release >> logAttention "execution result source unavailable" (object ["result" .= relay.reference])
          void . async $ relayResult `catchSync` (\err -> release >> logAttention "execution result relay failed" (object ["error" .= T.pack (show err)]))
        Router.MonitorCompleted receipt ->
          recordResult env receipt `catchSync` (monitorFailed env receipt . T.pack . show)
    dispatch job start failed = do
      sourceMessage <- loadDispatchMessage job.spec.source
      case sourceMessage of
        Just source | source.groupId == job.spec.group && source.authorPrincipalId == job.spec.principal -> do
          let trigger = source {body = Body [], replyTo = Nothing, mentionPrincipals = Map.empty}
          case start of
            AutomationTurn _ -> for_ job.spec.monitor (MonitorJob.markMonitorJobStarted . (.fireId))
            _ -> pure ()
          dispatchLLMWith start Nothing (case start of AutomationTurn _ -> OriginMonitor; _ -> OriginTask) trigger
        _ -> failed "task source provenance unavailable"

    -- The automation turn already spoke; its outcome only enters history.
    recordResult env receipt = do
      let job = receipt.job
      for_ ((,) <$> job.spec.monitor <*> job.result) $ \(fire, result) ->
        void (MonitorJob.recordMonitorResultWhen (atomically (Router.monitorIsCurrent receipt)) fire.fireId job.status result)
      liftIO (atomically (Router.releaseMonitorResult env.beJobs.resultRouter receipt))

    monitorFailed env receipt (detail :: T.Text) = do
      liftIO (atomically (Router.releaseMonitorResult env.beJobs.resultRouter receipt))
      logAttention "monitor result recording failed; not replayed" (object ["error" .= detail])
