-- |
-- Historian v2: one durable episode capture produces a rebuildable
-- chronological compartment and scoped semantic-memory proposals.
--
-- Quiet-period scheduling is intentionally in-memory; exact ranges, source
-- hashes, leases, retries, model output, validation, publication, and cursor
-- advancement are durable in 'Max.EpisodeStore'.  A restart therefore replays
-- the same range or recovers it from the historian cursor without skipping raw
-- messages.  Coverage below the cursor is self-healing while the process
-- runs: every publication and every quiet round enqueue the oldest uncovered
-- island ('healOldestCoverageGap'), so a message whose insert committed after
-- the cursor passed its ingest_seq waits for the next conversation event, not
-- the next restart.
module Max.Historian
  ( historianWorker,
    historianPromptVersion,
    historianSchemaVersion,
    CaptureProcessResult (..),
    processCaptureLease,
    healOldestCoverageGap,

    -- * Pure policy exposed for tests
    historianRetryDelaySeconds,
    takeEpisodeByToken,
    renderHistorianSourceLine,
    renderHistorianMessages,
    generateHistorianCapture,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, unless, void, when)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, getCurrentTime)
import Effectful
import Effectful.Exception (finally)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Context (estimateMessagesTokens, estimateTextTokens)
import Max.ConversationScope (ConversationScope, conversationScopeFor, conversationStorageId)
import Max.DB.ConversationCursor (historianCursor, loadCursor)
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    bestName,
    fetchOldestPageAfter,
    fetchOldestPageThrough,
    hasMessagesAfter,
  )
import Max.DB.Session (listSessions)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, chat)
import Max.EpisodeScheduler
  ( EpisodeScheduler,
    armEpisode,
    awaitDueEpisode,
    continueEpisodeAt,
    episodePendingDeadline,
    releaseEpisodeClaim,
    retryEpisodeAt,
  )
import Max.EpisodeStore
import Max.MemoryStore
  ( MemoryId (..),
    MemoryItem (..),
    MemoryVersion (..),
    groupMemoryNamespace,
    listMemories,
    userMemoryNamespace,
  )
import Max.ModelCatalog
  ( ModelCapabilities (..),
    ModelCatalog,
    contextInputBudget,
    defaultContextLimits,
    lookupModelCapabilities,
  )
import Max.Session.Types (Session (..))
import Max.Tasks (TaskRegistry, inFlightTriggers)
import Max.Time (fmtDateHM, fmtEnvStamp)
import Max.Util (catchSync, trySync, tshow)
import OneBot.Types (GroupId (..))

historianPromptVersion :: Text
historianPromptVersion = "historian/v3"

historianSchemaVersion :: Int
historianSchemaVersion = 1

-- | A lease must cover the initial generation, the one allowed structured
-- response repair, and publication.  Provider/transport failures do not run a
-- synchronous retry inside either call, so this is the actual worst case.
historianLeaseSeconds :: Int -> Int
historianLeaseSeconds timeoutSeconds = max 600 (2 * max 1 timeoutSeconds + 120)

historianProtectedRetrySeconds :: Int
historianProtectedRetrySeconds = 60

-- | Durable retry backoff.  The source range stays exact and retryable, but a
-- poison model response cannot consume every worker turn forever.
historianRetryDelaySeconds :: Int -> Int
historianRetryDelaySeconds attempt
  | attempt <= 1 = 60
  | attempt == 2 = 300
  | attempt == 3 = 900
  | attempt == 4 = 3600
  | otherwise = 21600

-- | Internal SQL pagination is not an episode-size policy.  Pages are joined
-- until the deterministic token boundary is reached.
ledgerPageSize :: Int
ledgerPageSize = 500

historianWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Int ->
  ModelCatalog ->
  TimeZone ->
  TaskRegistry ->
  Text ->
  EpisodeScheduler ->
  Eff es ()
