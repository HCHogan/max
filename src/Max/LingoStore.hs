-- | Conversation-scoped storage for learned lingo.  Merging a batch and
-- advancing the learner cursor commit together, so a crash never counts a
-- range twice or skips one.
module Max.LingoStore
  ( recordLingoBatch,
    redactedAmong,
    JargonCandidate (..),
    jargonAwaitingInference,
    recordJargonInference,
    listExpressionCandidates,
    listKnownJargon,
    LingoStats (..),
    lingoStats,
  )
where

import Control.Monad (forM_, void)
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.ConversationCursor (advanceCursor, historianCursor, lingoCursor, loadCursor)
import Max.DB.History (MessageCursor (..))
import Max.DB.Transaction (withTransaction)
import Max.Lingo.Policy (ExpressionObservation (..), JargonInference (..), JargonObservation (..))
import Max.Lingo.Types

-- | Merge one learned range and move the cursor from exactly @expected@ to
-- @next@.  'False' means another writer moved the cursor; nothing is stored.
recordLingoBatch ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  [ExpressionObservation] ->
  [JargonObservation] ->
  Eff es Bool
recordLingoBatch scope expected next expressions jargon = withTransaction $ do
  advanced <- advanceCursor scope lingoCursor expected next
  if not advanced
    then pure False
    else do
      forM_ expressions (upsertExpression scope)
      forM_ jargon (upsertJargon scope)
      pure True

upsertExpression :: (WithConnection :> es, IOE :> es) => ConversationScope -> ExpressionObservation -> Eff es ()
upsertExpression scope observation =
  void $
    execute
      "INSERT INTO lingo_expressions \
      \  (conversation_id, situation, style, style_key, example_message_id, example_text) \
      \ VALUES (?, ?, ?, ?, ?, ?) \
      \ ON CONFLICT (conversation_id, style_key) DO UPDATE SET \
      \   hits = lingo_expressions.hits + 1, \
      \   situation = EXCLUDED.situation, \
      \   style = EXCLUDED.style, \
      \   example_message_id = EXCLUDED.example_message_id, \
      \   example_text = EXCLUDED.example_text, \
      \   last_learned_at = now()"
      ( conversationStorageId scope,
        observation.eoSituation,
        observation.eoStyle,
        observation.eoStyleKey,
        observation.eoMessageId,
        observation.eoExample
      )

-- | Speakers are a bounded distinct sample (the inference gate only needs
-- two); contexts keep the eight most recent usages.
upsertJargon :: (WithConnection :> es, IOE :> es) => ConversationScope -> JargonObservation -> Eff es ()
upsertJargon scope observation =
  void $
    execute
      "INSERT INTO lingo_jargon \
      \  (conversation_id, term, term_key, speakers, contexts, example_message_id, example_text) \
      \ VALUES (?, ?, ?, ARRAY[?]::bigint[], ARRAY[?]::text[], ?, ?) \
      \ ON CONFLICT (conversation_id, term_key) DO UPDATE SET \
      \   hits = lingo_jargon.hits + 1, \
      \   speakers = CASE \
      \     WHEN EXCLUDED.speakers[1] = ANY (lingo_jargon.speakers) \
      \       OR cardinality(lingo_jargon.speakers) >= 16 THEN lingo_jargon.speakers \
      \     ELSE lingo_jargon.speakers || EXCLUDED.speakers END, \
      \   contexts = (lingo_jargon.contexts || EXCLUDED.contexts) \
      \     [greatest(1, cardinality(lingo_jargon.contexts) - 6):], \
      \   example_message_id = EXCLUDED.example_message_id, \
      \   example_text = EXCLUDED.example_text, \
      \   last_learned_at = now()"
      ( conversationStorageId scope,
        observation.joTerm,
        observation.joTermKey,
        observation.joPrincipal,
        observation.joContext,
        observation.joMessageId,
        observation.joExample
      )

-- | Messages their authors took back.  The learner never reads them.
redactedAmong :: (WithConnection :> es, IOE :> es) => [Int64] -> Eff es (Set Int64)
redactedAmong [] = pure Set.empty
redactedAmong ids = do
  rows <-
    query
      "SELECT DISTINCT target_canonical_message_id FROM message_relations \
      \ WHERE relation_kind = 'redacts' AND target_canonical_message_id IN ?"
      (Only (In ids))
  pure (Set.fromList [target | Only target <- rows])

