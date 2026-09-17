-- | Publication adapter. Pure rendering and preview collection cannot reach
-- this module; CAS and its fail-soft fallback are owned by prompt assembly.
module Max.Prompt.Materialize (collectPublishedHistory, materializeTieredHistory) where

import Control.Monad (when)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text qualified as T (pack)
import Effectful (Eff, IOE, type (:>))
import Effectful.Log (Log, UTCTime, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Context.Materialization
  ( ContextMaterialization (cmEndCursor, cmReason, cmRevision),
  )
import Max.Context.Types
  ( HistoryTokenWatermarks (htwHigh, htwLow),
  )
import Max.ContextMaterialization
  ( loadContextMaterialization,
    publishContextMaterialization,
  )
import Max.ConversationScope
  ( ConversationScope,
    conversationScopeFor,
  )
import Max.DB.History
  ( LedgerItem (cursor, history),
    MessageCursor (ingestSeq),
  )
import Max.Dispatch (DispatchMessage (canonicalId, groupId))
import Max.Episode.Types (SourceRange (..))
import Max.EpisodeStore
  ( ActiveCompartment (activeGapBefore, activeRange),
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
  )
import Max.Prompt.History
  ( HistorySelection (..),
    HistorySource (ProjectedHistory, RawHistory),
    collectHistoryProjection,
    fetchBoundedPromptTail,
    loadHistorySource,
  )
import Max.Prompt.Render
  ( historyTokenWatermarks,
    materializationDraft,
    materializationMatches,
    materializedCompartments,
    rawTailTokens,
    targetAtLowWater,
  )
import Max.Prompt.Request
  ( PromptRequest (prLimits, prMultimodal, prSession, prTrigger),
  )
import Max.Session.Types (Session (clearedAt))
import Max.Util (trySync)
import OneBot.Types (GroupId (..))

collectPublishedHistory :: (WithConnection :> es, Log :> es, IOE :> es) => UTCTime -> PromptRequest -> Eff es HistorySelection
collectPublishedHistory now request = do
  source <- loadHistorySource request
  case source of
    RawHistory _ -> collectHistoryProjection "raw_fallback" now request source
    ProjectedHistory covered -> do
      when (any (.activeGapBefore) (drop 1 covered)) $
        logAttention "context: invalid gap inside selected compartment suffix" (object ["group_id" .= gid])
      result <- trySync (materializeTieredHistory scope trigger request.prSession.clearedAt now limits covered)
      case result of
        Left failure -> do
          logAttention "context: tiered materialization failed; using last-known-good projection" (object ["group_id" .= gid, "error" .= T.pack (show failure)])
          collectHistoryProjection "last_known_good_projection_fallback" now request source
        Right (materialized, raw, dropped) -> do
          when dropped $
            logAttention "context: bounded tail dropped rows not yet owned by a compartment" $
              object
                [ "group_id" .= gid,
                  "materialization_end_seq" .= materialized.cmEndCursor.ingestSeq,
                  "tail_start_seq" .= fmap (.cursor.ingestSeq) (listToMaybe raw),
                  "tail_tokens" .= rawTailTokens raw,
                  "high_watermark" .= limits.htwHigh
                ]
          pure (HistorySelection (materializedCompartments covered materialized) (map (.history) raw) (Just materialized.cmRevision) (Just materialized.cmReason))
  where
    GroupId gid = request.prTrigger.groupId
    scope = conversationScopeFor request.prTrigger.groupId
    CanonicalMessageId trigger = request.prTrigger.canonicalId
    limits = historyTokenWatermarks request.prLimits request.prMultimodal

-- | The returned 'Bool' is the coverage-loss signal: 'True' means the bounded
-- tail fetch stopped before reaching the materialization end cursor, so raw
-- rows exist between the last compartment and the oldest returned tail row
-- that this turn cannot see (the historian has not folded them yet).  Callers
-- on that fail-soft path must record an observable attention state.
materializeTieredHistory ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Maybe UTCTime ->
  UTCTime ->
  HistoryTokenWatermarks ->
  [ActiveCompartment] ->
  Eff es (ContextMaterialization, [LedgerItem], Bool)
materializeTieredHistory scope triggerId cleared now' watermarks active = do
  stored <- loadContextMaterialization scope
  current <- case stored of
    Nothing -> publishOrReload Nothing "initial_materialization" active
    Just materialization
      | not (materializationMatches active materialization) -> do
          let retained = filter ((<= materialization.cmEndCursor) . (.srEnd) . (.activeRange)) active
              replacement = if null retained then active else retained
          publishOrReload (Just materialization.cmRevision) "projection_change" replacement
      | otherwise -> pure materialization
  (tailRows, tailTruncated) <-
    fetchBoundedPromptTail scope current.cmEndCursor triggerId cleared watermarks.htwHigh
  if not tailTruncated && rawTailTokens tailRows <= watermarks.htwHigh
    then pure (current, tailRows, False)
    else case targetAtLowWater current tailRows active watermarks.htwLow of
      Nothing -> pure (current, tailRows, tailTruncated)
      Just target -> do
        folded <- publishOrReload (Just current.cmRevision) "high_water" target
        (foldedTail, foldedTruncated) <-
          fetchBoundedPromptTail scope folded.cmEndCursor triggerId cleared watermarks.htwHigh
        pure (folded, foldedTail, foldedTruncated)
  where
    publishOrReload expected reason target = do
      let draft = materializationDraft now' (min 8192 watermarks.htwHigh) reason target
      publishContextMaterialization scope expected draft >>= \case
        Just materialization -> pure materialization
        Nothing ->
          loadContextMaterialization scope >>= \case
            Just winner -> pure winner
            Nothing -> error "context materialization CAS lost without a stored winner"
