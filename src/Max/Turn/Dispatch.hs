module Max.Turn.Dispatch
  ( dispatchLLM,
    dispatchLLMWith,
  )
where

import Control.Concurrent qualified as Thread
import Control.Exception qualified as Exception
import Control.Monad (unless, void, when)
import Data.Foldable (for_)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Exception
  ( SomeException,
    finally,
    mask,
    onException,
  )
import Effectful.Log
  ( Log,
    MonadLog (localDomain),
    logAttention,
    logInfo,
    object,
    (.=),
  )
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Browser.Runtime (releaseBrowserTurn)
import Max.Command.Parser (parseCommand)
import Max.Command.Types (Command (..))
import Max.Conversation qualified as Conversation
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
  ( AgentTurnTerminal (..),
    ensureAgentTurnCrashed,
    finishAgentTurn,
    startAgentTurn,
  )
import Max.DB.History
  ( HistoryItem (..),
    fetchMessageWithCursorInScope,
  )
import Max.Dispatch
  ( DispatchMessage (..),
    dispatchTextWithoutSelf,
  )
import Max.Effects.Agent (Agent)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound)
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.Handler.Output (replyText)
import Max.Handler.Reaction (failureFaceId, queueQQReaction)
import Max.Intent (IntentState)
import Max.Jobs qualified as Jobs
import Max.ModelCatalog (ModelCatalog)
import Max.Platform.Store.Conversation
  ( conversationAdvertisedCaps,
  )
import Max.Platform.Types
  ( AdvertisedCaps (canFace, canReaction),
    CanonicalMessageId (CanonicalMessageId, unCanonicalMessageId),
    PrincipalId (PrincipalId),
  )
import Max.Prompt (TriggerOrigin (OriginDirect))
import Max.Shutdown (enterDispatch, leaveDispatch)
import Max.Task.FrontendInput (FrontendInputView (..))
import Max.Task.State qualified as JobState
import Max.Task.Types (JobResult (JobResult), JobView (run))
import Max.Tasks
  ( TaskCancelled (TaskCancelled),
    TurnRuntime,
    activateTurnRuntime,
    beginTurnRuntime,
    finishTurnRuntime,
    turnRuntimeAgentTurn,
  )
import Max.Turn.Failure (handleTurnFailures)
import Max.Turn.Reply (runDispatch)
import Max.Turn.Start
  ( InputAdmission (AdmitFrontendInput, StartSeparateTurn),
    TurnStart (..),
    startAllowsInput,
  )
import Max.Turn.Types
  ( AgentTurnId (unAgentTurnId),
    AgentTurnRef (atrTurnId),
  )
import Max.Util (catchSync)
import OneBot.Types (GroupId (GroupId), UserId (UserId))

dispatchLLM ::
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
  Maybe IntentState ->
  TriggerOrigin ->
  DispatchMessage ->
  Eff es ()
dispatchLLM intent origin message =
  let allowInput = case parseCommand (dispatchTextWithoutSelf message) of
        Right (Just (Btw _)) -> False
        _ -> True
   in dispatchLLMWith (NewTurn (if allowInput then AdmitFrontendInput else StartSeparateTurn)) intent origin message

dispatchLLMWith ::
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
  TurnStart ->
  Maybe IntentState ->
  TriggerOrigin ->
  DispatchMessage ->
  Eff es ()
dispatchLLMWith start intent origin message =
  forkDispatch start origin message (runDispatch start intent origin message)

