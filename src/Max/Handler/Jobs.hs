module Max.Handler.Jobs
  ( shutdownJobs,
    jobsWorker,
  )
where

import Control.Monad (forever, void, when)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
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
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Prompt (TriggerOrigin (OriginTask))
import Max.Task.State qualified as JobState
import Max.Task.Types
  ( JobMonitor (fireId),
    JobResult (JobResult, text),
    JobRun (jobId),
    JobSpec (group, monitor, source),
    JobView (..),
    taskHandle,
  )
import Max.Turn.Dispatch (dispatchLLMWith)
import Max.Turn.Start (TurnStart (JobNotice, JobTurn))
import Max.Util (catchSync)

shutdownJobs :: (WithConnection :> es, Outbound :> es, Log :> es, IOE :> es) => Jobs.Jobs -> Eff es ()
shutdownJobs registry = do
  jobs <- liftIO (Jobs.closeJobs registry)
  for_ jobs $ \job ->
    ( for_ job.result $ \result -> do
        publish <- case job.spec.monitor of
          Nothing -> pure True
          Just monitor -> MonitorJob.recordMonitorResult monitor.fireId job.status result
        when publish $
          void $
            sendRecorded
              OutboundRequest
                { orKind = KindChat,
                  orGroupId = job.spec.group,
                  orBody = Body [NText result.text],
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
  forever $ do
    work <- liftIO (Jobs.takeJobWork env.beJobs)
    case work of
      Jobs.LaunchJob job ->
        let failed detail = liftIO (Jobs.completeJob env.beJobs job.run JobState.Failed (JobResult detail Nothing))
         in dispatch job (JobTurn job) failed `catchSync` (failed . T.pack . show)
      Jobs.PublishJobNotice job version body ->
        dispatch job (JobNotice job version body) (noticeFailed env job)
          `catchSync` (noticeFailed env job . T.pack . show)
      Jobs.RecordMonitorResult job ->
        recordResult env job `catchSync` (noticeFailed env job . T.pack . show)
  where
    dispatch job start failed = do
      sourceMessage <- loadDispatchMessage job.spec.source
      case sourceMessage of
        Just source | source.groupId == job.spec.group -> do
          let trigger = source {body = Body [], replyTo = Nothing, mentionPrincipals = Map.empty}
          case start of
            JobTurn _ -> for_ job.spec.monitor (MonitorJob.markMonitorJobStarted . (.fireId))
            _ -> pure ()
          dispatchLLMWith start Nothing OriginTask trigger
        _ -> failed "task source provenance unavailable"

    recordResult env job =
      for_ ((,) <$> job.spec.monitor <*> job.result) $ \(fire, result) -> do
        publish <- MonitorJob.recordMonitorResult fire.fireId job.status result
        when publish (liftIO (Jobs.queueJobResultNotice env.beJobs job.run))
        liftIO (Jobs.releaseJobNotice env.beJobs job.run)

    noticeFailed env job (detail :: T.Text) = do
      liftIO (Jobs.releaseJobNotice env.beJobs job.run)
      logAttention "job notice failed; not replayed" (object ["error" .= detail])
