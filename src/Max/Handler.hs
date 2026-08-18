module Max.Handler
  ( handleEvents,
    dispatchPendingWorker,
    dispatchProactive,
    dispatchMonitorFire,
    planDriverFor,
    resumeInterruptedTurn,
    recordAs,
    IngestOutcome (..),
    ingestAllowsDownstream,
    isSilentReply,
    parseSilence,
    splitQuoteHandles,
  )
where

import Control.Applicative ((<|>))
import Control.Exception qualified as Exception
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Control.Concurrent.STM (TQueue, atomically, newTVarIO, readTQueue, readTVarIO)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value, eitherDecodeStrict', encode, toJSON)
import Data.Char (isDigit, isSpace)
import Data.Foldable (for_)
import Data.List (find, unsnoc)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Data.Traversable (for)
import Effectful
import Effectful.Concurrent (threadDelay)
import Effectful.Concurrent.Async (Concurrent, async, race, withAsync)
import Effectful.Exception (SomeException, catch, finally)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.AgentEvent (AgentEvent (..), AgentOutputContext (..), handleAgentEvent)
import Max.Command.Dispatcher (DispatchResult (..))
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Parser (parseCommand)
import Max.Command.Permission (PermTier (..), requiredCapability, tierSatisfied)
import Max.Command.Types (Command (..))
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.AgentTurn
  ( AgentTurnRecovery (..),
    AgentTurnTerminal (..),
    ensureAgentTurnCrashed,
    ensureAgentTurnRecoveryPending,
    finishAgentTurn,
    markAgentTurnRunning,
    nextAgentTurnOutputChunk,
    recoveryViewForTurn,
    resolveJournalResultValue,
    startAgentTurn,
  )
import Max.DB.History (HistoryItem (..), fetchMessageInScope, fetchMessagesByIdsInScope, fetchRecentInGroup)
import Max.DB.Monitor
  ( ElaboratedMonitorFire (..),
    admitElaboratedMonitorTurn,
    expireElaboratedMonitorFire,
    loadAdmittedMonitorFire,
  )
import Max.DB.TurnContinuity
  ( ReplyTurnTarget (..),
    continuationDigest,
    recordForkFrom,
    replayChain,
    replyTurnIsFinished,
    replyTurnIsInFlight,
    resolveReplyTurn,
    setAgentTurnEnvironment,
  )
import Max.DB.Notify (WorkChannel (DispatchWork), claimOrWait)
import Max.Dispatch (DispatchMessage (..), dispatchMentionsSelf, dispatchTextWithoutSelf, stripDispatchVerb)
import Max.Dispatch qualified as Dispatch
import Max.Effects.Agent (Agent, AgentContext (..), AgentResult (..), agentTurn)
import Max.Effects.Blob (Blob, blobRefFromSha256, blobRefSha256, putBlob, readBlob)
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..), LLM)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), sendRecorded, wasDelivered)
import Max.Effects.PlatformApi (PlatformApi, sendAction)
import Max.Effects.Tools (ToolDefinition (..), ToolRef (..), runTools)
import Max.Env (BotEnv (..))
import Max.EpisodeScheduler (armEpisode, bumpEpisode)
import Max.Faces (faceIdByName)
import Max.FetchQueue (FetchSignal)
import Max.Files (enqueueFiles)
import Max.Forward (enqueueForwards)
import Max.Images (enqueueImages)
import Max.Intent (IntentState, clearPendingIntent, enqueueIntent, noteBotActivity)
import Max.IR
import Max.IR.Digest (digest)
import Max.MessageKind (MessageKind (..), renderMessageKind)
import Max.ModelCatalog (ModelCapabilities (..), ModelCatalog, defaultContextLimits, lookupModelCapabilities)
import Max.Monitor (nextCronFire)
import Max.Monitor.Types (MonitorRef (..), monitorHandleText)
import Max.Platform.QQ (ensureQQEndpoint, ensureQQEndpointFor, qqEnvelope, qqIngestBody, qqNoticeEnvelopes)
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store
  ( DispatchClaim (..),
    RegisteredEndpoint (..),
    DispatchCompletion (..),
    IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    OutboundDraft (..),
    ReactionDraft (..),
    claimDispatch,
    claimDispatches,
    completeDispatch,
    renewDispatchLease,
    releaseDeferredDispatches,
    conversationAdvertisedCaps,
    defaultIngestOptions,
    ensureEndpointPrincipals,
    ingestEnvelope,
    loadDispatchClaim,
    resolveMentionIdentities,
    mentionPrincipalsFor,
    enqueueReaction,
    recordInternalMessage,
    rememberConversationTitle,
  )
import Max.Platform.Types (AdvertisedCaps (..), CanonicalMessageId (..), noAdvertisedCaps, NativeUserId (..), Platform (PlatformQQ), PrincipalId (..), PrincipalIdentityId, ReactionAction (..))
import Max.Prompt (ContextReadMode (..), TriggerOrigin (..), buildContextWithReadModeForOutputContinuation, renderCurrentLine, renderHistoryLine)
import Max.ReplySend (ReplyTarget (..), cleanModelText, freshBudget, sendAndPersistReply)
import Max.Roster (GroupMember (..), GroupMeta (..), fetchGroupMembers, fetchGroupMeta, memberName, renderGroupBrief)
import Max.Session (Session (..), loadSession, readSession)
import Max.Shutdown (enterDispatch, leaveDispatch)
import Max.Skills (Skill (..), skillsForGroup)
import Max.Tasks
  ( Note (..),
    cancelAgentTurnTask,
    NoteVerb (..),
    TaskCancelled (..),
    TaskId (..),
    TaskInfo (..),
    TurnCompletion (..),
    awaitTurnSilence,
    beginDurableTurnRuntime,
    beginDurableTurnRuntimeAt,
    finishTurnRuntime,
    inFlightTriggers,
    listTasks,
    pushToLatest,
    pushToAgentTurn,
    pushToTrigger,
    setTurnPhase,
    turnRuntimeTaskId,
    turnRuntimeOutputContext,
  )
