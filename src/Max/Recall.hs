-- |
-- Conversation-scoped unified recall.
--
-- Candidate generation is deliberately split into lexical and compatible
-- embedding queries, but policy, ranking, quotas, and deduplication are shared.
-- Visibility is applied in SQL before any candidate can be scored.  The pure
-- selector prevents one corpus from monopolising the result set and collapses
-- the raw/pinned/caption forms of one source message.
module Max.Recall
  ( RecallCorpus (..),
    RecallCandidate (..),
    RecallHit (..),
    searchRecall,
    searchRecallIn,
    selectRecallHits,
  )
where

import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (FromRow, Query)
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (RecallPolicy, conversationStorageId, recallConversationScope)
import Max.Embedding (EmbeddingRecord (..))
import Max.EpisodeStore (EpisodeHandle)
import Max.MemoryStore (MemoryId)

data RecallCorpus
  = RecallMemories
  | RecallEpisodes
  | RecallMessages
  | RecallPins
  | RecallCaptions
  deriving stock (Show, Eq, Ord, Enum, Bounded)

data RecallCandidate = RecallCandidate
  { rcSource :: !Text,
    rcDedupKey :: !Text,
    rcSnippet :: !Text,
    rcOccurredAt :: !UTCTime,
    rcPrincipalId :: !(Maybe Int64),
    rcMessageId :: !(Maybe Int64),
    rcEpisodeHandle :: !(Maybe EpisodeHandle),
    rcMemoryId :: !(Maybe MemoryId),
    rcImportance :: !Double,
    rcLexicalScore :: !(Maybe Double),
    rcSemanticScore :: !(Maybe Double),
    rcPinned :: !Bool,
    rcPermanent :: !Bool
  }
  deriving stock (Show, Eq)

instance FromRow RecallCandidate where
  fromRow =
    RecallCandidate
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

data RecallHit = RecallHit
  { rhSource :: !Text,
    rhDedupKey :: !Text,
    rhSnippet :: !Text,
    rhOccurredAt :: !UTCTime,
    rhPrincipalId :: !(Maybe Int64),
    rhMessageId :: !(Maybe Int64),
    rhEpisodeHandle :: !(Maybe EpisodeHandle),
    rhMemoryId :: !(Maybe MemoryId),
    rhScore :: !Double,
    rhLexicalScore :: !(Maybe Double),
    rhSemanticScore :: !(Maybe Double),
    rhPinned :: !Bool,
    rhPermanent :: !Bool
  }
  deriving stock (Show, Eq)

-- | Search all current-conversation corpora.  An embedding record is optional:
-- lexical recall remains fully functional while the embedding service or a
-- compatible backfill is unavailable.
searchRecall ::
  (WithConnection :> es, IOE :> es) =>
  RecallPolicy ->
  Text ->
  Maybe EmbeddingRecord ->
  Int ->
  Eff es [RecallHit]
searchRecall policy rawQuery embedding requestedLimit =
  searchRecallIn policy (Set.fromList [minBound .. maxBound]) rawQuery embedding requestedLimit

-- | Search a code-selected subset of the unified recall corpus.  This is the
-- compatibility boundary for the older specialised tools: callers may narrow
-- what they present, but cannot widen the SQL visibility policy.
searchRecallIn ::
  (WithConnection :> es, IOE :> es) =>
  RecallPolicy ->
  Set.Set RecallCorpus ->
  Text ->
  Maybe EmbeddingRecord ->
  Int ->
  Eff es [RecallHit]