data JargonCandidate = JargonCandidate
  { jcId :: !Int64,
    jcTerm :: !Text,
    jcHits :: !Int,
    jcInferredHits :: !Int,
    jcSpeakers :: !Int,
    jcContexts :: ![Text]
  }
  deriving stock (Show, Eq)

-- | Terms at or past the first inference threshold that have not been
-- inferred at their current count.  The caller applies the threshold policy.
jargonAwaitingInference :: (WithConnection :> es, IOE :> es) => ConversationScope -> Int -> Eff es [JargonCandidate]
jargonAwaitingInference scope limit = do
  rows <-
    query
      "SELECT id, term, hits, inferred_hits, cardinality(speakers), contexts \
      \ FROM lingo_jargon \
      \ WHERE conversation_id = ? AND hits > inferred_hits AND hits >= 4 \
      \   AND cardinality(speakers) >= 2 \
      \ ORDER BY hits DESC, id \
      \ LIMIT ?"
      (conversationStorageId scope, limit)
  pure
    [ JargonCandidate jid term hits inferred speakers contexts
    | (jid, term, hits, inferred, speakers, PGArray contexts) <- rows
    ]

-- | Record an inference made at @hits@.  A no-information answer keeps any
-- earlier meaning but still marks the count as tried.
recordJargonInference :: (WithConnection :> es, IOE :> es) => Int64 -> Int -> JargonInference -> Eff es ()
recordJargonInference jid hits inference =
  void $ case inference.jiMeaning of
    Nothing ->
      execute
        "UPDATE lingo_jargon SET inferred_hits = ?, inferred_at = now() WHERE id = ?"
        (hits, jid)
    Just meaning ->
      execute
        "UPDATE lingo_jargon \
        \ SET meaning = ?, group_specific = ?, inferred_hits = ?, inferred_at = now() \
        \ WHERE id = ?"
        (meaning, inference.jiGroupSpecific, hits, jid)

-- | The most established expressions whose example is still visible.
listExpressionCandidates :: (WithConnection :> es, IOE :> es) => ConversationScope -> Int -> Eff es [LingoExpression]
listExpressionCandidates scope limit = do
  rows <-
    query
      "SELECT e.id, e.situation, e.style, e.hits, e.example_text \
      \ FROM lingo_expressions e \
      \ WHERE e.conversation_id = ? \
      \   AND NOT EXISTS ( \
      \     SELECT 1 FROM message_relations r \
      \     WHERE r.target_canonical_message_id = e.example_message_id \
      \       AND r.relation_kind = 'redacts') \
      \ ORDER BY e.hits DESC, e.last_learned_at DESC, e.id DESC \
      \ LIMIT ?"
      (conversationStorageId scope, limit)
  pure [LingoExpression eid situation style hits example | (eid, situation, style, hits, example) <- rows]

-- | Terms whose inferred meaning is specific to this group.
listKnownJargon :: (WithConnection :> es, IOE :> es) => ConversationScope -> Int -> Eff es [LingoJargon]
listKnownJargon scope limit = do
  rows <-
    query
      "SELECT term, meaning, hits FROM lingo_jargon \
      \ WHERE conversation_id = ? AND group_specific \
      \ ORDER BY hits DESC, id \
      \ LIMIT ?"
      (conversationStorageId scope, limit)
  pure [LingoJargon term meaning hits | (term, meaning, hits) <- rows]

data LingoStats = LingoStats
  { stExpressions :: !Int,
    stJargonCandidates :: !Int,
    stKnownJargon :: !Int,
    stLearnedThrough :: !MessageCursor,
    stSettledThrough :: !MessageCursor
  }
  deriving stock (Show, Eq)

lingoStats :: (WithConnection :> es, IOE :> es) => ConversationScope -> Eff es LingoStats
lingoStats scope = do
  counts <-
    query
      "SELECT \
      \  (SELECT count(*) FROM lingo_expressions WHERE conversation_id = ?), \
      \  (SELECT count(*) FROM lingo_jargon WHERE conversation_id = ?), \
      \  (SELECT count(*) FROM lingo_jargon WHERE conversation_id = ? AND group_specific)"
      (conversationStorageId scope, conversationStorageId scope, conversationStorageId scope)
  learned <- loadCursor scope lingoCursor
  settled <- loadCursor scope historianCursor
  pure $ case counts of
    [(expressions, candidates, known)] -> LingoStats expressions candidates known learned settled
    _ -> LingoStats 0 0 0 learned settled
