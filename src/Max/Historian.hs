-- | Quiet-period capture into sourced summaries and scoped memory.
-- Scheduling stays local; publication rechecks the source and cursor atomically.
module Max.Historian
  ( historianWorker,
    historianPromptVersion,
    historianSchemaVersion,
    CaptureProcessResult (..),
    processCaptureRun,
    prepareOldestCoverageGap,

    -- * Pure policy exposed for tests
    takeEpisodeByToken,
    renderHistorianSourceLine,
    renderHistorianMessages,
    generateHistorianCapture,
    historianSystem,
  )
where

import Control.Monad (forever, when)
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
import Data.Time (TimeZone, addUTCTime, getCurrentTime)
import Effectful
import Effectful.Exception (bracket)
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
  ( EpisodeRequest (..),
    EpisodeScheduler,
    EpisodeWork (..),
    armEpisode,
    awaitDueEpisode,
    continueEpisodeAt,
    deferEpisodeAt,
    episodeGroup,
    episodePendingDeadline,
    releaseEpisodeClaim,
    retryEpisodeAt,
  )
import Max.EpisodeStore
import Max.Http.Failure (renderResponseFailure)
import Max.LLM.Failure (renderLLMFailure)
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
import Max.Worker (recovering)
import OneBot.Types (GroupId (..))

historianPromptVersion :: Text
historianPromptVersion = "historian/v7"

historianSchemaVersion :: Int
historianSchemaVersion = 4

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
  recovering "historian discovery" $ do
    sessions <- listSessions defaultModel
    for_ sessions $ \session -> do
      let gid = session.groupId
          scope = conversationScopeFor gid
      gap <- findOldestBackfillGap scope
      case gap of
        Just _ -> liftIO (getCurrentTime >>= continueEpisodeAt scheduler gid)
        Nothing -> do
          cursor <- loadCursor scope historianCursor
          pending <- hasMessagesAfter scope cursor
          when pending (liftIO (armEpisode scheduler gid))
  forever $
    bracket
      (liftIO (awaitDueEpisode scheduler))
      (liftIO . releaseEpisodeClaim scheduler)
      ( \work ->
          runWork work `catchSync` \err -> do
            liftIO (getCurrentTime >>= retryEpisodeAt scheduler work)
            logAttention "historian: capture failed" (object ["group_id" .= unGroupId (episodeGroup work.request), "error" .= tshow err])
      )
  where
    inputBudget = historianInputBudget profile catalog
    sourceBudget = min 65536 (max 512 (inputBudget * 2 `div` 3))
    request reason model = CaptureRequest reason model historianPromptVersion historianSchemaVersion

    runWork work = do
      let gid = episodeGroup work.request
          scope = conversationScopeFor gid
      prepared <- case work.request of
        RebuildEpisode _ compartment model -> prepareRebuildRun scope compartment (request CaptureRebuild model)
        SettledConversation _ -> do
          moved <- liftIO (episodePendingDeadline scheduler gid)
          protected <- liftIO (inFlightTriggers tasks gid)
          case (moved, Set.null protected) of
            (Just _, _) -> pure Nothing
            (_, False) -> liftIO (getCurrentTime >>= deferEpisodeAt scheduler work) >> pure Nothing
            (Nothing, True) -> do
              gap <- prepareOldestCoverageGap tz profile sourceBudget scope
              case gap of
                Just run -> pure (Just run)
                Nothing -> do
                  cursor <- loadCursor scope historianCursor
                  window <- scanEpisodeWindow tz scope cursor sourceBudget
                  movedDuringScan <- liftIO (episodePendingDeadline scheduler gid)
                  case (window, movedDuringScan) of
                    (Just selected, Nothing) ->
                      prepareCaptureRun
                        scope
                        cursor
                        selected.endCursor
                        (request (if selected.hitTokenBoundary then CaptureTokenPressure else CaptureIdle) profile)
                    _ -> pure Nothing
      for_ prepared $ \run -> do
        outcome <- trySync (processCaptureRun (historianInputBudget run.crHistorianProfile catalog) timeoutSeconds tz tasks run)
        result <- case outcome of
          Right result -> pure result
          Left err -> do
            recordCaptureFailure run (tshow err) Nothing [] `catchSync` \writeError ->
              logAttention "historian: failure diagnostic unavailable" (object ["error" .= tshow writeError])
            logAttention "historian: generation or publication failed" (object ["capture_run_id" .= run.crId, "error" .= tshow err])
            pure CaptureFailed
        now <- liftIO getCurrentTime
        case result of
          CapturePublished compartment -> do
            logInfo "historian: capture published" (object ["group_id" .= run.crConversationId, "capture_run_id" .= run.crId, "compartment_id" .= compartment])
            gap <- findOldestBackfillGap scope
            cursor <- loadCursor scope historianCursor
            pending <- hasMessagesAfter scope cursor
            case gap of
              Just _ -> liftIO (continueEpisodeAt scheduler gid (addUTCTime 1 now))
              Nothing
                | pending ->
                    liftIO $
                      if run.crReason == "token_pressure" then continueEpisodeAt scheduler gid now else armEpisode scheduler gid
              Nothing -> pure ()
          CaptureFailed -> liftIO (retryEpisodeAt scheduler work now)
          CaptureDeferred -> liftIO (deferEpisodeAt scheduler work now)
          CaptureAbandoned -> liftIO (deferEpisodeAt scheduler work now)

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