searchRecallIn policy corpora rawQuery embedding requestedLimit
  | Set.null corpora = pure []
  | T.null queryText = pure []
  | otherwise = do
      let conversationId = conversationStorageId (recallConversationScope policy)
          resultLimit = max 1 (min 30 requestedLimit)
          candidateLimit = max 8 (min 200 (resultLimit * 4))
      lexical <- query lexicalCandidatesSql (conversationId, queryText, candidateLimit)
      semantic <- case embedding of
        Nothing -> pure []
        Just record ->
          query
            semanticCandidatesSql
            (conversationId, record.erModelId, record.erDimensions, record.erVector, candidateLimit)
      now <- liftIO getCurrentTime
      let allowedSources = Set.map corpusText corpora
      pure (selectRecallHits now resultLimit (filter ((`Set.member` allowedSources) . (.rcSource)) (lexical <> semantic)))
  where
    queryText = T.strip rawQuery

corpusText :: RecallCorpus -> Text
corpusText = \case
  RecallMemories -> "memory"
  RecallEpisodes -> "episode"
  RecallMessages -> "message"
  RecallPins -> "pin"
  RecallCaptions -> "caption"

-- | Merge duplicate representations, rank with bounded weak boosts, and apply
-- per-source quotas.  The second pass fills unused capacity only after every
-- available corpus has had a quota-protected opportunity.
selectRecallHits :: UTCTime -> Int -> [RecallCandidate] -> [RecallHit]
selectRecallHits now requestedLimit candidates =
  map (toHit now) final
  where
    resultLimit = max 1 (min 30 requestedLimit)
    merged = Map.elems (Map.fromListWith mergeCandidate [(candidate.rcDedupKey, candidate) | candidate <- candidates])
    eligible = filter ((>= minimumSignal) . candidateSignal) merged
    ranked = sortCandidates now eligible
    quotaSelected = take resultLimit (selectWithinQuotas resultLimit ranked)
    selectedKeys = Set.fromList (map (.rcDedupKey) quotaSelected)
    overflow = [candidate | candidate <- ranked, candidate.rcDedupKey `Set.notMember` selectedKeys]
    final = take resultLimit (sortCandidates now (quotaSelected <> take (resultLimit - length quotaSelected) overflow))

minimumSignal :: Double
minimumSignal = 0.08

candidateSignal :: RecallCandidate -> Double
candidateSignal candidate =
  max
    (clampScore (fromMaybe 0 candidate.rcLexicalScore))
    (clampScore (fromMaybe 0 candidate.rcSemanticScore))

mergeCandidate :: RecallCandidate -> RecallCandidate -> RecallCandidate
mergeCandidate left right =
  winner
    { rcLexicalScore = maxMaybe left.rcLexicalScore right.rcLexicalScore,
      rcSemanticScore = maxMaybe left.rcSemanticScore right.rcSemanticScore,
      rcImportance = max left.rcImportance right.rcImportance,
      rcPinned = left.rcPinned || right.rcPinned,
      rcPermanent = left.rcPermanent || right.rcPermanent
    }
  where
    winner =
      if presentationKey left >= presentationKey right
        then left
        else right
    presentationKey candidate =
      ( candidateSignal candidate,
        sourcePriority candidate.rcSource,
        candidate.rcOccurredAt,
        candidate.rcSource
      )

maxMaybe :: Maybe Double -> Maybe Double -> Maybe Double
maxMaybe Nothing right = right
maxMaybe left Nothing = left
maxMaybe (Just left) (Just right) = Just (max left right)

sortCandidates :: UTCTime -> [RecallCandidate] -> [RecallCandidate]
sortCandidates now =
  sortOn
    (\candidate -> (Down (scoreCandidate now candidate), Down candidate.rcOccurredAt, candidate.rcSource, candidate.rcDedupKey))

scoreCandidate :: UTCTime -> RecallCandidate -> Double
scoreCandidate now candidate =
  primary
    + 0.15 * secondary
    + 0.12 * clampScore candidate.rcImportance
    + (if candidate.rcPinned then 0.12 else 0)
    + (if candidate.rcPermanent then 0.08 else 0)
    + recencyBoost
  where
    lexical = clampScore (fromMaybe 0 candidate.rcLexicalScore)
    semantic = clampScore (fromMaybe 0 candidate.rcSemanticScore)
    primary = max lexical semantic
    secondary = min lexical semantic
    ageDays = max 0 (realToFrac (diffUTCTime now candidate.rcOccurredAt) / 86400 :: Double)
    recencyBoost = 0.08 / (1 + ageDays / 90)

