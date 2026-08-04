-- | The fully normalized input presented to the shared ingest kernel.
--
-- Content is an ADR 003 IR body in the 'Ingest' phase: everything an
-- adapter can build without database access.  Mentions still carry their
-- origin-native user id; 'Max.Platform.Store.ingestEnvelope' resolves them
-- to principal identities inside the ingest transaction and stores the
-- 'Canonical' phase.
--
-- @rawPayload@ is diagnostic evidence only; the store applies its
-- configured byte limit before persistence and it must never participate
-- in routing or authorization.
module Max.Platform.Envelope
  ( InboundEnvelope (..),
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.IR (Body, Phase (..))
import Max.Platform.Types
  ( EndpointId,
    EventKind,
    MessageRelation,
    NativeEventId,
    NativeUserId,
    PlatformCursor,
  )

data InboundEnvelope = InboundEnvelope
  { endpointId :: !EndpointId,
    nativeEventId :: !NativeEventId,
    senderNativeId :: !NativeUserId,
    senderDisplayName :: !(Maybe Text),
    occurredAt :: !UTCTime,
    receivedAt :: !UTCTime,
    eventKind :: !EventKind,
    content :: !(Body 'Ingest),
    relations :: ![MessageRelation],
    sourceCursor :: !(Maybe PlatformCursor),
    rawPayload :: !(Maybe Value)
  }
  deriving stock (Eq, Show)