-- | Backfill the oldest uncovered range below the live cursor, including late
-- commits whose ingestion sequence the cursor already passed. Publication checks
-- source hash and non-overlap without moving the live cursor.
prepareOldestCoverageGap ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  TimeZone ->
  Text ->
  Int ->
  ConversationScope ->
  Eff es (Maybe CaptureRun)
prepareOldestCoverageGap tz profile sourceBudget scope = do
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
          prepared <- prepareBackfillRun scope gap.backfillExpected window.endCursor request
          for_ prepared $ \run ->
            logInfo "historian: coverage backfill prepared" $
              object
                [ "group_id" .= conversationStorageId scope,
                  "capture_run_id" .= run.crId,
                  "start_ingest_seq" .= run.crRange.srStart.ingestSeq,
                  "end_ingest_seq" .= run.crRange.srEnd.ingestSeq,
                  "gap_end_ingest_seq" .= gap.backfillThrough.ingestSeq,
                  "source_tokens" .= window.estimatedTokens
                ]
          pure prepared

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
  | CaptureFailed
  | CaptureDeferred
  | CaptureAbandoned
  deriving stock (Show, Eq)

processCaptureRun :: (LLM :> es, WithConnection :> es, IOE :> es) => Int -> Int -> TimeZone -> TaskRegistry -> CaptureRun -> Eff es CaptureProcessResult
processCaptureRun inputBudget timeoutSeconds tz tasks run = do
  let gid = GroupId run.crConversationId
      scope = conversationScopeFor gid
  current <- captureRunSourceMatches scope run
  if not current || run.crPromptVersion /= historianPromptVersion || run.crSchemaVersion /= historianSchemaVersion
    then pure CaptureAbandoned
    else do
      source <- loadCaptureSource run
      protected <- liftIO (inFlightTriggers tasks gid)
      let sourceMessageIds = Set.fromList [entry.history.canonicalId | entry <- source]
      if not (Set.null (Set.intersection protected sourceMessageIds))
        then pure CaptureDeferred
        else do
          generated <-
            if any (.transcriptEligible) source
              then generateCapture inputBudget timeoutSeconds tz run.crHistorianProfile scope run source
              else let capture = deterministicFilteredCapture source in pure (Right (captureJsonText capture, capture))
          case generated of
            Left (raw, errors) -> failed raw errors
            Right (raw, capture) -> case validateEpisodeCapture run source capture of
              Left errors -> failed raw errors
              Right validated -> CapturePublished <$> publishCaptureRun scope run raw validated
  where
    failed raw errors = do
      recordCaptureFailure run (T.intercalate "; " (map (.validationMessage) errors)) (Just raw) errors
      pure CaptureFailed

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

-- | Repair malformed JSON once. Provider and semantic failures use the local
-- scheduler's backoff; they do not trigger repeated sampling within this call.
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
    -- Transport retries belong to the scheduler.
    historianCtx =
      ChatCtx
        "historian"
        (Just conversationId)
        Nothing
        (Just (max 1 timeoutSeconds))
        (Just [])
        Nothing
    decodeResponse = \case
      Left err -> Left ("", "provider: " <> renderLLMFailure err, False)
      Right (InterruptedResp raw err) -> Left (raw, "provider interrupted: " <> renderResponseFailure err, False)
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
      "summary_p1, summary_p2, and summary_p3 must each be an object with text and evidence_message_ids.",
      "Every message id, user_id, memory id, and expected_version must be a JSON number, never a quoted string.",
      "For add use only action,scope,user_id,content,category,evidence_message_ids.",
      "For update use only action,id,expected_version,content,evidence_message_ids; category/scope/user_id are forbidden.",
      "For archive use only action,id,expected_version,evidence_message_ids.",
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
    { captureSummaryP1 = emptySummary,
      captureSummaryP2 = emptySummary,
      captureSummaryP3 = emptySummary,
      captureImportance = 0,
      captureConfidence = 1,
      captureEpisodeKind = Ambient,
      captureMemoryProposals = []
    }
  where
    emptySummary = CitedSummary "No transcript-eligible chat messages were present in this source range." []