clampScore :: Double -> Double
clampScore = max 0 . min 1

selectWithinQuotas :: Int -> [RecallCandidate] -> [RecallCandidate]
selectWithinQuotas resultLimit = go Map.empty
  where
    go _ [] = []
    go counts (candidate : rest)
      | Map.findWithDefault 0 candidate.rcSource counts >= sourceQuota resultLimit candidate.rcSource =
          go counts rest
      | otherwise =
          candidate : go (Map.insertWith (+) candidate.rcSource 1 counts) rest

sourceQuota :: Int -> Text -> Int
sourceQuota resultLimit source = case source of
  "memory" -> max 1 ((resultLimit + 3) `div` 4)
  "episode" -> max 1 ((resultLimit + 3) `div` 4)
  "message" -> max 1 ((resultLimit + 2) `div` 3)
  "pin" -> max 1 ((resultLimit + 5) `div` 6)
  "caption" -> max 1 ((resultLimit + 4) `div` 5)
  _ -> 1

sourcePriority :: Text -> Int
sourcePriority = \case
  "pin" -> 5
  "caption" -> 4
  "episode" -> 3
  "memory" -> 2
  "message" -> 1
  _ -> 0

toHit :: UTCTime -> RecallCandidate -> RecallHit
toHit now candidate =
  RecallHit
    { rhSource = candidate.rcSource,
      rhDedupKey = candidate.rcDedupKey,
      rhSnippet = candidate.rcSnippet,
      rhOccurredAt = candidate.rcOccurredAt,
      rhPrincipalId = candidate.rcPrincipalId,
      rhMessageId = candidate.rcMessageId,
      rhEpisodeHandle = candidate.rcEpisodeHandle,
      rhMemoryId = candidate.rcMemoryId,
      rhScore = scoreCandidate now candidate,
      rhLexicalScore = candidate.rcLexicalScore,
      rhSemanticScore = candidate.rcSemanticScore,
      rhPinned = candidate.rcPinned,
      rhPermanent = candidate.rcPermanent
    }

