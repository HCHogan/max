-- | Reading a history projection does not publish or trace a prompt.
module Max.Prompt.History (HistorySource (..), HistorySelection (..), loadHistorySource, collectHistoryProjection, fetchBoundedPromptTail) where

import Data.Int (Int64)
import Data.Text (Text)
import Effectful (Eff, IOE, type (:>))
import Effectful.Log
  ( Log,
    UTCTime,
    logAttention,
    logInfo,
    object,
    (.=),
  )
import Effectful.PostgreSQL (WithConnection)
import Max.Context.Policy (applyBaseCompartmentTiers)
import Max.Context.Types
  ( ContextCompartment,
    ContextReadMode (RawLedgerEmergency, TieredContext),
    HistoryTokenWatermarks (htwHigh),
  )
import Max.ConversationScope
  ( ConversationScope,
    conversationScopeFor,
  )
import Max.DB.History
  ( HistoryItem,
    HistoryPage (hasMore, items),
    LedgerItem (cursor, history),
    MessageCursor (MessageCursor),
    fetchNewestPromptPageBefore,
  )
import Max.Dispatch (DispatchMessage (canonicalId, groupId))
import Max.Episode.Types (SourceRange (..))
import Max.EpisodeStore
  ( ActiveCompartment (..),
    listActiveCompartments,
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
  )
import Max.Prompt.Render
  ( contextCompartmentFromActive,
    historyTokenWatermarks,
    latestGapFreeSuffix,
    rawTailTokens,
  )
import Max.Prompt.Request
  ( PromptRequest
      ( prLimits,
        prMultimodal,
        prReadMode,
        prSession,
        prTrigger
      ),
  )
import Max.Session.Types (Session (clearedAt))
import OneBot.Types (GroupId (..))

data HistorySource = RawHistory !Text | ProjectedHistory ![ActiveCompartment]

data HistorySelection = HistorySelection ![ContextCompartment] ![HistoryItem] !(Maybe Int64) !(Maybe Text)

loadHistorySource :: (WithConnection :> es, Log :> es, IOE :> es) => PromptRequest -> Eff es HistorySource
loadHistorySource request = case request.prReadMode of
  RawLedgerEmergency -> do
    logAttention "context: global raw-ledger emergency reader enabled" (object ["group_id" .= gid])
    pure (RawHistory "operator_forced_raw_fallback")
  TieredContext -> do
    active <- listActiveCompartments scope
    let visible = maybe active (\cleared -> filter ((> cleared) . (.activeStartedAt)) active) request.prSession.clearedAt
    case latestGapFreeSuffix visible of
      [] -> do
        logInfo "context: no active compartment; using token-budgeted raw fallback" (object ["group_id" .= gid])
        pure (RawHistory "raw_fallback_no_compartments")
      covered -> pure (ProjectedHistory covered)
  where
    GroupId gid = request.prTrigger.groupId
    scope = conversationScopeFor request.prTrigger.groupId

collectHistoryProjection :: (WithConnection :> es, IOE :> es) => Text -> UTCTime -> PromptRequest -> HistorySource -> Eff es HistorySelection
collectHistoryProjection reason now request source = do
  let (cursor, compartments, detail) = case source of
        RawHistory why -> (MessageCursor 0, [], why)
        ProjectedHistory covered -> ((last covered).activeRange.srEnd, applyBaseCompartmentTiers now (map contextCompartmentFromActive covered), reason)
      scope = conversationScopeFor request.prTrigger.groupId
      CanonicalMessageId trigger = request.prTrigger.canonicalId
      limits = historyTokenWatermarks request.prLimits request.prMultimodal
  (raw, _) <- fetchBoundedPromptTail scope cursor trigger request.prSession.clearedAt limits.htwHigh
  pure (HistorySelection compartments (map (.history) raw) Nothing (Just detail))

-- | Collect only the newest token-sized raw tail.  SQL pages are walked
-- backward so an arbitrarily old ledger never has to enter memory merely to
-- be dropped by ContextPolicy.  The final page may overshoot the token target;
-- the pure policy remains the authoritative exact selection boundary.
fetchBoundedPromptTail ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Int ->
  Eff es ([LedgerItem], Bool)
fetchBoundedPromptTail scope after triggerId cleared tokenLimit = go Nothing [] 0
  where
    go before accumulated used = do
      page <- fetchNewestPromptPageBefore scope after before triggerId cleared promptTailPageSize
      let rows = page.items
          accumulated' = rows <> accumulated
          used' = used + rawTailTokens rows
      case rows of
        [] -> pure (accumulated, False)
        oldest : _
          | page.hasMore && used' < max 1 tokenLimit ->
              go (Just oldest.cursor) accumulated' used'
          | otherwise -> pure (accumulated', page.hasMore)

-- Internal database page size only; never a retained-message boundary.
promptTailPageSize :: Int
promptTailPageSize = 256
