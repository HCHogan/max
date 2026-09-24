-- | Read current summaries and the token-bounded raw tail they precede.
module Max.Prompt.History (HistorySelection (..), collectHistory, fetchBoundedPromptTail) where

import Control.Monad (when)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (listToMaybe)
import Effectful (Eff, IOE, type (:>))
import Effectful.Log (Log, UTCTime, logAttention, logInfo, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Context.Types (ContextCompartment, ContextReadMode (..))
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.History (HistoryItem, HistoryPage (..), LedgerItem (..), MessageCursor (..), fetchNewestPromptPageBefore)
import Max.Dispatch (DispatchMessage (canonicalId, groupId))
import Max.Episode.Types (SourceRange (..))
import Max.EpisodeStore (ActiveCompartment (..), listActiveCompartments)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Prompt.Render (contextCompartmentFromActive, historyTokenLimit, latestGapFreeSuffix, rawTailTokens)
import Max.Prompt.Request (PromptRequest (..))
import Max.Session.Types (Session (clearedAt))
import OneBot.Types (GroupId (..))

data HistorySelection = HistorySelection
  { selectedCompartments :: ![ContextCompartment],
    selectedHistory :: ![HistoryItem]
  }

collectHistory :: (WithConnection :> es, Log :> es, IOE :> es) => PromptRequest -> Eff es HistorySelection
collectHistory request = do
  covered <- case request.prReadMode of
    RawLedgerEmergency -> do
      logAttention "context: global raw-ledger emergency reader enabled" (object ["group_id" .= gid])
      pure []
    SummaryContext -> do
      active <- listActiveCompartments scope
      let visible = maybe active (\cleared -> filter ((> cleared) . (.activeStartedAt)) active) request.prSession.clearedAt
          suffix = latestGapFreeSuffix visible
      when (null suffix) $
        logInfo "context: no active compartment; using token-budgeted raw fallback" (object ["group_id" .= gid])
      pure suffix
  let end = maybe (MessageCursor 0) ((.activeRange.srEnd) . NE.last) (NE.nonEmpty covered)
      tokenLimit = historyTokenLimit request.prLimits request.prMultimodal
  (raw, dropped) <- fetchBoundedPromptTail scope end trigger request.prSession.clearedAt tokenLimit
  when dropped $
    logAttention "context: raw history exceeds bounded tail" $
      object
        [ "group_id" .= gid,
          "summary_end_seq" .= end.ingestSeq,
          "tail_start_seq" .= fmap (.cursor.ingestSeq) (listToMaybe raw),
          "tail_tokens" .= rawTailTokens raw,
          "tail_token_limit" .= tokenLimit
        ]
  pure
    HistorySelection
      { selectedCompartments = map contextCompartmentFromActive covered,
        selectedHistory = map (.history) raw
      }
  where
    GroupId gid = request.prTrigger.groupId
    scope = conversationScopeFor request.prTrigger.groupId
    CanonicalMessageId trigger = request.prTrigger.canonicalId

-- | Collect only the newest token-sized raw tail.  SQL pages are walked
-- backward so an arbitrarily old ledger never has to enter memory merely to
-- be dropped by ContextPolicy. Trim the final I/O page to the actual token
-- target; the overall prompt planner still protects current input and pins.
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
          | otherwise ->
              let selected = reverse (fit (max 0 tokenLimit) (reverse accumulated'))
               in pure (selected, page.hasMore || length selected < length accumulated')

    fit _ [] = []
    fit remaining (entry : rest)
      | cost <= remaining = entry : fit (remaining - cost) rest
      | otherwise = []
      where
        cost = rawTailTokens [entry]

-- Internal database page size only; never a retained-message boundary.
promptTailPageSize :: Int
promptTailPageSize = 256
