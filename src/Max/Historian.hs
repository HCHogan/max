-- |
-- Historian v2: one durable episode capture produces a rebuildable
-- chronological compartment and scoped semantic-memory proposals.
--
-- Quiet-period scheduling is intentionally in-memory; exact ranges, source
-- hashes, leases, retries, model output, validation, publication, and cursor
-- advancement are durable in 'Max.EpisodeStore'.  A restart therefore replays
-- the same range or recovers it from the historian cursor without skipping raw
-- messages.
module Max.Historian
  ( historianWorker,
    historianPromptVersion,
    historianSchemaVersion,
    CaptureProcessResult (..),
    processCaptureLease,

    -- * Pure policy exposed for tests
    takeEpisodeByToken,
    renderHistorianSourceLine,
  )
where

import Control.Monad (forever, unless, when)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.ConversationCursor (historianCursor, loadCursor)
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    bestName,
    fetchOldestPageAfter,
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
  ( MemoryItem (..),
    MemoryId (..),
    MemoryVersion (..),
    groupMemoryNamespace,
    listMemories,
    userMemoryNamespace,
  )
import Max.ModelCatalog
  ( ModelCatalog,
    ModelCapabilities (..),
    contextInputBudget,
    defaultContextLimits,
    lookupModelCapabilities,
  )
import Max.Session.Types (Session (..))
import Max.Tasks (TaskRegistry, inFlightTriggers)
import Max.Time (fmtDate, fmtDateHM)
import Max.Util (catchSync, trySync)
import OneBot.Types (GroupId (..))

historianPromptVersion :: Text
historianPromptVersion = "historian/v2"

historianSchemaVersion :: Int
historianSchemaVersion = 1

historianLeaseSeconds :: Int
historianLeaseSeconds = 600

historianRetrySeconds :: Int
historianRetrySeconds = 60

-- | Internal SQL pagination is not an episode-size policy.  Pages are joined
-- until the deterministic token boundary is reached.
ledgerPageSize :: Int
ledgerPageSize = 500

historianWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  ModelCatalog ->
  TimeZone ->
  TaskRegistry ->
  Text ->
  EpisodeScheduler ->
  Eff es ()
historianWorker profile catalog tz tasks defaultModel scheduler = localDomain "historian" $ do
  -- Persistent jobs win at boot.  The scheduler can disappear; leases and
  -- exact source ranges cannot.
  drainAvailableRuns
  recoverPendingConversations
  forever $ do
    gid <- liftIO (awaitDueEpisode scheduler)
    finally
      ( (enqueueSettledConversation gid >> drainAvailableRuns)
          `catchSync` \err -> do
            retryConversation gid
            logAttention "historian: scheduling round crashed" $
              object ["group_id" .= unGroupId gid, "error" .= T.pack (show err)]
      )
      (liftIO (releaseEpisodeClaim scheduler gid))
  where
    inputBudget = historianInputBudget profile catalog
    sourceBudget = max 512 (inputBudget * 2 `div` 3)

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
            Nothing -> pure ()
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
      claimCaptureRun "historian-v2" historianLeaseSeconds >>= \case
        Nothing -> pure ()
        Just lease -> do
          let runInputBudget = historianInputBudget lease.leaseRun.crHistorianProfile catalog
          result <- trySync (processCaptureLease runInputBudget tz tasks lease)
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
              pending <- hasMessagesAfter scope run.crRange.srEnd
              when pending $ do
                now <- liftIO getCurrentTime
                if run.crReason == "token_pressure"
                  then liftIO (continueEpisodeAt scheduler gid now)
                  else liftIO (armEpisode scheduler gid)
            Right CaptureRetryScheduled -> retryConversation (GroupId lease.leaseRun.crConversationId)
            Right CaptureAbandoned -> retryConversation (GroupId lease.leaseRun.crConversationId)
            Left err -> recoverLeaseFailure lease (T.pack (show err))
          drainAvailableRuns

    recoverLeaseFailure lease err = do
      let gid = GroupId lease.leaseRun.crConversationId
          scope = conversationScopeFor gid
      sourceCurrent <- captureRunSourceMatches scope lease.leaseRun `catchSync` \_ -> pure True
      if sourceCurrent
        then do
          _ <- failCaptureRun lease historianRetrySeconds err []
          retryConversation gid
          logAttention "historian: capture retry scheduled" $
            object ["capture_run_id" .= lease.leaseRun.crId, "error" .= err]
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
scanEpisodeWindow tz scope initial tokenLimit = go initial 0 Nothing
  where
    go cursor used latest = do
      page <- fetchOldestPageAfter scope cursor ledgerPageSize
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
  TimeZone ->
  TaskRegistry ->
  CaptureLease ->
  Eff es CaptureProcessResult
