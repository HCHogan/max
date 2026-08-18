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
    ReactionAction (..),
    MessageRelation (..),
    AdvertisedCaps (..),
    noAdvertisedCaps,
    qqAdvertisedCaps,
    DeliveryStatus (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Int (Int64)
import Data.Text (Text)
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
  | -- | WeChat through a hooked Windows PC client.  Its own platform rather
    -- than "WeChat": an endpoint's platform is what routes its outbound
    -- traffic, and the endpoints, capabilities and delivery evidence are the
    -- hook's own.  A WeChatPadPro relay lived beside it here until 2026-08-18,
    -- when that project stopped being maintained and the adapter was deleted.
    PlatformWeChatHook
  | PlatformCustom !Text
  deriving stock (Eq, Ord, Show, Generic)

renderPlatform :: Platform -> Text
renderPlatform = \case
  PlatformQQ -> "qq"
  PlatformMatrix -> "matrix"
  PlatformIMessage -> "imessage"
  PlatformWeChatHook -> "wechathook"
  PlatformCustom name -> name

parsePlatform :: Text -> Platform
parsePlatform = \case
  "qq" -> PlatformQQ
  "matrix" -> PlatformMatrix
  "imessage" -> PlatformIMessage
  "wechathook" -> PlatformWeChatHook
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

data ReactionAction = ReactionAdd | ReactionRemove
  deriving stock (Eq, Ord, Show, Generic)

data MessageRelation
  = ReplyTo !NativeEventId
  | Replaces !NativeEventId
  | -- | A redaction/recall of the target.  Distinct from 'Replaces': an
    -- edit supersedes content, a redaction removes it.
    Redacts !NativeEventId
  | ReactsTo !NativeEventId !Text !ReactionAction
  | -- | A fetched forward node contained by another canonical message.
    -- The position is local to the container and preserves wire order.
    ContainedIn !NativeEventId !Int
  deriving stock (Eq, Show, Generic)

-- | Semantic actions advertised to the model.  Content actions are not an
-- endpoint intersection: reply, mention and media may lower to text on weak
-- endpoints.  Only genuinely non-degradable actions stay capability-gated.
data AdvertisedCaps = AdvertisedCaps
  { canReply :: !Bool,
    canMention :: !Bool,
    canMedia :: !Bool,
    canReaction :: !Bool,
    canFace :: !Bool
  }
  deriving stock (Eq, Show, Generic)

noAdvertisedCaps :: AdvertisedCaps
noAdvertisedCaps =
  AdvertisedCaps
    { canReply = False,
      canMention = False,
      canMedia = False,
      canReaction = False,
      canFace = False
    }

qqAdvertisedCaps :: AdvertisedCaps
qqAdvertisedCaps =
  AdvertisedCaps
    { canReply = True,
      canMention = True,
      canMedia = True,
      canReaction = True,
      canFace = True
    }

data DeliveryStatus
  = DeliveryPending
  | DeliverySending
  | DeliveryAcceptedUnconfirmed
  | DeliveryConfirmed
  | DeliveryFailed
  | DeliveryOutcomeUnknown
  | DeliverySuppressed
  deriving stock (Eq, Ord, Show, Generic)
