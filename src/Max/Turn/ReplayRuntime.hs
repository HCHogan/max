-- | Read-only replay loading and fallback. Replay admission stays pure.
module Max.Turn.ReplayRuntime (replayContinuation, injectRecoveryView) where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS (ByteString)
import Data.List (unsnoc)
import Data.Map.Strict qualified as Map (fromList, lookup)
import Data.Text qualified as T (Text, pack)
import Data.Time (TimeZone)
import Effectful (Eff, IOE, type (:>))
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention, logInfo, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Context.Types (ContinuationInput (..))
import Max.ConversationScope (ConversationScope)
import Max.DB.History
  ( HistoryItem (..),
    fetchMessagesByIdsInScope,
  )
import Max.DB.TurnContinuity (replayChain)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.LLM.Types (ChatMessage (..), ContentBlock (..))
import Max.Prompt.Render (renderHistoryLine)
import Max.Turn.Replay
  ( ReplayCandidate
      ( rcArchiveSha,
        rcTriggerCanonicalId,
        rcTriggerLine
      ),
    ReplayEnvironment,
    ReplayPlan (rpEstimatedTokens, rpSegments, rpStoppedBecause),
    ReplayReject (RejectArchiveUnreadable),
    TurnArchive (taAppended, taVersion),
    defaultChainDepth,
    planCoveredCanonicalIds,
    planReplay,
    planReplayMessages,
    replayRejectText,
  )
import Max.Turn.Types (AgentTurnRef (..), TurnOrdinal (..))
import Max.Util (catchSync)

replayContinuation ::
  (Blob :> es, Log :> es, WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ConversationScope ->
  ReplayEnvironment ->
  AgentTurnRef ->
  -- | Digest tier: the whole record, and the floor every failure lands on.
  ContinuationInput ->
  -- | Replay tier companion: the drift note only, since the record itself
  -- arrives as wire items.
  ContinuationInput ->
  Eff es ContinuationInput
replayContinuation tz scope replayEnv target digestOnly replayDelta =
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
                  renderHistoryLine tz
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
