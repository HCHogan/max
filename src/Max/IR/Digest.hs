-- | The log projection (ADR 003 §5): bounded, pointers not payloads, and
-- the only phase-polymorphic consumer of the IR.
--
-- Ingest logs the 'Canonical' digest, delivery logs the 'Lowered' digest
-- (exactly what went to the wire), ReplySend logs 'ModelParsed'.  Full
-- content always lives in the database; a log line carries shapes, sizes
-- and references — @text(42B)+mention(pid:7)+image(blob:ab12ef34…,182.0KB)@
-- — with stable keys for journalctl grep.
module Max.IR.Digest
  ( LogDecor (..),
    digest,
    digestLine,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Void (Void, absurd)
import Max.IR
import Max.Platform.Types
  ( NativeUserId (..),
    PrincipalId (..),
    PrincipalIdentityId (..),
  )

-- | Compact debug form of one phase-varying decoration.  Instances for
-- foreign types live here with the class, so none are orphans.
class LogDecor x where
  decorDigest :: x -> Text

instance LogDecor NativeUserId where
  decorDigest (NativeUserId native) = "@" <> bounded 16 native

instance LogDecor MentionTarget where
  decorDigest = \case
    MentionIdentity (PrincipalIdentityId pid) -> "pid:" <> T.pack (show pid)
    MentionAll -> "all"

instance LogDecor (Maybe MediaRef) where
  decorDigest = maybe "no-source" refDigest

instance LogDecor ResolvedMedia where
  decorDigest = \case
    ResolvedBytes payload -> "bytes:" <> humanBytes (fromIntegral (BS.length payload))
    ResolvedUrl url -> bounded 24 url

instance LogDecor OutboundMediaRef where
  decorDigest = \case
    RefSticker n -> "sticker#" <> T.pack (show n)
    RefStickerDesc d -> "sticker#" <> bounded 12 d
    RefImage n -> "image#" <> T.pack (show n)

instance LogDecor HydratedMention where
  decorDigest hm = case hm.principal of
    Just (PrincipalId pid) -> "principal:" <> T.pack (show pid)
    Nothing | hm.allMembers -> "all"
    Nothing -> "principal:missing"

instance LogDecor MediaView where
  decorDigest mv = bounded 24 mv.url

instance LogDecor ForwardRef where
  decorDigest fr = bounded 16 fr.nativeId

instance LogDecor HydratedForward where
  decorDigest hf = "children:" <> T.pack (show (length hf.children))

instance LogDecor Unsupported where
  decorDigest u = bounded 24 u.source

instance LogDecor Void where
  decorDigest = absurd

refDigest :: MediaRef -> Text
refDigest ref = case (mediaRefBlobSha ref, mediaRefRemoteUrl ref) of
  (Just sha, _) -> "blob:" <> T.take 8 sha <> "…"
  (_, Just url) -> bounded 24 url
  _ -> "invalid-ref"

-- | Structured log fields for one body, any phase.
digest :: (ForAllX LogDecor p) => Body p -> Value
digest body =
  object
    [ "nodes" .= length body.nodes,
      "text_bytes" .= sum [utf8Length t | NText t <- body.nodes],
      "digest" .= digestLine body
    ]

digestLine :: (ForAllX LogDecor p) => Body p -> Text
digestLine body = truncateText 400 (T.intercalate "+" (map nodeDigest body.nodes))

nodeDigest :: (ForAllX LogDecor p) => Node p -> Text
nodeDigest = \case
  NText t -> "text(" <> T.pack (show (utf8Length t)) <> "B)"
  NMention x _ -> "mention(" <> decorDigest x <> ")"
  NEmote e ->
    "emote(" <> bounded 16 (e.nativeId <> maybe "" (":" <>) e.name) <> ")"
  NMedia x meta ->
    mediaKindText meta.kind
      <> "("
      <> decorDigest x
      <> maybe "" (("," <>) . humanBytes) meta.sizeBytes
      <> ")"
  NCard c -> "card(" <> bounded 24 (fromMaybe "" (orElse c.title c.url)) <> ")"
  NForward x -> "forward(" <> decorDigest x <> ")"
  NUnsupported x -> "unsupported(" <> decorDigest x <> ")"
  where
    orElse a b = a <|> b

utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

bounded :: Int -> Text -> Text
bounded = truncateText
