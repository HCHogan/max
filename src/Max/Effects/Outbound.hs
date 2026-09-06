{-# LANGUAGE TypeFamilies #-}

-- |
-- The application boundary for a visible outbound chat message.
--
-- Canonical publication is the commit point.  Per-endpoint delivery is durable
-- outbox work performed afterwards, so no transport can expose a message that
-- the conversation ledger forgot.
--
-- 'Published' acknowledges the canonical transaction, never physical delivery.
-- Platform receipts belong to the durable delivery worker.
module Max.Effects.Outbound
  ( Outbound,
    OutboundRequest (..),
    OutboundDeliveryScope (..),
    PublicationResult (..),
    runOutbound,
    runOutboundWith,
    sendRecorded,
    wasPublished,
  )
where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.IR
import Max.MessageKind (MessageKind (..), renderMessageKind)
import Max.Monitor.Types (MonitorFireId)
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Turn.Types (TurnOutputLink)
import Max.Util (trySync)
import OneBot.Types (GroupId (..))

-- | Everything fixed before one visible message is sent.
data OutboundRequest = OutboundRequest
  { orKind :: !MessageKind,
    orGroupId :: !GroupId,
    -- | The one semantic body published to the ledger.  Inline bytes,
    -- model-only handles and model-authored principals must all be resolved
    -- before crossing this boundary.
    orBody :: !(Body 'Canonical),
    -- | Reply is an envelope relation, never a content node.
    orReplyTo :: !(Maybe CanonicalMessageId),
    -- | Conversation replies fan out; command/debug output can stay on the
    -- exact endpoint that supplied its durable source message.
    orDeliveryScope :: !OutboundDeliveryScope,
    -- | Present only for visible output produced by an agent turn.  The
    -- canonical publish transaction commits this provenance with the message.
    orTurnOutput :: !(Maybe TurnOutputLink),
    -- | Present only for a durable canned monitor fire. The database makes
    -- this provenance unique, turning publication into an idempotent boundary.
    orMonitorFireId :: !(Maybe MonitorFireId)
  }
  deriving stock (Show, Eq)

data OutboundDeliveryScope
  = DeliverConversation
  | DeliverSourceEndpoint !CanonicalMessageId
  deriving stock (Show, Eq)

-- | The canonical publication commit point, independent of platform delivery.
data PublicationResult
  = PublicationFailed !Text
  | Published !CanonicalMessageId
  deriving stock (Show, Eq)

wasPublished :: PublicationResult -> Bool
wasPublished PublicationFailed {} = False
wasPublished Published {} = True

data Outbound :: Effect where
  SendRecorded :: OutboundRequest -> Outbound m PublicationResult

type instance DispatchOf Outbound = Dynamic

-- | Production interpreter: publish the canonical bot message and every
-- endpoint delivery before any transport worker can send it.  A platform
-- outage therefore leaves durable backlog instead of an unrecorded visible
-- message; 'Published' now means the canonical send intent is committed.
runOutbound ::
  forall es a.
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Eff (Outbound : es) a ->
  Eff es a
runOutbound = runOutboundWith deliver
  where
    deliver :: OutboundRequest -> Eff es PublicationResult
    deliver req = do
      let GroupId group = req.orGroupId
          draft =
            OutboundDraft
              { legacyConversationId = group,
                transcriptKind = renderMessageKind req.orKind,
                sourceCanonicalMessageId = case req.orDeliveryScope of
                  DeliverConversation -> Nothing
                  DeliverSourceEndpoint (CanonicalMessageId source) -> Just source,
                canonicalBody = req.orBody,
                replyToCanonicalMessageId = (\(CanonicalMessageId reply) -> reply) <$> req.orReplyTo,
                turnOutputLink = req.orTurnOutput,
                monitorFireId = req.orMonitorFireId
              }
      trySync (enqueueOutbound draft) >>= \case
        Left e -> failed req ("canonical publish failed: " <> T.pack (show (e :: SomeException)))
        Right queued -> pure (Published queued.canonicalMessageId)

    failed :: OutboundRequest -> Text -> Eff es PublicationResult
    failed req reason = do
      logAttention "outbound: send failed" $
        object
          [ "group_id" .= req.orGroupId,
            "kind" .= T.pack (show req.orKind),
            "error" .= reason
          ]
      pure (PublicationFailed reason)

-- | Install any request handler as the interpreter.  Besides keeping
-- 'runOutbound' small, this is the in-memory seam for Handler/Agent tests: a
-- fake can capture requests and choose any delivery state without platform RPC or a
-- database.
runOutboundWith ::
  (OutboundRequest -> Eff es PublicationResult) ->
  Eff (Outbound : es) a ->
  Eff es a
runOutboundWith f = interpret $ \_ -> \case
  SendRecorded req -> f req

sendRecorded :: (Outbound :> es) => OutboundRequest -> Eff es PublicationResult
sendRecorded = send . SendRecorded
