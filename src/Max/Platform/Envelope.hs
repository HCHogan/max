-- | Adapter input with native mention IDs. The ingest transaction resolves
-- principal identities and persists the canonical body (ADR 003).
-- @rawPayload@ is size-limited diagnostic data, never routing or authorization input.
module Max.Platform.Envelope
  ( IngestClass (..),
    InboundEnvelope (..),
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

-- | Host-authenticated provenance for one adapter delivery.  This value is
-- supplied by adapter control flow, never inferred from content or clocks.
-- Historical import is deliberately the fail-closed constructor.
data IngestClass
  = LiveDelivery
  | Backfill
  deriving stock (Eq, Show)

data InboundEnvelope = InboundEnvelope
  { endpointId :: !EndpointId,
    nativeEventId :: !NativeEventId,
    senderNativeId :: !NativeUserId,
    senderDisplayName :: !(Maybe Text),
    occurredAt :: !UTCTime,
    receivedAt :: !UTCTime,
    eventKind :: !EventKind,
    ingestClass :: !IngestClass,
    content :: !(Body 'Ingest),
    relations :: ![MessageRelation],
    sourceCursor :: !(Maybe PlatformCursor),
    rawPayload :: !(Maybe Value)
  }
  deriving stock (Eq, Show)