processCaptureLease inputBudget tz tasks lease = do
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
          let sourceMessageIds = Set.fromList [entry.history.messageId | entry <- source]
              protectedInRange = Set.intersection protected sourceMessageIds
          if not (Set.null protectedInRange)
            then do
              _ <- failCaptureRun lease historianRetrySeconds "source range contains an in-flight turn" []
              pure CaptureRetryScheduled
            else do
              captureResult <-
                if null [() | entry <- source, entry.transcriptEligible]
                  then
                    let capture = deterministicFilteredCapture source
                     in pure (Right (captureJsonText capture, capture))
                  else generateCapture inputBudget tz run.crHistorianProfile scope run source
              case captureResult of
                Left (raw, errors) -> do
                  stored <-
                    recordCaptureRejected
                      lease
                      historianRetrySeconds
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
                        historianRetrySeconds
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
  TimeZone ->
  Text ->
  ConversationScope ->
  CaptureRun ->
  [LedgerItem] ->
  Eff es (Either (Text, [CaptureValidationError]) (Text, EpisodeCapture))
generateCapture inputBudget tz profile scope run source = do
  now <- liftIO getCurrentTime
  memoryCatalog <- loadMemoryCatalog scope source
  let sourceLines = [renderHistorianSourceLine tz entry.history | entry <- source, entry.transcriptEligible]
      input = renderHistorianInput tz now run memoryCatalog sourceLines inputBudget
      messages = [MsgSystem historianSystem, MsgUser input]
  if estimateMessagesTokens messages > inputBudget
    then
      pure $
        Left
          ( input,
            [CaptureValidationError "input_budget" "historian prompt exceeded the configured profile input budget"]
          )
    else
      chat (ChatCtx "historian" (Just run.crConversationId) Nothing) profile messages [] >>= \case
        Left err ->
          pure (Left ("", [CaptureValidationError "provider" err]))
        Right ToolCallsResp {} ->
          pure (Left ("", [CaptureValidationError "response" "historian returned unexpected tool calls"]))
        Right (ContentResp raw) -> case parseEpisodeCapture raw of
          Left err ->
            pure (Left (raw, [CaptureValidationError "response" (T.pack err)]))
          Right capture -> pure (Right (raw, capture))

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
        $ [ (entry.history.userId, 1 :: Int)
          | entry <- source,
            entry.transcriptEligible,
            entry.history.userId /= entry.history.selfId
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
    [ "date=" <> fmtDate tz now,
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
    <> " user_id="
    <> tshow history.userId
    <> " name="
    <> fromMaybe (tshow history.userId) (bestName history)
    <> " message_id="
    <> tshow history.messageId
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
      "  P1 (<=4000 chars): faithful episode account: speakers, goals, decisions, commitments, unresolved points, and outcome.",
      "  P2 (<=2000 chars): compact key facts and outcome.",
      "  P3 (<=500 chars): one anchor saying what happened.",
      "  Every summary must cite one or more message_id values from the supplied transcript.",
      "  Preserve who said what. Do not turn speculation, jokes, or another speaker's claim into a fact about someone.",
      "",
      "Memory proposals are optional and must be stable enough to help future conversations. Most episodes need none.",
      "Allowed add categories: person_fact, preference, group_convention, ongoing_project, commitment, decision, running_joke.",
      "Never infer relationship_context. Never create reminders, tasks, or transient state as memory.",
      "For user scope, user_id must be the subject and at least one cited message must be spoken by that user.",
      "For group scope, omit user_id. Only update/archive ids and versions listed in Existing scoped memories.",
      "Each proposal must cite exact source message ids. Content is self-contained, <=300 chars, with absolute dates.",
      "Maximum 12 proposals.",
      "",
      "Proposal forms:",
      "  {\"action\":\"add\",\"scope\":\"group\",\"content\":\"...\",\"category\":\"decision\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"...\",\"category\":\"preference\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"archive\",\"id\":5,\"version\":2,\"evidence_message_ids\":[1]}"
    ]

captureJsonText :: EpisodeCapture -> Text
captureJsonText = TE.decodeUtf8 . LBS.toStrict . encode

tshow :: (Show a) => a -> Text
tshow = T.pack . show

unGroupId :: GroupId -> Int64
unGroupId (GroupId gid) = gid
