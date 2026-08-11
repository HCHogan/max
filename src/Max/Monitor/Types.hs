-- | Stable identities for ADR 006 monitors.  Surrogate ids stay inside the
-- host; the model-visible namespace is the conversation-scoped @m#<n>@
-- ordinal and is resolved under a freshly minted ConversationScope.
module Max.Monitor.Types
  ( MonitorId (..),
    MonitorOrdinal (..),
    MonitorRef (..),
    MonitorFireId (..),
    monitorHandleText,
    parseMonitorHandle,
    LedgerMatchSpec (..),
    ledgerMatchSpecValue,
    parseLedgerMatchSpec,
    ledgerSpecMatches,
  )
where

import Data.Aeson (Value, object, withObject, (.:?), (.=))
import Data.Aeson.Types (parseEither)
import Data.Maybe (fromMaybe, isNothing)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import Max.IR (Body (..), MediaKind (..), MediaMeta (..), MentionTarget (..), Node (..), Phase (Canonical))
import Max.Platform.Types (PrincipalId, PrincipalIdentityId)
import Text.Read (readMaybe)

newtype MonitorId = MonitorId {unMonitorId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

newtype MonitorOrdinal = MonitorOrdinal {unMonitorOrdinal :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

data MonitorRef = MonitorRef
  { mrMonitorId :: !MonitorId,
    mrMonitorOrdinal :: !MonitorOrdinal
  }
  deriving stock (Show, Eq, Ord)

newtype MonitorFireId = MonitorFireId {unMonitorFireId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

monitorHandleText :: MonitorOrdinal -> Text
monitorHandleText ordinal = "m#" <> T.pack (show ordinal.unMonitorOrdinal)

-- | Exact handle grammar.  Bare surrogate ids are deliberately not aliases:
-- possession of syntax never substitutes for the conversation scope check.
parseMonitorHandle :: Text -> Maybe MonitorOrdinal
parseMonitorHandle raw = do
  digits <- T.stripPrefix "m#" (T.strip raw)
  value <- readMaybe (T.unpack digits)
  if value > 0 then Just (MonitorOrdinal value) else Nothing

-- | Cheap, typed predicate evaluated against exactly one newly committed
-- canonical inbound row.  Text matching is an Unicode case-folded substring,
-- deliberately not model-authored regex or code.
data LedgerMatchSpec = LedgerMatchSpec
  { lmsSenderPrincipal :: !(Maybe PrincipalId),
    lmsTextContains :: !(Maybe Text),
    lmsMediaKind :: !(Maybe MediaKind),
    lmsMentionSelf :: !Bool
  }
  deriving stock (Show, Eq)

ledgerMatchSpecValue :: LedgerMatchSpec -> Value
ledgerMatchSpecValue spec =
  object
    [ "kind" .= ("LedgerMatch" :: Text),
      "version" .= (1 :: Int),
      "sender_principal" .= spec.lmsSenderPrincipal,
      "text_contains" .= spec.lmsTextContains,
      "media_kind" .= fmap mediaKindText spec.lmsMediaKind,
      "mention_self" .= spec.lmsMentionSelf
    ]

parseLedgerMatchSpec :: Value -> Either Text LedgerMatchSpec
parseLedgerMatchSpec value = case parseEither parser value of
  Left err -> Left (T.pack err)
  Right spec
    | noPredicate spec -> Left "LedgerMatch requires at least one predicate"
    | maybe False (T.null . T.strip) spec.lmsTextContains -> Left "text_contains must not be blank"
    | otherwise -> Right spec
  where
    parser = withObject "LedgerMatch" $ \o -> do
      kind <- o .:? "kind"
      version <- o .:? "version"
      sender <- o .:? "sender_principal"
      contains <- o .:? "text_contains"
      media <- o .:? "media_kind"
      mentionSelf <- o .:? "mention_self"
      case (kind :: Maybe Text, version :: Maybe Int) of
        (Just "LedgerMatch", Just 1) -> pure ()
        _ -> fail "unsupported LedgerMatch kind/version"
      parsedMedia <- traverse parseMediaKind (media :: Maybe Text)
      pure (LedgerMatchSpec sender (T.strip <$> contains) parsedMedia (fromMaybe False mentionSelf))

    parseMediaKind = \case
      "image" -> pure MImage
      "sticker" -> pure MSticker
      "video" -> pure MVideo
      "audio" -> pure MAudio
      "file" -> pure MFile
      _ -> fail "media_kind must be image/sticker/video/audio/file"

    noPredicate spec =
      isNothing spec.lmsSenderPrincipal
        && isNothing spec.lmsTextContains
        && isNothing spec.lmsMediaKind
        && not spec.lmsMentionSelf

ledgerSpecMatches ::
  LedgerMatchSpec ->
  PrincipalId ->
  PrincipalId ->
  Map PrincipalIdentityId PrincipalId ->
  Text ->
  Body 'Canonical ->
  Bool
ledgerSpecMatches spec sender self mentionPrincipals rendered body =
  notSelf && senderMatches && textMatches && mediaMatches && mentionMatches
  where
    -- Max's own utterance is never a world event for Max's own watcher.
    -- The ingest path already excludes outbound and internal rows, but a
    -- self-event that echo reconciliation failed to match arrives as an
    -- ordinary live inbound row — and an elaborated continuation speaks.
    -- Without this the monitor could retrigger on its own reply.
    notSelf = sender /= self
    senderMatches = maybe True (== sender) spec.lmsSenderPrincipal
    textMatches = maybe True (\needle -> T.toCaseFold needle `T.isInfixOf` T.toCaseFold rendered) spec.lmsTextContains
    mediaMatches = maybe True (\kind -> any (hasMedia kind) body.nodes) spec.lmsMediaKind
    mentionMatches = not spec.lmsMentionSelf || any mentionsSelf body.nodes

    hasMedia expected = \case
      NMedia _ meta -> meta.kind == expected
      _ -> False

    mentionsSelf = \case
      NMention MentionAll _ -> True
      NMention (MentionIdentity identity) _ -> Map.lookup identity mentionPrincipals == Just self
      _ -> False

mediaKindText :: MediaKind -> Text
mediaKindText = \case
  MImage -> "image"
  MSticker -> "sticker"
  MVideo -> "video"
  MAudio -> "audio"
  MFile -> "file"
