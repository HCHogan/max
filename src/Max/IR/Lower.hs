-- | Capability-tiered lowering (ADR 003): the single place degradation
-- happens.
--
-- @'lower'@ folds every node the destination endpoint cannot carry
-- natively into the shared text vocabulary ('Max.IR.fallbackText'), so an
-- adapter's transport is emit-only: if a node reaches it, the endpoint
-- declared it native.  Attribution prefixes, reply quoting, media budgets
-- and 'maxTextBytes' chunking are all decided here, once — never in an
-- adapter, and chunking replaces the old permanent-failure on oversized
-- text.
--
-- Capabilities are data with three explicit tiers per content feature.
-- 'TierDrop' is a deliberate, declared choice; a missing or malformed
-- declaration falls back to 'TierText', which is always achievable because
-- every node carries its own fallback.  The atomic cutover migration rewrites
-- old boolean manifests; runtime has exactly this one v2 decoder.
module Max.IR.Lower
  ( Tier (..),
    OutboundCaps (..),
    noOutboundCaps,
    textOnlyCaps,
    outboundCapsFromValue,
    outboundCapsToValue,
    Attribution (..),
    ReplyContext (..),
    LowerEnv (..),
    NoteOutcome (..),
    LowerNote (..),
    LoweredMessage (..),
    lower,
    platformDisplayLabel,
  )
where