historianWorker profile timeoutSeconds catalog tz tasks defaultModel scheduler = localDomain "historian" $ do
  -- Persistent jobs win at boot.  The scheduler can disappear; leases and
  -- exact source ranges cannot.
  drainAvailableRuns
  recoverHistoricalConversations
  drainAvailableRuns
  recoverPendingConversations
  forever $ do
    gid <- liftIO (awaitDueEpisode scheduler)
    finally
      ( (enqueueSettledConversation gid >> drainAvailableRuns)
          `catchSync` \err -> do
            retryConversation gid
            logAttention "historian: scheduling round crashed" $
              object ["group_id" .= unGroupId gid, "error" .= tshow err]
      )
      (liftIO (releaseEpisodeClaim scheduler gid))
  where
    inputBudget = historianInputBudget profile catalog
    -- A larger model window should improve headroom, not silently turn one
    -- noisy episode into an unreviewable 100K-message projection.  64K of raw
    -- source is already ample for a settled group-chat episode; larger gaps
    -- continue as exact adjacent capture runs.
    sourceBudget = min 65536 (max 512 (inputBudget * 2 `div` 3))

    recoverPendingConversations = do
      sessions <- listSessions defaultModel
      for_ sessions $ \session -> do
        let scope = conversationScopeFor session.groupId
        cursor <- loadCursor scope historianCursor
        pending <- hasMessagesAfter scope cursor
        when pending $ do
          liftIO (armEpisode scheduler session.groupId)
          logInfo "historian: recovered pending conversation" $
            object ["group_id" .= unGroupId session.groupId, "cursor" .= cursor.ingestSeq]

    recoverHistoricalConversations = do
      sessions <- listSessions defaultModel
      for_ sessions (healCoverage . (.groupId))

    healCoverage gid =
      void (healOldestCoverageGap tz profile sourceBudget (conversationScopeFor gid))

    enqueueSettledConversation gid@(GroupId rawGroupId) = do
      rescheduled <- liftIO (episodePendingDeadline scheduler gid)
      protected <- liftIO (inFlightTriggers tasks gid)
      case (rescheduled, Set.null protected) of
        (Just _, _) ->
          logInfo "historian: new traffic moved the quiet boundary" $
            object ["group_id" .= rawGroupId]
        (Nothing, False) -> do
          retryConversation gid
          logInfo "historian: protected live turn deferred" $
            object ["group_id" .= rawGroupId, "in_flight" .= Set.toList protected]
        (Nothing, True) -> do
          let scope = conversationScopeFor gid
          cursor <- loadCursor scope historianCursor
          scanEpisodeWindow tz scope cursor sourceBudget >>= \case
            Nothing ->
              -- A quiet round with nothing pending above the cursor is exactly
              -- the wake-up a commit-order skip gets: the late row's handler
              -- armed this round, but its ingest_seq already sits at or below
              -- the cursor, so only the coverage query can see it.
              healCoverage gid
            Just window -> do
              movedDuringScan <- liftIO (episodePendingDeadline scheduler gid)
              case movedDuringScan of
                Just _ ->
                  logInfo "historian: scan discarded after new traffic" $
                    object ["group_id" .= rawGroupId]
                Nothing -> do
                  let reason = if window.hitTokenBoundary then CaptureTokenPressure else CaptureIdle
                      request =
                        CaptureRequest
                          { requestReason = reason,
                            requestHistorianProfile = profile,
                            requestPromptVersion = historianPromptVersion,
                            requestSchemaVersion = historianSchemaVersion
                          }
                  enqueueCaptureRun scope cursor window.endCursor request >>= \case
                    Nothing -> pure ()
                    Just run ->
                      logInfo "historian: durable capture enqueued" $
                        object
                          [ "group_id" .= rawGroupId,
                            "capture_run_id" .= run.crId,
                            "start_ingest_seq" .= run.crRange.srStart.ingestSeq,
                            "end_ingest_seq" .= run.crRange.srEnd.ingestSeq,
                            "source_messages" .= run.crRange.srMessageCount,
                            "source_tokens" .= window.estimatedTokens,
                            "reason" .= run.crReason
                          ]

    drainAvailableRuns =
      claimCaptureRun "historian-v2" (historianLeaseSeconds timeoutSeconds) >>= \case
        Nothing -> pure ()
        Just lease -> do
          let runInputBudget = historianInputBudget lease.leaseRun.crHistorianProfile catalog
          result <- trySync (processCaptureLease runInputBudget timeoutSeconds tz tasks lease)
          case result of
            Right (CapturePublished compartment) -> do
              let run = lease.leaseRun
                  gid = GroupId run.crConversationId
                  scope = conversationScopeFor gid
              logInfo "historian: capture published" $
                object
                  [ "group_id" .= run.crConversationId,
                    "capture_run_id" .= run.crId,
                    "compartment_id" .= compartment
                  ]
              liveCursor <- loadCursor scope historianCursor
              pending <- hasMessagesAfter scope liveCursor
              when pending $ do
                now <- liftIO getCurrentTime
                if run.crReason == "token_pressure"
                  then liftIO (continueEpisodeAt scheduler gid now)
                  else liftIO (armEpisode scheduler gid)
              -- Backfill chains pace themselves so bulk catch-up cannot
              -- tight-loop the provider (all conversations enqueued their
              -- first gaps together at boot).  A settled publication heals
              -- immediately: the cursor advance it just performed is the only
              -- step that can strand a late-committed row below coverage.
              when (run.crReason == "backfill") $ liftIO (threadDelay 1_000_000)
              healCoverage gid
            Right CaptureRetryScheduled -> retryConversation (GroupId lease.leaseRun.crConversationId)
            Right CaptureAbandoned -> retryConversation (GroupId lease.leaseRun.crConversationId)
            Left err -> recoverLeaseFailure lease (tshow err)
          drainAvailableRuns

    recoverLeaseFailure lease err = do
      let gid = GroupId lease.leaseRun.crConversationId
          scope = conversationScopeFor gid
      sourceCurrent <- captureRunSourceMatches scope lease.leaseRun `catchSync` \_ -> pure True
      if sourceCurrent
        then do
          let retrySeconds = historianRetryDelaySeconds lease.leaseRun.crAttempt
          _ <- failCaptureRun lease retrySeconds err []
          retryConversation gid
          logAttention "historian: capture retry scheduled" $
            object
              [ "capture_run_id" .= lease.leaseRun.crId,
                "attempt" .= lease.leaseRun.crAttempt,
                "retry_seconds" .= retrySeconds,
                "error" .= err
              ]
        else do
          _ <- abandonCaptureRun lease ("stale source or cursor: " <> err) []
          retryConversation gid
          logAttention "historian: stale capture abandoned" $
            object ["capture_run_id" .= lease.leaseRun.crId, "error" .= err]

    retryConversation gid = do
      now <- liftIO getCurrentTime
      liftIO (retryEpisodeAt scheduler gid now)

