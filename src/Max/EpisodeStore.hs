-- | Source-checked publication of summaries, citations and scoped memory.
-- Capture execution stays in memory; completed results commit atomically.
module Max.EpisodeStore
  ( CaptureRunId (..),
    CompartmentId (..),
    EpisodeHandle (..),
    episodeHandleText,
    parseEpisodeHandle,
    CaptureReason (..),
    CaptureRun (..),
    CaptureRequest (..),
    BackfillGap (..),
    SourceRange (..),
    EpisodeKind (..),
    CitedSummary (..),
    EpisodeMemoryProposal (..),
    EpisodeCapture (..),
    CaptureValidationError (..),
    ValidatedEpisodeCapture,
    ActiveCompartment (..),
    EpisodeExpansion (..),
    parseEpisodeCapture,
    validateEpisodeCapture,
    captureValidationWarnings,
    prepareCaptureRun,
    findOldestBackfillGap,
    prepareBackfillRun,
    prepareRebuildRun,
    loadCaptureSource,
    recordCaptureFailure,
    reviewRejectedMemoryProposal,
    captureRunSourceMatches,
    publishCaptureRun,
    listActiveCompartments,
    expandEpisode,
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM, unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple
  ( FromRow,
    In (..),
    Only (..),
    Query,
  )
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Database.PostgreSQL.Simple.ToField (ToField)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope
  ( ConversationScope,
    RecallPolicy,
    conversationStorageId,
    currentConversationRecall,
    recallConversationScope,
  )
import Max.DB.ConversationCursor
  ( advanceCursor,
    historianCursor,
    loadCursor,
  )
import Max.DB.ConversationLock (lockConversation)
import Max.DB.History
  ( HistoryItem (..),
    LedgerItem (..),
    MessageCursor (..),
    historyColumns,
    transcriptEligibleExpr,
  )
import Max.DB.Transaction (withTransaction)
import Max.Episode.Types
import Max.Memory.Policy
  ( DuplicatePolicy (RejectExactDuplicates),
    MemoryAdmissionFailure (..),
  )
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryCategory (..),
    MemoryDraft (..),
    MemoryEvidence (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryLifecycle (..),
    MemoryMutationResult (..),
    MemoryScope (..),
    MemoryUpdate (..),
    MemoryVersion (..),
    admitMemory,
    archiveVisibleMemory,
    fetchVisibleMemory,
    memoryNamespace,
    parseCategory,
    parseScope,
    updateVisibleMemory,
  )
import Max.Util (encodeText, tshow)

newtype CaptureRunId = CaptureRunId {unCaptureRunId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField, FromJSON, ToJSON)

data CaptureReason
  = CaptureIdle
  | CaptureVolume
  | CaptureTokenPressure
  | CaptureBackfill
  | CaptureRebuild
  deriving stock (Show, Eq)

captureReasonText :: CaptureReason -> Text
captureReasonText = \case
  CaptureIdle -> "idle"
  CaptureVolume -> "volume"
  CaptureTokenPressure -> "token_pressure"
  CaptureBackfill -> "backfill"
  CaptureRebuild -> "rebuild"

data CaptureRun = CaptureRun
  { crId :: !CaptureRunId,
    crConversationId :: !Int64,
    crExpectedCursor :: !MessageCursor,
    crRange :: !SourceRange,
    crReason :: !Text,
    crHistorianProfile :: !Text,
    crPromptVersion :: !Text,
    crSchemaVersion :: !Int,
    crReplacesCompartment :: !(Maybe CompartmentId)
  }
  deriving stock (Show, Eq)

instance FromRow CaptureRun where
  fromRow =
    CaptureRun
      <$> field
      <*> field
      <*> (MessageCursor <$> field)
      <*> (SourceRange . MessageCursor <$> field <*> (MessageCursor <$> field) <*> field <*> field)
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data CaptureRequest = CaptureRequest
  { requestReason :: !CaptureReason,
    requestHistorianProfile :: !Text,
    requestPromptVersion :: !Text,
    requestSchemaVersion :: !Int
  }
  deriving stock (Show, Eq)

-- | The oldest contiguous source island at or before the live Historian
-- cursor that is not yet owned by an active compartment.  @backfillExpected@
-- is the preceding message in this conversation; @backfillThrough@ is the
-- final message before the next active owner (or the live cursor).
data BackfillGap = BackfillGap
  { backfillExpected :: !MessageCursor,
    backfillThrough :: !MessageCursor
  }
  deriving stock (Show, Eq)

data EpisodeKind
  = MaxInteraction
  | Ambient
  | Mixed
  | EpisodeDecision
  | Support
  | Social
  deriving stock (Show, Eq)

episodeKindText :: EpisodeKind -> Text
episodeKindText = \case
  MaxInteraction -> "max_interaction"
  Ambient -> "ambient"
  Mixed -> "mixed"
  EpisodeDecision -> "decision"
  Support -> "support"
  Social -> "social"

instance FromJSON EpisodeKind where
  parseJSON = withText "episode_kind" $ \case
    "max_interaction" -> pure MaxInteraction
    "ambient" -> pure Ambient
    "mixed" -> pure Mixed
    "decision" -> pure EpisodeDecision
    "support" -> pure Support
    "social" -> pure Social
    other -> fail ("unknown episode_kind: " <> T.unpack other)

instance ToJSON EpisodeKind where
  toJSON = String . episodeKindText

data CitedSummary = CitedSummary
  { summaryText :: !Text,
    evidenceMessageIds :: ![Int64]
  }
  deriving stock (Show, Eq)

instance FromJSON CitedSummary where
  parseJSON = withObject "cited_summary" $ \o -> do
    rejectUnknownKeys "cited_summary" ["text", "evidence_message_ids"] o
    CitedSummary <$> o .: "text" <*> o .: "evidence_message_ids"

instance ToJSON CitedSummary where
  toJSON summary =
    object
      [ "text" .= summary.summaryText,
        "evidence_message_ids" .= summary.evidenceMessageIds
      ]

data EpisodeMemoryProposal
  = ProposalAdd !Text !(Maybe Int64) !Text !(Maybe Text) ![Int64]
  | ProposalUpdate !MemoryId !MemoryVersion !Text ![Int64]
  | ProposalArchive !MemoryId !MemoryVersion ![Int64]
  deriving stock (Show, Eq)

instance FromJSON EpisodeMemoryProposal where
  parseJSON = withObject "memory_proposal" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> do
        rejectUnknownKeys "memory_proposal.add" ["action", "scope", "user_id", "content", "category", "evidence_message_ids"] o
        ProposalAdd
          <$> o .: "scope"
          <*> o .:? "user_id"
          <*> o .: "content"
          <*> o .:? "category"
          <*> o .: "evidence_message_ids"
      "update" -> do
        rejectUnknownKeys "memory_proposal.update" ["action", "id", "expected_version", "content", "evidence_message_ids"] o
        ProposalUpdate
          <$> o .: "id"
          <*> o .: "expected_version"
          <*> o .: "content"
          <*> o .: "evidence_message_ids"
      "archive" -> do
        rejectUnknownKeys "memory_proposal.archive" ["action", "id", "expected_version", "evidence_message_ids"] o
        ProposalArchive
          <$> o .: "id"
          <*> o .: "expected_version"
          <*> o .: "evidence_message_ids"
      other -> fail ("unknown memory proposal action: " <> T.unpack other)

instance ToJSON EpisodeMemoryProposal where
  toJSON = \case
    ProposalAdd scope userId content category evidence ->
      object
        [ "action" .= ("add" :: Text),
          "scope" .= scope,
          "user_id" .= userId,
          "content" .= content,
          "category" .= category,
          "evidence_message_ids" .= evidence
        ]
    ProposalUpdate memoryId version content evidence ->
      object
        [ "action" .= ("update" :: Text),
          "id" .= memoryId,
          "expected_version" .= version,
          "content" .= content,
          "evidence_message_ids" .= evidence
        ]
    ProposalArchive memoryId version evidence ->
      object
        [ "action" .= ("archive" :: Text),
          "id" .= memoryId,
          "expected_version" .= version,
          "evidence_message_ids" .= evidence
        ]

data EpisodeCapture = EpisodeCapture
  { captureSummaryP1 :: !CitedSummary,
    captureSummaryP2 :: !CitedSummary,
    captureSummaryP3 :: !CitedSummary,
    captureImportance :: !Double,
    captureConfidence :: !Double,
    captureEpisodeKind :: !EpisodeKind,
    captureMemoryProposals :: ![EpisodeMemoryProposal]
  }
  deriving stock (Show, Eq)

instance FromJSON EpisodeCapture where
  parseJSON = withObject "episode_capture" $ \o -> do
    rejectUnknownKeys
      "episode_capture"
      [ "summary_p1",
        "summary_p2",
        "summary_p3",
        "importance",
        "confidence",
        "episode_kind",
        "memory_proposals"
      ]
      o
    capture <-
      EpisodeCapture
        <$> o .: "summary_p1"
        <*> o .: "summary_p2"
        <*> o .: "summary_p3"
        <*> o .: "importance"
        <*> o .: "confidence"
        <*> o .: "episode_kind"
        <*> o .: "memory_proposals"
    unless (capture.captureImportance >= 0 && capture.captureImportance <= 1) $
      fail "importance must be between 0 and 1"
    unless (capture.captureConfidence >= 0 && capture.captureConfidence <= 1) $
      fail "confidence must be between 0 and 1"
    pure capture

rejectUnknownKeys :: String -> [Text] -> Object -> Parser ()
rejectUnknownKeys label allowed objectValue =
  unless (null unknown) $
    fail (label <> " contains unknown fields: " <> show (map Key.toText unknown))
  where
    allowedKeys = Set.fromList (map Key.fromText allowed)
    unknown = filter (`Set.notMember` allowedKeys) (KeyMap.keys objectValue)

instance ToJSON EpisodeCapture where
  toJSON capture =
    object
      [ "summary_p1" .= capture.captureSummaryP1,
        "summary_p2" .= capture.captureSummaryP2,
        "summary_p3" .= capture.captureSummaryP3,
        "importance" .= capture.captureImportance,
        "confidence" .= capture.captureConfidence,
        "episode_kind" .= capture.captureEpisodeKind,
        "memory_proposals" .= capture.captureMemoryProposals
      ]

data CaptureValidationError = CaptureValidationError
  { validationPath :: !Text,
    validationMessage :: !Text
  }
  deriving stock (Show, Eq)

instance ToJSON CaptureValidationError where
  toJSON validation =
    object
      [ "path" .= validation.validationPath,
        "message" .= validation.validationMessage
      ]

data ValidatedMemoryProposal
  = ValidatedAdd !MemoryScope !(Maybe Int64) !Text !(Maybe MemoryCategory) ![Int64]
  | ValidatedUpdate !MemoryId !MemoryVersion !Text ![Int64]
  | ValidatedArchive !MemoryId !MemoryVersion ![Int64]

data IndexedValidatedProposal = IndexedValidatedProposal
  { ivpIndex :: !Int,
    ivpOriginal :: !EpisodeMemoryProposal,
    ivpValidated :: !ValidatedMemoryProposal
  }

data RejectedProposal = RejectedProposal
  { rejectedIndex :: !Int,
    rejectedOriginal :: !EpisodeMemoryProposal,
    rejectedErrors :: ![CaptureValidationError]
  }

data ValidatedEpisodeCapture = ValidatedEpisodeCapture
  { validatedCapture :: !EpisodeCapture,
    validatedProposals :: ![IndexedValidatedProposal],
    rejectedProposals :: ![RejectedProposal]
  }

parseEpisodeCapture :: Text -> Either String EpisodeCapture
parseEpisodeCapture raw =
  eitherDecode (LBS.fromStrict (TE.encodeUtf8 (extractJsonObject raw)))

extractJsonObject :: Text -> Text
extractJsonObject raw =
  let stripped = T.strip raw
      endIndex = (T.length stripped - 1 -) <$> T.findIndex (== '}') (T.reverse stripped)
   in case (T.findIndex (== '{') stripped, endIndex) of
        (Just start, Just end) | end >= start -> T.take (end - start + 1) (T.drop start stripped)
        _ -> stripped

validateEpisodeCapture :: CaptureRun -> [LedgerItem] -> EpisodeCapture -> Either [CaptureValidationError] ValidatedEpisodeCapture
validateEpisodeCapture run source capture =
  if null summaryErrors
    then
      Right
        ValidatedEpisodeCapture
          { validatedCapture = capture,
            validatedProposals = valid,
            rejectedProposals = rejected
          }
    else Left summaryErrors
  where
    eligibleByMessage =
      Map.fromList
        [ (entry.history.canonicalId, entry.history.authorPrincipalId)
        | entry <- source,
          entry.transcriptEligible
        ]
    summaryErrors =
      validateSummary eligibleByMessage "summary_p1" 4000 capture.captureSummaryP1
        <> validateSummary eligibleByMessage "summary_p2" 2000 capture.captureSummaryP2
        <> validateSummary eligibleByMessage "summary_p3" 500 capture.captureSummaryP3
        <> [ CaptureValidationError "source_range" "loaded source does not match the capture run range"
           | not (sourceMatchesRun run source)
           ]
    proposalResults =
      [ validateProposal eligibleByMessage index proposal
      | (index, proposal) <- take 12 (zip [0 ..] capture.captureMemoryProposals)
      ]
        <> [ Left
               RejectedProposal
                 { rejectedIndex = index,
                   rejectedOriginal = proposal,
                   rejectedErrors = [CaptureValidationError ("memory_proposals[" <> tshow index <> "]") "proposal limit is 12"]
                 }
           | (index, proposal) <- drop 12 (zip [0 ..] capture.captureMemoryProposals)
           ]
    (rejected, valid) = partitionEithers proposalResults

-- | Proposal-local failures do not discard otherwise valid chronological
-- summaries.  Persist these warnings with the raw model output so rejected
-- proposals remain auditable even though publication can continue.
captureValidationWarnings :: ValidatedEpisodeCapture -> [CaptureValidationError]
captureValidationWarnings = concatMap (.rejectedErrors) . (.rejectedProposals)

sourceMatchesRun :: CaptureRun -> [LedgerItem] -> Bool
sourceMatchesRun run source = case source of
  [] -> False
  first : _ ->
    let final = last source
     in first.cursor == run.crRange.srStart
          && final.cursor == run.crRange.srEnd
          && length source == run.crRange.srMessageCount

validateSummary :: Map Int64 Int64 -> Text -> Int -> CitedSummary -> [CaptureValidationError]
validateSummary source path maxChars summary =
  contentErrors <> summaryEvidenceErrors
  where
    content = T.strip summary.summaryText
    contentErrors =
      [CaptureValidationError (path <> ".text") "summary must not be blank" | T.null content]
        <> [CaptureValidationError (path <> ".text") ("summary exceeds " <> tshow maxChars <> " characters") | T.length content > maxChars]
    summaryEvidenceErrors
      | Map.null source && null summary.evidenceMessageIds = []
      | otherwise = evidenceErrors source (path <> ".evidence_message_ids") summary.evidenceMessageIds

validateProposal :: Map Int64 Int64 -> Int -> EpisodeMemoryProposal -> Either RejectedProposal IndexedValidatedProposal
validateProposal source index proposal = case proposal of
  ProposalAdd scopeRaw userId content categoryRaw evidence ->
    finish $
      case parseScope scopeRaw of
        Nothing -> (Nothing, [err "scope" "scope must be group or user"])
        Just ScopeGroup ->
          ( ValidatedAdd ScopeGroup Nothing <$> validContent <*> validCategory <*> pure evidence,
            contentErrors
              <> categoryErrors
              <> categoryScopeErrors ScopeGroup categoryRaw
              <> evidenceErrs
              <> [err "user_id" "group scope must not specify user_id" | isJust userId]
          )
        Just ScopeUser ->
          let subjectErrors = case userId of
                Nothing -> [err "user_id" "user scope requires user_id"]
                Just uid
                  | uid `notElem` [speaker | messageId <- evidence, Just speaker <- [Map.lookup messageId source]] ->
                      [err "user_id" "at least one cited message must be spoken by the subject"]
                _ -> []
           in ( ValidatedAdd ScopeUser userId <$> validContent <*> validCategory <*> pure evidence,
                contentErrors <> categoryErrors <> categoryScopeErrors ScopeUser categoryRaw <> evidenceErrs <> subjectErrors
              )
    where
      (validContent, contentErrors) = validateMemoryContent (base <> ".content") content
      (validCategory, categoryErrors) = validateMemoryCategory (base <> ".category") categoryRaw
      evidenceErrs = evidenceErrors source (base <> ".evidence_message_ids") evidence
  ProposalUpdate memoryId version content evidence ->
    let (validContent, contentErrors) = validateMemoryContent (base <> ".content") content
        errors =
          contentErrors
            <> evidenceErrors source (base <> ".evidence_message_ids") evidence
            <> [err "id" "memory id must be positive" | memoryId.unMemoryId <= 0]
            <> [err "expected_version" "observed memory version must be positive" | version.unMemoryVersion <= 0]
     in finish (ValidatedUpdate memoryId version <$> validContent <*> pure evidence, errors)
  ProposalArchive memoryId version evidence ->
    finish
      ( Just (ValidatedArchive memoryId version evidence),
        evidenceErrors source (base <> ".evidence_message_ids") evidence
          <> [err "id" "memory id must be positive" | memoryId.unMemoryId <= 0]
          <> [err "expected_version" "observed memory version must be positive" | version.unMemoryVersion <= 0]
      )
  where
    base = "memory_proposals[" <> tshow index <> "]"
    err fieldName message = CaptureValidationError (base <> "." <> fieldName) message
    finish (candidate, errors) = case (candidate, errors) of
      (Just validated, []) -> Right (IndexedValidatedProposal index proposal validated)
      _ -> Left (RejectedProposal index proposal errors)
    categoryScopeErrors scope categoryRaw = case categoryRaw >>= parseCategory of
      Just PersonFact | scope == ScopeGroup -> [err "category" "person_fact requires user scope"]
      Just Preference | scope == ScopeGroup -> [err "category" "preference requires user scope"]
      Just Commitment | scope == ScopeGroup -> [err "category" "commitment requires user scope"]
      Just GroupConvention | scope == ScopeUser -> [err "category" "group_convention requires group scope"]
      _ -> []

validateMemoryContent :: Text -> Text -> (Maybe Text, [CaptureValidationError])
validateMemoryContent path raw
  | T.null content = (Nothing, [CaptureValidationError path "memory content must not be blank"])
  | T.length content > 300 = (Nothing, [CaptureValidationError path "memory content exceeds 300 characters"])
  | otherwise = (Just content, [])
  where
    content = T.strip raw

validateMemoryCategory :: Text -> Maybe Text -> (Maybe (Maybe MemoryCategory), [CaptureValidationError])
validateMemoryCategory _ Nothing = (Just Nothing, [])
validateMemoryCategory path (Just raw) = case parseCategory raw of
  Nothing -> (Nothing, [CaptureValidationError path "unknown memory category"])
  Just RelationshipContext -> (Nothing, [CaptureValidationError path "relationship_context is disabled for automatic capture"])
  Just category -> (Just (Just category), [])

evidenceErrors :: Map Int64 Int64 -> Text -> [Int64] -> [CaptureValidationError]
evidenceErrors source path evidence =
  [CaptureValidationError path "at least one evidence message is required" | null evidence]
    <> [CaptureValidationError path "evidence message ids must be unique" | length evidence /= length (nub evidence)]
    <> [ CaptureValidationError path ("message " <> tshow messageId <> " is outside the eligible source transcript")
       | messageId <- evidence,
         Map.notMember messageId source
       ]

--------------------------------------------------------------------------------
-- Durable job/store operations.

captureRunColumns :: Text
captureRunColumns =
  "id, conversation_id, expected_cursor_seq, start_ingest_seq, end_ingest_seq, \
  \source_hash, source_message_count, scheduling_reason, historian_profile, \
  \prompt_version, schema_version, replaces_compartment_id"

prepareCaptureRun :: (WithConnection :> es, IOE :> es) => ConversationScope -> MessageCursor -> MessageCursor -> CaptureRequest -> Eff es (Maybe CaptureRun)
prepareCaptureRun scope expected end request = do
  source <- captureSourceRange scope expected end
  traverse (newCaptureRun scope expected request Nothing) source

-- Only the public result ID is allocated before generation; no execution row exists.
newCaptureRun :: (WithConnection :> es, IOE :> es) => ConversationScope -> MessageCursor -> CaptureRequest -> Maybe CompartmentId -> SourceRange -> Eff es CaptureRun
newCaptureRun scope expected request replaced range = do
  ids <- query "SELECT nextval('episode_capture_runs_id_seq')" ()
  case ids of
    [Only runId] ->
      pure
        CaptureRun
          { crId = runId,
            crConversationId = conversationStorageId scope,
            crExpectedCursor = expected,
            crRange = range,
            crReason = captureReasonText request.requestReason,
            crHistorianProfile = request.requestHistorianProfile,
            crPromptVersion = request.requestPromptVersion,
            crSchemaVersion = request.requestSchemaVersion,
            crReplacesCompartment = replaced
          }
    _ -> publicationFailure "failed to allocate capture result ID"

-- | Find the oldest exact historical hole without crossing the live cursor or
-- an existing active compartment.  Concurrent publishers may make the answer
-- stale after this read; source hashing and the active-range exclusion remain
-- the final transactional fence.
findOldestBackfillGap ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es (Maybe BackfillGap)
findOldestBackfillGap scope = do
  cursor <- loadCursor scope historianCursor
  rows <-
    query
      "WITH first_uncovered AS ( \
      \  SELECT min(source.ingest_seq) AS start_seq \
      \  FROM messages AS source \
      \  WHERE source.group_id = ? AND source.ingest_seq <= ? \
      \    AND NOT EXISTS ( \
      \      SELECT 1 FROM conversation_compartments AS owner \
      \      WHERE owner.conversation_id = ? AND owner.state = 'active' \
      \        AND source.ingest_seq BETWEEN owner.start_ingest_seq AND owner.end_ingest_seq \
      \    ) \
      \), bounds AS ( \
      \  SELECT start_seq, ( \
      \    SELECT min(owner.start_ingest_seq) \
      \    FROM conversation_compartments AS owner \
      \    WHERE owner.conversation_id = ? AND owner.state = 'active' \
      \      AND owner.start_ingest_seq > first_uncovered.start_seq \
      \  ) AS next_active_start \
      \  FROM first_uncovered WHERE start_seq IS NOT NULL \
      \) \
      \ SELECT \
      \   COALESCE((SELECT max(previous.ingest_seq) FROM messages AS previous \
      \             WHERE previous.group_id = ? AND previous.ingest_seq < bounds.start_seq), 0), \
      \   (SELECT max(source.ingest_seq) FROM messages AS source \
      \    WHERE source.group_id = ? AND source.ingest_seq >= bounds.start_seq \
      \      AND source.ingest_seq <= ? \
      \      AND (bounds.next_active_start IS NULL OR source.ingest_seq < bounds.next_active_start)) \
      \ FROM bounds"
      ( conversationStorageId scope,
        cursor.ingestSeq,
        conversationStorageId scope,
        conversationStorageId scope,
        conversationStorageId scope,
        conversationStorageId scope,
        cursor.ingestSeq
      )
  pure $ case rows :: [(Int64, Int64)] of
    (expected, through) : _ -> Just (BackfillGap (MessageCursor expected) (MessageCursor through))
    [] -> Nothing

-- | Schedule an explicitly selected historical range without moving the live
-- historian cursor.  Publication still enforces the source hash and active
-- non-overlap constraint.  This is the controlled path for history predating
-- migration 041's deployment baseline.
prepareBackfillRun ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  CaptureRequest ->
  Eff es (Maybe CaptureRun)
prepareBackfillRun scope expected end request =
  prepareCaptureRun
    scope
    expected
    end
    request {requestReason = CaptureBackfill}

-- | Prepare a replacement while the old summary remains active.
prepareRebuildRun :: (WithConnection :> es, IOE :> es) => ConversationScope -> CompartmentId -> CaptureRequest -> Eff es (Maybe CaptureRun)
prepareRebuildRun scope replaced request = do
  ranges <-
    query
      "SELECT start_ingest_seq, end_ingest_seq, source_hash, source_message_count \
      \ FROM conversation_compartments WHERE id=? AND conversation_id=? AND state='active'"
      (replaced, conversationStorageId scope)
  case (ranges :: [SourceRange]) of
    [] -> pure Nothing
    range : _ -> do
      predecessors <-
        query
          "SELECT COALESCE(max(ingest_seq),0) FROM messages WHERE group_id=? AND ingest_seq<?"
          (conversationStorageId scope, range.srStart.ingestSeq)
      case predecessors of
        [Only previous] -> do
          fresh <- captureSourceRange scope (MessageCursor previous) range.srEnd
          traverse (newCaptureRun scope (MessageCursor previous) request {requestReason = CaptureRebuild} (Just replaced)) fresh
        _ -> publicationFailure "failed to read predecessor of rebuild range"

captureSourceRange ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  Eff es (Maybe SourceRange)
captureSourceRange scope (MessageCursor expected) (MessageCursor end) = do
  rows <-
    query
      "WITH source AS ( \
      \ SELECT min(ingest_seq) AS start_seq, max(ingest_seq) AS end_seq, count(*)::int AS message_count \
      \ FROM messages WHERE group_id = ? AND ingest_seq > ? AND ingest_seq <= ? \
      \) \
      \ SELECT start_seq, end_seq, conversation_source_hash(?, start_seq, end_seq), message_count \
      \ FROM source WHERE message_count > 0 AND end_seq = ?"
      (conversationStorageId scope, expected, end, conversationStorageId scope, end)
  pure (case rows of range : _ -> Just range; [] -> Nothing)

loadCaptureSource ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  Eff es [LedgerItem]
loadCaptureSource run =
  query
    ( "SELECT ingest_seq, "
        <> historyColumns
        <> ", "
        <> transcriptEligibleExpr
        <> " FROM messages \
           \ WHERE group_id = ? AND ingest_seq BETWEEN ? AND ? \
           \ ORDER BY ingest_seq"
    )
    (run.crConversationId, run.crRange.srStart.ingestSeq, run.crRange.srEnd.ingestSeq)

recordCaptureFailure :: (WithConnection :> es, IOE :> es) => CaptureRun -> Text -> Maybe Text -> [CaptureValidationError] -> Eff es ()
recordCaptureFailure run err raw errors = insertCaptureResult run "failed" (Just err) raw Nothing errors

insertCaptureResult :: (WithConnection :> es, IOE :> es) => CaptureRun -> Text -> Maybe Text -> Maybe Text -> Maybe EpisodeCapture -> [CaptureValidationError] -> Eff es ()
insertCaptureResult run status err raw capture errors = do
  _ <-
    execute
      "INSERT INTO episode_capture_runs \
      \ (id,conversation_id,expected_cursor_seq,start_ingest_seq,end_ingest_seq,source_hash, \
      \  source_message_count,scheduling_reason,historian_profile,prompt_version,schema_version, \
      \  replaces_compartment_id,status,last_error,raw_output,parsed_output,validation_errors) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?::jsonb,?::jsonb)"
      ( run.crId,
        run.crConversationId,
        run.crExpectedCursor.ingestSeq,
        run.crRange.srStart.ingestSeq,
        run.crRange.srEnd.ingestSeq,
        run.crRange.srHash,
        run.crRange.srMessageCount,
        run.crReason,
        run.crHistorianProfile,
        run.crPromptVersion,
        run.crSchemaVersion,
        run.crReplacesCompartment,
        status,
        err,
        raw,
        encodeText <$> capture,
        encodeText errors
      )
  pure ()

-- | Check the source and cursor before spending a model call.
captureRunSourceMatches ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CaptureRun ->
  Eff es Bool
captureRunSourceMatches scope run = do
  current <- loadCursor scope historianCursor
  source <- captureSourceRange scope run.crExpectedCursor run.crRange.srEnd
  pure $
    (not (runRequiresLiveCursor run) || current == run.crExpectedCursor)
      && source == Just run.crRange

publishCaptureRun :: (WithConnection :> es, IOE :> es) => ConversationScope -> CaptureRun -> Text -> ValidatedEpisodeCapture -> Eff es CompartmentId
publishCaptureRun scope run raw validated = withTransaction $ do
  unless (conversationStorageId scope == run.crConversationId) (publicationFailure "capture conversation mismatch")
  locked <- lockConversation (conversationStorageId scope)
  unless locked (publicationFailure "capture conversation no longer exists")
  verifyRunSource scope run
  insertCaptureResult run "published" Nothing (Just raw) (Just validated.validatedCapture) (captureValidationWarnings validated)
  compartment <- insertStagedCompartment run validated.validatedCapture
  insertSummaryEvidence run compartment validated.validatedCapture
  insertRejectedProposals run validated.rejectedProposals
  forM validated.validatedProposals (applyMemoryProposal scope run compartment) >>= mapM_ (insertProposalOutcome run)
  activateCompartment run compartment
  when (runRequiresLiveCursor run) $ do
    advanced <- advanceCursor scope historianCursor run.crExpectedCursor run.crRange.srEnd
    unless advanced (publicationFailure "historian cursor compare-and-swap conflict")
  _ <-
    execute
      "UPDATE episode_capture_runs SET published_compartment_id=?, published_at=now(), updated_at=now() WHERE id=?"
      (compartment, run.crId)
  pure compartment

verifyRunSource ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CaptureRun ->
  Eff es ()
verifyRunSource scope run = do
  current <- loadCursor scope historianCursor
  when (runRequiresLiveCursor run && current /= run.crExpectedCursor) $
    publicationFailure "historian cursor no longer matches the run's expected cursor"
  verifyCaptureSource scope run

verifyCaptureSource :: (WithConnection :> es, IOE :> es) => ConversationScope -> CaptureRun -> Eff es ()
verifyCaptureSource scope run = do
  source <- captureSourceRange scope run.crExpectedCursor run.crRange.srEnd
  case source of
    Just range
      | range == run.crRange -> pure ()
      | otherwise -> publicationFailure "source range/hash changed after generation"
    Nothing -> publicationFailure "source range is no longer complete"

runRequiresLiveCursor :: CaptureRun -> Bool
runRequiresLiveCursor run =
  isNothing run.crReplacesCompartment && run.crReason /= "backfill"

insertStagedCompartment ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  EpisodeCapture ->
  Eff es CompartmentId
insertStagedCompartment run capture = do
  rows <-
    query
      "INSERT INTO conversation_compartments \
      \ (conversation_id, capture_run_id, start_ingest_seq, end_ingest_seq, source_hash, \
      \  source_message_count, summary, summary_p1, summary_p2, summary_p3, episode_kind, \
      \  importance, confidence, state, historian_profile, prompt_version, schema_version, \
      \  materialization_version, speaker_stats) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'staged', ?, ?, ?, \
      \         COALESCE((SELECT max(materialization_version) + 1 \
      \                   FROM conversation_compartments WHERE conversation_id = ?), 1), \
      \         (SELECT jsonb_object_agg(user_id::text, message_count) \
      \          FROM (SELECT user_id, count(*)::int AS message_count FROM messages \
      \                WHERE group_id = ? AND ingest_seq BETWEEN ? AND ? GROUP BY user_id) stats)) \
      \ RETURNING id"
      ( run.crConversationId,
        run.crId,
        run.crRange.srStart.ingestSeq,
        run.crRange.srEnd.ingestSeq,
        run.crRange.srHash,
        run.crRange.srMessageCount,
        T.intercalate "\n" (nub (map (T.strip . (.summaryText)) [capture.captureSummaryP1, capture.captureSummaryP2, capture.captureSummaryP3])),
        T.strip capture.captureSummaryP1.summaryText,
        T.strip capture.captureSummaryP2.summaryText,
        T.strip capture.captureSummaryP3.summaryText,
        episodeKindText capture.captureEpisodeKind,
        capture.captureImportance,
        capture.captureConfidence,
        run.crHistorianProfile,
        run.crPromptVersion,
        run.crSchemaVersion,
        run.crConversationId,
        run.crConversationId,
        run.crRange.srStart.ingestSeq,
        run.crRange.srEnd.ingestSeq
      )
  case rows of
    Only compartment : _ -> pure compartment
    [] -> publicationFailure "failed to insert staged compartment"

insertSummaryEvidence ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  CompartmentId ->
  EpisodeCapture ->
  Eff es ()
insertSummaryEvidence run compartment capture =
  mapM_
    insertTier
    [ ("p1", capture.captureSummaryP1.evidenceMessageIds),
      ("p2", capture.captureSummaryP2.evidenceMessageIds),
      ("p3", capture.captureSummaryP3.evidenceMessageIds),
      ("summary", nub (concatMap (.evidenceMessageIds) [capture.captureSummaryP1, capture.captureSummaryP2, capture.captureSummaryP3]))
    ]
  where
    insertTier (tier, messageIds) = do
      inserted <-
        execute
          "INSERT INTO compartment_evidence \
          \ (compartment_id, summary_tier, source_canonical_message_id, source_principal_id) \
          \ SELECT ?, ?, canonical_message_id, author_principal_id FROM messages \
          \ WHERE group_id = ? AND ingest_seq BETWEEN ? AND ? AND canonical_message_id IN ?"
          ( compartment,
            tier :: Text,
            run.crConversationId,
            run.crRange.srStart.ingestSeq,
            run.crRange.srEnd.ingestSeq,
            In messageIds
          )
      unless (inserted == fromIntegral (length messageIds)) $
        publicationFailure "summary citation left the authorized source range"

data ProposalOutcome = ProposalOutcome
  { outcomeIndex :: !Int,
    outcomeProposal :: !EpisodeMemoryProposal,
    outcomeEvidence :: ![Int64],
    outcomeStatus :: !Text,
    outcomeReason :: !(Maybe Text),
    outcomeMemory :: !(Maybe MemoryItem)
  }

insertRejectedProposals ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  [RejectedProposal] ->
  Eff es ()
insertRejectedProposals run rejected =
  mapM_
    ( \proposal ->
        insertProposalOutcome
          run
          ProposalOutcome
            { outcomeIndex = proposal.rejectedIndex,
              outcomeProposal = proposal.rejectedOriginal,
              outcomeEvidence = proposalEvidenceIds proposal.rejectedOriginal,
              outcomeStatus = "rejected_validation",
              outcomeReason = Just (T.intercalate "; " (map (.validationMessage) proposal.rejectedErrors)),
              outcomeMemory = Nothing
            }
    )
    rejected

applyMemoryProposal ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  CaptureRun ->
  CompartmentId ->
  IndexedValidatedProposal ->
  Eff es ProposalOutcome
applyMemoryProposal scope _run compartment indexed = case indexed.ivpValidated of
  ValidatedAdd memoryScope userId content category evidence -> do
    let subject = case memoryScope of
          ScopeGroup -> conversationStorageId scope
          ScopeUser -> fromMaybe (conversationStorageId scope) userId
        namespace = memoryNamespace scope memoryScope subject
    admitted <-
      admitMemory
        RejectExactDuplicates
        historianActor
        namespace
        MemoryDraft
          { draftContent = content,
            draftLifecycle = MemoryActive,
            draftCategory = category,
            draftEvidence = EpisodeEvidence scope compartment.unCompartmentId
          }
    case admitted of
      Right memory -> applied memory evidence
      Left ExactMemoryAlreadyExists -> rejected "exact duplicate already exists" evidence
      Left MemoryAtCapacity -> rejected "memory namespace is at capacity" evidence
      Left MemoryConversationMissing -> publicationFailure "memory conversation no longer exists"
      Left MemorySubjectNotVisible -> rejected "memory subject is not a known principal in this conversation" evidence
  ValidatedUpdate memoryId version content evidence ->
    updateVisibleMemory
      historianActor
      (currentConversationRecall scope)
      memoryId
      (ExpectedVersion version)
      (MemoryUpdate content (EpisodeEvidence scope compartment.unCompartmentId))
      >>= mutationOutcome memoryId version evidence
  ValidatedArchive memoryId version evidence ->
    archiveVisibleMemory
      historianActor
      (currentConversationRecall scope)
      memoryId
      (ExpectedVersion version)
      >>= mutationOutcome memoryId version evidence
  where
    applied memory evidence =
      pure (baseOutcome evidence "applied" Nothing (Just memory))
    rejected reason evidence =
      pure (baseOutcome evidence "rejected_store" (Just reason) Nothing)
    mutationOutcome memoryId version evidence = \case
      MemoryMutationApplied memory -> applied memory evidence
      MemoryMutationRejected -> do
        visible <- fetchVisibleMemory (currentConversationRecall scope) memoryId
        let reason = case visible of
              Nothing -> "memory is not visible in this conversation"
              Just memory
                | memory.memLifecycle == "permanent" -> "permanent memory requires explicit user authorization"
                | version < memory.memVersion -> "stale expected_version; re-read current memory and evidence before proposing again"
                | version > memory.memVersion -> "future expected_version; copy the observed version without incrementing"
                | otherwise -> "memory lifecycle or expected version rejected the mutation"
        rejected reason evidence
    baseOutcome evidence status reason memory =
      ProposalOutcome indexed.ivpIndex indexed.ivpOriginal evidence status reason memory

historianActor :: MemoryActor
historianActor = MemoryActor ActorHistorian Nothing (Just "episode capture proposal")

-- | Explicit review after re-reading evidence and current scoped memories.
-- Reuses proposal validation and automatic-actor protections; this entry point
-- cannot increment a supplied version, bypass permanent memory, move a cursor,
-- or republish a summary. Nothing means an audited dismissal.
reviewRejectedMemoryProposal ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope -> CaptureRunId -> Int -> Text -> Text -> Maybe EpisodeMemoryProposal -> Eff es Text
reviewRejectedMemoryProposal scope captureId index actor reason proposed = withTransaction $ do
  unless (not (T.null (T.strip actor)) && not (T.null (T.strip reason))) $
    publicationFailure "memory review requires an actor and evidence-based reason"
  locked <- lockConversation (conversationStorageId scope)
  unless locked (publicationFailure "memory review conversation no longer exists")
  available <-
    query
      "SELECT count(*) FROM episode_memory_review_queue WHERE capture_run_id=? AND proposal_index=? AND conversation_id=?"
      (captureId, index, conversationStorageId scope)
  unless (available == [Only (1 :: Int)]) $ publicationFailure "proposal is outside scope or already reviewed"
  runs <-
    query
      (fromTextQuery ("SELECT " <> captureRunColumns <> " FROM episode_capture_runs WHERE id=? AND conversation_id=? AND status='published' FOR UPDATE"))
      (captureId, conversationStorageId scope)
  run <- case runs of
    [value] -> pure value
    _ -> publicationFailure "memory review requires a published capture"
  compartments <- query "SELECT published_compartment_id FROM episode_capture_runs WHERE id=?" (Only captureId)
  compartment <- case compartments of
    [Only (Just value)] -> pure value
    _ -> publicationFailure "published capture has no compartment"
  source <- loadCaptureSource run
  when (isJust proposed) $ verifyCaptureSource scope run
  let eligible = Map.fromList [(entry.history.canonicalId, entry.history.authorPrincipalId) | entry <- source, entry.transcriptEligible]
  (status, detail, memory) <- case proposed of
    Nothing -> pure ("dismissed", Nothing, Nothing)
    Just proposal -> case validateProposal eligible index proposal of
      Left invalid -> pure ("rejected_validation", Just (T.intercalate "; " (map (.validationMessage) invalid.rejectedErrors)), Nothing)
      Right valid -> do
        result <- applyMemoryProposal scope run compartment valid
        pure (result.outcomeStatus, result.outcomeReason, result.outcomeMemory)
  _ <-
    execute
      "INSERT INTO episode_memory_reviews(capture_run_id,proposal_index,proposal,outcome,outcome_reason,memory_id,memory_version,actor,reason) VALUES (?,?,?::jsonb,?,?,?,?,?,?)"
      (captureId, index, encodeText <$> proposed, status, detail, (.memId) <$> memory, (.memVersion) <$> memory, actor, reason)
  pure status

insertProposalOutcome ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  ProposalOutcome ->
  Eff es ()
insertProposalOutcome run outcome = do
  let memoryId = (.memId) <$> outcome.outcomeMemory
      memoryVersion = (.memVersion) <$> outcome.outcomeMemory
  inserted <-
    execute
      "INSERT INTO episode_memory_proposals \
      \ (capture_run_id, proposal_index, proposal, evidence_message_ids, outcome, \
      \  outcome_reason, memory_id, memory_version) \
      \ VALUES (?, ?, ?::jsonb, ?, ?, ?, ?, ?)"
      ( run.crId,
        outcome.outcomeIndex,
        encodeText outcome.outcomeProposal,
        PGArray outcome.outcomeEvidence,
        outcome.outcomeStatus,
        outcome.outcomeReason,
        memoryId,
        memoryVersion
      )
  unless (inserted == 1) (publicationFailure "failed to persist memory proposal outcome")

proposalEvidenceIds :: EpisodeMemoryProposal -> [Int64]
proposalEvidenceIds = \case
  ProposalAdd _ _ _ _ evidence -> evidence
  ProposalUpdate _ _ _ evidence -> evidence
  ProposalArchive _ _ evidence -> evidence

activateCompartment ::
  (WithConnection :> es, IOE :> es) =>
  CaptureRun ->
  CompartmentId ->
  Eff es ()
activateCompartment run compartment = do
  case run.crReplacesCompartment of
    Nothing -> pure ()
    Just replaced -> do
      changed <-
        execute
          "UPDATE conversation_compartments \
          \ SET state = 'superseded', superseded_by = ? \
          \ WHERE id = ? AND conversation_id = ? AND state = 'active' \
          \   AND start_ingest_seq = ? AND end_ingest_seq = ?"
          ( compartment,
            replaced,
            run.crConversationId,
            run.crRange.srStart.ingestSeq,
            run.crRange.srEnd.ingestSeq
          )
      unless (changed == 1) (publicationFailure "rebuild target is no longer the active exact range")
  changed <-
    execute
      "UPDATE conversation_compartments \
      \ SET state = 'active', activated_at = now() \
      \ WHERE id = ? AND state = 'staged'"
      (Only compartment)
  unless (changed == 1) (publicationFailure "failed to activate staged compartment")

listActiveCompartments ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es [ActiveCompartment]
listActiveCompartments scope =
  query
    "WITH active AS ( \
    \  SELECT c.*, lag(c.end_ingest_seq) OVER (ORDER BY c.start_ingest_seq, c.end_ingest_seq) AS previous_end \
    \  FROM conversation_compartments AS c \
    \  WHERE c.conversation_id = ? AND c.state = 'active' \
    \) \
    \ SELECT a.id, a.expand_handle, a.start_ingest_seq, a.end_ingest_seq, a.source_hash, a.source_message_count, \
    \        first_message.received_at, last_message.received_at, \
    \        (a.previous_end IS NOT NULL AND EXISTS ( \
    \          SELECT 1 FROM messages AS gap_message \
    \          WHERE gap_message.group_id = a.conversation_id \
    \            AND gap_message.ingest_seq > a.previous_end \
    \            AND gap_message.ingest_seq < a.start_ingest_seq \
    \        )), \
    \        COALESCE(a.summary_p1, a.summary), a.summary_p2, a.summary_p3, a.importance, a.confidence \
    \ FROM active AS a \
    \ JOIN messages AS first_message \
    \   ON first_message.group_id = a.conversation_id AND first_message.ingest_seq = a.start_ingest_seq \
    \ JOIN messages AS last_message \
    \   ON last_message.group_id = a.conversation_id AND last_message.ingest_seq = a.end_ingest_seq \
    \ ORDER BY a.start_ingest_seq, a.end_ingest_seq"
    (Only (conversationStorageId scope))

-- | Expand an opaque episode handle inside the conversations authorized by
-- the supplied read policy.  The handle is only a locator: the SQL predicate
-- independently requires the current policy's conversation on every page.
-- Superseded compartments remain expandable because their immutable source
-- range is still valid evidence for a previously returned handle.
expandEpisode ::
  (WithConnection :> es, IOE :> es) =>
  RecallPolicy ->
  EpisodeHandle ->
  Maybe MessageCursor ->
  Int ->
  Eff es (Maybe EpisodeExpansion)
expandEpisode policy handle requestedAfter requestedSize = do
  let scope = recallConversationScope policy
      conversationId = conversationStorageId scope
      pageSize = max 1 (min 100 requestedSize)
  metadata <-
    query
      "SELECT expand_handle, start_ingest_seq, end_ingest_seq, source_hash, source_message_count, state, \
      \       source_hash = conversation_source_hash(conversation_id, start_ingest_seq, end_ingest_seq) \
      \ FROM conversation_compartments \
      \ WHERE conversation_id = ? AND expand_handle = ? \
      \ LIMIT 1"
      (conversationId, handle)
  case metadata :: [(EpisodeHandle, Int64, Int64, Text, Int, Text, Bool)] of
    [] -> pure Nothing
    (storedHandle, start, end, sourceHash, messageCount, state, sourceMatches) : _ -> do
      let after = max (start - 1) (maybe (start - 1) (.ingestSeq) requestedAfter)
      rows <-
        query
          ( "SELECT ingest_seq, "
              <> historyColumns
              <> ", "
              <> transcriptEligibleExpr
              <> " FROM messages \
                 \ WHERE group_id = ? AND ingest_seq BETWEEN ? AND ? AND ingest_seq > ? \
                 \ ORDER BY ingest_seq \
                 \ LIMIT ?"
          )
          (conversationId, start, end, after, pageSize + 1)
      let allRows = rows :: [LedgerItem]
          page = take pageSize allRows
          hasMore = length allRows > pageSize
          nextCursor =
            if hasMore
              then case reverse page of
                item : _ -> Just item.cursor
                [] -> Nothing
              else Nothing
      pure . Just $
        EpisodeExpansion
          { expansionHandle = storedHandle,
            expansionRange = SourceRange (MessageCursor start) (MessageCursor end) sourceHash messageCount,
            expansionState = state,
            expansionSourceHashMatches = sourceMatches,
            expansionMessages = page,
            expansionHasMore = hasMore,
            expansionNextCursor = nextCursor
          }

publicationFailure :: (IOE :> es) => String -> Eff es a
publicationFailure = liftIO . throwIO . userError

fromTextQuery :: Text -> Query
fromTextQuery = fromString . T.unpack
