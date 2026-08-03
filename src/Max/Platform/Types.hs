{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Platform-neutral identity and event vocabulary.
--
-- Native identifiers are deliberately opaque text.  They are meaningful only
-- together with the account or endpoint that issued them; no adapter may route
-- by a numeric range or leak a platform identifier into authorization logic.
module Max.Platform.Types
  ( ConversationId (..),
    EndpointId (..),
    PlatformAccountId (..),
    PrincipalId (..),
    PrincipalIdentityId (..),
    CanonicalMessageId (..),
    PlatformEventId (..),
    DeliveryId (..),
    NativeAccountId (..),
    NativeConversationId (..),
    NativeUserId (..),
    NativeEventId (..),
    PlatformCursor (..),
    Platform (..),
    renderPlatform,
    parsePlatform,
    ConversationKind (..),
    EndpointMode (..),
    EventKind (..),
    MessageRelation (..),
    MediaSource (..),
    ContentPart (..),
    PlatformCapabilities (..),
    noCapabilities,
    InboundEnvelope (..),
    DeliveryStatus (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

newtype ConversationId = ConversationId {unConversationId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype EndpointId = EndpointId {unEndpointId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype PlatformAccountId = PlatformAccountId {unPlatformAccountId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype PrincipalId = PrincipalId {unPrincipalId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype PrincipalIdentityId = PrincipalIdentityId {unPrincipalIdentityId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype CanonicalMessageId = CanonicalMessageId {unCanonicalMessageId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype PlatformEventId = PlatformEventId {unPlatformEventId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype DeliveryId = DeliveryId {unDeliveryId :: Int64}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype NativeAccountId = NativeAccountId {unNativeAccountId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype NativeConversationId = NativeConversationId {unNativeConversationId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype NativeUserId = NativeUserId {unNativeUserId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype NativeEventId = NativeEventId {unNativeEventId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype PlatformCursor = PlatformCursor {unPlatformCursor :: Value}
  deriving stock (Eq, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

data Platform
  = PlatformQQ
  | PlatformMatrix
  | PlatformIMessage
  | PlatformWeChatPad
  | PlatformCustom !Text
  deriving stock (Eq, Ord, Show, Generic)

renderPlatform :: Platform -> Text
renderPlatform = \case
  PlatformQQ -> "qq"
  PlatformMatrix -> "matrix"
  PlatformIMessage -> "imessage"
  PlatformWeChatPad -> "wechatpad"
  PlatformCustom name -> name

parsePlatform :: Text -> Platform
parsePlatform = \case
  "qq" -> PlatformQQ
  "matrix" -> PlatformMatrix
  "imessage" -> PlatformIMessage
  "wechatpad" -> PlatformWeChatPad
  name -> PlatformCustom name

data ConversationKind = ConversationGroup | ConversationDirect
  deriving stock (Eq, Ord, Show, Generic)

data EndpointMode = EndpointStandalone | EndpointMirror
  deriving stock (Eq, Ord, Show, Generic)

data EventKind
  = EventMessage
  | EventEdit
  | EventReaction
  | EventRedaction
  | EventMembership
  deriving stock (Eq, Ord, Show, Generic)

data MessageRelation
  = ReplyTo !NativeEventId
  | Replaces !NativeEventId
  | ReactsTo !NativeEventId !Text
  deriving stock (Eq, Show, Generic)

data MediaSource
  = RemoteMedia !Text !(Maybe Text) !(Maybe Int64) !(Maybe Text)
  | InlineMedia !ByteString !(Maybe Text) !(Maybe Text)
  deriving stock (Eq, Show, Generic)

data ContentPart
  = ContentText !Text
  | ContentMention !NativeUserId !(Maybe Text)
  | ContentMedia !MediaSource !(Maybe Text)
  | ContentUnsupported !Text
  deriving stock (Eq, Show, Generic)

-- | Capabilities are data owned by an endpoint, never optimistic defaults.
data PlatformCapabilities = PlatformCapabilities
  { canSendText :: !Bool,
    canSendMedia :: !Bool,
    canReply :: !Bool,
    canEdit :: !Bool,
    canReact :: !Bool,
    canRedact :: !Bool,
    maxTextBytes :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

noCapabilities :: PlatformCapabilities
noCapabilities =
  PlatformCapabilities
    { canSendText = False,
      canSendMedia = False,
      canReply = False,
      canEdit = False,
      canReact = False,
      canRedact = False,
      maxTextBytes = Nothing
    }

-- | Fully normalized input presented to the shared ingest kernel.
-- @rawPayload@ is diagnostic evidence only; the store applies its configured
-- byte limit before persistence and it must never participate in routing or
-- authorization.
data InboundEnvelope = InboundEnvelope
  { endpointId :: !EndpointId,
    nativeEventId :: !NativeEventId,
    senderNativeId :: !NativeUserId,
    senderDisplayName :: !(Maybe Text),
    occurredAt :: !UTCTime,
    receivedAt :: !UTCTime,
    eventKind :: !EventKind,
    content :: ![ContentPart],
    relations :: ![MessageRelation],
    sourceCursor :: !(Maybe PlatformCursor),
    rawPayload :: !(Maybe Value)
  }
  deriving stock (Eq, Show, Generic)

data DeliveryStatus
  = DeliveryPending
  | DeliverySending
  | DeliveryAcceptedUnconfirmed
  | DeliveryConfirmed
  | DeliveryFailed
  | DeliveryOutcomeUnknown
  | DeliverySuppressed
  deriving stock (Eq, Ord, Show, Generic)