data EpisodeWindow = EpisodeWindow
  { endCursor :: !MessageCursor,
    estimatedTokens :: !Int,
    hitTokenBoundary :: !Bool
  }

scanEpisodeWindow ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ConversationScope ->
  MessageCursor ->
  Int ->
  Eff es (Maybe EpisodeWindow)
scanEpisodeWindow tz scope initial tokenLimit =
  scanEpisodeWindowBounded tz scope initial Nothing tokenLimit

scanEpisodeWindowThrough ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  Int ->
  Eff es (Maybe EpisodeWindow)
scanEpisodeWindowThrough tz scope initial through tokenLimit =
  scanEpisodeWindowBounded tz scope initial (Just through) tokenLimit

scanEpisodeWindowBounded ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ConversationScope ->
  MessageCursor ->
  Maybe MessageCursor ->
  Int ->
  Eff es (Maybe EpisodeWindow)
scanEpisodeWindowBounded tz scope initial through tokenLimit = go initial 0 Nothing
  where
    go cursor used latest = do
      page <- case through of
        Nothing -> fetchOldestPageAfter scope cursor ledgerPageSize
        Just upper -> fetchOldestPageThrough scope cursor upper ledgerPageSize
      let remaining = max 1 (tokenLimit - used)
          selected = case page.items of
            first : _
              | used > 0 && ledgerTokenCost tz first > remaining -> []
            _ -> takeEpisodeByToken tz remaining page.items
          selectedTokens = sum (map (ledgerTokenCost tz) selected)
          latest' = case reverse selected of
            entry : _ -> Just entry.cursor
            [] -> latest
          stoppedInsidePage = length selected < length page.items
      if stoppedInsidePage
        then pure (EpisodeWindow <$> latest' <*> pure (used + selectedTokens) <*> pure True)
        else case latest' of
          Nothing -> pure Nothing
          Just end
            | page.hasMore && used + selectedTokens < tokenLimit ->
                go end (used + selectedTokens) latest'
            | otherwise ->
                pure (Just (EpisodeWindow end (used + selectedTokens) page.hasMore))

-- | One event-driven coverage-heal step: enqueue the oldest raw island at or
-- below the live historian cursor as a durable backfill run.  Boot uses it
-- for history predating enrollment; every publication and every quiet round
-- reuse it so a commit-order skip (an insert whose ingest_seq committed after
-- the cursor passed it) or an interrupted backfill chain is repaired on the
-- next conversation event instead of the next restart.  Publication of the
-- enqueued run still validates source hash and active non-overlap, and never
-- moves the live cursor.
healOldestCoverageGap ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  TimeZone ->
  Text ->
  Int ->
  ConversationScope ->
  Eff es (Maybe CaptureRun)
healOldestCoverageGap tz profile sourceBudget scope = do
  findOldestBackfillGap scope >>= \case
    Nothing -> pure Nothing
    Just gap ->
      scanEpisodeWindowThrough tz scope gap.backfillExpected gap.backfillThrough sourceBudget >>= \case
        Nothing -> pure Nothing
        Just window -> do
          let request =
                CaptureRequest
                  { requestReason = CaptureBackfill,
                    requestHistorianProfile = profile,
                    requestPromptVersion = historianPromptVersion,
                    requestSchemaVersion = historianSchemaVersion
                  }
          enqueued <- enqueueBackfillRun scope gap.backfillExpected window.endCursor request
          for_ enqueued $ \run ->
            logInfo "historian: coverage backfill enqueued" $
              object
                [ "group_id" .= conversationStorageId scope,
                  "capture_run_id" .= run.crId,
                  "start_ingest_seq" .= run.crRange.srStart.ingestSeq,
                  "end_ingest_seq" .= run.crRange.srEnd.ingestSeq,
                  "gap_end_ingest_seq" .= gap.backfillThrough.ingestSeq,
                  "source_tokens" .= window.estimatedTokens
                ]
          pure enqueued

-- | Select a non-empty prefix by conservative token cost.  Message count is
-- deliberately absent from the policy: a 200-line emoji exchange and a
-- 20-line technical discussion should not consume the same generation.
takeEpisodeByToken :: TimeZone -> Int -> [LedgerItem] -> [LedgerItem]
takeEpisodeByToken tz tokenLimit = go 0 []
  where
    go _ selected [] = reverse selected
    go _ [] (entry : rest) = go (ledgerTokenCost tz entry) [entry] rest
    go used selected (entry : rest)
      | used + cost > max 1 tokenLimit = reverse selected
      | otherwise = go (used + cost) (entry : selected) rest
      where
        cost = ledgerTokenCost tz entry

ledgerTokenCost :: TimeZone -> LedgerItem -> Int
ledgerTokenCost tz entry
  | entry.transcriptEligible = 4 + estimateTextTokens (renderHistorianSourceLine tz entry.history)
  | otherwise = 1

data CaptureProcessResult
  = CapturePublished !CompartmentId
  | CaptureRetryScheduled
  | CaptureAbandoned
  deriving stock (Show, Eq)

processCaptureLease ::
  (LLM :> es, WithConnection :> es, IOE :> es) =>
  Int ->
  Int ->
  TimeZone ->
  TaskRegistry ->
  CaptureLease ->
  Eff es CaptureProcessResult
processCaptureLease inputBudget timeoutSeconds tz tasks lease = do
  let run = lease.leaseRun
      gid = GroupId run.crConversationId
      scope = conversationScopeFor gid
  if run.crPromptVersion /= historianPromptVersion || run.crSchemaVersion /= historianSchemaVersion
    then do
      _ <- abandonCaptureRun lease "capture run uses an unsupported historian prompt/schema version" []
      pure CaptureAbandoned
    else do
      current <- captureRunSourceMatches scope run
      if not current
        then do
          _ <- abandonCaptureRun lease "source hash or historian cursor changed before generation" []
          pure CaptureAbandoned
        else do
          source <- loadCaptureSource run
          protected <- liftIO (inFlightTriggers tasks gid)
          let sourceMessageIds = Set.fromList [entry.history.canonicalId | entry <- source]
              protectedInRange = Set.intersection protected sourceMessageIds
          if not (Set.null protectedInRange)
            then do
              _ <- failCaptureRun lease historianProtectedRetrySeconds "source range contains an in-flight turn" []
              pure CaptureRetryScheduled
            else do
              captureResult <-
                if null [() | entry <- source, entry.transcriptEligible]
                  then
                    let capture = deterministicFilteredCapture source
                     in pure (Right (captureJsonText capture, capture))
                  else generateCapture inputBudget timeoutSeconds tz run.crHistorianProfile scope run source
              case captureResult of
                Left (raw, errors) -> do
                  stored <-
                    recordCaptureRejected
                      lease
                      (historianRetryDelaySeconds run.crAttempt)
                      (T.intercalate "; " (map (.validationMessage) errors))
                      raw
                      errors
                  unless stored (error "historian rejection lease expired before retry was recorded")
                  pure CaptureRetryScheduled
                Right (raw, capture) -> case validateEpisodeCapture run source capture of
                  Left errors -> do
                    stored <-
                      recordCaptureRejected
                        lease
                        (historianRetryDelaySeconds run.crAttempt)
                        "episode capture failed semantic validation"
                        raw
                        errors
                    unless stored (error "historian validation lease expired before retry was recorded")
                    pure CaptureRetryScheduled
                  Right validated -> do
                    stored <-
                      recordCaptureGenerated
                        lease
                        raw
                        capture
                        (captureValidationWarnings validated)
                    unless stored (error "historian generation lease expired before publication")
                    CapturePublished <$> publishCaptureRun scope lease validated

generateCapture ::
  (LLM :> es, WithConnection :> es, IOE :> es) =>
  Int ->
  Int ->
  TimeZone ->
  Text ->
  ConversationScope ->
  CaptureRun ->
  [LedgerItem] ->
  Eff es (Either (Text, [CaptureValidationError]) (Text, EpisodeCapture))
generateCapture inputBudget timeoutSeconds tz profile scope run source = do
  now <- liftIO getCurrentTime
  memoryCatalog <- loadMemoryCatalog scope source
  let sourceLines = [renderHistorianSourceLine tz entry.history | entry <- source, entry.transcriptEligible]
      messages = renderHistorianMessages tz now run memoryCatalog sourceLines inputBudget
  if estimateMessagesTokens messages > inputBudget
    then
      pure $
        Left
          ( case messages of
              [_, MsgUser input] -> input
              _ -> "",
            [CaptureValidationError "input_budget" "historian prompt exceeded the configured profile input budget"]
          )
    else generateHistorianCapture timeoutSeconds profile run.crConversationId messages

-- | Execute the exact model-facing Historian generation policy.  A malformed
-- JSON/schema response receives one bounded repair turn containing the raw
-- answer and a precise wire contract.  Provider failures and semantic
-- validation failures are not retried here: the durable capture-run retry
-- policy owns those, and omission must never be hidden by repeated sampling.
generateHistorianCapture ::
  (LLM :> es) =>
  Int ->
  Text ->
  Int64 ->
  [ChatMessage] ->
  Eff es (Either (Text, [CaptureValidationError]) (Text, EpisodeCapture))
generateHistorianCapture timeoutSeconds profile conversationId messages = do
  first <- chat historianCtx profile messages []
  case decodeResponse first of
    Right capture -> pure (Right capture)
    Left (raw, responseError, True) -> do
      repaired <- chat historianCtx profile (repairMessages raw) []
      pure $ case decodeResponse repaired of
        Right capture -> Right capture
        Left (repairRaw, repairError, _) ->
          Left
            ( repairRaw,
              [ CaptureValidationError
                  "response"
                  ("initial response invalid: " <> responseError <> "; repair invalid: " <> repairError)
              ]
            )
    Left (raw, responseError, False) ->
      pure (Left (raw, [CaptureValidationError "response" responseError]))
  where
    -- This durable job gets one long transport attempt.  The capture-run
    -- queue owns retries across attempts, which keeps their timing visible and
    -- lets pending work pass a failed range.
    historianCtx =
      ChatCtx
        "historian"
        (Just conversationId)
        Nothing
        (Just (max 1 timeoutSeconds))
        (Just [])
        Nothing
        Nothing
    decodeResponse = \case
      Left err -> Left ("", "provider: " <> err, False)
      Right (InterruptedResp raw err) -> Left (raw, "provider interrupted: " <> err, False)
      Right ToolCallsResp {} -> Left ("", "historian returned unexpected tool calls", False)
      Right (ContentResp raw) -> case parseEpisodeCapture raw of
        Left err -> Left (raw, T.pack err, True)
        Right capture -> Right (raw, capture)
    repairMessages raw =
      messages
        <> [ MsgAssistant (if T.null (T.strip raw) then "{}" else T.take 16_000 raw),
             MsgUser historianRepairPrompt
           ]

historianRepairPrompt :: Text
historianRepairPrompt =
  T.unlines
    [ "The previous answer was not valid EpisodeCapture JSON.",
      "Return the complete corrected JSON object only; do not explain the repair.",
      "summary_p1/summary_p2/summary_p3 must each be objects with text and evidence_message_ids.",
      "Every message id, user_id, memory id, and version must be a JSON number, never a quoted string.",
      "For add use only action,scope,user_id,content,category,evidence_message_ids.",
      "For update use only action,id,version,content,evidence_message_ids; category/scope/user_id are forbidden.",
      "For archive use only action,id,version,evidence_message_ids.",
      "Use exactly the top-level and nested fields required by the original system instruction."
    ]

loadMemoryCatalog ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  [LedgerItem] ->
  Eff es [Text]
loadMemoryCatalog scope source = do
  groupMemories <- listMemories (groupMemoryNamespace scope)
  userMemories <- mapM loadUser topSpeakers
  pure $
    ["[group memories]"]
      <> memoryLines groupMemories
      <> concat [["", "[user memories — user_id=" <> tshow userId <> "]"] <> memoryLines memories | (userId, memories) <- userMemories]
  where
    topSpeakers =
      take 12
        . map fst
        . sortOn (Down . snd)
        . Map.toList
        . Map.fromListWith (+)
        $ [ (entry.history.authorPrincipalId, 1 :: Int)
          | entry <- source,
            entry.transcriptEligible,
            not entry.history.fromBot
          ]
    loadUser userId = (userId,) <$> listMemories (userMemoryNamespace scope userId)
    memoryLines [] = ["(none)"]
    memoryLines memories = map renderMemory memories
    renderMemory memory =
      "- id="
        <> tshow memory.memId.unMemoryId
        <> " version="
        <> tshow memory.memVersion.unMemoryVersion
        <> " lifecycle="
        <> memory.memLifecycle
        <> maybe "" (" category=" <>) memory.memCategory
        <> ": "
        <> memory.memContent

renderHistorianInput :: TimeZone -> UTCTime -> CaptureRun -> [Text] -> [Text] -> Int -> Text
renderHistorianInput tz now run memoryCatalog sourceLines inputBudget =
  T.unlines $
    [ "local_now=" <> fmtEnvStamp tz now,
      "conversation_id=" <> tshow run.crConversationId,
      "source_ingest_range=" <> tshow run.crRange.srStart.ingestSeq <> ".." <> tshow run.crRange.srEnd.ingestSeq,
      "source_message_count=" <> tshow run.crRange.srMessageCount,
      "",
      "Existing scoped memories (only these ids/versions may be updated or archived):"
    ]
      <> takeLinesByToken (max 256 (inputBudget `div` 5)) memoryCatalog
      <> ["", "Source transcript (cite message_id values exactly):"]
      <> sourceLines
      <> ["", "Return the EpisodeCapture JSON object."]

-- | Exact production Historian request construction, exposed so the offline
-- release-gate executable can replay labelled fixtures against a real profile
-- without touching PostgreSQL or publishing projections.
renderHistorianMessages :: TimeZone -> UTCTime -> CaptureRun -> [Text] -> [Text] -> Int -> [ChatMessage]
renderHistorianMessages tz now run memoryCatalog sourceLines inputBudget =
  [ MsgSystem historianSystem,
    MsgUser (renderHistorianInput tz now run memoryCatalog sourceLines inputBudget)
  ]

takeLinesByToken :: Int -> [Text] -> [Text]
takeLinesByToken tokenLimit = go 0
  where
    go _ [] = []
    go used (line : rest)
      | used + cost > tokenLimit = ["(additional memories omitted by input budget)"]
      | otherwise = line : go (used + cost) rest
      where
        cost = 1 + estimateTextTokens line

renderHistorianSourceLine :: TimeZone -> HistoryItem -> Text
renderHistorianSourceLine tz history =
  "["
    <> fmtDateHM tz history.receivedAt
    <> " principal_id="
    <> tshow history.authorPrincipalId
    <> " name="
    <> bestName history
    <> " message_id="
    <> tshow history.canonicalId
    <> maybe "" (\reply -> " reply_to=" <> tshow reply) history.replyTo
    <> "]: "
    <> T.replace "\n" " ⏎ " history.renderedText

deterministicFilteredCapture :: [LedgerItem] -> EpisodeCapture
deterministicFilteredCapture _ =
  EpisodeCapture
    { captureSummaryP1 = CitedSummary "No transcript-eligible chat messages were present in this source range." [],
      captureSummaryP2 = CitedSummary "No visible chat messages." [],
      captureSummaryP3 = CitedSummary "Non-chat ledger activity." [],
      captureImportance = 0,
      captureConfidence = 1,
      captureEpisodeKind = Ambient,
      captureMemoryProposals = []
    }

historianInputBudget :: Text -> ModelCatalog -> Int
historianInputBudget profile catalog =
  contextInputBudget limits False
  where
    limits = maybe defaultContextLimits (.contextLimits) (lookupModelCapabilities profile catalog)

historianSystem :: Text
historianSystem =
  T.unlines
    [ "You are Max's Historian v2. Capture one settled multi-speaker chat episode once.",
      "Return exactly one JSON object and no prose. Unknown fields are rejected.",
      "Raw messages are immutable; your output is a rebuildable projection with exact evidence.",
      "",
      "Required top-level fields:",
      "  summary_p1, summary_p2, summary_p3: {text, evidence_message_ids}",
      "  importance: number 0..1",
      "  confidence: number 0..1",
      "  episode_kind: max_interaction|ambient|mixed|decision|support|social",
      "  memory_proposals: array",
      "",
      "Summary policy:",
      "  Write summaries and memory content in the source transcript's dominant language; preserve names, dates, and technical terms exactly.",
      "  P1 (<=4000 chars): faithful episode account: speakers, goals, decisions, commitments, unresolved points, and outcome.",
      "  P2 (<=2000 chars): compact key facts and outcome.",
      "  P3 (<=500 chars): one anchor saying what happened.",
      "  Every summary must cite one or more message_id values from the supplied transcript.",
      "  Preserve who said what. Do not turn speculation, jokes, or another speaker's claim into a fact about someone.",
      "",
      "Memory proposals are optional and must be stable enough to help future conversations. Most ambient/social episodes need none.",
      "Never store one-off meal/social plans, same-day coordination, transient troubleshooting outcomes, or casual acknowledgements as durable memory.",
      "An explicit group decision or a named speaker's explicit commitment tied to an absolute-dated plan is high-value durable memory; the date may be stated on that line or inherited only when the surrounding plan makes it unambiguous.",
      "When a speaker corrects an earlier statement, store only the final state and cite the correcting message (the earlier message may be cited too).",
      "When new evidence corrects or replaces an existing listed memory about the same subject and topic, update that id/version in place; never archive it and add a duplicate identity.",
      "Archive an existing memory only when it is clearly obsolete and there is no replacement fact to store.",
      "Allowed add categories: person_fact, preference, group_convention, ongoing_project, commitment, decision, running_joke.",
      "Never infer relationship_context. Never create reminders, tasks, or transient state as memory.",
      "A named person's fact, preference, project, or commitment must use user scope with that user_id; never encode the subject id only inside group-memory content.",
      "When several speakers make distinct durable commitments, emit one user-scope commitment proposal for each speaker; do not collapse them into group memory or omit one because another was captured.",
      "Use group scope for group-wide decisions, conventions, and shared running jokes, not as a container for an individual's memory.",
      "For user scope, user_id must be the subject and at least one cited message must be spoken by that user.",
      "For group scope, omit user_id. Only update/archive ids and versions listed in Existing scoped memories.",
      "Each proposal must cite exact source message ids. Content is self-contained, <=300 chars, with absolute dates.",
      "Resolve yesterday/tomorrow/weekday and other relative dates from the local_now date and weekday supplied in the input; never guess the calendar.",
      "Maximum 12 proposals.",
      "Before returning, silently scan every speaker's lines once more: each explicit group decision and each named speaker's explicit commitment tied to an absolute-dated plan must have its own correctly scoped proposal unless an existing memory already says it. One speaker's proposal never substitutes for another's; never guess an ambiguous inherited date.",
      "",
      "Proposal forms:",
      "  {\"action\":\"add\",\"scope\":\"group\",\"content\":\"...\",\"category\":\"decision\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"...\",\"category\":\"preference\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"archive\",\"id\":5,\"version\":2,\"evidence_message_ids\":[1]}"
    ]

captureJsonText :: EpisodeCapture -> Text
captureJsonText = TE.decodeUtf8 . LBS.toStrict . encode

unGroupId :: GroupId -> Int64
unGroupId (GroupId gid) = gid