lexicalCandidatesSql :: Query
lexicalCandidatesSql =
  "WITH input AS ( \
  \  SELECT ?::bigint AS conversation_id, ?::text AS query_text, ?::int AS candidate_limit \
  \), pins AS ( \
  \  SELECT DISTINCT pin.value::bigint AS message_id \
  \  FROM sessions AS session \
  \  JOIN input ON input.conversation_id = session.group_id \
  \  CROSS JOIN LATERAL jsonb_array_elements_text(session.pinned) AS pin(value) \
  \), memory_candidates AS ( \
  \  SELECT 'memory'::text AS source, \
  \         CASE WHEN evidence.source_episode_id IS NOT NULL THEN 'episode:' || evidence.source_episode_id::text \
  \              WHEN evidence.source_message_id IS NOT NULL THEN 'message:' || evidence.source_message_id::text \
  \              ELSE 'memory:' || memory.id::text END AS dedup_key, \
  \         left(memory.content, 800) AS snippet, memory.updated_at AS occurred_at, \
  \         CASE WHEN memory.scope = 'user' THEN memory.scope_id ELSE NULL END::bigint AS principal_id, \
  \         NULL::bigint AS message_id, NULL::uuid AS episode_handle, memory.id AS memory_id, \
  \         0::double precision AS importance, \
  \         GREATEST(similarity(memory.content, input.query_text), \
  \           CASE WHEN position(lower(input.query_text) in lower(memory.content)) > 0 THEN 1 ELSE 0 END \
  \         )::double precision AS lexical_score, \
  \         NULL::double precision AS semantic_score, false AS is_pinned, \
  \         (memory.lifecycle = 'permanent') AS is_permanent \
  \  FROM memories AS memory CROSS JOIN input \
  \  LEFT JOIN LATERAL ( \
  \    SELECT source_episode_id, source_message_id FROM memory_evidence \
  \    WHERE memory_id = memory.id AND memory_version = memory.version \
  \    ORDER BY id DESC LIMIT 1 \
  \  ) AS evidence ON true \
  \  WHERE ((memory.scope = 'group' AND memory.scope_id = input.conversation_id) \
  \      OR (memory.scope = 'user' AND memory.source_group_id = input.conversation_id)) \
  \    AND memory.lifecycle IN ('active', 'permanent') \
  \    AND (position(lower(input.query_text) in lower(memory.content)) > 0 \
  \      OR similarity(memory.content, input.query_text) >= 0.08) \
  \  ORDER BY lexical_score DESC, memory.updated_at DESC, memory.id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \), episode_candidates AS ( \
  \  SELECT 'episode'::text AS source, 'episode:' || episode.id::text AS dedup_key, \
  \         left(episode.summary_p2, 800) AS snippet, COALESCE(episode.activated_at, episode.created_at) AS occurred_at, \
  \         NULL::bigint AS principal_id, NULL::bigint AS message_id, episode.expand_handle AS episode_handle, \
  \         NULL::bigint AS memory_id, episode.importance, \
  \         GREATEST(similarity(concat_ws(' ', episode.summary_p1, episode.summary_p2, episode.summary_p3), input.query_text), \
  \           CASE WHEN position(lower(input.query_text) in lower(concat_ws(' ', episode.summary_p1, episode.summary_p2, episode.summary_p3))) > 0 THEN 1 ELSE 0 END \
  \         )::double precision AS lexical_score, \
  \         NULL::double precision AS semantic_score, false AS is_pinned, false AS is_permanent \
  \  FROM conversation_compartments AS episode CROSS JOIN input \
  \  WHERE episode.conversation_id = input.conversation_id AND episode.state = 'active' \
  \    AND (position(lower(input.query_text) in lower(concat_ws(' ', episode.summary_p1, episode.summary_p2, episode.summary_p3))) > 0 \
  \      OR similarity(concat_ws(' ', episode.summary_p1, episode.summary_p2, episode.summary_p3), input.query_text) >= 0.08) \
  \  ORDER BY lexical_score DESC, occurred_at DESC, episode.id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \), message_candidates AS ( \
  \  SELECT CASE WHEN pins.message_id IS NULL THEN 'message' ELSE 'pin' END::text AS source, \
  \         'message:' || message.message_id::text AS dedup_key, left(message.rendered_text, 800) AS snippet, \
  \         message.received_at AS occurred_at, message.user_id AS principal_id, message.message_id, \
  \         NULL::uuid AS episode_handle, NULL::bigint AS memory_id, 0::double precision AS importance, \
  \         GREATEST(similarity(message.rendered_text, input.query_text), \
  \           CASE WHEN position(lower(input.query_text) in lower(message.rendered_text)) > 0 THEN 1 ELSE 0 END \
  \         )::double precision AS lexical_score, \
  \         NULL::double precision AS semantic_score, (pins.message_id IS NOT NULL) AS is_pinned, false AS is_permanent \
  \  FROM messages AS message CROSS JOIN input LEFT JOIN pins ON pins.message_id = message.message_id \
  \  WHERE message.group_id = input.conversation_id AND NOT message.is_synthetic \
  \    AND message.kind = 'chat' AND message.forwarded_in_message_id IS NULL \
  \    AND (position(lower(input.query_text) in lower(message.rendered_text)) > 0 \
  \      OR similarity(message.rendered_text, input.query_text) >= 0.08) \
  \  ORDER BY lexical_score DESC, message.received_at DESC, message.message_id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \), media AS ( \
  \  SELECT source.message_id, string_agg(DISTINCT source.description, ' | ') AS description \
  \  FROM ( \
  \    SELECT link.message_id, image.description FROM message_images AS link \
  \    JOIN images AS image USING (sha256) JOIN messages AS message USING (message_id) CROSS JOIN input \
  \    WHERE image.description IS NOT NULL AND message.group_id = input.conversation_id \
  \    UNION ALL \
  \    SELECT link.message_id, video.description FROM message_videos AS link \
  \    JOIN videos AS video USING (sha256) JOIN messages AS message USING (message_id) CROSS JOIN input \
  \    WHERE video.description IS NOT NULL AND message.group_id = input.conversation_id \
  \  ) AS source \
  \  GROUP BY source.message_id \
  \), caption_candidates AS ( \
  \  SELECT 'caption'::text AS source, 'message:' || message.message_id::text AS dedup_key, \
  \         left(media.description, 800) AS snippet, message.received_at AS occurred_at, \
  \         message.user_id AS principal_id, message.message_id, NULL::uuid AS episode_handle, \
  \         NULL::bigint AS memory_id, 0::double precision AS importance, \
  \         GREATEST(similarity(media.description, input.query_text), \
  \           CASE WHEN position(lower(input.query_text) in lower(media.description)) > 0 THEN 1 ELSE 0 END \
  \         )::double precision AS lexical_score, \
  \         NULL::double precision AS semantic_score, (pins.message_id IS NOT NULL) AS is_pinned, false AS is_permanent \
  \  FROM media JOIN messages AS message USING (message_id) CROSS JOIN input \
  \  LEFT JOIN pins ON pins.message_id = message.message_id \
  \  WHERE message.group_id = input.conversation_id \
  \    AND (position(lower(input.query_text) in lower(media.description)) > 0 \
  \      OR similarity(media.description, input.query_text) >= 0.08) \
  \  ORDER BY lexical_score DESC, message.received_at DESC, message.message_id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \) \
  \SELECT * FROM memory_candidates \
  \UNION ALL SELECT * FROM episode_candidates \
  \UNION ALL SELECT * FROM message_candidates \
  \UNION ALL SELECT * FROM caption_candidates"