import Data.Aeson (ToJSON (..), Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.List (mapAccumL)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.Platform.Types
  ( NativeEventId,
    NativeUserId,
    Platform (..),
    PrincipalIdentityId,
  )

-- | How an endpoint carries one content feature.  Text is always
-- achievable (total fallbacks), so it is the safe default; drop must be
-- declared, never inferred from a missing case branch.
data Tier = TierNative | TierText | TierDrop
  deriving stock (Eq, Ord, Show, Bounded, Enum)

data OutboundCaps = OutboundCaps
  { text :: !Bool,
    mention :: !Tier,
    reply :: !Tier,
    emote :: !Tier,
    image :: !Tier,
    sticker :: !Tier,
    video :: !Tier,
    audio :: !Tier,
    file :: !Tier,
    card :: !Tier,
    reaction :: !Bool,
    edit :: !Bool,
    redact :: !Bool,
    maxTextBytes :: !(Maybe Int),
    maxNativeMedia :: !Int
  }
  deriving stock (Eq, Show)

-- | Fail-closed: cannot deliver anything.  The decode fallback for a
-- malformed manifest, matching the old "manifest is malformed" refusal.
noOutboundCaps :: OutboundCaps
noOutboundCaps = textOnlyCaps {text = False}

-- | An honest minimal endpoint: text out, everything else degraded to
-- text, no meta-actions.
textOnlyCaps :: OutboundCaps
textOnlyCaps =
  OutboundCaps
    { text = True,
      mention = TierText,
      reply = TierText,
      emote = TierText,
      image = TierText,
      sticker = TierText,
      video = TierText,
      audio = TierText,
      file = TierText,
      card = TierText,
      reaction = False,
      edit = False,
      redact = False,
      maxTextBytes = Nothing,
      maxNativeMedia = 1
    }

-- | Total decoder over the endpoint capability manifest.  Missing or unknown
-- content tiers safely become text; meta-actions safely become unavailable.
outboundCapsFromValue :: Value -> OutboundCaps
outboundCapsFromValue = fromMaybe noOutboundCaps . parseMaybe parser
  where
    parser = withObject "outbound capabilities" $ \o -> do
      text <- o .:? "send_text" .!= False
      mention <- tierField o "mention_tier"
      reply <- tierField o "reply_tier"
      emote <- tierField o "emote_tier"
      image <- tierField o "image_tier"
      sticker <- tierField o "sticker_tier"
      video <- tierField o "video_tier"
      audio <- tierField o "audio_tier"
      file <- tierField o "file_tier"
      card <- tierField o "card_tier"
      reaction <- o .:? "reaction" .!= False
      edit <- o .:? "edit" .!= False
      redact <- o .:? "redact" .!= False
      maxTextBytes <- o .:? "max_text_bytes"
      maxNativeMedia <- o .:? "max_native_media" .!= 1
      pure
        OutboundCaps
          { text,
            mention,
            reply,
            emote,
            image,
            sticker,
            video,
            audio,
            file,
            card,
            reaction,
            edit,
            redact,
            maxTextBytes,
            maxNativeMedia
          }
    tierField o key =
      o .:? key >>= \case
        Just (t :: Text) -> pure (tierFromText t)
        Nothing -> pure TierText

tierFromText :: Text -> Tier
tierFromText = \case
  "native" -> TierNative
  "drop" -> TierDrop
  _ -> TierText

tierText :: Tier -> Text
tierText = \case
  TierNative -> "native"
  TierText -> "text"
  TierDrop -> "drop"

-- | Encode the sole runtime manifest vocabulary.
outboundCapsToValue :: OutboundCaps -> Value
outboundCapsToValue caps =
  object $
    [ "send_text" .= caps.text,
      "reaction" .= caps.reaction,
      "edit" .= caps.edit,
      "redact" .= caps.redact,
      "mention_tier" .= tierText caps.mention,
      "reply_tier" .= tierText caps.reply,
      "emote_tier" .= tierText caps.emote,
      "image_tier" .= tierText caps.image,
      "sticker_tier" .= tierText caps.sticker,
      "video_tier" .= tierText caps.video,
      "audio_tier" .= tierText caps.audio,
      "file_tier" .= tierText caps.file,
      "card_tier" .= tierText caps.card,
      "max_native_media" .= caps.maxNativeMedia
    ]
      <> maybe [] (\n -> ["max_text_bytes" .= n]) caps.maxTextBytes

-- | Mirror attribution, applied here and nowhere else.
data Attribution = Attribution
  { platformLabel :: !Text,
    sender :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | Reply context resolved by the caller (claim SQL): the target's native
-- event id on THIS endpoint when a native copy exists, plus quotable
-- fallback facts.
data ReplyContext = ReplyContext
  { nativeId :: !(Maybe NativeEventId),
    author :: !(Maybe Text),
    excerpt :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data LowerEnv = LowerEnv
  { -- | Destination platform; a native emote additionally requires its
    -- origin to match (a QQ face has no Matrix identity).
    platform :: !Platform,
    caps :: !OutboundCaps,
    attribution :: !(Maybe Attribution),
    -- | Pre-resolved against the destination endpoint; pure by design so
    -- 'lower' stays a function.
    mentionNative :: !(PrincipalIdentityId -> Maybe NativeUserId),
    mediaResolve :: !(MediaRef -> Maybe ResolvedMedia),
    replyTarget :: !(Maybe ReplyContext)
  }

data NoteOutcome = NoteFolded | NoteDropped
  deriving stock (Eq, Show)

-- | One degradation/drop record.  Persisted per delivery
-- (@message_deliveries.lower_notes@) and logged; the audit answer to
-- "what did this endpoint's copy lose".
data LowerNote = LowerNote
  { subject :: !Text,
    outcome :: !NoteOutcome,
    detail :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON LowerNote where
  toJSON n =
    object $
      [ "subject" .= n.subject,
        "outcome"
          .= ( case n.outcome of
                 NoteFolded -> "folded" :: Text
                 NoteDropped -> "dropped"
             )
      ]
        <> maybe [] (\d -> ["detail" .= d]) n.detail

-- | Lowering output.  Empty 'chunks' means nothing survived for this
-- endpoint (the delivery should suppress, not send a bare attribution
-- prefix).  'replyNative' applies to the first chunk.
data LoweredMessage = LoweredMessage
  { replyNative :: !(Maybe NativeEventId),
    chunks :: ![[Node 'Lowered]],
    notes :: ![LowerNote]
  }
  deriving stock (Eq, Show)

lower :: LowerEnv -> Body 'Canonical -> LoweredMessage
lower env body =
  let (_, results) = mapAccumL (lowerNode env) 0 body.nodes
      contentNodes = concatMap fst results
      contentNotes = concatMap snd results
      (replyNative, replyNodes, replyNotes) = lowerReply env
      substance = trimEdges (mergeText (replyNodes <> contentNodes))
      (assembled, attributionNotes) = case (env.attribution, substance) of
        (_, []) -> ([], [])
        (Nothing, _) -> (substance, [])
        (Just a, _)
          | canEmitText env.caps -> (mergeText (attributionNode a : substance), [])
          | otherwise -> (substance, [LowerNote "attribution" NoteDropped (Just "endpoint has no text tier")])
      (chunks, chunkNotes) = chunkNodes env.caps.maxTextBytes assembled
   in LoweredMessage
        { replyNative = if null chunks then Nothing else replyNative,
          chunks,
          notes = replyNotes <> contentNotes <> attributionNotes <> chunkNotes
        }

lowerNode :: LowerEnv -> Int -> Node 'Canonical -> (Int, ([Node 'Lowered], [LowerNote]))
lowerNode env mediaUsed = \case
  NText t
    | canEmitText env.caps -> keep (NText t)
    | otherwise -> dropWith (LowerNote "text" NoteDropped (Just "endpoint has no text tier"))
  n@(NMention target display) -> case env.caps.mention of
    TierDrop -> dropWith (LowerNote "mention" NoteDropped (Just display))
    TierText -> fold n (LowerNote "mention" NoteFolded Nothing)
    TierNative -> case target of
      MentionAll -> fold n (LowerNote "mention" NoteFolded (Just "mention-all not native"))
      MentionIdentity pid -> case env.mentionNative pid of
        Just nid -> keep (NMention nid display)
        Nothing -> fold n (LowerNote "mention" NoteFolded (Just "no identity on endpoint"))
  n@(NEmote e) -> case env.caps.emote of
    TierDrop -> dropWith (LowerNote "emote" NoteDropped Nothing)
    TierNative
      | e.origin == env.platform -> keep (NEmote e)
      | otherwise -> fold n (LowerNote "emote" NoteFolded (Just "origin mismatch"))
    TierText -> fold n (LowerNote "emote" NoteFolded Nothing)
  n@(NMedia src meta) ->
    let subject = mediaKindText meta.kind
        foldMedia detail =
          if canEmitText env.caps
            then
              ( mediaUsed,
                ([NText (mediaFoldText src meta)], [LowerNote subject NoteFolded detail])
              )
            else
              ( mediaUsed,
                ([], [LowerNote subject NoteDropped (Just "endpoint has no text tier")])
              )
     in case mediaTier env.caps meta.kind of
          TierDrop -> dropWith (LowerNote subject NoteDropped (Just (fallbackText n)))
          TierText -> foldMedia Nothing
          TierNative -> case src of
            Nothing -> foldMedia (Just "no source")
            Just ref -> case env.mediaResolve ref of
              Nothing -> foldMedia (Just "unresolvable source")
              Just payload
                | mediaUsed >= env.caps.maxNativeMedia -> foldMedia (Just "media budget")
                | otherwise -> (mediaUsed + 1, ([NMedia payload meta], []))
  n@(NCard c) -> case env.caps.card of
    TierDrop -> dropWith (LowerNote "card" NoteDropped (Just (fallbackText n)))
    TierText -> fold n (LowerNote "card" NoteFolded Nothing)
    -- The captured raw protocol value is a card's native payload. A card
    -- created on another edge or internally may retain semantic structure
    -- without one, so fold it here rather than asking an emitter to degrade.
    TierNative
      | isJust c.raw -> keep (NCard c)
      | otherwise -> fold n (LowerNote "card" NoteFolded (Just "no native payload"))
  n@(NForward _) -> fold n (LowerNote "forward" NoteFolded Nothing)
  n@(NUnsupported _) -> fold n (LowerNote "unsupported" NoteFolded Nothing)
  where
    keep node = (mediaUsed, ([node], []))
    fold n note
      | canEmitText env.caps = (mediaUsed, ([NText (fallbackText n)], [note]))
      | otherwise =
          ( mediaUsed,
            ([], [note {outcome = NoteDropped, detail = Just "endpoint has no text tier"}])
          )
    dropWith note = (mediaUsed, ([], [note]))

canEmitText :: OutboundCaps -> Bool
canEmitText caps = caps.text && maybe True (> 0) caps.maxTextBytes

mediaTier :: OutboundCaps -> MediaKind -> Tier
mediaTier caps = \case
  MImage -> caps.image
  MSticker -> caps.sticker
  MVideo -> caps.video
  MAudio -> caps.audio
  MFile -> caps.file

-- | A folded remote attachment keeps its URL — readable AND clickable;
-- blob references are internal and never leak.
-- | What a picture becomes on an endpoint that will not carry it.
--
-- A media node max /generated/ from text — a rendered table or code block —
-- knows the text it was made from and says so in @fold_text@.  Folding that
-- to @[图片: code.png]@ throws the content away at the last step, and it is
-- reachable without any text-only endpoint in the room: matrix, iMessage and
-- the WeChat hook all advertise @max_native_media: 1@, so the second picture
-- in one reply folds even though the first went native.
--
-- Only for nodes that carry the key.  A picture that arrived as a picture has
-- no text form, and inventing one is worse than naming it.
mediaFoldText :: Maybe MediaRef -> MediaMeta -> Text
mediaFoldText src meta = case rawFoldText meta.raw of
  Just text -> text
  Nothing -> fallbackText (NMedia src meta) <> maybe "" (" " <>) (src >>= mediaRefRemoteUrl)

rawFoldText :: Maybe Value -> Maybe Text
rawFoldText raw =
  nonBlank
    =<< (raw >>= parseMaybe (withObject "generated media" (.: "fold_text")))

lowerReply :: LowerEnv -> (Maybe NativeEventId, [Node 'Lowered], [LowerNote])
lowerReply env = case env.replyTarget of
  Nothing -> (Nothing, [], [])
  Just rc -> case env.caps.reply of
    TierDrop -> (Nothing, [], [LowerNote "reply" NoteDropped Nothing])
    TierNative
      | Just nid <- rc.nativeId -> (Just nid, [], [])
      | otherwise -> quoted rc (Just "no native copy on endpoint")
    TierText -> quoted rc Nothing
  where
    quoted rc why
      | not (canEmitText env.caps) =
          (Nothing, [], [LowerNote "reply" NoteDropped (Just "endpoint has no text tier")])
      | otherwise = case quoteText rc of
          Just q -> (Nothing, [NText q], [LowerNote "reply" NoteFolded why])
          Nothing -> (Nothing, [], [LowerNote "reply" NoteDropped (Just "no quotable context")])

quoteText :: ReplyContext -> Maybe Text
quoteText rc = case (blank rc.author, truncateText 60 <$> blank rc.excerpt) of
  (Nothing, Nothing) -> Nothing
  (author, excerpt) ->
    Just ("「" <> T.intercalate ": " (maybe [] pure author <> maybe [] pure excerpt) <> "」\n")
  where
    blank m = do
      t <- m
      let t' = T.strip t
      if T.null t' then Nothing else Just t'

attributionNode :: Attribution -> Node 'Lowered
attributionNode a =
  NText ("[" <> a.platformLabel <> maybe "" (" · " <>) a.sender <> "] ")

-- | Single implementation of the human platform label (previously copied
-- in Delivery, Handler and History).
platformDisplayLabel :: Platform -> Text
platformDisplayLabel = \case
  PlatformQQ -> "QQ"
  PlatformMatrix -> "Matrix"
  PlatformIMessage -> "iMessage"
  -- Both spellings of WeChat read the same to a person, and that is the whole
  -- job of this function.  They are separate platforms because their endpoints,
  -- capabilities and delivery evidence differ — none of which is visible in a
  -- transcript line.
  PlatformWeChatHook -> "WeChat"
  PlatformCustom name -> name

--------------------------------------------------------------------------------
-- Chunking.

-- | Split lowered nodes into chunks whose text cost fits the byte budget.
-- Oversized text nodes split at character boundaries; an indivisible
-- text-bearing node that cannot fit is dropped with an audit note.  Replaces
-- the old behaviour of permanently failing the delivery on
-- @max_text_bytes@.
chunkNodes :: Maybe Int -> [Node 'Lowered] -> ([[Node 'Lowered]], [LowerNote])
chunkNodes Nothing ns = ([ns | not (null ns)], [])
chunkNodes (Just rawLimit) ns0 = go [] 0 ns0
  where
    limit = max 0 rawLimit
    go acc _ [] = ([reverse acc | not (null acc)], [])
    go acc used (n : rest)
      | used + cost n <= limit = go (n : acc) (used + cost n) rest
      | NText t <- n =
          let (pre, post) = splitAtBytes (limit - used) t
           in if T.null pre
                then
                  if null acc
                    then
                      let (chunks, notes) = go [] 0 rest
                       in (chunks, LowerNote "text" NoteDropped (Just "one character exceeds max_text_bytes") : notes)
                    else flush acc (n : rest)
                else
                  let (chunks, notes) = go [] 0 (NText post : rest)
                   in (reverse (NText pre : acc) : chunks, notes)
      | otherwise = flush acc (n : rest)
    flush [] (_ : rest) =
      let (chunks, notes) = go [] 0 rest
       in (chunks, LowerNote "node" NoteDropped (Just "node exceeds max_text_bytes") : notes)
    flush acc rest =
      let (chunks, notes) = go [] 0 rest
       in (reverse acc : chunks, notes)

    cost = \case
      NText t -> utf8Bytes t
      NMention _ display -> utf8Bytes (mentionToken display)
      _ -> 0

splitAtBytes :: Int -> Text -> (Text, Text)
splitAtBytes budget t0 = T.splitAt (fitting 0 0 t0) t0
  where
    fitting !k !b t = case T.uncons t of
      Nothing -> k
      Just (c, rest) ->
        let b' = b + charUtf8Bytes c
         in if b' > budget then k else fitting (k + 1) b' rest

utf8Bytes :: Text -> Int
utf8Bytes = T.foldl' (\acc c -> acc + charUtf8Bytes c) 0

charUtf8Bytes :: Char -> Int
charUtf8Bytes c
  | n < 0x80 = 1
  | n < 0x800 = 2
  | n < 0x10000 = 3
  | otherwise = 4
  where
    n = fromEnum c