historianInputBudget :: Text -> ModelCatalog -> Int
historianInputBudget profile catalog =
  contextInputBudget limits False
  where
    limits = maybe defaultContextLimits (.contextLimits) (lookupModelCapabilities profile catalog)

historianSystem :: Text
historianSystem =
  T.unlines
    [ "You are Max's Historian v4. Capture one settled multi-speaker chat episode once.",
      "Return exactly one JSON object and no prose. Unknown fields are rejected.",
      "Raw messages are immutable; your output is a rebuildable projection with exact evidence.",
      "",
      "Required top-level fields:",
      "  summary_p1: {text, evidence_message_ids}",
      "  summary_p2: {text, evidence_message_ids}",
      "  summary_p3: {text, evidence_message_ids}",
      "  importance: number 0..1",
      "  confidence: number 0..1",
      "  episode_kind: max_interaction|ambient|mixed|decision|support|social",
      "  memory_proposals: array",
      "",
      "Summary policy:",
      "  Write the summary and memory content in the source transcript's dominant language; preserve names, dates, and technical terms exactly.",
      "  P1 (<=4000 chars): faithful account of speakers, goals, decisions, commitments, unresolved points, and outcome.",
      "  P2 (<=2000 chars): shorter, self-contained key facts, decisions, and unresolved points.",
      "  P3 (<=500 chars): brief, self-contained anchor for recognizing and retrieving this episode.",
      "  Each shorter tier compresses the same evidence; never add facts absent from P1. Prefer P3 shorter than P2 and P2 shorter than P1.",
      "  Each summary must cite one or more message_id values from the supplied transcript.",
      "  Preserve who said what. Do not turn speculation, jokes, or another speaker's claim into a fact about someone.",
      "",
      "Memory proposals are optional and must be stable enough to help future conversations. Most ambient/social episodes need none.",
      "Never store one-off meal/social plans, same-day coordination, transient troubleshooting outcomes, or casual acknowledgements as durable memory.",
      "An explicit group decision or a named speaker's explicit commitment tied to an absolute-dated plan is high-value durable memory; the date may be stated on that line or inherited only when the surrounding plan makes it unambiguous.",
      "When a speaker corrects an earlier statement, store only the final state and cite the correcting message (the earlier message may be cited too).",
      "When new evidence corrects or replaces an existing listed memory about the same subject and topic, update that id with its listed current expected_version in place; never archive it and add a duplicate identity.",
      "Archive an existing memory only when it is clearly obsolete and there is no replacement fact to store.",
      "Allowed add categories: person_fact, preference, group_convention, ongoing_project, commitment, decision, running_joke.",
      "Never infer relationship_context. Never create reminders, tasks, or transient state as memory.",
      "A named person's fact, preference, project, or commitment must use user scope with that user_id; never encode the subject id only inside group-memory content.",
      "When several speakers make distinct durable commitments, emit one user-scope commitment proposal for each speaker; do not collapse them into group memory or omit one because another was captured.",
      "Use group scope for group-wide decisions, conventions, and shared running jokes, not as a container for an individual's memory.",
      "For user scope, user_id must be the internal principal_id printed on the subject's source lines, copied exactly. Never use a QQ/platform account number, display name, or a number mentioned in message text. At least one cited message must be spoken by that principal.",
      "For group scope, omit user_id. Only update/archive ids listed in Existing scoped memories. Copy the listed current version exactly into expected_version; NEVER increment it. The database generates the new version.",
      "Each proposal must cite exact source message ids. Content is self-contained, <=300 chars, with absolute dates.",
      "Resolve yesterday/tomorrow/weekday and other relative dates from the local_now date and weekday supplied in the input; never guess the calendar.",
      "Maximum 12 proposals.",
      "Before returning, silently scan every speaker's lines once more: each explicit group decision and each named speaker's explicit commitment tied to an absolute-dated plan must have its own correctly scoped proposal unless an existing memory already says it. One speaker's proposal never substitutes for another's; never guess an ambiguous inherited date.",
      "",
      "Proposal forms (for the update/archive examples, Existing scoped memories contains id=5 version=1):",
      "  {\"action\":\"add\",\"scope\":\"group\",\"content\":\"...\",\"category\":\"decision\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"...\",\"category\":\"preference\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"update\",\"id\":5,\"expected_version\":1,\"content\":\"...\",\"evidence_message_ids\":[1]}",
      "  {\"action\":\"archive\",\"id\":5,\"expected_version\":1,\"evidence_message_ids\":[1]}"
    ]

captureJsonText :: EpisodeCapture -> Text
captureJsonText = TE.decodeUtf8 . LBS.toStrict . encode

unGroupId :: GroupId -> Int64
unGroupId (GroupId gid) = gid