semanticCandidatesSql :: Query
semanticCandidatesSql =
  "WITH input AS ( \
  \  SELECT ?::bigint AS conversation_id, ?::text AS model_id, ?::int AS dimensions, \
  \         ?::vector AS query_vector, ?::int AS candidate_limit \
  \), pins AS ( \
  \  SELECT DISTINCT pin.value::bigint AS message_id \
  \  FROM sessions AS session \
  \  JOIN input ON input.conversation_id = session.group_id \
  \  CROSS JOIN LATERAL jsonb_array_elements_text(session.pinned) AS pin(value) \
  \), compatible_memories AS MATERIALIZED ( \
  \  SELECT memory.*, evidence.source_episode_id AS recall_episode_id, \
  \         evidence.source_message_id AS recall_message_id, input.query_vector, input.candidate_limit \
  \  FROM memories AS memory CROSS JOIN input \
  \  LEFT JOIN LATERAL ( \
  \    SELECT source_episode_id, source_message_id FROM memory_evidence \
  \    WHERE memory_id = memory.id AND memory_version = memory.version \
  \    ORDER BY id DESC LIMIT 1 \
  \  ) AS evidence ON true \
  \  WHERE ((memory.scope = 'group' AND memory.scope_id = input.conversation_id) \
  \      OR (memory.scope = 'user' AND memory.source_group_id = input.conversation_id)) \
  \    AND memory.lifecycle IN ('active', 'permanent') \
  \    AND memory.embedding_model = input.model_id AND memory.embedding_dimensions = input.dimensions \
  \), memory_candidates AS ( \
  \  SELECT 'memory'::text AS source, \
  \         CASE WHEN memory.recall_episode_id IS NOT NULL THEN 'episode:' || memory.recall_episode_id::text \
  \              WHEN memory.recall_message_id IS NOT NULL THEN 'message:' || memory.recall_message_id::text \
  \              ELSE 'memory:' || memory.id::text END AS dedup_key, \
  \         left(memory.content, 800) AS snippet, memory.updated_at AS occurred_at, \
  \         CASE WHEN memory.scope = 'user' THEN memory.scope_id ELSE NULL END::bigint AS principal_id, \
  \         NULL::bigint AS message_id, NULL::uuid AS episode_handle, memory.id AS memory_id, \
  \         0::double precision AS importance, NULL::double precision AS lexical_score, \
  \         (1 - (memory.embedding <=> memory.query_vector))::double precision AS semantic_score, \
  \         false AS is_pinned, (memory.lifecycle = 'permanent') AS is_permanent \
  \  FROM compatible_memories AS memory \
  \  ORDER BY memory.embedding <=> memory.query_vector, memory.updated_at DESC, memory.id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \), compatible_episodes AS MATERIALIZED ( \
  \  SELECT episode.*, input.query_vector, input.candidate_limit \
  \  FROM conversation_compartments AS episode CROSS JOIN input \
  \  WHERE episode.conversation_id = input.conversation_id AND episode.state = 'active' \
  \    AND episode.embedding_model = input.model_id AND episode.embedding_dimensions = input.dimensions \
  \), episode_candidates AS ( \
  \  SELECT 'episode'::text AS source, 'episode:' || episode.id::text AS dedup_key, \
  \         left(episode.summary_p2, 800) AS snippet, COALESCE(episode.activated_at, episode.created_at) AS occurred_at, \
  \         NULL::bigint AS principal_id, NULL::bigint AS message_id, episode.expand_handle AS episode_handle, \
  \         NULL::bigint AS memory_id, episode.importance, NULL::double precision AS lexical_score, \
  \         (1 - (episode.embedding <=> episode.query_vector))::double precision AS semantic_score, \
  \         false AS is_pinned, false AS is_permanent \
  \  FROM compatible_episodes AS episode \
  \  ORDER BY episode.embedding <=> episode.query_vector, occurred_at DESC, episode.id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \), compatible_messages AS MATERIALIZED ( \
  \  SELECT message.*, input.query_vector, input.candidate_limit \
  \  FROM messages AS message CROSS JOIN input \
  \  WHERE message.group_id = input.conversation_id AND NOT message.is_synthetic \
  \    AND message.kind = 'chat' AND message.forwarded_in_message_id IS NULL \
  \    AND message.embedding_model = input.model_id AND message.embedding_dimensions = input.dimensions \
  \), message_candidates AS ( \
  \  SELECT CASE WHEN pins.message_id IS NULL THEN 'message' ELSE 'pin' END::text AS source, \
  \         'message:' || message.message_id::text AS dedup_key, left(message.rendered_text, 800) AS snippet, \
  \         message.received_at AS occurred_at, message.user_id AS principal_id, message.message_id, \
  \         NULL::uuid AS episode_handle, NULL::bigint AS memory_id, 0::double precision AS importance, \
  \         NULL::double precision AS lexical_score, \
  \         (1 - (message.embedding <=> message.query_vector))::double precision AS semantic_score, \
  \         (pins.message_id IS NOT NULL) AS is_pinned, false AS is_permanent \
  \  FROM compatible_messages AS message LEFT JOIN pins ON pins.message_id = message.message_id \
  \  ORDER BY message.embedding <=> message.query_vector, message.received_at DESC, message.message_id \
  \  LIMIT (SELECT candidate_limit FROM input) \
  \) \
  \SELECT * FROM memory_candidates \
  \UNION ALL SELECT * FROM episode_candidates \
  \UNION ALL SELECT * FROM message_candidates"
