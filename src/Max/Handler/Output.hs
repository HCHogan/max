module Max.Handler.Output
  ( sendTarget,
    sendAndRecord,
    replyText,
    parseSilence,
    splitQuoteHandles,
    isSilentReply,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (void)
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.Maybe (isJust, listToMaybe, mapMaybe)
import Data.Text qualified as T
import Effectful (Eff, type (:>))
import Max.Dispatch
  ( DispatchMessage (canonicalId, groupId, selfPrincipalId),
  )
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (DeliverSourceEndpoint),
    OutboundRequest (..),
    sendRecorded,
  )
import Max.Faces (faceIdByName)
import Max.IR (Body (Body), Node (NText), Phase (Canonical))
import Max.MessageKind (MessageKind (KindCommand))
import Max.Platform.Types
  ( AdvertisedCaps (..),
    CanonicalMessageId,
    PrincipalId,
  )
import Max.ReplySend (ReplyTarget (..))
import Max.Turn.Types (TurnOutputContext)
import Max.Util (readIntegral)
import OneBot.Types (GroupId)

--------------------------------------------------------------------------------
-- Reply helper.

-- | Derive reply capabilities and provenance from the current dispatch.
sendTarget ::
  AdvertisedCaps ->
  DispatchMessage ->
  [(T.Text, PrincipalId)] ->
  Bool ->
  Maybe TurnOutputContext ->
  ReplyTarget
sendTarget outputCaps gm rosterNames stickersOn turnOutput =
  ReplyTarget
    { rtGroupId = gm.groupId,
      rtRosterNames = rosterNames,
      rtSelfPrincipal = Just gm.selfPrincipalId,
      rtStickers = stickersOn,
      rtCanReply = outputCaps.canReply,
      rtCanMention = outputCaps.canMention,
      rtCanFace = outputCaps.canFace,
      rtCanImage = outputCaps.canMedia,
      rtTurnOutputContext = turnOutput
    }

-- | Publish command or other non-turn output through the canonical outbound
-- boundary, preserving its delivery scope and optional reply target.
sendAndRecord ::
  (Outbound :> es) =>
  MessageKind ->
  OutboundDeliveryScope ->
  GroupId ->
  Body 'Canonical ->
  Maybe CanonicalMessageId ->
  Eff es ()
sendAndRecord kind deliveryScope gid body replyTo =
  void $
    sendRecorded
      OutboundRequest
        { orKind = kind,
          orGroupId = gid,
          orBody = body,
          orReplyTo = replyTo,
          orDeliveryScope = deliveryScope,
          orTurnOutput = Nothing,
          orMonitorFireId = Nothing
        }

-- | Command UI returns to the source endpoint and stays out of model history.
replyText ::
  (Outbound :> es) =>
  DispatchMessage ->
  T.Text ->
  Eff es ()
replyText gm body =
  sendAndRecord KindCommand (DeliverSourceEndpoint gm.canonicalId) gm.groupId (Body [NText body]) Nothing

-- | Recognise an empty reply or an exact [silence]/[silence:reason] marker
-- after leading quote handles. Embedded markers do not silence real prose.
-- Nothing means a normal reply; Just contains the optional reason face.
parseSilence :: T.Text -> Maybe (Maybe Int)
parseSilence t0
  | T.null t || closed == "[silence]" || closed == "[沉默]" = Just Nothing
  | Just inner <- withReason = Just (faceIdByName (T.strip inner))
  | otherwise = Nothing
  where
    t = dropQuoteHandles t0
    -- Repair a missing closing bracket only when the entire input has no ']'.
    -- Exact matching below still rejects prose containing a silence marker.
    closed
      | T.any (== ']') t = t
      | otherwise = T.stripEnd t <> "]"
    withReason =
      (T.stripPrefix "[silence:" closed <|> T.stripPrefix "[silence：" closed)
        >>= T.stripSuffix "]"

-- | Parse leading reply handles (including legacy spelling) for silence reactions.
-- Handles within ordinary text remain content.
splitQuoteHandles :: T.Text -> ([Int64], T.Text)
splitQuoteHandles = go []
  where
    go acc s =
      let s' = T.stripStart s
       in case listToMaybe (mapMaybe (`T.stripPrefix` s') ["[reply#", "[↩#"]) of
            Just rest
              | (num, rest') <- T.span (\c -> isDigit c || c == '-') rest,
                not (T.null (T.filter isDigit num)),
                Just rest'' <- T.stripPrefix "]" rest' ->
                  go (acc <> maybe [] pure (readIntegral num)) rest''
            _ -> (acc, s')

dropQuoteHandles :: T.Text -> T.Text
dropQuoteHandles = snd . splitQuoteHandles

isSilentReply :: T.Text -> Bool
isSilentReply = isJust . parseSilence