-- Owns the shutdown slot, registered runtime, conversation ticket and browser
-- scope from before context collection until the child terminates.
forkDispatch ::
  ( Log :> es,
    WithConnection :> es,
    Outbound :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TurnStart ->
  TriggerOrigin ->
  DispatchMessage ->
  (AdvertisedCaps -> TurnRuntime -> AgentTurnRef -> Eff es ()) ->
  Eff es ()
forkDispatch start origin gm work = do
  env :: BotEnv <- ask
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      CanonicalMessageId midRaw = gm.canonicalId
      ident =
        object
          [ "group_id" .= gidRaw,
            "user_id" .= fromRaw,
            "message_id" .= midRaw,
            "origin" .= T.pack (show origin)
          ]
  outputCaps <- conversationAdvertisedCaps gidRaw (if midRaw > 0 then Just midRaw else Nothing)
  -- Acquire shutdown admission before spawning, in the same transaction as
  -- the drain check. The slot covers setup, context collection and execution;
  -- Handler also registers the TurnRuntime before launching the child.
  launched <- mask $ \restore -> do
    acquired <- liftIO (enterDispatch env.beShutdown)
    case acquired of
      False -> pure False
      True -> do
        -- Register before context collection so concurrent triggers, !ps and
        -- !kill can see the turn before the Agent loop starts.
        turnRef <-
          restore
            (startAgentTurn gm.groupId gm.canonicalId gm.authorPrincipalId)
            `onException` liftIO (leaveDispatch env.beShutdown)
        let runtimeFailed =
              ensureTerminal turnRef "dispatch failed before runtime registration"
                `finally` liftIO (leaveDispatch env.beShutdown)
        turn <-
          liftIO (beginTurnRuntime env.beTasks turnRef gm.groupId gm.userId (Just gm.canonicalId))
            `onException` runtimeFailed
        let launchFailed =
              ensureTerminal turnRef "dispatch failed before worker launch"
                `finally` do
                  releaseTurnScope env turn
                  for_ backgroundJob $ \job -> liftIO (Jobs.detachJobTurn env.beJobs job.run)
        case start of
          JobTurn job -> do
            attached <- liftIO (Jobs.attachJobTurn env.beJobs job.run turnRef)
            unless attached (launchFailed >> liftIO (ioError (userError "job replaced or cancelled before launch")))
          JobNotice job version _ -> liftIO (Jobs.bindJobNotice env.beJobs turnRef.atrTurnId job.run version)
          _ -> pure ()
        ticket <- (if background then pure Nothing else admitConversation env turnRef) `onException` launchFailed
        if not background && isNothing ticket
          then do
            finishAgentTurn turnRef TurnAborted 0 (Just "conversation queue full") `finally` launchFailed
            when (origin == OriginDirect) (replyText gm "当前处理队列已满，请稍后重试。")
          else
            launchTurn env outputCaps ident gidRaw restore turn turnRef ticket
              `onException` (for_ ticket (liftIO . Conversation.release env.beConversations) >> launchFailed)
        pure True
  unless launched $ do
    for_ backgroundJob $ \job -> liftIO (Jobs.completeJob env.beJobs job.run JobState.Cancelled (JobResult "service shutting down" Nothing))
    logInfo "llm dispatch declined: draining" ident
    -- Signal declined direct triggers with a reaction during drain.
    when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
      queueQQReaction gm.groupId gm.canonicalId failureFaceId True
  where
    allowInput = startAllowsInput start
    backgroundJob = case start of JobTurn job -> Just job; _ -> Nothing
    background = isJust backgroundJob
    notice = case start of JobNotice {} -> True; _ -> False
    admitConversation env turnRef = do
      source <- fetchMessageWithCursorInScope (conversationScopeFor gm.groupId) gm.canonicalId.unCanonicalMessageId
      let sourceOrder = fst <$> source
          feedback = case (parseCommand (dispatchTextWithoutSelf gm), source) of
            (Right (Just (Feedback _)), Just (_, history))
              | PrincipalId history.authorPrincipalId == gm.authorPrincipalId ->
                  Just (FrontendInputView history.canonicalId "steering" history.authorPrincipalId history.senderNickname history.receivedAt history.replyTo history.renderedText)
            _ -> Nothing
      liftIO $
        Conversation.enqueue
          env.beConversations
          Conversation.TurnInput
            { group = gm.groupId,
              turn = turnRef.atrTurnId,
              principal = gm.authorPrincipalId,
              sourceOrder,
              feedback = if allowInput then feedback else Nothing,
              acceptsFeedback = allowInput && not notice,
              notice
            }

    launchTurn env outputCaps ident gidRaw restore turn turnRef ticket =
      void . async . restore $
        ( localDomain "llm" $ do
            logInfo "llm dispatch" ident
            -- Cancellation reaches this owner; tool error handlers do not swallow it.
            handleTurnFailures
              ( \e -> do
                  finishAgentTurn turnRef TurnCrashed 0 (Just (T.pack (show e)))
                  logAttention "llm dispatch crashed" $ object ["error" .= T.pack (show e)]
                  when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
                    queueQQReaction gm.groupId gm.canonicalId failureFaceId True
              )
              ( \err -> do
                  finishAgentTurn turnRef TurnFailed 0 (Just ("reply publication failed: " <> err))
                  logAttention "stream publication failed; committed prefix retained" $ object ["error" .= err]
              )
              ( do
                  finishAgentTurn turnRef TurnCancelled 0 (Just "cancelled by !kill")
                  for_ backgroundJob $ \job -> liftIO (Jobs.completeJob env.beJobs job.run JobState.Cancelled (JobResult "任务已取消。" Nothing))
                  logInfo "llm dispatch cancelled" $ object ["group_id" .= gidRaw]
              )
              ( do
                  worker <- liftIO Thread.myThreadId
                  preKilled <- liftIO (activateTurnRuntime turn "queued" (Thread.throwTo worker TaskCancelled))
                  when preKilled (liftIO (Exception.throwIO TaskCancelled))
                  running <- maybe (pure True) (liftIO . Conversation.awaitTurn) ticket
                  if running
                    then work outputCaps turn turnRef
                    else finishAgentTurn turnRef TurnAborted 0 (Just "feedback consumed by the active conversation turn")
              )
        )
          `finally` do
            ensureTerminal turnRef "dispatch unwound before a terminal checkpoint"
              `finally` do
                for_ ticket (liftIO . Conversation.release env.beConversations)
                releaseTurnScope env turn
                for_ backgroundJob $ \job -> liftIO $ do
                  Jobs.completeJob env.beJobs job.run JobState.Failed (JobResult "任务中断；已发生的外部操作不会重试。" Nothing)
                  Jobs.detachJobTurn env.beJobs job.run

    ensureTerminal ref reason =
      ensureAgentTurnCrashed ref reason
        `catchSync` \e ->
          logAttention "turn terminal cleanup failed" $
            object ["turn_id" .= ref.atrTurnId.unAgentTurnId, "reason" .= reason, "error" .= T.pack (show (e :: SomeException))]

    -- Release local ownership before browser teardown, which may block or fail.
    releaseTurnScope env turn = do
      let ref = turnRuntimeAgentTurn turn
      liftIO $ do
        leaveDispatch env.beShutdown
        finishTurnRuntime env.beTasks turn
      releaseBrowserTurn env.beJobs env.beBrowsers gm.groupId ref.atrTurnId
        `catchSync` \e ->
          logAttention "browser scope finalizer failed" $
            object ["error" .= T.pack (show (e :: SomeException))]
      liftIO (Jobs.detachJobNotice env.beJobs ref.atrTurnId)
