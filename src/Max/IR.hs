{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | The canonical message IR (ADR 003).
--
-- One closed, phase-indexed tree expresses every conversation's content.
-- The shape is identical across phases; only the decorations at four slots
-- change, and two constructors are uninhabited outside 'Canonical'.  The
-- tree is deliberately closed: platform-private content is a value-level
-- 'NUnsupported' with a mandatory human-readable description, never a
-- type-level extension — that is what keeps 'fallbackText' total and the
-- stored format a single versioned schema.
--
-- Phase transitions are the pipeline: model output parses to 'ModelParsed'
-- and resolves to 'Canonical' (ReplySend); 'Max.IR.Lower' degrades
-- 'Canonical' per endpoint capability; the admin surface hydrates it.
-- Only @'Body' \''Canonical'@ has JSON instances — the stored codec is
-- pinned to exactly one phase, encoded as @{"v":2,"nodes":[...]}@.
module Max.IR
  ( -- * The tree
    Phase (..),
    Body (..),
    Node (..),
    XMention,
    XMedia,
    XForward,
    XUnsupported,
    ForAllX,

    -- * Universal payloads
    MentionTarget (..),
    Emote (..),
    MediaKind (..),
    mediaKindText,
    MediaMeta (..),
    Card (..),
    ForwardRef (..),
    Unsupported (..),

    -- * Phase-specific decorations
    MediaRef,
    mediaBlobRef,
    mediaRemoteRef,
    mediaRefBlobSha,
    mediaRefRemoteUrl,
    renderMediaRef,
    parseMediaRef,
    ResolvedMedia (..),
    OutboundMediaRef (..),
    HydratedMention (..),
    MediaView (..),
    HydratedForward (..),

    -- * The one degradation vocabulary
    fallbackText,
    plainText,
    humanBytes,
    truncateText,
    nonBlank,
    mentionToken,

    -- * Node-list utilities
    mentionIdentities,
    mergeText,
    trimEdges,
    resolveIngest,
  )
where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Kind (Constraint, Type)
import Data.List (unsnoc)
import Control.Applicative ((<|>))
import Data.Char (isDigit)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Max.Platform.Types
  ( CanonicalMessageId,
    NativeUserId (..),
    Platform (..),
    PrincipalId,
    PrincipalIdentityId,
    parsePlatform,
    renderPlatform,
  )
import Text.Printf (printf)

-- | Pipeline phases.  'Canonical' is the only stored phase; the others are
-- in-memory shapes on either side of it.  'Ingest' is what an adapter can
-- build without database access: identical to 'Canonical' except mentions
-- still carry the origin-native user id — 'ingestEnvelope' resolves them
-- to principal identities inside the ingest transaction.
data Phase = ModelParsed | Ingest | Canonical | Lowered | Hydrated

data Body (p :: Phase) = Body {nodes :: ![Node p]}

-- | One inline node.  Universal fields (the mention display, 'MediaMeta',
-- 'Emote', 'Card') carry the captured textual fallback, so degradation
-- never needs a lookup; the @X*@ slots hold what genuinely varies by phase.
data Node (p :: Phase)
  = NText !Text
  | -- | Target + display name captured at origin.  The display is the
    -- text tier; it must never be blank for a real mention.
    NMention !(XMention p) !Text
  | NEmote !Emote
  | NMedia !(XMedia p) !MediaMeta
  | NCard !Card
  | NForward !(XForward p)
  | NUnsupported !(XUnsupported p)

type family XMention (p :: Phase) where
  -- | ADR 004: the model addresses /people/.  A @[\@#123]@ token names a
  -- principal; resolving it to the account that will carry the mention is
  -- the send path's job, and an unknown principal simply does not resolve.
  XMention 'ModelParsed = PrincipalId
  XMention 'Ingest = NativeUserId -- origin-native, pre-identity
  XMention 'Canonical = MentionTarget
  XMention 'Lowered = NativeUserId -- DESTINATION endpoint's native id
  XMention 'Hydrated = HydratedMention

type family XMedia (p :: Phase) where
  XMedia 'ModelParsed = OutboundMediaRef -- [sticker#42] / [image#7.0] reference
  XMedia 'Ingest = Maybe MediaRef
  XMedia 'Canonical = Maybe MediaRef -- never inline bytes at rest
  XMedia 'Lowered = ResolvedMedia -- sendable payload, NOT Maybe
  XMedia 'Hydrated = MediaView

type family XForward (p :: Phase) where
  XForward 'Ingest = ForwardRef
  XForward 'Canonical = ForwardRef
  XForward 'Hydrated = HydratedForward
  XForward _ = Void -- model can't author; lowering folds

type family XUnsupported (p :: Phase) where
  XUnsupported 'Ingest = Unsupported
  XUnsupported 'Canonical = Unsupported
  XUnsupported 'Hydrated = Unsupported
  XUnsupported _ = Void -- can never reach a wire

-- | Lift a constraint over every phase-varying slot; the price of the
-- family-indexed tree is paid once here instead of at each instance.
type ForAllX :: (Type -> Constraint) -> Phase -> Constraint
type ForAllX c p =
  (c (XMention p), c (XMedia p), c (XForward p), c (XUnsupported p))

deriving stock instance (ForAllX Eq p) => Eq (Node p)

deriving stock instance (ForAllX Show p) => Show (Node p)

deriving stock instance (ForAllX Eq p) => Eq (Body p)

deriving stock instance (ForAllX Show p) => Show (Body p)

data MentionTarget
  = -- | Resolves to a principal AND its origin native id; whether the
    -- principal has an identity on a destination endpoint decides
    -- native-vs-text lowering there.
    MentionIdentity !PrincipalIdentityId
  | MentionAll
  deriving stock (Eq, Show)

-- | A platform face/emote.  Native only when re-sent to its own platform;
-- 'raw' preserves the origin payload for that round trip.
data Emote = Emote
  { origin :: !Platform,
    nativeId :: !Text,
    name :: !(Maybe Text),
    raw :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

data MediaKind = MImage | MSticker | MVideo | MAudio | MFile
  deriving stock (Eq, Show, Bounded, Enum)

-- | Media facts that survive every phase.  'description' is the captured
-- human caption/summary; blank is treated as absent everywhere (a NapCat
-- @summary: ""@ must never become an empty transcript line again).
data MediaMeta = MediaMeta
  { kind :: !MediaKind,
    mime :: !(Maybe Text),
    sizeBytes :: !(Maybe Int64),
    name :: !(Maybe Text),
    description :: !(Maybe Text),
    raw :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- | Where stored media lives.  Rendered as @blob:\<sha256\>@ or the remote
-- URL in the stored form.
data MediaRef = MediaBlob !Text | MediaRemote !Text
  deriving stock (Eq, Show)

-- | Construct a content-addressed reference.  Canonical blob ids are always
-- lowercase SHA-256 hex; keeping the constructor private prevents arbitrary
-- paths or disguised inline payloads from entering the stored phase.
mediaBlobRef :: Text -> Maybe MediaRef
mediaBlobRef sha
  | T.length sha == 64 && T.all isLowerHex sha = Just (MediaBlob sha)
  | otherwise = Nothing
  where
    isLowerHex c = isDigit c || ('a' <= c && c <= 'f')

-- | Construct a bounded-fetch or platform-authenticated remote reference.
-- Inline/data/file schemes are deliberately rejected: those payloads must be
-- imported into BlobStore before the body can become canonical.
mediaRemoteRef :: Text -> Maybe MediaRef
mediaRemoteRef url
  | any (`T.isPrefixOf` T.toLower url) ["https://", "http://", "mxc://"] =
      Just (MediaRemote url)
  | otherwise = Nothing

mediaRefBlobSha :: MediaRef -> Maybe Text
mediaRefBlobSha = \case
  MediaBlob sha -> Just sha
  MediaRemote _ -> Nothing

mediaRefRemoteUrl :: MediaRef -> Maybe Text
mediaRefRemoteUrl = \case
  MediaBlob _ -> Nothing
  MediaRemote url -> Just url

renderMediaRef :: MediaRef -> Text
renderMediaRef = \case
  MediaBlob sha -> "blob:" <> sha
  MediaRemote url -> url

parseMediaRef :: Text -> Maybe MediaRef
parseMediaRef t = case T.stripPrefix "blob:" t of
  Just sha -> mediaBlobRef sha
  Nothing -> mediaRemoteRef t

-- | A payload an adapter can actually send: bytes already loaded, or a URL
-- the adapter may fetch through its own bounded runtime.
data ResolvedMedia
  = ResolvedBytes !ByteString
  | ResolvedUrl !Text
  deriving stock (Eq, Show)

-- | Model-authored media references, mirroring the reply-token grammar.
--
-- 'RefImage' carries a canonical message id and, when the model addressed
-- one picture rather than the message, its @seg_index@ — together the
-- primary key of @message_images@ (ADR 004).  'Nothing' means every image
-- on that message, which is what a bare @[image#\<id\>]@ has always meant.
--
-- Sticker ids are a different namespace entirely: @stickers.id@ names a
-- library entry, not a message, so it stays a bare 'Int64'.
data OutboundMediaRef
  = RefSticker !Int64
  | RefStickerDesc !Text
  | RefImage !CanonicalMessageId !(Maybe Int)
  deriving stock (Eq, Show)

data HydratedMention = HydratedMention
  { principal :: !(Maybe PrincipalId),
    displayName :: !(Maybe Text),
    identities :: ![(Platform, NativeUserId)],
    allMembers :: !Bool
  }
  deriving stock (Eq, Show)

data MediaView = MediaView
  { url :: !Text,
    thumbnail :: !(Maybe Text),
    ref :: !(Maybe MediaRef)
  }
  deriving stock (Eq, Show)

newtype HydratedForward = HydratedForward {children :: [CanonicalMessageId]}
  deriving stock (Eq, Show)

-- | A structured share card.  Portable fields render everywhere; 'raw'
-- keeps the origin payload (QQ lightapp JSON) for a native round trip.
data Card = Card
  { title :: !(Maybe Text),
    subtitle :: !(Maybe Text),
    url :: !(Maybe Text),
    tag :: !(Maybe Text),
    preview :: !(Maybe MediaRef),
    raw :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

-- | A merged-forward container.  Children are canonical messages linked
-- via a @contained_in@ relation; the node itself is only the marker.
data ForwardRef = ForwardRef
  { nativeId :: !Text,
    count :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

data Unsupported = Unsupported
  { source :: !Text,
    -- | REQUIRED human-readable fallback, e.g. @语音消息@.
    description :: !Text,
    raw :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- Degradation vocabulary.

-- | The single place a node becomes human-readable text.  Total by
-- construction: every constructor either is text or carries its captured
-- fallback.  Everything that folds a node to text — lowering, the plain
-- projection, mirrors — must come through here.
fallbackText :: Node 'Canonical -> Text
fallbackText = \case
  NText t -> t
  NMention _ display -> mentionToken display
  NEmote e -> case nonBlank =<< e.name of
    Just n -> "[表情: " <> n <> "]"
    Nothing -> "[表情]"
  NMedia _ meta -> mediaFallback meta
  NCard c -> cardFallback c
  NForward fr -> case fr.count of
    Just n -> "[聊天记录: " <> T.pack (show n) <> "条]"
    Nothing -> "[聊天记录]"
  NUnsupported u -> case nonBlank u.description of
    Just d -> "[" <> d <> "]"
    Nothing -> "[" <> u.source <> "]"

mediaFallback :: MediaMeta -> Text
mediaFallback meta = "[" <> label <> maybe "" (": " <>) detail <> "]"
  where
    label = case meta.kind of
      MImage -> "图片"
      MSticker -> "表情包"
      MVideo -> "视频"
      MAudio -> "语音"
      MFile -> "文件"
    detail = case meta.kind of
      MFile ->
        case (nonBlank =<< meta.name, meta.sizeBytes) of
          (Just n, Just s) -> Just (n <> " (" <> humanBytes s <> ")")
          (Just n, Nothing) -> Just n
          (Nothing, _) -> nonBlank =<< meta.description
      _ -> firstNonBlank [meta.description, meta.name]
    firstNonBlank = foldr (\m acc -> (nonBlank =<< m) <|> acc) Nothing

cardFallback :: Card -> Text
cardFallback c = case parts of
  [] -> "[分享]"
  ps -> "[分享: " <> T.intercalate " | " ps <> "]"
  where
    parts =
      dedupAdjacent . catMaybes $
        [ nonBlank =<< c.tag,
          nonBlank =<< c.title,
          fmap (truncateText 80) (nonBlank =<< c.subtitle),
          nonBlank =<< c.url
        ]
    dedupAdjacent (a : b : rest)
      | a == b = dedupAdjacent (a : rest)
      | otherwise = a : dedupAdjacent (b : rest)
    dedupAdjacent xs = xs

-- | The plain projection: prompt/search-audience text.  Straight
-- concatenation — spacing is captured at ingest, never invented here.
plainText :: Body 'Canonical -> Text
plainText body = T.concat (map fallbackText body.nodes)

-- | The visible @-form of a mention display.  Matrix ids already start with
-- '@' and a second one is not a nicer way to say the same thing.
mentionToken :: Text -> Text
mentionToken display
  | "@" `T.isPrefixOf` display = display
  | otherwise = "@" <> display

nonBlank :: Text -> Maybe Text
nonBlank t =
  let t' = T.strip t
   in if T.null t' then Nothing else Just t'

humanBytes :: Int64 -> Text
humanBytes n
  | n < 1024 = T.pack (show n) <> "B"
  | n < 1024 * 1024 = fmt (fromIntegral n / 1024) "KB"
  | n < 1024 * 1024 * 1024 = fmt (fromIntegral n / (1024 * 1024)) "MB"
  | otherwise = fmt (fromIntegral n / (1024 * 1024 * 1024)) "GB"
  where
    fmt :: Double -> Text -> Text
    fmt v u = T.pack (printf "%.1f" v) <> u

truncateText :: Int -> Text -> Text
truncateText limit t
  | T.length t <= limit = t
  | otherwise = T.take (max 0 (limit - 1)) t <> "…"

--------------------------------------------------------------------------------
-- Node-list utilities (phase-polymorphic: they only touch 'NText').

-- | Every principal identity a stored body mentions, in node order.  The
-- one place that answers "who does this message address", shared by
-- delivery (identity -> native id on the destination) and by every
-- model-facing projection (identity -> principal).
mentionIdentities :: Body 'Canonical -> [PrincipalIdentityId]
mentionIdentities body = [identity | NMention (MentionIdentity identity) _ <- body.nodes]

-- | Merge adjacent text runs, dropping empty ones.
mergeText :: [Node p] -> [Node p]
mergeText = \case
  (NText a : NText b : rest) -> mergeText (NText (a <> b) : rest)
  (NText a : rest) | T.null a -> mergeText rest
  (n : rest) -> n : mergeText rest
  [] -> []

-- | Resolve an adapter-built body into the stored phase.  The callback
-- turns an origin-native mention (id plus captured display) into its
-- principal identity and the display to persist; every other node converts
-- unchanged.  Effectful only through the callback, so the ingest
-- transaction owns all database work.
resolveIngest ::
  (Applicative f) =>
  (NativeUserId -> Text -> f (MentionTarget, Text)) ->
  Body 'Ingest ->
  f (Body 'Canonical)
resolveIngest resolve body = Body <$> traverse go body.nodes
  where
    go = \case
      NText t -> pure (NText t)
      NMention native display -> uncurry NMention <$> resolve native display
      NEmote e -> pure (NEmote e)
      NMedia src meta -> pure (NMedia src meta)
      NCard c -> pure (NCard c)
      NForward fr -> pure (NForward fr)
      NUnsupported u -> pure (NUnsupported u)

-- | Trim whitespace at the outer edges of a node list; an edge text node
-- that was nothing but whitespace disappears entirely.
trimEdges :: [Node p] -> [Node p]
trimEdges ns =
  let start = case ns of
        (NText x : rest) ->
          let x' = T.stripStart x
           in if T.null x' then rest else NText x' : rest
        _ -> ns
   in case unsnoc start of
        Just (rest, NText x) ->
          let x' = T.stripEnd x
           in if T.null x' then rest else rest <> [NText x']
        _ -> start

--------------------------------------------------------------------------------
-- Stored codec: pinned to the 'Canonical' phase, versioned.

canonicalVersion :: Int
canonicalVersion = 2

instance ToJSON (Body 'Canonical) where
  toJSON body =
    object ["v" .= canonicalVersion, "nodes" .= map nodeValue body.nodes]

instance FromJSON (Body 'Canonical) where
  parseJSON = withObject "Body" $ \o -> do
    v <- o .: "v" :: Parser Int
    if v /= canonicalVersion
      then fail ("unsupported canonical content version " <> show v)
      else Body <$> (traverse parseNode =<< o .: "nodes")

nodeValue :: Node 'Canonical -> Value
nodeValue = \case
  NText t -> node "text" ["text" .= t]
  NMention target display ->
    node "mention" $
      ("display" .= display)
        : case target of
          MentionIdentity pid -> ["identity" .= pid]
          MentionAll -> ["all" .= True]
  NEmote e ->
    node "emote" $
      [ "platform" .= renderPlatform e.origin,
        "native_id" .= e.nativeId
      ]
        <> opt "name" e.name
        <> opt "raw" e.raw
  NMedia src meta ->
    node "media" $
      ["kind" .= mediaKindText meta.kind]
        <> opt "source" (renderMediaRef <$> src)
        <> opt "mime" meta.mime
        <> opt "size" meta.sizeBytes
        <> opt "name" meta.name
        <> opt "description" meta.description
        <> opt "raw" meta.raw
  NCard c ->
    node "card" $
      opt "title" c.title
        <> opt "subtitle" c.subtitle
        <> opt "url" c.url
        <> opt "tag" c.tag
        <> opt "preview" (renderMediaRef <$> c.preview)
        <> opt "raw" c.raw
  NForward fr ->
    node "forward" (("native_id" .= fr.nativeId) : opt "count" fr.count)
  NUnsupported u ->
    node "unsupported" $
      ["source" .= u.source, "description" .= u.description] <> opt "raw" u.raw
  where
    node :: Text -> [Pair] -> Value
    node ty fields = object (("type" .= ty) : fields)
    opt :: (ToJSON a) => Key -> Maybe a -> [Pair]
    opt k = maybe [] (\v -> [k .= v])

parseNode :: Value -> Parser (Node 'Canonical)
parseNode = withObject "Node" $ \o -> do
  ty <- o .: "type" :: Parser Text
  case ty of
    "text" -> NText <$> o .: "text"
    "mention" -> do
      display <- o .: "display"
      mIdentity <- o .:? "identity"
      target <- case mIdentity of
        Just pid -> pure (MentionIdentity pid)
        Nothing ->
          o .:? "all" >>= \case
            Just True -> pure MentionAll
            _ -> fail "mention needs identity or all"
      pure (NMention target display)
    "emote" -> do
      platform <- parsePlatform <$> o .: "platform"
      nativeId <- o .: "native_id"
      name <- o .:? "name"
      raw <- o .:? "raw"
      pure (NEmote Emote {origin = platform, nativeId, name, raw})
    "media" -> do
      kind <- parseMediaKind =<< o .: "kind"
      sourceText <- o .:? "source"
      source <- traverse parseStoredMediaRef sourceText
      mime <- o .:? "mime"
      sizeBytes <- o .:? "size"
      name <- o .:? "name"
      description <- o .:? "description"
      raw <- o .:? "raw"
      pure (NMedia source MediaMeta {kind, mime, sizeBytes, name, description, raw})
    "card" -> do
      title <- o .:? "title"
      subtitle <- o .:? "subtitle"
      url <- o .:? "url"
      tag <- o .:? "tag"
      previewText <- o .:? "preview"
      preview <- traverse parseStoredMediaRef previewText
      raw <- o .:? "raw"
      pure (NCard Card {title, subtitle, url, tag, preview, raw})
    "forward" -> do
      nativeId <- o .: "native_id"
      count <- o .:? "count"
      pure (NForward ForwardRef {nativeId, count})
    "unsupported" -> do
      source <- o .: "source"
      description <- o .: "description"
      raw <- o .:? "raw"
      pure (NUnsupported Unsupported {source, description, raw})
    other -> fail ("unknown canonical node type " <> T.unpack other)

parseStoredMediaRef :: Text -> Parser MediaRef
parseStoredMediaRef value =
  maybe (fail ("invalid canonical media reference " <> T.unpack value)) pure (parseMediaRef value)

mediaKindText :: MediaKind -> Text
mediaKindText = \case
  MImage -> "image"
  MSticker -> "sticker"
  MVideo -> "video"
  MAudio -> "audio"
  MFile -> "file"

parseMediaKind :: Text -> Parser MediaKind
parseMediaKind = \case
  "image" -> pure MImage
  "sticker" -> pure MSticker
  "video" -> pure MVideo
  "audio" -> pure MAudio
  "file" -> pure MFile
  other -> fail ("unknown media kind " <> T.unpack other)