import Max.ToolContext (SubgoalReturn (..), TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import Max.Effects.Http (Http)
import Max.Effects.Embedding (Embedding)
import Max.Effects.ToolOutput (defaultInlineMediaLimit, runToolOutput)
import Max.HttpRuntime (HttpRuntime)
import Max.DB.Plan
  ( ChildDispatch (..),
    WakeablePlan (..),
    PlanOrdinal (..),
    PlanId (..),
    PlanRef (..),
    StoredPlan (..),
    admitClaimedPlanWake,
    childHasResult,
    loadChildDispatch,
    loadPlanWake,
    remainingChildBudget,
    requestClaimedChildCancellation,
    startClaimedPlanChild,
  )
import Max.Plan.Brief (renderPlanValue, subgoalBrief)
import Max.Plan.Catalog (childReachableEffects, planCatalog)
import Max.Plan.Execute
  ( Deopt (..),
    ExecState,
    ExecutionEnd (..),
    ExecutionEnv (..),
    ExecutionResult (..),
    deoptText,
    resumePlan,
  )
import Max.Plan.Drive (Dispatchable (..))
import Max.Plan.Reconcile (Desired (..))
import Max.Plan.Types (Binder (..), EffectBudget (..), Goal (..), NodeId (..), PlanDocument (..))
import Max.Plan.Validate (CatalogEntry (..), ValidationEnv (..), rejectionText, validatePlan)
import Max.Plan.Worker (PlanDriver (..), Resumption)
import Max.Plan.Worker qualified as Worker
import Max.Tools.Plan (planResourceHandles, validationEnvForContract)
import Max.Toolset (plannableToolsFor, toolDefinitionsFor)
import Max.Context.Types (ContinuationInput (..), digestOnlyContinuation, noContinuation)
import Max.Turn.Continuity (currentPromptMajor, renderContinuationDigest, renderReplayDelta, toolCatalogFingerprint)
import Max.Turn.Replay
  ( ReplayCandidate (..),
    ReplayEnvironment (..),
    ReplayPlan (..),
    ReplayReject (RejectArchiveUnreadable),
    TurnArchive (..),
    defaultChainDepth,
    defaultChainTokenBudget,
    planCoveredCanonicalIds,
    planReplay,
    planReplayMessages,
    replayRejectText,
  )
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..), TurnOutputContext, nextTurnOutputLink)
import Max.Util (catchSync, readIntegral, trySync, tshow)
import OneBot.Action (Action (..))
import OneBot.Event (Event (..), GroupMessage (..), MessageNotice (..), PokeEvent (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)
import System.Cron.Parser (parseCronSchedule)

data IngestOutcome
  = IngestDurable !CanonicalMessageId
  | IngestDuplicate
  | IngestFailed !T.Text
  deriving stock (Show, Eq)

ingestAllowsDownstream :: IngestOutcome -> Bool
ingestAllowsDownstream IngestDurable {} = True
ingestAllowsDownstream IngestDuplicate = False
ingestAllowsDownstream IngestFailed {} = False

-- | May this turn be swallowed by one already running?
--
-- The supplement classifier exists to guess what an unmarked
-- message meant, so a turn that already said it outright must not be
-- sent back for a second opinion — @!btw@ means \"leave the running
-- turn alone\", and a classifier that disagreed would do exactly the
-- thing the user ruled out.
--
-- Carried separately from 'TriggerOrigin' because the two ask
-- different questions.  Origin says what woke the bot (and the
-- reaction sites test it for \"is there a real trigger message to
-- react to\"); absorbable says whether this turn is up for grabs.
-- Direct and proactive triggers both are — a proactive followup
-- (\"不对，改成X\" said without an @) steers a running turn exactly
-- like the @-ed version of the same words.  A poke is not: it lands
-- in a running turn's inbox before ever dispatching (see 'onPoke'),
-- and the sentinel trigger it dispatches with has no message for the
-- classifier to read.
--
-- This used to ride on 'Max.Persistence.isEphemeral' — @!btw@ ran in a
-- non-persisting scope, and the classifier skipped non-persisting
-- turns.  True by accident, and it broke the moment @!btw@ stopped
-- being ephemeral.
data Absorbable
  = MayAbsorb
  | NeverAbsorb
  deriving stock (Show, Eq)

-- | Decision derived from one group message.
data Trigger
  = -- | Bot was not addressed and message is not a command; do nothing.
    TriggerNone
  | -- | @\@bot ping@ — fast path, no LLM.
    TriggerPong
  | -- | @\@bot ...@ with any other body. Carries the user-facing body
    -- with the @bot mention already stripped.
    TriggerLLM !T.Text
  | -- | Message is a @!@-command (with or without @-mention).  Dispatch
    -- through 'Max.Command.Dispatcher'; no LLM.
    TriggerCommand !T.Text
  | -- | Malformed command (starts with @!ident@ but parser failed).
    -- Surface the error back to the user.
    TriggerCommandError !T.Text
  deriving stock (Show)

-- | How a freshly received message is recorded: its kind, and a
-- rewritten @rendered_text@ when the stored form should differ from
-- what was literally typed.
--
-- Most commands are the UI used to operate the bot, and the model has
-- no business reading them back.  @!btw@ and @!feedback@ are the
-- exception — their bodies are things somebody said *to* the bot, and
-- the bot answers them.  They are conversation wearing a command
-- prefix, so they record as 'KindChat' with the verb stripped, landing
-- in the transcript exactly where the implicit supplement path already
-- puts the same words.  An empty body isn't conversation, it's a
-- mistyped command, and stays 'KindCommand'.
--
-- QQ segments remain raw provenance either way; only the IR body used for
-- the prompt projection is rewritten.
recordAs :: GroupMessage -> (MessageKind, Maybe T.Text)
recordAs gm =
  case parseCommand stripped of
    Right Nothing -> (KindChat, Nothing)
    Right (Just cmd)
      | Just note <- conversational cmd,
        not (T.null (T.strip note)) ->
          (KindChat, Just (renderPlainText (stripVerb gm.message)))
    _ -> (KindCommand, Nothing)
  where
    stripped = T.strip (stripMentions gm.selfId (T.strip (renderPlainText gm.message)))
    conversational = \case
      Btw note -> Just note
      Feedback note -> Just note
      _ -> Nothing

-- | Drop the leading @!verb@ from the first text segment carrying one,
-- leaving everything before it — notably the @-mention — in place, so
-- the line reads like any other message to the bot.
stripVerb :: [Segment] -> [Segment]
stripVerb [] = []
stripVerb (SegText t : rest)
  | Just body <- T.stripPrefix "!" (T.stripStart t) =
      SegText (T.stripStart (T.dropWhile (not . isSpace) body)) : rest
stripVerb (s : rest) = s : stripVerb rest

-- | App-lived event loop. Persists every group message, enqueues image
-- and forward jobs, dispatches @\@bot@ traffic. DB and dispatch failures
-- are logged but never tear down the loop.
handleEvents ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  TQueue Event ->
  -- | Wakes the media workers after each ingest; the jobs themselves
  -- go to @fetch_jobs@ (see "Max.FetchQueue").
  FetchSignal ->
  Maybe IntentState -> -- proactive-trigger buffers ('Nothing' = feature off)
  Eff es ()
handleEvents q fetchSig mIntent = loop
  where
    loop = do
      ev <- liftIO (atomically (readTQueue q))
      case ev of
        EvHeartbeat -> pure ()
        EvLifecycle sub ->
          logInfo "lifecycle" $ object ["sub_type" .= sub]
        EvRaw _ ->
          -- Unknown OneBot events may contain an entire user-authored payload.
          -- Keep the diagnostic marker, but leave the durable raw copy to the
          -- canonical ingest paths that understand the event shape.
          logTrace "unhandled event" $ object []
        EvGroupMessage source raw gm -> do
          -- Move the quiet boundary before the row becomes visible to the
          -- historian's DB scan.  Otherwise a due scan could race persistence
          -- and fold the just-arrived live-tail message.
          env :: BotEnv <- ask
          for_ env.beEpisodeScheduler $ \scheduler -> liftIO (bumpEpisode scheduler gm.groupId)
          persisted <- persist source raw gm
          case persisted of
            IngestDurable canonical ->
              processCanonicalDispatch "event-handler" fetchSig mIntent canonical
            IngestDuplicate -> do
              let MessageId messageId = gm.messageId
              logTrace "ingest: duplicate source event ignored" $
                object ["source" .= source, "message_id" .= messageId]
            IngestFailed {} -> do
              let GroupId groupId = gm.groupId
                  MessageId messageId = gm.messageId
              logAttention "ingest: downstream work suppressed because ledger insert failed" $
                object
                  [ "group_id" .= groupId,
                    "message_id" .= messageId,
                    "state" .= ("not-durable" :: T.Text)
                  ]
        EvMessageNotice raw notice -> do
          endpoint <- ensureQQEndpointFor notice.mnSelfId notice.mnGroupId
          received <- liftIO getCurrentTime
          forM_ (qqNoticeEnvelopes endpoint received raw notice) $ \envelope -> do
            ingestEnvelope
              defaultIngestOptions
                { createDispatch = False,
                  createMirrorDeliveries = True,
                  transcriptKind = renderMessageKind KindSystem
                }
              envelope
              >>= \case
                Ingested fresh ->
                  logInfo "QQ meta-event ingested" $
                    object
                      [ "canonical_message_id" .= fresh.canonicalMessageId,
                        "content" .= digest fresh.canonicalBody
                      ]
                AlreadyIngested {} -> pure ()
                DeliveryEcho {} -> pure ()
                EchoUnmatched -> pure ()
        EvPoke pk -> onPoke mIntent pk
        -- Auto-approve friend requests: being friends is what makes
        -- private query delivery (silent commands) reliable on QQ —
        -- NapCat has no API to *initiate* friendships, so we accept
        -- every incoming one instantly instead.
        EvFriendRequest flag (UserId uidRaw) -> do
          logInfo "friend request: auto-approving" $ object ["user_id" .= uidRaw]
          sendAction (SetFriendAddRequest flag True)
      loop

-- | Persistence runs before any dispatch decision, so it re-derives
-- "is this a command" from the same parser 'classify' uses rather than
-- waiting for the trigger — the DB lookup 'classify' needs for
-- reply-to-bot has nothing to do with it.  A malformed command counts:
-- it still looks like one to the reader, and it gets an error reply
-- rather than an answer.
persist :: (Log :> es, WithConnection :> es, IOE :> es) => T.Text -> Value -> GroupMessage -> Eff es IngestOutcome
persist source raw gm =
  trySync persistOne >>= \case
    Right outcome -> pure outcome
    Left e -> do
      let message = T.pack (show e)
      logAttention "db insert failed" $
        object ["error" .= message]
      pure (IngestFailed message)
  where
    persistOne
      | source == "qq" = do
          endpoint <- ensureQQEndpoint gm
          received <- liftIO getCurrentTime
          let (kind, rewritten) = recordAs gm
              contentSegments = case (kind, rewritten) of
                (KindChat, Just _) -> stripVerb gm.message
                _ -> gm.message
              options =
                defaultIngestOptions
                  { transcriptKind = renderMessageKind kind,
                    qqProvenanceSegments = Just (toJSON gm.message)
                  }
              envelope = (qqEnvelope endpoint received raw gm) {content = qqIngestBody contentSegments}
          ingestEnvelope options envelope >>= \case
            Ingested fresh -> do
              logInfo "QQ event ingested" $
                object
                  [ "canonical_message_id" .= fresh.canonicalMessageId,
                    "content" .= digest fresh.canonicalBody
                  ]
              pure (IngestDurable fresh.canonicalMessageId)
            AlreadyIngested _ -> pure IngestDuplicate
            DeliveryEcho _ -> pure IngestDuplicate
            EchoUnmatched -> pure IngestDuplicate
      | otherwise = error ("non-QQ event entered the OneBot ingress queue: " <> T.unpack source)

-- | Recover the commit-to-runtime crash window.  The source adapter may call
-- 'processCanonicalDispatch' immediately, but this worker is the authority:
-- every pending row remains discoverable after process death and one lease
-- winner evaluates its trigger eligibility.
dispatchPendingWorker ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  T.Text ->
  FetchSignal ->
  Maybe IntentState ->
  Eff es ()
dispatchPendingWorker workerId fetchSig mIntent = localDomain "dispatch" loop
  where
    loop = do
      claims <-
        claimOrWait DispatchWork $
          claimDispatches workerId dispatchBatchSize dispatchLeaseSeconds
      forM_ claims (runDispatchClaim workerId fetchSig mIntent)
      loop

processCanonicalDispatch ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  T.Text ->
  FetchSignal ->
  Maybe IntentState ->
  CanonicalMessageId ->
  Eff es ()
processCanonicalDispatch workerId fetchSig mIntent canonical =
  claimDispatch workerId canonical dispatchLeaseSeconds >>= mapM_ (runDispatchClaim workerId fetchSig mIntent)

runDispatchClaim ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  T.Text ->
  FetchSignal ->
  Maybe IntentState ->
  DispatchClaim ->
  Eff es ()
runDispatchClaim workerId fetchSig mIntent claim =
  trySync
    ( do
        mentionPrincipals <- mentionPrincipalsFor (mentionIdentities claim.body)
        let message = dispatchMessage mentionPrincipals claim
        enqueueImages fetchSig message
        enqueueForwards fetchSig message
        enqueueFiles fetchSig message
        onDispatchMessage (Just owner) mIntent message
    )
    >>= \case
      -- Only the paths that finished the work here settle the row.  A turn
      -- takes the row with it (issue #17.D): this used to mark the message
      -- answered the moment the dispatch async was forked, so a turn that
      -- crashed, was killed, or lost a drain took the question with it, and a
      -- message deferred behind a running turn had nowhere to be recorded.
      Right ClaimSettledHere -> void (completeDispatch workerId claim.canonicalMessageId claim.attemptCount DispatchCompleted)
      Right ClaimHandedToTurn -> pure ()
      Left e -> failClaim (T.pack (show (e :: SomeException)))
  where
    owner = DispatchOwner workerId claim.canonicalMessageId claim.attemptCount
    failClaim err = do
      now <- liftIO getCurrentTime
      let retryAt = addUTCTime (dispatchRetrySeconds claim.attemptCount) now
      logAttention "canonical dispatch failed" $
        object
          [ "canonical_message_id" .= claim.canonicalMessageId,
            "attempt" .= claim.attemptCount,
            "error" .= err
          ]
      void (completeDispatch workerId claim.canonicalMessageId claim.attemptCount (DispatchRetry err retryAt))

-- | Runtime view of the canonical claim. No transport event or legacy
-- segment projection exists beyond the QQ ingress boundary.
dispatchMessage :: Map.Map PrincipalIdentityId PrincipalId -> DispatchClaim -> DispatchMessage
dispatchMessage mentionPrincipals claim =
  DispatchMessage
    { selfId = UserId claim.compatibilitySelfId,
      groupId = GroupId claim.compatibilityConversationId,
      userId = UserId claim.compatibilityUserId,
      selfPrincipalId = claim.selfPrincipalId,
      authorPrincipalId = claim.authorPrincipalId,
      canonicalId = claim.canonicalMessageId,
      body = claim.body,
      replyTo = CanonicalMessageId <$> claim.replyToCanonicalMessageId,
      senderDisplayName = claim.senderDisplayName,
      sourcePlatform = claim.sourcePlatform,
      mentionPrincipals
    }

dispatchBatchSize :: Int
dispatchBatchSize = 32

dispatchLeaseSeconds :: NominalDiffTime
dispatchLeaseSeconds = 120

dispatchRetrySeconds :: Int -> NominalDiffTime
dispatchRetrySeconds attempts = fromIntegral (min (300 :: Int) (2 ^ min 8 (max 0 attempts)))

onDispatchMessage ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  -- | The dispatch row behind this message, when the caller holds its claim.
  Maybe DispatchOwner ->
  Maybe IntentState ->
  DispatchMessage ->
  Eff es ClaimDisposition
onDispatchMessage owner mIntent gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "content" .= digest gm.body
      ]
  -- Cheap pure pass first; only when it says "not addressed" AND the
  -- message quotes something do we pay a PK lookup to see whether
  -- the quoted message was ours (reply-to-bot counts as addressing).
  trig <- case classifyDispatch False gm of
    TriggerNone
      | Just (CanonicalMessageId rid) <- gm.replyTo -> do
          mQuoted <- fetchMessageInScope (conversationScopeFor gm.groupId) rid
          pure $ case mQuoted of
            Just quoted | quoted.fromBot -> classifyDispatch True gm
            _ -> TriggerNone
    t -> pure t
  -- Any addressed trigger stamps the gate's followup hot window.  The
  -- pending intent buffer is NOT cleared here: that happens inside
  -- 'dispatchLLM' at the moment a turn commits to building context —
  -- only then do the buffered messages actually reach a model as
  -- ambient text.  Clearing on every command was a hole: a pending
  -- "max帮我看看" (no @) was silently swallowed by an unrelated
  -- @!status@, which feeds no model at all.
  let noteActivity = for_ mIntent $ \st -> liftIO (noteBotActivity st gm.groupId)
  case trig of
    -- Not addressed: hand the message to the intent classifier —
    -- maybe the bot wants to join in anyway.
    TriggerNone -> settledHere (for_ mIntent $ \st -> liftIO (enqueueIntent st gm))
    TriggerPong -> settledHere (noteActivity >> sendPong gm)
    TriggerCommand body -> settledHere (noteActivity >> dispatchCommand mIntent gm body)
    TriggerCommandError err -> settledHere (replyText gm ("命令解析失败:\n" <> err))
    -- The one path that outlives this call: the turn it starts owns the row
    -- from here, and settles it when it knows what happened.
    TriggerLLM _ -> do
      noteActivity
      dispatchLLM owner mIntent OriginDirect MayAbsorb [] gm
      pure ClaimHandedToTurn
  where
    settledHere act = act >> pure ClaimSettledHere

classifyDispatch :: Bool -> DispatchMessage -> Trigger
classifyDispatch repliesToBot gm =
  let stripped = T.strip (dispatchTextWithoutSelf gm)
      addressed =
        dispatchMentionsSelf gm
          || repliesToBot
          || isPrivateChat gm.groupId
   in case parseCommand stripped of
        Right (Just _) -> TriggerCommand stripped
        Left err -> TriggerCommandError err
        Right Nothing
          | not addressed -> TriggerNone
          | otherwise -> case stripped of
              "ping" -> TriggerPong
              _ -> TriggerLLM stripped

-- | A 戳一戳 aimed at the bot: a contentless direct wake, the soft
-- version of an @.  If the group already has a running turn the poke
-- reads as a nudge and goes into its feedback inbox; otherwise it
-- starts a normal dispatch with 'OriginPoke' so the prompt says
-- honestly who poked (and that there is no message).  Pokes between
-- other members, and echoes of the bot's own outbound pokes, are
-- ignored.
onPoke ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  PokeEvent ->
  Eff es ()
onPoke mIntent pk
  | pk.pkTargetId /= pk.pkSelfId || pk.pkUserId == pk.pkSelfId = pure ()
  | otherwise = do
      env :: BotEnv <- ask
      let GroupId gidRaw = pk.pkGroupId
          UserId pokerRaw = pk.pkUserId
      logInfo "poked" $ object ["group_id" .= gidRaw, "user_id" .= pokerRaw]
      -- Stamp the followup hot window; the pending buffer survives —
      -- an injected poke feeds no model, so 'dispatchLLM' clears it
      -- only when the fallback dispatch actually builds context.
      for_ mIntent $ \st -> liftIO (noteBotActivity st pk.pkGroupId)
      -- Best-effort display name for the poker (groups only; the
      -- private-chat peer needs no introduction).
      mName <-
        if isPrivateChat pk.pkGroupId
          then pure Nothing
          else do
            members <- fetchGroupMembers pk.pkGroupId
            pure (memberName <$> (find (\m -> m.mUserId == pk.pkUserId) =<< members))
      let pokerName = fromMaybe (T.pack (show pokerRaw)) mName
      -- A poke has no content for the classifier to judge, so it takes
      -- the same route an explicit !feedback does: into whatever turn
      -- the group has running, whoever started it.  Nothing running →
      -- a dispatch of its own.
      --
      -- It goes in as an annotation rather than a steer: a poke says
      -- somebody is there, not what to do differently, and reading it
      -- as an instruction can only make the turn change course toward
      -- nothing in particular.
      landed <-
        liftIO $
          pushToLatest
            env.beTasks
            pk.pkGroupId
            Nothing
            Nothing
            (Note (pokerName <> " 戳了戳你") Nothing NoteAmbient)
      case landed of
        Just (TaskId into) ->
          logInfo "poke: injected into running task" $
            object ["group_id" .= gidRaw, "task" .= into]
        Nothing -> do
          -- A poke is a real interaction that never went through ingest, so
          -- both parties may still lack a principal here.
          endpoint <- ensureQQEndpointFor pk.pkSelfId pk.pkGroupId
          let UserId selfRaw = pk.pkSelfId
          principals <-
            ensureEndpointPrincipals
              endpoint.endpointId
              ( Map.fromList
                  [ (NativeUserId (tshow selfRaw), Just "max"),
                    (NativeUserId (tshow pokerRaw), mName)
                  ]
              )
          case ( Map.lookup (NativeUserId (tshow selfRaw)) principals,
                 Map.lookup (NativeUserId (tshow pokerRaw)) principals
               ) of
            (Just selfPrincipal, Just pokerPrincipal) ->
              dispatchLLM Nothing mIntent OriginPoke NeverAbsorb [] $
                pokeTrigger pk selfPrincipal pokerPrincipal mName
            _ ->
              logAttention "poke: could not resolve principals" $
                object ["group_id" .= gidRaw, "user_id" .= pokerRaw]

-- | Synthesize the platform-neutral trigger for a poke dispatch. There
-- is no real message: id 0 is the "no trigger message" sentinel —
-- nothing quotes or reacts to it, and 'Max.Tasks.beginDispatch' reads
-- it as no trigger rather than as an id every poke shares — and the
-- body is empty ('OriginPoke' rendering never shows it).
pokeTrigger :: PokeEvent -> PrincipalId -> PrincipalId -> Maybe T.Text -> DispatchMessage
pokeTrigger pk selfPrincipal senderPrincipal mName =
  DispatchMessage
    { selfId = pk.pkSelfId,
      groupId = pk.pkGroupId,
      userId = pk.pkUserId,
      selfPrincipalId = selfPrincipal,
      authorPrincipalId = senderPrincipal,
      canonicalId = CanonicalMessageId 0,
      body = Body [],
      replyTo = Nothing,
      senderDisplayName = mName,
      sourcePlatform = PlatformQQ,
      mentionPrincipals = Map.empty
    }

--------------------------------------------------------------------------------
-- Commands.

dispatchCommand ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  DispatchMessage ->
  T.Text ->
  Eff es ()
dispatchCommand mIntent gm body = localDomain "cmd" $ do
  case parseCommand body of
    Left err -> replyText gm ("命令解析失败:\n" <> err)
    Right Nothing -> pure () -- shouldn't reach here; classify already filtered
    Right (Just cmd) -> do
      env :: BotEnv <- ask
      let sourcePlatform = gm.sourcePlatform
      targetGid <- resolveAdminTarget env gm cmd
      effTier <- effectiveTier env targetGid gm
      let allowed = checkCmdPermission effTier cmd
      if not allowed
        then do
          let UserId uidRaw = gm.userId
          logInfo "command denied" $
            object ["cmd" .= T.pack (show cmd), "user_id" .= uidRaw]
          if isForeignSource sourcePlatform
            then replyText gm "没有权限"
            else
              -- Same NO face as [silence:NO]: visibly refused, zero noise.
              queueQQReaction gm.groupId gm.canonicalId deniedFaceId True
        else dispatchAllowed env targetGid sourcePlatform cmd
  where
    isForeignSource = (/= PlatformQQ)

    dispatchAllowed env targetGid sourcePlatform cmd = do
      t <- loadSession env.beSessions env.beDefaultModel targetGid
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      let replyTarget = (\(CanonicalMessageId target) -> target) <$> gm.replyTo
      result <- CmdDispatch.execute t targetGid gm.userId gm.authorPrincipalId replyTarget cmd
      case result of
        -- In a group, textual command output (queries, error texts)
        -- goes to the sender's DMs — the group only sees an OK
        -- reaction.  Private chats reply inline as before.  When the
        -- DM can't be delivered (not friends; QQ throttles temp
        -- sessions), fall back to the group with a befriend hint.
        ReplyText reply
          | isPrivateChat gm.groupId || isForeignSource sourcePlatform -> replyText gm reply
          | otherwise -> deliverPrivate reply
        -- Deliberately group-audience output (e.g. !version).
        ReplyPublicText reply -> replyText gm reply
        -- Pure acknowledgement: an OK reaction on the command message
        -- beats another line of chat noise.
        ReplyAck
          | isForeignSource sourcePlatform -> replyText gm "OK"
          | otherwise -> queueQQReaction gm.groupId gm.canonicalId ackFaceId True
        SideQuestion askBody -> do
          logInfo "btw: side question" $
            object ["len" .= T.length askBody]
          -- Dispatch the message itself with only the !btw verb
          -- stripped — the same form 'recordAs' persisted.  Keeping
          -- the original segments is the point: a @!btw@ typed as a
          -- reply keeps its quote (buildContext reads the reply
          -- target out of the segments), and attached images keep
          -- their markers.  An earlier version rebuilt the segment
          -- list from the parsed body and silently dropped both.
          dispatchLLM Nothing mIntent OriginDirect NeverAbsorb [] (stripDispatchVerb gm)
        -- !feedback: aim the note at the turn whose trigger the user
        -- replied to, and at the newest running turn otherwise — a
        -- reply to something that isn't a live turn (mis-click, a turn
        -- that has since finished) falls through rather than erroring,
        -- because a note that refuses to land ends up in nobody's
        -- context at all.  Nothing running is not an error either: the
        -- note is a question somebody asked the bot, so answer it as
        -- one — a fresh dispatch, absorbable so that a turn starting
        -- in the race window can still take it.  The one dead end is a
        -- @!use@-redirected note (a DM steering a group task) with no
        -- task to steer: a turn in the DM isn't what was asked for,
        -- so that alone keeps the failure face.
        FeedbackNote noteBody -> do
          noteAt <- liftIO getCurrentTime
          let line = renderCurrentLine env.beTimeZone noteAt (gm {Dispatch.body = Body [NText noteBody]})
              -- The !feedback message records as chat (verb stripped),
              -- so it is a visible question in the transcript with the
              -- answer threaded at someone else's message.  Mark it
              -- absorbed for the lifetime of the turn that took it, or
              -- a concurrent dispatch answers it a second time — the
              -- implicit path has needed this all along.
              CanonicalMessageId noteMid = gm.canonicalId
              absorb = Just noteMid
              -- A reply target only means something in the chat it was
              -- typed in: under a !use redirect the quoted mid belongs
              -- to the DM, and aiming it at the target group's turns
              -- could only ever miss.
              redirected = targetGid /= gm.groupId
              -- The source is the same stripped shape the
              -- nothing-running fallback below dispatches — a turn
              -- that dies without serving the note falls back to
              -- exactly that.  Not under a redirect: a DM turn isn't
              -- the group task that was being steered.
              -- A steer by construction: the user typed the verb.  The
              -- classifier is never consulted here and never should be —
              -- an explicit instruction that gets demoted to background
              -- because a router disagreed is the one failure that would
              -- make the explicit half untrustworthy.
              note =
                Note
                  line
                  (if redirected then Nothing else Just (stripDispatchVerb gm))
                  NoteSteer
          aimed <- case replyTarget of
            Just tgt | not redirected -> liftIO (pushToTrigger env.beTasks targetGid Nothing absorb tgt note)
            _ -> pure Nothing
          landed <- case aimed of
            Just _ -> pure aimed
            Nothing -> liftIO (pushToLatest env.beTasks targetGid Nothing absorb note)
          case landed of
            Just (TaskId into) -> do
              logInfo "feedback: explicit note" $
                object ["task" .= into, "aimed" .= isJust replyTarget]
              -- 托腮, not OK: the note is queued for a turn that may
              -- or may not still drain it, so the honest claim is
              -- "being chewed on", the same face the turn's own
              -- trigger wears.  The absorbing turn takes it back off
              -- when it ends (see the 'absorbedTriggers' sweep in
              -- 'dispatchLLM').
              queueQQReaction gm.groupId gm.canonicalId processingFaceId True
            Nothing
              | redirected -> do
                  let GroupId targetRaw = targetGid
                  logInfo "feedback: nothing running in redirect target" $
                    object ["group_id" .= targetRaw]
                  queueQQReaction gm.groupId gm.canonicalId failureFaceId True
              | otherwise -> do
                  logInfo "feedback: nothing running, answering as a turn" $
                    object ["len" .= T.length noteBody]
                  dispatchLLM Nothing mIntent OriginDirect MayAbsorb [] (stripDispatchVerb gm)

    -- Recorded against the DM's pseudo-group rather than the group the
    -- command came from: that is the conversation it actually appeared
    -- in, and the record follows the chat.
    deliverPrivate reply = do
      let GroupId gidRaw = gm.groupId
          UserId uidRaw = gm.userId
          header = "（群 " <> T.pack (show gidRaw) <> " 的命令结果）\n"
      outcome <-
        sendRecorded
          OutboundRequest
            { orKind = KindCommand,
              orGroupId = GroupId (negate uidRaw),
              orBody = Body [NText (header <> reply)],
              orReplyTo = Nothing,
              orDeliveryScope = DeliverConversation,
              orTurnOutput = Nothing,
              orMonitorFireId = Nothing
            }
      if wasDelivered outcome
        then queueQQReaction gm.groupId gm.canonicalId ackFaceId True
        else do
          logInfo "cmd: private delivery failed, group fallback" $
            object ["user_id" .= uidRaw, "group_id" .= gidRaw]
          replyText gm (reply <> "\n\n（加我好友后，这类结果会私聊发你，不刷群）")

--------------------------------------------------------------------------------
-- LLM dispatch.

-- | @ping@ is an ordinary exchange that happens not to cost an LLM
-- call, so it records as 'KindChat' — the trigger is in the transcript
-- and an answer that wasn't would read as a question nobody answered.
sendPong ::
  (Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  DispatchMessage ->
  Eff es ()
sendPong gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      display = fromMaybe (tshow fromRaw) gm.senderDisplayName
  resolved <-
    if isPrivateChat gm.groupId
      then pure Map.empty
      else resolveMentionIdentities gidRaw [gm.authorPrincipalId]
  let mention =
        [ NMention (MentionIdentity identity) display
        | Just identity <- [Map.lookup gm.authorPrincipalId resolved]
        ]
  sendAndRecord KindChat DeliverConversation gm.groupId (Body (mention <> [NText " pong"])) (Just gm.canonicalId)
  logInfo "replied pong" $ object ["to" .= fromRaw, "group_id" .= gidRaw]

-- | Entry point for the intent worker: dispatch a batch of messages
-- nobody @-ed at the bot (chronological, newest last), with the
-- prompt honestly labelled as a proactive turn (and @[silence]@
-- explicitly on the table).  The newest message is the trigger — a
-- fresh turn sees the rest as ambient history anyway — and the
-- earlier ones ride along as companions so that an absorbed batch
-- reaches the running turn whole.  Absorbable like a direct trigger:
-- an unaddressed followup landing while a turn is still running
-- steers that turn, it doesn't talk over it.
dispatchProactive ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  [DispatchMessage] ->
  Eff es ()
dispatchProactive mIntent batch = case unsnoc batch of
  Nothing -> pure ()
  Just (older, trigger) ->
    dispatchLLM Nothing mIntent OriginProactive MayAbsorb older trigger

-- | Cross the durable monitor-fire boundary into one ordinary horizon-1
-- turn.  Role and schedule are revalidated before the admission transaction;
-- after that transaction succeeds, the linked turn is the only continuation
-- and boot recovery resumes it instead of minting another.
dispatchMonitorFire ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  ElaboratedMonitorFire ->
  Eff es ()
dispatchMonitorFire fire = case fire.emfClaimOwner of
  Nothing -> pure ()
  Just owner -> do
    seedClaim <- maybe (pure Nothing) loadDispatchClaim fire.emfSeedCanonicalMessage
    case seedClaim of
      Nothing -> expire owner "arming principal no longer has an inbound dispatch seed"
      Just claim -> do
        principals <- mentionPrincipalsFor (mentionIdentities claim.body)
        let seed = dispatchMessage principals claim
        if seed.groupId /= GroupId fire.emfGroupId || seed.authorPrincipalId /= fire.emfArmedByPrincipal
          then expire owner "arming principal provenance no longer resolves in this conversation"
          else do
            env :: BotEnv <- ask
            tier <- effectiveTier env seed.groupId seed
            if not (roleStillAllows fire.emfRequiredRole tier)
              then expire owner "arming principal role no longer permits monitors"
              else do
                now <- liftIO getCurrentTime
                nextAt <- case fire.emfCron of
                  Nothing -> pure (Right Nothing)
                  Just expression -> case parseCronSchedule expression of
                    Left err -> pure (Left ("invalid persisted cron: " <> T.pack err))
                    Right schedule -> pure (Right (nextCronFire env.beTimeZone schedule now))
                case nextAt of
                  Left err -> expire owner err
                  Right maybeNext -> do
                    admitted <- admitElaboratedMonitorTurn owner fire.emfFireId maybeNext
                    for_ admitted $ \turn -> launchMonitorTurn Nothing turn fire
  where
    expire owner reason = do
      expired <- expireElaboratedMonitorFire owner fire.emfFireId reason
      when expired $
        logAttention "monitor: elaborated fire expired at revalidation" $
          object
            [ "monitor" .= monitorHandleText fire.emfMonitor.mrMonitorOrdinal,
              "reason" .= reason
            ]

roleStillAllows :: T.Text -> PermTier -> Bool
roleStillAllows required actual = case required of
  "owner" -> tierSatisfied TierOwner actual
  "group_admin" -> tierSatisfied TierGroupAdmin actual
  _ -> False

renderMonitorFireView :: ElaboratedMonitorFire -> T.Text
renderMonitorFireView fire =
  T.intercalate
    "\n"
    [ "[monitor fire — " <> monitorHandleText fire.emfMonitor.mrMonitorOrdinal <> "]",
      "goal: " <> T.take 4000 fire.emfGoal,
      "trigger: " <> fire.emfTriggerKind <> " at " <> tshow fire.emfScheduledAt,
      "evidence: " <> T.take 1600 fire.emfTriggerEvidence
    ]

launchMonitorTurn ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe T.Text ->
  AgentTurnRef ->
  ElaboratedMonitorFire ->
  Eff es ()
launchMonitorTurn recoveryView turn fire = do
  seedClaim <- maybe (pure Nothing) loadDispatchClaim fire.emfSeedCanonicalMessage
  case seedClaim of
    Nothing -> ensureAgentTurnCrashed turn "monitor arming principal seed is missing"
    Just claim -> do
      principals <- mentionPrincipalsFor (mentionIdentities claim.body)
      let seed = dispatchMessage principals claim
      if seed.groupId /= GroupId fire.emfGroupId || seed.authorPrincipalId /= fire.emfArmedByPrincipal
        then ensureAgentTurnCrashed turn "monitor arming principal seed changed scope"
        else do
          let triggerId = fromMaybe (CanonicalMessageId 0) fire.emfTriggerCanonicalMessage
              trigger =
                seed
                  { canonicalId = triggerId,
                    body = Body [],
                    replyTo = Nothing,
                    mentionPrincipals = Map.empty
                  }
          dispatchLLMWith
            (Just turn)
            recoveryView
            (Just (renderMonitorFireView fire))
            (Just fire.emfEffectToolGrants)
            Nothing
            Nothing
            Nothing
            OriginMonitor
            NeverAbsorb
            []
            trigger

--------------------------------------------------------------------------------
-- ADR 007 step 11: driving a suspended plan

-- | The effectful half of "Max.Plan.Worker".
--
-- Everything here needs the dispatch row, which is why the worker takes it as
-- an argument rather than doing any of it: the decision about a parked plan is
-- pure and lives in "Max.Plan.Drive", and this is the four things acting on
-- that decision requires the whole bot for.
planDriverFor ::
  ( Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  PlanDriver es
planDriverFor runtime =
  PlanDriver
    { pdSpawn = spawnChild,
      pdStop = stopChild,
      pdResume = resumeSuspended runtime,
      pdWake = wakeOwner
    }

-- | The trigger a plan's turns are dispatched against.
--
-- The plan's own seed message, re-read rather than remembered: it is the same
-- construction 'launchMonitorTurn' uses, and for the same reason — a turn needs
-- real provenance in a real conversation, and the only honest source of one is
-- the message that started all this.  Body emptied, because nothing the seed
-- said is what this turn is about; the host-authored view is.
planSeedTrigger ::
  (WithConnection :> es, IOE :> es) =>
  WakeablePlan ->
  Eff es (Maybe DispatchMessage)
planSeedTrigger plan = case plan.wpSeedMessage of
  Nothing -> pure Nothing
  Just messageId -> do
    mClaim <- loadDispatchClaim (CanonicalMessageId messageId)
    case mClaim of
      Nothing -> pure Nothing
      Just claim -> do
        principals <- mentionPrincipalsFor (mentionIdentities claim.body)
        let seed = dispatchMessage principals claim
        pure $
          if seed.groupId /= plan.wpGroup
            then Nothing
            else Just seed {body = Body [], replyTo = Nothing, mentionPrincipals = Map.empty}

-- | Open a turn for one subgoal, record the spawn edge, and let it run.
--
-- The order is the durability: the edge exists before the turn is dispatched,
-- so a crash between them leaves a child the reconciler can see rather than a
-- turn nobody owns.  It also takes the plan out of the wakeable set
-- immediately, which is what stops a second claim dispatching the same subgoal.
spawnChild ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  WakeablePlan ->
  Dispatchable ->
  Eff es (Maybe AgentTurnId)
spawnChild plan item = do
  env :: BotEnv <- ask
  mTrigger <- planSeedTrigger plan
  case mTrigger of
    Nothing -> do
      logAttention "plan: cannot open a child without the plan's seed message" $
        object ["plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId, "node" .= desired.dsNode.unNodeId]
      pure Nothing
    Just trigger -> do
      let view = renderSubgoalView plan item
          grants = childGrants env plan item
      mChild <-
        startClaimedPlanChild
          plan
          plan.wpPlan.stRootTurn
          trigger.canonicalId
          trigger.authorPrincipalId
          desired.dsHash
          desired.dsNode.unNodeId
          desired.dsGoal
          view
          grants
          item.dpInputs
      for_ mChild $ \child -> do
        logInfo "plan: child opened" $
          object
            [ "plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId,
              "node" .= desired.dsNode.unNodeId,
              "child_turn" .= child.atrTurnOrdinal.unTurnOrdinal,
              "inputs" .= [binder.unBinder | (binder, _) <- item.dpInputs]
            ]
        dispatchLLMWith
          (Just child)
          Nothing
          (Just view)
          (Just grants)
          (Just (ChildDispatch desired.dsGoal view grants item.dpInputs False))
          Nothing
          Nothing
          OriginPlan
          NeverAbsorb
          []
          trigger
      pure ((.atrTurnId) <$> mChild)
  where
    desired = item.dpDesired

-- | What a fork child may touch: the tools a plan itself may call, the one way
-- it hands its answer back, and the two that let it delegate in turn.
--
-- Working tools come only from plannable catalog entries whose declared
-- effects and authorities fit the Goal, intersected with both the exact catalog
-- stored on the parent plan and the definitions this binary currently exposes.
-- The return tool is host-minted; guide/run are administrative delegation tools
-- and survive only when the parent held their exact grants. Nothing in this set
-- sends, so a child cannot speak.
--
-- __A child may plan, and therefore may fork.__  ADR 007 §12.  Nothing in the
-- machinery distinguishes a plan opened by a child from one opened by the front
-- model — 'openPlan' takes its conversation from the turn either way, and the
-- spawn edge from a grandchild names the child's turn as its parent.  The one
-- thing that has to be true is that a child which parked a plan is not counted
-- as decided, which is a property of the query that finds running children
-- rather than of anything here.
childGrants :: BotEnv -> WakeablePlan -> Dispatchable -> Map.Map T.Text T.Text
childGrants env plan item =
  Map.fromList
    [ (definition.tdRef.unToolRef, toolCatalogFingerprint [definition])
    | definition <- definitions,
      allowed definition
    ]
  where
    goal = item.dpDesired.dsGoal
    caps =
      TurnCapabilities
        True
        False
        False
        noAdvertisedCaps
        False
        Map.empty
        (Just plan.wpPlan.stToolGrants)
        (Just (SubgoalReturn (AgentTurnId 0) goal item.dpInputs))
    definitions = toolDefinitionsFor env plan.wpGroup caps
    parentAllows definition =
      Map.lookup definition.tdRef.unToolRef plan.wpPlan.stToolGrants
        == Just (toolCatalogFingerprint [definition])
    -- Authorities come off the definition either way; only the effects needed
    -- a judgement, and it is now one a tool can receive without anybody having
    -- written down what it returns (issue #17.E).
    reachable definition effects =
      Set.isSubsetOf effects goal.goalBudget.ebEffects
        && Set.isSubsetOf definition.tdAuthorities goal.goalAuthority
    allowed definition
      | definition.tdRef == ToolRef "subgoal_return" = True
      | not (parentAllows definition) = False
      | definition.tdRef `elem` [ToolRef "plan_guide", ToolRef "plan_run"] = True
      | otherwise = maybe False (reachable definition) (childReachableEffects definition)

-- | What a child is told, which is "Max.Plan.Brief"'s business rather than this
-- module's: the words are the artifact under test, and answering what a real
-- model does with them should not require standing up a bot.
renderSubgoalView :: WakeablePlan -> Dispatchable -> T.Text
renderSubgoalView plan =
  subgoalBrief (fromIntegral plan.wpPlan.stRef.prOrdinal.unPlanOrdinal)

isolatedChildSystem :: T.Text
isolatedChildSystem =
  T.unlines
    [ "你正在执行一个隔离的、有限预算的子任务。",
      "你看不到聊天、人格、记忆、父计划或其他子任务；下面提供的 Goal 和输入就是全部上下文。",
      "不得把普通文字当作结果：所有进度和最终 prose 都不会展示给任何人。",
      "完成后必须调用 subgoal_return，且返回值严格符合它的 schema。",
      "工具或资料不足时也不要猜造外部事实；在允许的结果类型内明确表达限制。"
    ]

discardChildEvent :: Applicative m => AgentEvent a -> m a
discardChildEvent = \case
  AgentProgressText _ -> pure ()
  AgentToolDebug _ -> pure ()
  AgentFinalStreamText _ -> pure False

stopChild ::
  (Log :> es, WithConnection :> es, Reader BotEnv :> es, IOE :> es) =>
  WakeablePlan ->
  AgentTurnId ->
  Eff es ()
stopChild plan child = do
  env :: BotEnv <- ask
  durable <- requestClaimedChildCancellation plan child
  stopped <- if durable then liftIO (cancelAgentTurnTask env.beTasks child) else pure False
  logInfo "plan: child no longer wanted" $
    object
      [ "plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId,
        "child_turn" .= child.unAgentTurnId,
        -- False is not a failure: the child may have finished a moment ago, or
        -- be running on another process.  Saying which is all this can do.
        "killed_here" .= stopped,
        "cancelled_durably" .= durable
      ]

-- | Continue a parked walk with the tools it would have had inline.
--
-- The turn identity is synthesized, and the honest description of it is that a
-- resume has no author: nobody said anything, and the conversation is the only
-- part of "who is asking" that still means something.  The plannable set is
-- read-only conversation tools, so what is left blank here is what none of them
-- consult.
resumeSuspended ::
  ( Blob :> es,
    Http :> es,
    Embedding :> es,
    Log :> es,
    Concurrent :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  HttpRuntime ->
  WakeablePlan ->
  ExecState ->
  Eff es Resumption
resumeSuspended runtime plan state = do
  env :: BotEnv <- ask
  handle <- loadSession env.beSessions env.beDefaultModel plan.wpGroup
  s <- liftIO (readSession handle)
  childContract <- loadChildDispatch plan.wpPlan.stRootTurn
  let child = case childContract of
        Just (Right contract) -> Just contract
        _ -> Nothing
      contractError = case childContract of
        Just (Left detail) -> Just detail
        _ -> Nothing
      requested = planResourceHandles ((.cdGoal) <$> child) plan.wpPlan.stDocument.pdPlan
  bodies <-
    Map.fromList . catMaybes
      <$> traverse
        (\resource -> fmap ((resource,) <$>) (resolveJournalResultValue (conversationScopeFor plan.wpGroup) s.clearedAt resource))
        requested
  let caps =
        TurnCapabilities
          False
          False
          False
          noAdvertisedCaps
          False
          plan.wpPlan.stToolGrants
          (Just plan.wpPlan.stToolGrants)
          Nothing
      identity =
        TurnIdentity
          plan.wpGroup
          (CanonicalMessageId (fromMaybe 0 plan.wpSeedMessage))
          (UserId 0)
          (UserId 0)
          (fromMaybe (PrincipalId 0) plan.wpInitiator)
          s.clearedAt
          Nothing
      toolCtx = mkToolContext identity caps
      definitions = toolDefinitionsFor env plan.wpGroup caps
      document = plan.wpPlan.stDocument
      -- Cosmetic: the objective only reaches prompt text, and on this path
      -- there is no prompt.  What the environment actually decides — the
      -- ceiling, the expected result type, the plannable catalog — does not
      -- depend on it.
      subgoal = (\contract -> SubgoalReturn plan.wpPlan.stRootTurn contract.cdGoal contract.cdInputs) <$> child
      baseVenv = validationEnvForContract (planCatalog definitions) document.pdRoot subgoal bodies
      venv = maybe baseVenv (\goal -> baseVenv {venGoal = goal}) plan.wpPlan.stRootGoal
  case contractError of
    Just detail -> pure (Worker.Stopped ("子任务的恢复契约读不回来：" <> detail))
    Nothing -> case plannableToolsFor runtime env toolCtx of
      Left err ->
        pure (Worker.Stopped ("这一轮拿不到工具：" <> T.pack (show err)))
      Right catalog -> case validatePlan venv document.pdRoot document.pdPlan of
        -- The plan was admissible when it was written and is not now: a tool it
        -- names has been gated off, or the ceiling moved.  A real answer, and the
        -- only one that does not run a plan nobody admitted.
        Left rejection -> pure (Worker.Stopped ("计划现在过不了校验了：" <> rejectionText rejection))
        Right valid -> do
          result <-
            runToolOutput defaultInlineMediaLimit . runTools catalog $
              resumePlan
                ExecutionEnv {exValidation = venv, exHandles = Map.restrictKeys bodies (Map.keysSet venv.venHandles), exRoot = document.pdRoot}
                valid
                state
          pure $ case result.erEnd of
            Produced value -> Worker.Produced value
            Deoptimized (AtFork node _ _ _) -> Worker.Parked node.unNodeId (toJSON result.erState)
            Deoptimized deopt -> Worker.Stopped (deoptText deopt)

-- | Tell whoever owns the plan how it came out, in a turn of their own.
--
-- The plan does not speak; a model does.  What arrives here is a value or a
-- reason, and the turn this opens is an ordinary one that happens to start with
-- the host saying what happened — the same construction a monitor fire uses,
-- because it is the same situation: nobody said anything, and something in the
-- world is worth a reply.
wakeOwner ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  WakeablePlan ->
  Value ->
  Eff es Bool
wakeOwner plan outcome = do
  mTrigger <- planSeedTrigger plan
  case mTrigger of
    Nothing -> do
      logAttention "plan: finished with nobody to tell" $
        object ["plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId]
      pure False
    Just trigger -> do
      -- Admission before dispatch, and admission rather than closing as the
      -- idempotency point.  A process dying after this line is recovered by the
      -- turn machinery; one dying before it drives the plan again, reaches the
      -- same result, and finds the wake already taken.
      let view = renderPlanWakeView plan outcome
      admitted <- admitClaimedPlanWake plan trigger.canonicalId trigger.authorPrincipalId view
      for_ admitted $ \turn ->
        dispatchLLMWith (Just turn) Nothing (Just view) Nothing Nothing Nothing Nothing OriginPlan NeverAbsorb [] trigger
      when (not (isJust admitted)) $
        logInfo "plan: wake already reported or lease became stale" $
          object ["plan_id" .= plan.wpPlan.stRef.prPlanId.unPlanId]
      pure (isJust admitted)

renderPlanWakeView :: WakeablePlan -> Value -> T.Text
renderPlanWakeView plan outcome =
  T.intercalate
    "\n"
    [ "[计划回来了 — 计划 #" <> tshow plan.wpPlan.stRef.prOrdinal.unPlanOrdinal <> "]",
      "你之前挂起的那个计划跑完了。结果：",
      T.take 8000 (renderPlanValue outcome),
      "",
      "这是原始结果，不是给人看的话。照上面的东西回一句就行；没什么值得说的就 [silence]。"
    ]

-- | Spawn an async to build the prompt, call the LLM, post the reply,
-- and append the (user, assistant) turn to the session history.
-- The 'TriggerOrigin' says what woke the bot — see
-- 'Max.Prompt.PromptInputs.origin'.
--
-- This is the process's only asynchronous agent-turn path (commands run
-- inline on the event loop; Historian is a supervised background worker), so
-- it is also where graceful shutdown gates: once draining,
-- new triggers are logged and dropped rather than started.  See
-- "Max.Shutdown".
-- | Who is responsible for the dispatch row once 'onDispatchMessage' returns.
--
-- Only the LLM path hands it on: everything else — a command, a pong, a
-- message the classifier merely buffered — finished its work inside the call,
-- so the claim loop settles it there and then.
data ClaimDisposition
  = ClaimSettledHere
  | ClaimHandedToTurn
  deriving stock (Eq, Show)

-- | The durable dispatch row a turn is answering for, the worker identity that
-- holds its lease, and which claim of that row this is.
--
-- All three are needed to settle it.  Owner alone is not enough, because a
-- worker identity is per process and per subsystem — one string for the whole
-- life of the dispatch loop — so a row this process claimed, gave up, and
-- claimed again is owned by the same name both times.  The gap is real and
-- narrow: a message deferred behind a busy conversation writes @deferred@ from
-- inside its own turn's body, and the turn ahead can release it and this
-- worker re-claim it before that first turn's epilogue unwinds.  Its
-- unconditional @DispatchCompleted@ would then land on the /new/ claim and
-- mark a question answered that nothing had yet answered — precisely the bug
-- issue #17.D set out to fix.
--
-- 'attemptCount' is the fencing token, and it costs nothing: the claim already
-- increments it and already hands it back.
data DispatchOwner = DispatchOwner
  { doWorker :: !T.Text,
    doMessage :: !CanonicalMessageId,
    doAttempt :: !Int
  }

-- | What a message arriving into a busy conversation did instead of taking a
-- turn of its own.
data BusyOutcome
  = -- | Nothing else was running; go ahead.
    BusyNoOne
  | -- | Folded into the turn already in flight, which will read it.
    BusyAbsorbed
  | -- | Not about that turn's work, so it waits for one of its own.
    BusyDeferred
  deriving stock (Eq, Show)

-- | How long a deferred message waits if nothing releases it.
--
-- A bound, not a schedule.  The turn ahead releases its deferred rows when it
-- ends, which is the precise wakeup; this only catches the row that deferred
-- itself in the window between that release and the turn leaving the registry,
-- so it wants to be short enough not to be felt and long enough not to spin.
deferredRetrySeconds :: NominalDiffTime
deferredRetrySeconds = 30

dispatchLLM ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  -- | The dispatch row being answered, when the caller holds one.
  Maybe DispatchOwner ->
  Maybe IntentState ->
  TriggerOrigin ->
  Absorbable ->
  -- | Earlier messages of the same proactive batch (chronological),
  -- steering context that must ride along in the note if this turn is
  -- absorbed.  Empty for every other origin: a direct trigger or poke
  -- is one message.
  [DispatchMessage] ->
  DispatchMessage ->
  Eff es ()
dispatchLLM = dispatchLLMWith Nothing Nothing Nothing Nothing Nothing

-- | Resume one boot-claimed turn with the immutable original trigger and a
-- bounded host-rendered journal view.  Missing or cross-conversation trigger
-- state fails closed and terminally; it never admits a replacement turn.
resumeInterruptedTurn ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  AgentTurnRecovery ->
  Eff es ()
resumeInterruptedTurn recovery = do
  case recovery.atrRecoveryMonitorFire of
    Just fireId -> do
      mFire <- loadAdmittedMonitorFire fireId
      case mFire of
        Just fire
          | fire.emfAdmittedTurn == Just recovery.atrRecoveryTurn,
            GroupId fire.emfGroupId == recovery.atrRecoveryGroupId -> do
              view <- recoveryViewForTurn recovery.atrRecoveryTurn
              launchMonitorTurn (Just view) recovery.atrRecoveryTurn fire
        _ -> ensureAgentTurnCrashed recovery.atrRecoveryTurn "restart recovery monitor fire is missing or changed scope"
    Nothing -> case recovery.atrRecoveryTrigger of
      Nothing -> ensureAgentTurnCrashed recovery.atrRecoveryTurn "restart recovery trigger is missing"
      Just trigger -> do
        mClaim <- loadDispatchClaim trigger
        case mClaim of
          Nothing ->
            ensureAgentTurnCrashed recovery.atrRecoveryTurn "restart recovery trigger is missing"
          Just claim
            | GroupId claim.compatibilityConversationId /= recovery.atrRecoveryGroupId ->
                ensureAgentTurnCrashed recovery.atrRecoveryTurn "restart recovery trigger changed conversation"
            | otherwise -> do
                principals <- mentionPrincipalsFor (mentionIdentities claim.body)
                view <- recoveryViewForTurn recovery.atrRecoveryTurn
                -- An admitted plan wake is not a reply to the seed message it
                -- was dispatched against; it happens to share its provenance.
                -- Relaunching it as an ordinary reply would answer a question
                -- that was answered turns ago and say nothing about the plan.
                planWake <- loadPlanWake recovery.atrRecoveryTurn.atrTurnId
                child <- loadChildDispatch recovery.atrRecoveryTurn.atrTurnId
                let message = dispatchMessage principals claim
                    origin
                      | isJust planWake || isJust child = OriginPlan
                      | isPrivateChat message.groupId || dispatchMentionsSelf message = OriginDirect
                      | otherwise = OriginProactive
                    trigger'
                      | isJust planWake || isJust child = message {body = Body [], replyTo = Nothing, mentionPrincipals = Map.empty}
                      | otherwise = message
                case child of
                  Just (Left detail) ->
                    ensureAgentTurnCrashed recovery.atrRecoveryTurn ("restart recovery refused child: " <> detail)
                  Just (Right contract)
                    | contract.cdCancelRequested ->
                        ensureAgentTurnCrashed recovery.atrRecoveryTurn "restart recovery refused cancelled child"
                    | otherwise ->
                        dispatchLLMWith
                          (Just recovery.atrRecoveryTurn)
                          (Just view)
                          (Just contract.cdView)
                          (Just contract.cdToolGrants)
                          (Just contract)
                          Nothing
                          Nothing
                          OriginPlan
                          NeverAbsorb
                          []
                          trigger'
                  Nothing ->
                    dispatchLLMWith
                      (Just recovery.atrRecoveryTurn)
                      (Just view)
                      planWake
                      Nothing
                      Nothing
                      Nothing
                      Nothing
                      origin
                      NeverAbsorb
                      []
                      trigger'

dispatchLLMWith ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe AgentTurnRef ->
  Maybe T.Text ->
  -- | Host-authored, budgeted monitor goal/evidence view.
  Maybe T.Text ->
  -- | Arm-time tool-name ceiling; intersected with the current catalog.
  Maybe (Map.Map T.Text T.Text) ->
  -- | Durable fork-child contract. Ordinary dispatches carry Nothing.
  Maybe ChildDispatch ->
  -- | The dispatch row this turn is answering for, when there is one.  The
  -- turn settles it rather than the claim loop, so a message is only marked
  -- answered once something actually answered it (issue #17.D).  Proactive,
  -- poke, monitor and plan-child dispatches carry Nothing: no row exists.
  Maybe DispatchOwner ->
  Maybe IntentState ->
  TriggerOrigin ->
  Absorbable ->
  [DispatchMessage] ->
  DispatchMessage ->
  Eff es ()
dispatchLLMWith existingTurn recoveryView monitorView effectCeiling childDispatch owner mIntent origin absorbable companions gm = do
  env :: BotEnv <- ask
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      CanonicalMessageId midRaw = gm.canonicalId
      ident =
        object
          [ "group_id" .= gidRaw,
            "user_id" .= fromRaw,
            "message_id" .= midRaw,
            "origin" .= T.pack (show origin),
            "recovered" .= isJust existingTurn
          ]
  outputCaps <- conversationAdvertisedCaps gidRaw (if midRaw > 0 then Just midRaw else Nothing)
  -- Claim the shutdown slot out here rather than inside the async:
  -- 'Max.Effects.Agent.agentTurn' doesn't reach its 'registerTask'
  -- until after 'Max.Prompt.buildContext', which on its own can spend
  -- 30s waiting for the trigger's images, so a drain watching only the
  -- task registry would walk straight past a dispatch sitting in that
  -- gap.  Claiming before the spawn also closes the race the other
  -- way: 'enterDispatch' and the drain flag share one transaction.
  started <- liftIO (enterDispatch env.beShutdown)
  -- Same reason the shutdown slot is claimed here: the agent loop is
  -- tens of seconds away, and until it attaches, a concurrent trigger
  -- has to be able to see this question is already taken — as do !ps
  -- and !kill.  The registry entry opens now and the loop adopts it.
  mTurn <-
    if started
      then
        ( do
            durable <-
              maybe
                (startAgentTurn gm.groupId gm.canonicalId gm.authorPrincipalId)
                pure
                existingTurn
            ( do
                runtime <- case existingTurn of
                  Nothing ->
                    liftIO (beginDurableTurnRuntime env.beTasks durable gm.groupId gm.userId (Just gm.canonicalId))
                  Just _ -> do
                    firstChunk <- nextAgentTurnOutputChunk durable.atrTurnId
                    liftIO (beginDurableTurnRuntimeAt env.beTasks durable firstChunk gm.groupId gm.userId (Just gm.canonicalId))
                pure (Just (runtime, durable))
              )
              `catchSync` \e -> do
                ensureAgentTurnCrashed durable "failed to create the in-memory turn runtime"
                liftIO (Exception.throwIO (e :: SomeException))
        )
          `catchSync` \e -> do
            liftIO (leaveDispatch env.beShutdown)
            liftIO (Exception.throwIO (e :: SomeException))
      else pure Nothing
  case mTurn of
    Nothing -> do
      for_ existingTurn $ \durable ->
        ensureAgentTurnCrashed durable "restart recovery declined during shutdown drain"
      logInfo "llm dispatch declined: draining" ident
      -- The drain can run for a couple of minutes behind a long turn,
      -- and every @ landing in that window would otherwise get total
      -- silence — the one failure mode worth being loud about.  A face
      -- says "seen, not doing it" without a line of chat noise, same
      -- as the crash and denied-command paths.  Direct triggers only:
      -- proactive turns stay traceless and a poke has no message to
      -- react to.
      when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
        queueQQReaction gm.groupId gm.canonicalId failureFaceId True
      -- No async will run, so nothing downstream will settle this row.  A
      -- drain is a restart, and the next boot should answer the question
      -- rather than find it marked done — so it is deferred, not completed.
      declinedAt <- addUTCTime deferredRetrySeconds <$> liftIO getCurrentTime
      settleOwner (DispatchDeferred declinedAt)
    Just (turn, durable) ->
      void . async $
        ( localDomain "llm" . holdingDispatchLease $ do
            logInfo "llm dispatch" ident
            -- 'TaskCancelled' is async-tagged, so it flies past 'catchSync'
            -- (and every trySyncIO on the way up) — the outer 'catch' is the
            -- one place a user-initiated @!kill@ comes to rest.
            ( work outputCaps turn durable `catchSync` \e -> do
                finishAgentTurn durable TurnCrashed 0 (Just (T.pack (show (e :: SomeException)))) Nothing
                logAttention "llm dispatch crashed" $
                  object ["error" .= T.pack (show e)]
                -- The processing reaction is already gone (its 'finally' ran
                -- while the exception unwound), which without this looked
                -- exactly like a silent success: 托腮 vanished, no reply, no
                -- face.  Swap in the failure face so a crash is visibly a
                -- crash — direct triggers only; proactive turns stay
                -- traceless, and a poke has no message to react to.
                when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
                  queueQQReaction gm.groupId gm.canonicalId failureFaceId True
              )
              `catch` \TaskCancelled ->
                -- User-initiated !kill — quieter log, not an error.
                do
                  finishAgentTurn durable TurnAborted 0 (Just "cancelled by !kill") Nothing
                  logInfo "llm dispatch cancelled" $
                    object ["group_id" .= gidRaw]
        )
          `finally` do
            -- Any asynchronous exit other than !kill, including forced
            -- shutdown after the drain deadline, reaches here.  Keep a
            -- non-terminal row reclaimable for the next boot; normal, killed,
            -- and synchronously failed rows are already terminal and this is
            -- therefore a no-op.
            ensureAgentTurnRecoveryPending durable "dispatch unwound before a terminal checkpoint"
              `catchSync` \e ->
                logAttention "durable turn finalizer failed" $
                  object ["error" .= T.pack (show (e :: SomeException))]
            -- The dispatch row is settled here rather than by the claim loop,
            -- which used to mark it answered the instant this async was
            -- forked — before a token had been spent, so a turn that then
            -- crashed took the question with it (issue #17.D).  Every exit
            -- reaches this finally, and a row already written as deferred is
            -- left alone by the owner guard.
            settleOwner DispatchCompleted
              `catchSync` \e ->
                logAttention "dispatch settle failed" $
                  object ["error" .= T.pack (show (e :: SomeException))]
            -- Take the 托腮 back off everything this turn absorbed —
            -- implicit supplements and explicit !feedback notes both
            -- wear it from the moment they land in the inbox.  Read
            -- before 'endDispatch' drops the entry, but send after the
            -- bookkeeping: a throwing send must not leak the shutdown
            -- slot.  A mid that never had the reaction un-reacts as a
            -- no-op.
            completion <- liftIO $ do
              leaveDispatch env.beShutdown
              finishTurnRuntime env.beTasks turn
            let absorbed = completion.tcAbsorbedTriggers
                unserved = completion.tcUnservedNotes
            when (outputCaps.canReaction && outputCaps.canFace) $
              for_ absorbed $ \m ->
                queueQQReaction gm.groupId (CanonicalMessageId m) processingFaceId False
            -- Notes this turn accepted but never answered ('endDispatch'
            -- returns none for a killed turn — !kill drops them by
            -- contract).  Ones that ARE a message get a turn of their
            -- own: the streamed answer they raced is in the transcript
            -- by now, so the fresh turn sees both it and them.
            -- NeverAbsorb — absorption already failed this note once.
            -- Origin re-derived from the message itself, because an
            -- un-@'d supplement still deserves the option of [silence];
            -- sourceless notes (pokes) have nothing left to say.
            --
            -- The verb deliberately does /not/ filter this list, and that
            -- is the whole rule the supplement router works under: it may
            -- delay a note or attach it quietly, and it may never end one.
            -- Deciding an annotation is not worth answering is a judgement
            -- about what somebody meant, made against a conversation the
            -- router cannot see, by a model chosen for being cheap — and
            -- the turn that would answer it can already say [silence],
            -- which is the same restraint reached by whoever is qualified
            -- to exercise it.
            let revivable = [src | note <- unserved, Just src <- [note.noteSource]]
                dropped = length unserved - length revivable
            unless (dropped == 0) $
              logAttention "dispatch: unserved notes dropped" $
                object ["count" .= dropped]
            for_ revivable $ \src -> do
              let orig
                    | isPrivateChat src.groupId || dispatchMentionsSelf src = OriginDirect
                    | otherwise = OriginProactive
                  CanonicalMessageId srcMid = src.canonicalId
              logInfo "dispatch: unserved note re-dispatched" $
                object ["message_id" .= srcMid]
              dispatchLLM Nothing mIntent orig NeverAbsorb [] src
  where
    -- Settling is idempotent by the same guard that makes it safe: the row has
    -- to still be claimed by this worker, so whichever of these runs first
    -- decides and the rest are no-ops.  That is what lets the deferral be
    -- written where it is known and the completion unconditionally in the
    -- finally, without either having to know about the other.
    settleOwner completion =
      for_ owner $ \o -> void (completeDispatch o.doWorker o.doMessage o.doAttempt completion)

    -- The lease was sized for the milliseconds the claim loop used to hold a
    -- row; since issue #17.D the turn holds it instead, and 3.6% of turns run
    -- longer than the whole lease.  Renewing while the turn is alive is what
    -- keeps 'expiredClaimedDispatchSql' aimed at dead processes rather than
    -- slow ones.
    --
    -- 'withAsync' rather than 'race': a lost lease is not a reason to end a
    -- turn that has already said something to somebody.  The renewer gives up
    -- and says so; the turn runs to its own ending and settles as usual, which
    -- is a no-op against a row that has moved on.
    holdingDispatchLease act = case owner of
      Nothing -> act
      Just o -> withAsync (renewDispatchLeaseLoop o) (const act)

    renewDispatchLeaseLoop o = do
      threadDelay (max 1 (floor dispatchLeaseSeconds `div` 3) * 1_000_000)
      -- A blip reaching the database is not evidence the row was taken away,
      -- so it costs a renewal and not the lease.
      held <-
        renewDispatchLease o.doWorker o.doMessage o.doAttempt dispatchLeaseSeconds
          `catchSync` \e -> do
            logAttention "dispatch lease renewal failed" $
              object ["error" .= T.pack (show (e :: SomeException))]
            pure True
      if held
        then renewDispatchLeaseLoop o
        else
          logAttention "dispatch lease lost while the turn was still running" $
            object
              [ "canonical_message_id" .= o.doMessage,
                "worker" .= o.doWorker
              ]

    work outputCaps turn durable = do
      env :: BotEnv <- ask
      let tid = turnRuntimeTaskId turn
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      s <- liftIO (readSession t)
      markAgentTurnRunning durable s.model
      replyTarget0 <- case existingTurn of
        Just _ -> pure Nothing
        Nothing -> case gm.replyTo of
          Nothing -> pure Nothing
          Just target -> resolveReplyTurn (conversationScopeFor gm.groupId) s.clearedAt target
      steered <- trySteerExactReply outputCaps env tid replyTarget0
      -- The producer may finish between the durable lookup and the STM
      -- delivery.  Re-read once so that race becomes a digest continuation,
      -- not an unclassified ordinary reply.
      replyTarget <- case (steered, replyTarget0, gm.replyTo) of
        (False, Just target, Just replyMessage) | replyTurnIsInFlight target ->
          resolveReplyTurn (conversationScopeFor gm.groupId) s.clearedAt replyMessage
        _ -> pure replyTarget0
      injected <-
        if steered || isJust replyTarget
          then pure (if steered then BusyAbsorbed else BusyNoOne)
          else tryAbsorbIntoRunningTurn outputCaps env s tid
      case injected of
        BusyAbsorbed -> do
          archive <- captureTurnArchiveFields durable s.model [] 0 (Just "absorbed into an in-flight turn")
          finishAgentTurn durable TurnAborted 0 (Just "absorbed into an in-flight turn") archive
        BusyDeferred -> do
          -- Written before the epilogue's DispatchCompleted, in this same
          -- thread, which is what makes the ordering a fact rather than a
          -- hope: 'completeDispatch' only matches a row still @claimed@ by
          -- this worker, so once it reads @deferred@ the later write is a
          -- no-op.  The retry time is a bound, not the plan — the plan is
          -- 'releaseDeferredDispatches' when the turn ahead finishes, and this
          -- is what catches the row whose releaser raced past it.
          deferAt <- addUTCTime deferredRetrySeconds <$> liftIO getCurrentTime
          settleOwner (DispatchDeferred deferAt)
          archive <- captureTurnArchiveFields durable s.model [] 0 (Just "deferred behind an in-flight turn")
          finishAgentTurn durable TurnAborted 0 (Just "deferred behind an in-flight turn") archive
        BusyNoOne -> do
          -- Commit point: this turn is going to build context, and the
          -- group's pending intent buffer reaches the model as ambient
          -- text of it — clear the buffer so the same messages can't
          -- also produce a proactive reply.  Not earlier (an absorbed
          -- trigger builds nothing, and the buffer must survive it) and
          -- not later (buildContext is about to read history).
          for_ mIntent $ \st -> liftIO (clearPendingIntent st gm.groupId)
          withProcessingReaction outputCaps (dispatch outputCaps turn durable env s (replyTarget >>= finishedTarget))
          -- The reason anything was deferred behind this conversation just
          -- stopped being true.  Writing those rows back to pending is what
          -- fires max_notify_dispatch_work, so the waiting worker is woken
          -- precisely rather than on its next fallback scan.
          released <- releaseDeferredDispatches (let GroupId g = gm.groupId in g)
          when (released > 0) $
            logInfo "released messages deferred behind this turn" $
              object ["group_id" .= (let GroupId g = gm.groupId in g), "released" .= released]
      where
        finishedTarget target
          | replyTurnIsFinished target = Just target
          | otherwise = Nothing

    -- Replying to a linked output of a live t# is an exact steer.  No intent
    -- classifier is allowed to redirect it to whichever task happened to
    -- start most recently.
    trySteerExactReply outputCaps env tid = \case
      Just target | replyTurnIsInFlight target -> do
        noteAt <- liftIO getCurrentTime
        let CanonicalMessageId messageId = gm.canonicalId
            -- Replying to a live turn's own output is as explicit as
            -- typing the verb, so it is a steer for the same reason.
            note = Note (renderCurrentLine env.beTimeZone noteAt gm) (Just gm) NoteSteer
        landed <-
          liftIO $
            pushToAgentTurn
              env.beTasks
              gm.groupId
              (Just tid)
              (Just messageId)
              target.rttTurn
              note
        for_ landed $ \(TaskId into) -> do
          logInfo "feedback: exact reply steer" $
            object
              [ "message_id" .= messageId,
                "target_turn" .= target.rttTurn.atrTurnOrdinal.unTurnOrdinal,
                "task" .= into
              ]
          when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
            queueQQReaction gm.groupId gm.canonicalId processingFaceId True
        pure (isJust landed)
      _ -> pure False

    -- React [托腮] on the trigger while the dispatch runs — a quiet
    -- "seen, working on it" — and clear it once the reply (or
    -- silence / crash / !kill) lands.  Fire-and-forget both ways: a
    -- failed reaction must never affect the dispatch.  Proactive
    -- turns show it too (the bot IS working; a busy pause with no
    -- tell reads as ignoring the group) — but their [silence] leaves
    -- no other trace: the 托腮 just vanishes, no reason face.  Pokes
    -- have no message to react to.
    withProcessingReaction outputCaps act
      | origin `elem` [OriginPoke, OriginMonitor, OriginPlan] || not (outputCaps.canReaction && outputCaps.canFace) = act
      | otherwise =
          (queueQQReaction gm.groupId gm.canonicalId processingFaceId True >> act)
            `finally` queueQQReaction gm.groupId gm.canonicalId processingFaceId False

    -- When the group already has a turn running, whatever gets said next goes
    -- into that turn's inbox and the front model decides what it is.  There is
    -- no classifier here any more, and removing it is the point rather than a
    -- saving: "is this steering the running task or starting a new one" is a
    -- question about what somebody meant, and it was being answered from four
    -- lines of history by a model chosen for being cheap.  The model that has
    -- the conversation, the memory and the work in progress can answer it, and
    -- can also decline to choose — one reply addressing both things is a
    -- perfectly good outcome that a router has no way to express.
    --
    -- So the targeting problem ADR 002 called "a present-tense correctness gap"
    -- is dissolved rather than narrowed.  Mis-aiming stops being a failure and
    -- becomes extra context.
    --
    -- Two things are given up on purpose.  A second, unrelated question no
    -- longer gets a concurrent turn of its own — two turns in one group cannot
    -- see each other, may both speak, and interleave; parallelism belongs
    -- inside a plan where it has structure.  And that question now waits for
    -- the running turn's next decision point, bounded by one model round.
    --
    -- Aiming mirrors @!feedback@: a trigger that replies to a running
    -- turn's trigger (or to a message that turn already absorbed) is
    -- steering THAT turn, not whichever started last — 'pushToTrigger'
    -- first, newest turn as the fallback.
    --
    -- Turns that declared themselves un-absorbable never reroute — @!btw@ said
    -- so outright.  Direct and proactive triggers both may: the same "不对，改成
    -- X" steers the running turn whether or not it carried an @.  No longer
    -- gated on the intent profile being configured, because nothing here needs
    -- a model any more.
    tryAbsorbIntoRunningTurn outputCaps env s tid =
      case absorbable of
        MayAbsorb -> do
          -- Our own entry has been in the registry since dispatch
          -- entry, so "is anybody working?" has to discount it.
          running <- liftIO (listTasks env.beTasks (Just gm.groupId))
          -- 'listTasks' sorts by start time, so the last of the others is the
          -- newest — the same one 'pushToLatest' would choose, which is what
          -- makes "is this the same person's work?" a question about the turn
          -- that would actually take the note.
          case reverse (filter (\ti -> ti.tiId /= tid) running) of
            [] -> pure BusyNoOne
            newest : _ -> do
              let GroupId gidRaw = gm.groupId
                  CanonicalMessageId midRaw = gm.canonicalId
              -- Only the trigger and its companions; the history around them
              -- was context for a classifier that no longer exists, and the
              -- turn absorbing this note already has its own.
              rows <- fetchRecentInGroup gidRaw 0 s.clearedAt (length companions + 1)
              noteAt <- liftIO getCurrentTime
              -- Companions (the earlier messages of a proactive batch)
              -- go in alongside the trigger: if the turn absorbs, the whole
              -- batch is the note — the running turn never re-reads history,
              -- so a line left behind here is a line it never sees.  Rendered
              -- from their DB rows for real timestamps; a row missing in a
              -- pathological flood just drops its line, same call the intent
              -- worker already makes.
              let render = renderHistoryLine env.beTimeZone
                  companionMids =
                    Set.fromList [m | c <- companions, let CanonicalMessageId m = c.canonicalId]
                  companionRows =
                    [ h
                      | h <- rows,
                        h.canonicalId /= midRaw,
                        h.canonicalId `Set.member` companionMids
                    ]
                  newLine =
                    T.intercalate "\n" $
                      map render companionRows <> [renderCurrentLine env.beTimeZone noteAt gm]
              -- Record the trigger as absorbed by whichever turn takes it:
              -- ours is about to exit and unmark it, and a question that looks
              -- unanswered gets answered again by the next dispatch.
              --
              -- Ambient rather than steer, and that is a structural fact rather
              -- than a reading: nobody claimed this message is about the work.
              -- What it means is the front model's to decide, and the label
              -- only tells it where the line came from.
              let note = Note newLine (Just gm) NoteAmbient
              aimed <- case (\(CanonicalMessageId target) -> target) <$> gm.replyTo of
                Just tgt ->
                  liftIO (pushToTrigger env.beTasks gm.groupId (Just tid) (Just midRaw) tgt note)
                Nothing -> pure Nothing
              -- __Reentrancy, not merging__ (issue #17.C).  Folding every
              -- message into whatever turn happened to be running is what made
              -- one conversation's busy turn swallow a second person's
              -- unrelated question and never answer it.  Two things say this
              -- message belongs to the work already in flight, and only they:
              -- it replies into that turn (or into something the turn already
              -- swallowed), or its author is the person whose question the
              -- turn is answering.  Anything else waits.
              --
              -- Non-direct origins keep the old behaviour outright: a
              -- proactive impulse or a poke has no dispatch row to defer and
              -- nothing to come back to, so folding it in is the only place it
              -- can go.
              let reentrant = newest.tiUser == gm.userId || origin /= OriginDirect
              landed <- case aimed of
                Just _ -> pure aimed
                Nothing
                  | reentrant ->
                      liftIO (pushToLatest env.beTasks gm.groupId (Just tid) (Just midRaw) note)
                  | otherwise -> pure Nothing
              for_ landed $ \(TaskId into) -> do
                logInfo "absorbed into a running turn" $
                  object
                    [ "group_id" .= gidRaw,
                      "message_id" .= midRaw,
                      "aimed" .= isJust aimed,
                      "task" .= into
                    ]
                -- Same 托腮 an explicit !feedback gets, cleared by the
                -- absorbing turn's epilogue.  Unconditional now: the face
                -- promises the message will be read, and since the router
                -- stopped deciding which ones deserve reading, that promise is
                -- true of every note that lands.  Direct triggers only — an
                -- absorbed proactive candidate was never addressed to the bot,
                -- and reacting would break the "traceless until it speaks"
                -- rule.
                when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
                  queueQQReaction gm.groupId gm.canonicalId processingFaceId True
              case (landed, reentrant) of
                (Just _, _) -> pure BusyAbsorbed
                -- Both pushes missed although this message belonged to that
                -- turn: it finished between the registry read and the push.
                -- Nothing is running now, so take our own turn rather than
                -- wait for something that has already ended.
                (Nothing, True) -> pure BusyNoOne
                (Nothing, False) -> do
                  logInfo "deferred behind a running turn" $
                    object
                      [ "group_id" .= gidRaw,
                        "message_id" .= midRaw,
                        "behind_task" .= newest.tiId.unTaskId,
                        "behind_user" .= (let UserId u = newest.tiUser in u)
                      ]
                  pure BusyDeferred
        _ -> pure BusyNoOne

    dispatch outputCaps turn durable env s continuationTarget = case childDispatch of
      Just child -> dispatchChild turn durable env s child
      Nothing -> dispatchOrdinary outputCaps turn durable env s continuationTarget

    -- A fork child is not a chat turn. It receives no persona, roster, group
    -- brief, skills, history, memory, sibling state, or output capability. All
    -- typed events are swallowed, and only subgoal_return can make it succeed.
    dispatchChild turn durable env s child = do
      (remainingCalls, remainingWallClockMs) <-
        remainingChildBudget
          durable.atrTurnId
          child.cdGoal.goalBudget.ebMaxCalls
          child.cdGoal.goalBudget.ebMaxWallClockMs
      let runtimeBudget =
            child.cdGoal.goalBudget
              { ebMaxCalls = remainingCalls,
                ebMaxWallClockMs = remainingWallClockMs
              }
          runtimeGoal = child.cdGoal {goalBudget = runtimeBudget}
          caps =
            TurnCapabilities
              False
              False
              False
              noAdvertisedCaps
              False
              child.cdToolGrants
              (Just child.cdToolGrants)
              (Just (SubgoalReturn durable.atrTurnId runtimeGoal child.cdInputs))
          definitions = toolDefinitionsFor env gm.groupId caps
          catalogFingerprint = toolCatalogFingerprint definitions
          toolCtx =
            mkToolContext
              ( TurnIdentity
                  gm.groupId
                  gm.canonicalId
                  gm.userId
                  gm.selfId
                  gm.authorPrincipalId
                  s.clearedAt
                  (turnRuntimeOutputContext turn)
              )
              caps
          agentCtx =
            AgentContext
              toolCtx
              s.effortOverride
              (Just remainingCalls)
          recoveryMessages = maybe [] (\view -> [MsgUser view]) recoveryView
          messages =
            [ MsgSystem isolatedChildSystem,
              MsgUser child.cdView
            ]
              <> recoveryMessages
      setAgentTurnEnvironment durable currentPromptMajor catalogFingerprint
      raced <-
        if remainingWallClockMs <= 0
          then pure (Right ())
          else
            race
              (agentTurn turn agentCtx s.model messages discardChildEvent)
              (threadDelay (remainingWallClockMs * 1000))
      case raced of
        Right () -> do
          logAttention "plan: child exhausted its wall-clock budget" $
            object ["child_turn" .= durable.atrTurnOrdinal.unTurnOrdinal]
          finishAgentTurn durable TurnFailed 0 (Just "child wall-clock budget exhausted") Nothing
        Left result -> do
          returned <- childHasResult durable.atrTurnId
          let terminal = if returned then TurnSucceeded else TurnFailed
              reason
                | returned = result.aborted
                | otherwise = Just (fromMaybe "child ended without subgoal_return" result.aborted)
          unless returned $
            logAttention "plan: child ended without a typed result" $
              object ["child_turn" .= durable.atrTurnOrdinal.unTurnOrdinal]
          archive <- captureTurnArchive durable s.model result
          finishAgentTurn durable terminal result.turnsUsed reason archive

    dispatchOrdinary outputCaps turn durable env s continuationTarget = do
      catalog :: ModelCatalog <- ask
      let capabilities = lookupModelCapabilities s.model catalog
          multimodal = maybe False supportsMultimodal capabilities
          historyTurns = maybe False usesHistoryTurns capabilities
          limits = maybe defaultContextLimits (.contextLimits) capabilities
      brief <- fetchGroupBrief outputCaps gm.groupId
      -- Questions another turn is already working on.  Ours is in there
      -- too (claimed just above) — drop it, it isn't history yet.
      let CanonicalMessageId ownMid = gm.canonicalId
      inFlight <- Set.delete ownMid <$> liftIO (inFlightTriggers env.beTasks gm.groupId)
      -- One registry snapshot serves both halves of the disclosure:
      -- the index rendered into the system prompt and the tool-capability
      -- gate that registers the use_skill tool reading the bodies.
      skills <- liftIO (skillsForGroup env.beSkills gm.groupId)
      tier <- effectiveTier env gm.groupId gm
      let skillIndex = [(sk.skillName, sk.skillDescription) | sk <- skills]
          debugEff = fromMaybe env.beDebugDefault s.debugOverride
          stickersEff = fromMaybe env.beStickerDefault s.stickerOverride
          platformStickers = stickersEff && outputCaps.canMedia
          baseCapabilities =
            TurnCapabilities
              multimodal
              platformStickers
              (not (null skills))
              outputCaps
              (tierSatisfied TierGroupAdmin tier)
              Map.empty
              effectCeiling
              -- The turn naming itself: a fork child's return tool is keyed by
              -- the turn the spawn edge points at, and taking that from the
              -- caller would create a way to name the wrong one.
              ( (\child -> SubgoalReturn durable.atrTurnId child.cdGoal child.cdInputs)
                  <$> childDispatch
              )
          currentDefinitions = toolDefinitionsFor env gm.groupId baseCapabilities
          catalogGrants =
            Map.fromList
              [ (definition.tdRef.unToolRef, toolCatalogFingerprint [definition])
              | definition <- currentDefinitions
              ]
          turnCapabilities = baseCapabilities {tcCatalogGrants = catalogGrants}
          catalogFingerprint = toolCatalogFingerprint currentDefinitions
      setAgentTurnEnvironment durable currentPromptMajor catalogFingerprint
      replyContinuation <- for continuationTarget $ \target -> do
        _ <-
          recordForkFrom
            (conversationScopeFor gm.groupId)
            durable
            target.rttTurn
            gm.authorPrincipalId
        now <- liftIO getCurrentTime
        digestView <-
          continuationDigest
            (conversationScopeFor gm.groupId)
            s.clearedAt
            gm.canonicalId
            now
            currentPromptMajor
            catalogFingerprint
            target
        -- The digest is computed first and unconditionally: it is the floor
        -- the replay tier degrades to, so a validity failure costs nothing
        -- already spent.  If replay does succeed it swaps the whole record
        -- for the drift note alone — the record is about to be shown
        -- verbatim, and stating it twice is what dedup exists to avoid.
        let digestOnly = digestOnlyContinuation (renderContinuationDigest env.beTimeZone <$> digestView)
            replayDelta = digestOnlyContinuation (renderReplayDelta env.beTimeZone <$> digestView)
        replayContinuation
          env
          (conversationScopeFor gm.groupId)
          ReplayEnvironment
            { reNow = now,
              reProfile = s.model,
              rePromptMajor = currentPromptMajor,
              reCatalogFingerprint = catalogFingerprint,
              reChainTokenBudget = defaultChainTokenBudget
            }
          target.rttTurn
          digestOnly
          replayDelta
      liftIO (setTurnPhase turn "context")
      let continuation = case monitorView of
            -- A monitor fire is a world event, not a continuation of an
            -- earlier turn: its host-authored view replaces the reply
            -- continuation rather than joining it.
            Just view -> digestOnlyContinuation (Just view)
            Nothing -> fromMaybe noContinuation replyContinuation
      (ctx, roster) <-
        buildContextWithReadModeForOutputContinuation
          continuation
          limits
          (if env.beForceRawContext then RawLedgerEmergency else TieredContext)
          outputCaps
          env.bePersona
          multimodal
          historyTurns
          origin
          env.beTimeZone
          brief
          skillIndex
          inFlight
          s
          gm
      let recoveredCtx = maybe ctx (`injectRecoveryView` ctx) recoveryView
          toolCtx =
            mkToolContext
              (TurnIdentity gm.groupId gm.canonicalId gm.userId gm.selfId gm.authorPrincipalId s.clearedAt (turnRuntimeOutputContext turn))
              turnCapabilities
          agentCtx = AgentContext toolCtx s.effortOverride Nothing
          -- The name→principal map the send path rescues "@显示名" against is
          -- the roster the prompt just showed the model, so the names it may
          -- write are exactly the names it read.  Before ADR 004 this was a
          -- separate QQ member-list fetch, in a different id space.
          rosterNames = [(name, PrincipalId principal) | (principal, name) <- roster]
          target =
            sendTarget
              outputCaps
              gm
              rosterNames
              platformStickers
              (turnRuntimeOutputContext turn)
      -- The streaming sink.  It sends whole paragraphs the model has
      -- finished with, down the same path the final reply takes — the
      -- budget TVar is what keeps the two halves of one split reply
      -- bounded together (see "Max.ReplySend").
      streamBudget <- liftIO (newTVarIO freshBudget)
      let output = AgentOutputContext target gm.canonicalId debugEff streamBudget
      -- The front turn's ceiling, and issue #17's second half.  A fork child
      -- races a total wall-clock budget it declared; a front turn cannot, both
      -- because nobody declared one and because killing a turn for taking a
      -- while is wrong when taking a while is the job.  What it races instead
      -- is /silence/: 'awaitTurnSilence' only fires once this turn has stopped
      -- changing phase, so honest multi-round work pushes its own deadline out
      -- and only a turn wedged inside one round runs it down.
      --
      -- Racing rather than a deadline checked at round boundaries, because the
      -- failure this exists for is a tool call that never returns — a boundary
      -- check is never reached from inside one.  The cost is that the loop's
      -- own bookkeeping is lost, which is why the timeout branch settles the
      -- turn the same way the no-reply branch does rather than pretending to
      -- have an 'AgentResult'.
      raced <-
        race
          (agentTurn turn agentCtx s.model recoveredCtx (handleAgentEvent output))
          (liftIO (awaitTurnSilence turn (env.beTurnSilenceSeconds * 1_000_000)))
      case raced of
        Right () -> do
          logAttention "llm dispatch cut off: turn stopped making progress" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "silent_seconds" .= env.beTurnSilenceSeconds
              ]
          -- Whatever streamed already reached the group as it was written, so
          -- the room sees a truncated answer; the face is what tells them it
          -- was cut off rather than finished.  Nothing is drained: the btw
          -- notes and the inbox belong to a turn that delivers.
          when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $ do
            queueQQReaction gm.groupId gm.canonicalId processingFaceId False
            queueQQReaction gm.groupId gm.canonicalId failureFaceId True
          finishAgentTurn durable TurnFailed 0 (Just "turn stopped making progress") Nothing
        Left result -> settleTurn outputCaps env s target streamBudget durable result

    settleTurn outputCaps env s target streamBudget durable result = do
      terminal <- case result.reply of
        -- The loop produced no model-authored reply — upstream API
        -- down, or the turn-cap fallback call failed too.  Error text
        -- in the group would just be noise; swap the processing
        -- reaction for a NO (face 123) so the trigger visibly failed.
        -- Nothing is drained or persisted, same as a silent turn.
        Nothing -> do
          logAttention "llm dispatch failed" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "turns" .= result.turnsUsed,
                "aborted" .= result.aborted
              ]
          when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $ do
            queueQQReaction gm.groupId gm.canonicalId processingFaceId False
            queueQQReaction gm.groupId gm.canonicalId failureFaceId True
          pure TurnFailed
        Just replyRaw -> handleReply outputCaps env s target streamBudget result replyRaw
      archive <- captureTurnArchive durable s.model result
      finishAgentTurn durable terminal result.turnsUsed result.aborted archive

    handleReply outputCaps env s target streamBudget result replyRaw = do
      -- Real stickers/images are the [sticker#<id>] / [image#<id>]
      -- tokens, resolved when the reply is sent.  The captionless
      -- "[表情包: …]" and bare "[image]"/"[动画表情]"/"[face]"/…
      -- forms are hallucinations — a weaker model imitating the
      -- display style of something it saw — so strip those as a
      -- backstop while leaving the id-carrying send tokens intact
      -- (see 'Max.ReplySend.cleanModelText').
      -- Whatever streaming already put in the group is gone from here:
      -- what's left to send is the tail.  'Max.Reply.readyPrefix' only
      -- ever cuts at a blank line, so dropping the prefix cannot split
      -- a paragraph — the remainder plans into chunks exactly as it
      -- would have on its own.
      let remaining = T.drop (T.length result.sentPrefix) replyRaw
          stickersEff = fromMaybe env.beStickerDefault s.stickerOverride && outputCaps.canMedia
          stripped = cleanModelText remaining
      when (stripped /= T.strip remaining) $
        logAttention "reply: hallucinated model markers stripped" $
          object ["dropped_chars" .= (T.length remaining - T.length stripped)]
      -- A non-empty prefix means this reply already ran to at least two
      -- paragraphs, and the opt-out is never more than one — so it can
      -- only be the tail of a real answer, never a silence marker that
      -- happens to sit at the end.
      case if T.null result.sentPrefix then parseSilence stripped else Nothing of
        Just mFace -> do
          -- The model opted out of replying (see 'parseSilence') —
          -- the escape hatch for turns that need no response, most
          -- importantly another bot @-ing us: answering would
          -- re-trigger it and ping-pong forever.  Nothing is sent;
          -- btw notes are NOT drained (they wait for a turn that
          -- actually delivers them); no episode timer is armed (a turn judged
          -- not worth answering is noise).  The silence itself
          -- IS persisted, as an internal canonical IR row — without it the
          -- declined question reads as still pending in the next
          -- chronological context and gets answered a turn late.
          --
          -- On a direct trigger the silence still shows: the named
          -- reason face (闭嘴 as the bare-[silence] fallback) is
          -- reacted onto the trigger message.  Proactive turns stay
          -- traceless, and a poke has no message to react to.
          logInfo "llm chose silence" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "turns" .= result.turnsUsed,
                "face" .= mFace,
                "aborted" .= result.aborted
              ]
          let GroupId group = gm.groupId
              CanonicalMessageId triggerMessage = gm.canonicalId
              -- The quote is consumed, not stored: 'replyToCanonicalMessageId'
              -- already says what this declines, and leaving the token in the
              -- body too made the next turn's transcript line carry two of
              -- them — the rendered one and the literal one, naming different
              -- messages.
              (quoted, marker) = splitQuoteHandles stripped
              silenceText = if T.null marker then "[silence]" else marker
              sourceMessage = if triggerMessage == 0 then Nothing else Just triggerMessage
              -- A negative id is a pre-cutover compatibility id echoed out of
              -- old history; it names no canonical message, so it is not a
              -- target for either the link or the face.
              quotedTarget = listToMaybe [q | q <- quoted, q > 0]
              declined = quotedTarget <|> sourceMessage
          turnOutput <- traverse (liftIO . nextTurnOutputLink) target.rtTurnOutputContext
          void $
            recordInternalMessage
              OutboundDraft
                { legacyConversationId = group,
                  transcriptKind = renderMessageKind KindChat,
                  sourceCanonicalMessageId = sourceMessage,
                  canonicalBody = Body [NText silenceText],
                  replyToCanonicalMessageId = declined,
                  turnOutputLink = turnOutput,
                  monitorFireId = Nothing
                }
          -- On the message being declined, which is only the trigger when the
          -- model did not say otherwise.  The two differ whenever it answers
          -- an earlier message in the thread, and the face belongs on the one
          -- it named.
          when (origin == OriginDirect && outputCaps.canReaction && outputCaps.canFace) $
            queueQQReaction
              gm.groupId
              (maybe gm.canonicalId CanonicalMessageId quotedTarget)
              (fromMaybe defaultSilenceFace mFace)
              True
          pure TurnSilence
        Nothing -> do
          -- Outbound gets the platform message_id and persists this
          -- message into the messages table.  That's where
          -- subsequent dispatches will read this turn's assistant reply
          -- back from the chronological ledger.
          -- The same budget the streaming sink spent from: one reply
          -- split across two senders still gets one message ceiling and
          -- one image-dedupe set (see "Max.ReplySend").
          budget <- liftIO (readTVarIO streamBudget)
          _ <-
            sendAndPersistReply
              target {rtStickers = stickersEff}
              budget
              stripped
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length stripped,
                "streamed" .= T.length result.sentPrefix,
                "turns" .= result.turnsUsed,
                "appended" .= length result.appended,
                "aborted" .= result.aborted
              ]
          -- Post-reply: arm Historian v2's protected quiet-tail timer.  One
          -- settled capture later produces both chronological summaries and
          -- scoped memory proposals from the same exact source range.
          for_ env.beEpisodeScheduler $ \scheduler -> liftIO (armEpisode scheduler gm.groupId)
          pure TurnSucceeded

    captureTurnArchive durable profile result = do
      captureTurnArchiveFields durable profile result.appended result.turnsUsed result.aborted

    captureTurnArchiveFields durable profile appended turnsUsed aborted = do
      (Just <$> writeArchive)
        `catchSync` \e -> do
          -- The wire archive is disposable replay cache, never turn truth.
          -- A cache write failure after a visible reply must not turn that
          -- successfully completed reply into a user-visible crash.
          logAttention "turn trace archive capture failed" $
            object
              [ "turn_id" .= durable.atrTurnId.unAgentTurnId,
                "error" .= T.pack (show (e :: SomeException))
              ]
          pure Nothing
      where
        writeArchive = do
          now <- liftIO getCurrentTime
          let payload =
                object
                  [ "version" .= (1 :: Int),
                    "turn_id" .= durable.atrTurnId.unAgentTurnId,
                    "turn_ordinal" .= durable.atrTurnOrdinal.unTurnOrdinal,
                    "profile" .= profile,
                    "trigger"
                      .= object
                        [ "canonical_message_id" .= gm.canonicalId,
                          "body" .= gm.body
                        ],
                    "appended" .= appended,
                    "turns_used" .= turnsUsed,
                    "aborted" .= aborted
                  ]
              bytes = LBS.toStrict (encode payload)
          blob <- putBlob bytes
          pure
            ( blobRefSha256 blob,
              fromIntegral (BS.length bytes),
              addUTCTime (14 * 24 * 60 * 60) now
            )

-- | Try ADR 005's verbatim tier for one resolved continuation target, and
-- return the digest-only input unchanged when anything about the chain says
-- no.  Replay is a cache over the digest floor: every failure here is a
-- cheaper prompt, never a wrong one, so the whole path is wrapped against
-- exceptions as well.
--
-- Per-provider filtering is deliberately absent: the segments are ordinary
-- 'ChatMessage' values spliced into the same list an in-dispatch round trip
-- builds, so whatever each protocol strips or round-trips it does to replayed
-- items by exactly the same code — no second rule set to keep honest.
replayContinuation ::
  (Blob :> es, Log :> es, WithConnection :> es, IOE :> es) =>
  BotEnv ->
  ConversationScope ->
  ReplayEnvironment ->
  AgentTurnRef ->
  -- | Digest tier: the whole record, and the floor every failure lands on.
  ContinuationInput ->
  -- | Replay tier companion: the drift note only, since the record itself
  -- arrives as wire items.
  ContinuationInput ->
  Eff es ContinuationInput
replayContinuation env scope replayEnv target digestOnly replayDelta =
  attempt `catchSync` \e -> do
    logAttention "continuation: replay attempt failed, using digest" $
      object ["error" .= T.pack (show (e :: SomeException))]
    pure digestOnly
  where
    attempt = do
      chain <- replayChain scope target defaultChainDepth
      triggers <-
        fetchMessagesByIdsInScope
          scope
          [messageId | candidate <- chain, Just messageId <- [candidate.rcTriggerCanonicalId]]
      let byId = Map.fromList [(item.canonicalId, item) | item <- triggers]
          withTriggerLine candidate =
            candidate
              { rcTriggerLine =
                  renderHistoryLine env.beTimeZone
                    <$> (candidate.rcTriggerCanonicalId >>= \messageId -> Map.lookup messageId byId)
              }
      loaded <- traverse (loadSegment . withTriggerLine) chain
      let plan = planReplay replayEnv loaded
      if null plan.rpSegments
        then do
          logInfo "continuation: digest tier" $
            object
              [ "target_turn" .= target.atrTurnOrdinal.unTurnOrdinal,
                "reason" .= (replayRejectText <$> plan.rpStoppedBecause)
              ]
          pure digestOnly
        else do
          logInfo "continuation: replay tier" $
            object
              [ "target_turn" .= target.atrTurnOrdinal.unTurnOrdinal,
                "segments" .= length plan.rpSegments,
                "estimated_tokens" .= plan.rpEstimatedTokens,
                "chain_stopped" .= (replayRejectText <$> plan.rpStoppedBecause)
              ]
          pure
            replayDelta
              { ciSegments = planReplayMessages plan,
                ciCovered = planCoveredCanonicalIds plan
              }

    -- Loading is the only job here: whether these bytes may be replayed, and
    -- what the finished segment costs, is 'planReplay''s pure decision.
    loadSegment candidate = case candidate.rcArchiveSha >>= blobRefFromSha256 of
      Just ref -> do
        bytes <- readBlob ref
        pure (candidate, maybe (Left RejectArchiveUnreadable) (Right . (.taAppended)) (decodeArchive bytes))
      Nothing -> pure (candidate, Left RejectArchiveUnreadable)

    decodeArchive :: BS.ByteString -> Maybe TurnArchive
    decodeArchive bytes = case eitherDecodeStrict' bytes of
      Left _ -> Nothing
      Right archive
        | archive.taVersion == 1 -> Just archive
        | otherwise -> Nothing

-- | Keep the prompt's final role shape intact while appending the boot-only
-- hole view to the current user turn.  Multimodal triggers retain their
-- existing blocks and receive one final host-authored text block.
injectRecoveryView :: T.Text -> [ChatMessage] -> [ChatMessage]
injectRecoveryView view messages = case unsnoc messages of
  Just (prefix, MsgUser body) -> prefix <> [MsgUser (body <> "\n\n" <> view)]
  Just (prefix, MsgUserBlocks blocks) ->
    prefix <> [MsgUserBlocks (blocks <> [TextBlock ("\n\n" <> view)])]
  _ -> messages <> [MsgUser view]

--------------------------------------------------------------------------------
-- Reply helper.

-- | The send-side view of a dispatch: what "Max.ReplySend" needs that
-- the handler already has.  Built here rather than carried around,
-- because every field is derived from something the caller holds
-- anyway.
sendTarget ::
  AdvertisedCaps ->
  DispatchMessage ->
  [(T.Text, PrincipalId)] ->
  Bool ->
  Maybe TurnOutputContext ->
  ReplyTarget
sendTarget outputCaps gm rosterNames stickersOn turnOutput =
  ReplyTarget
    { rtGroupId = gm.groupId,
      rtSelfId = gm.selfId,
      rtRosterNames = rosterNames,
      rtSelfPrincipal = gm.selfPrincipalId,
      rtStickers = stickersOn,
      rtCanReply = outputCaps.canReply,
      rtCanMention = outputCaps.canMention,
      rtCanFace = outputCaps.canFace,
      rtCanImage = outputCaps.canMedia,
      rtTurnOutputContext = turnOutput
    }

-- | Send a message and write it down, so the messages table mirrors
-- what the conversation actually saw.
--
-- Recording requires the round-trip: @message_id@ is assigned by QQ
-- and only comes back in the send response, and it is the table's
-- primary key — the id every @[reply#id]@ quote and reply link resolves
-- against.  Fire-and-forget cannot record anything.
--
-- Every failure only logs.  A message that went out but couldn't be
-- written down leaves the record incomplete, which is bad; failing the
-- dispatch over it is worse.
sendAndRecord ::
  (Outbound :> es) =>
  MessageKind ->
  OutboundDeliveryScope ->
  GroupId ->
  Body 'Canonical ->
  Maybe CanonicalMessageId ->
  Eff es ()
sendAndRecord kind deliveryScope gid body replyTo =
  void $
    sendRecorded
      OutboundRequest
        { orKind = kind,
          orGroupId = gid,
          orBody = body,
          orReplyTo = replyTo,
          orDeliveryScope = deliveryScope,
          orTurnOutput = Nothing,
          orMonitorFireId = Nothing
        }

-- | Command output: plain text, no quote and no @ — in the moment
-- right after a command both read as noise.  Recorded as
-- 'KindCommand', so the group's record is complete but the model
-- doesn't read back the UI used to operate it.
replyText ::
  (Outbound :> es) =>
  DispatchMessage ->
  T.Text ->
  Eff es ()
replyText gm body =
  sendAndRecord KindCommand (DeliverSourceEndpoint gm.canonicalId) gm.groupId (Body [NText body]) Nothing

-- | One roster fetch serving two prompt-side consumers: the member id
-- set for outbound @-mention validation ('Nothing' when there is no
-- meaningful list — private chat or NapCat failure — so conversion
-- falls back to syntax-only matching and a flaky API never mutes
-- legitimate @s), and the rendered 群信息 lines for the system
-- prompt's [environment] block (empty on the same failures — the model
-- just doesn't get the block).
-- | The group's own description lines for the environment block.  QQ-only,
-- and no longer a source of identity: the roster the model reads and the
-- names the send path accepts both come from the ledger now.
fetchGroupBrief ::
  (PlatformApi :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AdvertisedCaps ->
  GroupId ->
  Eff es [T.Text]
fetchGroupBrief outputCaps gid
  | isPrivateChat gid || not outputCaps.canMention = pure []
  | otherwise = do
      members <- fetchGroupMembers gid
      meta <- fetchGroupMeta gid
      -- The name we just fetched for the prompt is the only human
      -- label this room has; write it through to the ledger so it
      -- outlives the turn.
      forM_ meta $ \m -> let GroupId raw = gid in rememberConversationTitle raw m.gmName
      pure (renderGroupBrief meta members)

-- | QQ-ingress only: this path still holds the raw OneBot segments, where the
-- bot's compatibility id and its native id are the same number.  Canonical
-- dispatch uses 'dispatchTextWithoutSelf' instead.
stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) t =
  foldr
    (\m acc -> T.replace m "" acc)
    t
    ["[@#" <> uid <> "] ", "[@#" <> uid <> "]", "@" <> uid]
  where
    uid = T.pack (show u)

-- | The group a private-chat command actually operates on: the
-- @!use@ target when one is set (and the sender is entitled to it),
-- else the chat's own (pseudo) group.  The !use family itself never
-- redirects — it manages the selection.  Entitlement: owners aim
-- anywhere; anyone else must be a member of the target group, which
-- also closes the "!use someone else's group and read its !status"
-- hole.
resolveAdminTarget ::
  (PlatformApi :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  DispatchMessage ->
  Command ->
  Eff es GroupId
resolveAdminTarget env gm cmd
  | not (isPrivateChat gm.groupId) = pure gm.groupId
  | useFamily cmd = pure gm.groupId
  | otherwise = do
      let UserId uidRaw = gm.userId
      targets <- liftIO (readTVarIO env.beAdminTarget)
      case Map.lookup uidRaw targets of
        Nothing -> pure gm.groupId
        Just g
          | uidRaw `elem` env.beOwners -> pure (GroupId g)
          | otherwise -> do
              members <- fetchGroupMembers (GroupId g)
              if any (\m -> m.mUserId == gm.userId) (fromMaybe [] members)
                then pure (GroupId g)
                else do
                  logInfo "cmd: admin target dropped (not a member)" $
                    object ["user_id" .= uidRaw, "target" .= g]
                  pure gm.groupId
  where
    useFamily = \case
      UseShow -> True
      UseSet _ -> True
      UseClear -> True
      _ -> False

-- | The sender's effective tier IN THE TARGET GROUP: config owner
-- list first, then the NapCat role there.  Resolved once per command
-- and threaded into both the permission check and 'CmdDispatch.execute'.
effectiveTier :: (PlatformApi :> es, Log :> es) => BotEnv -> GroupId -> DispatchMessage -> Eff es PermTier
effectiveTier env targetGid gm
  | let UserId uid = gm.userId, uid `elem` env.beOwners = pure TierOwner
  | otherwise = actorTier targetGid gm.userId

-- | May the sender run this command against the target group?  The tier the
-- command declares against the tier the sender has.  Commands without a
-- capability are open to all.
checkCmdPermission :: PermTier -> Command -> Bool
checkCmdPermission effTier cmd = case requiredCapability cmd of
  Nothing -> True
  Just (_, tier) -> tierSatisfied tier effTier

-- | The sender's role tier in a group.  A private pseudo-group means
-- the sender administers their own session by definition; owner tier
-- is config-only and resolved by the caller.
actorTier :: (PlatformApi :> es, Log :> es) => GroupId -> UserId -> Eff es PermTier
actorTier gid uid
  | isPrivateChat gid = pure TierGroupAdmin
  | otherwise = do
      members <- fetchGroupMembers gid
      let role = [m.mRole | m <- fromMaybe [] members, m.mUserId == uid]
      pure $ case role of
        (r : _) | r `elem` ["owner", "admin"] -> TierGroupAdmin
        _ -> TierMember

-- | Reactions are lightweight canonical meta-events.  Publishing them is the
-- only side effect on the dispatch path; the capability-aware delivery worker
-- resolves the target's QQ copy and performs the native action durably.
-- Missing/unsupported targets are quiet by design.
queueQQReaction ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  GroupId ->
  CanonicalMessageId ->
  Int ->
  Bool ->
  Eff es ()
queueQQReaction (GroupId group) (CanonicalMessageId message) faceId added =
  trySync
    ( enqueueReaction
        ReactionDraft
          { legacyConversationId = group,
            targetCanonicalMessageId = message,
            reactionKey = T.pack (show faceId),
            reactionAction = if added then ReactionAdd else ReactionRemove,
            requiredPlatform = Just PlatformQQ
          }
    )
    >>= \case
      Right _ -> pure ()
      Left e ->
        logAttention "reaction outbox publish failed" $
          object
            [ "group_id" .= group,
              "message_id" .= message,
              "face_id" .= faceId,
              "added" .= added,
              "error" .= T.pack (show (e :: SomeException))
            ]

-- | Reaction for a permission-denied command: the NO face — same one
-- @[silence:NO]@ uses, visibly refused with zero chat noise.
deniedFaceId :: Int
deniedFaceId = 123

-- | The "processing" reaction face: 托腮 (chin-on-hand, thinking).
-- Face ids come from NapCat's face_config.json (QSid).
processingFaceId :: Int
processingFaceId = 212

-- | The command-acknowledged face: OK (the hand gesture) — replaces
-- the old "✓ …" text replies for pure acks.
ackFaceId :: Int
ackFaceId = 124

-- | The "request failed" reaction face: 裂开 — swapped in for
-- 'processingFaceId' when a dispatch produced no reply.  Distinct
-- from the /NO (123) that @[silence:NO]@ puts on refused (political)
-- topics: broken vs refused should read differently.
failureFaceId :: Int
failureFaceId = 357

-- | Reaction used when a direct-trigger silence names no (known)
-- face: 闭嘴 — the mechanical "不接这条".  The format guide no longer
-- pushes the model to always name a reason; a bare [silence] gets
-- this face by machinery instead of by prompt pressure.
defaultSilenceFace :: Int
defaultSilenceFace = 7

-- | Did the model opt out of replying?  The format guide tells it to
-- answer with a lone @[silence]@ — or @[silence:表情名]@ to say why —
-- when a turn calls for no response, e.g. another bot mechanically
-- @-ing us, where any answer would re-trigger it in an endless loop.
-- Expects pre-stripped input; an empty reply counts as silence too.
--
-- Returns 'Nothing' when the reply is a real answer; @Just mFace@
-- when it is silence, with the reason face (if a known one was
-- named).  Only an exact match qualifies: a reply that merely
-- *contains* the marker still goes out, so the model can't
-- accidentally mute a real answer.  Leading quote handles are the one
-- exception — the guide drills "回谁就引谁" so hard that the model
-- writes @[↩#id] [silence]@, and that used to fail the exact match
-- and send the marker as literal text.
parseSilence :: T.Text -> Maybe (Maybe Int)
parseSilence t0
  | T.null t || closed == "[silence]" || closed == "[沉默]" = Just Nothing
  | Just inner <- withReason = Just (faceIdByName (T.strip inner))
  | otherwise = Nothing
  where
    t = dropQuoteHandles t0
    -- A reply that is a marker missing its closing bracket is repaired before
    -- it is read.  Streamed replies lose that last character often enough to
    -- matter: eleven production replies in three days ended in an unclosed
    -- token, and every one of them came back from the same profile.  What made
    -- it worth handling here rather than shrugging at the provider is the
    -- direction the near-miss falls — an opt-out that does not quite parse is
    -- not treated as a malformed opt-out, it is treated as ordinary text, so
    -- the bot answers a message it had decided to stay out of by shouting
    -- "[silence" at the group.
    --
    -- The repair applies only when there is no @]@ anywhere, which is both the
    -- narrow rule and the true one: a marker that lost its bracket has no
    -- bracket left to find.  Anything carrying one is read exactly as before,
    -- so @[silence:吃瓜] 再说一句@ stays a reply with a marker in it rather than
    -- becoming a silence with an unreadable reason, and prose that mentions
    -- [silence] in passing still fails every comparison below.  That property
    -- is what the exact match was protecting and is worth keeping: max has
    -- already sent a good message joking about how it sends three in a row.
    closed
      | T.any (== ']') t = t
      | otherwise = T.stripEnd t <> "]"
    withReason =
      (T.stripPrefix "[silence:" closed <|> T.stripPrefix "[silence：" closed)
        >>= T.stripSuffix "]"

-- | Leading @[reply#id]@ handles and the text after them.  Only the prefix:
-- a quote in the middle of real text is content.  Both openers are read for
-- the same reason 'Max.Reply.matchToken' reads both — a model quoting a
-- pre-rename line writes what that line spells.
--
-- The ids come back because a silence quotes what it is declining, and that
-- is a more useful reaction target than whatever woke max.
splitQuoteHandles :: T.Text -> ([Int64], T.Text)
splitQuoteHandles = go []
  where
    go acc s =
      let s' = T.stripStart s
       in case listToMaybe (mapMaybe (`T.stripPrefix` s') ["[reply#", "[↩#"]) of
            Just rest
              | (num, rest') <- T.span (\c -> isDigit c || c == '-') rest,
                not (T.null (T.filter isDigit num)),
                Just rest'' <- T.stripPrefix "]" rest' ->
                  go (acc <> maybe [] pure (readIntegral num)) rest''
            _ -> (acc, s')

dropQuoteHandles :: T.Text -> T.Text
dropQuoteHandles = snd . splitQuoteHandles

isSilentReply :: T.Text -> Bool
isSilentReply = isJust . parseSilence
