-- | The model-token codec (ADR 003 §4): the LLM prompt is the N+1th
-- platform, and this is its parse direction — model-authored text into
-- @'Body' \''ModelParsed'@ plus the chunk's reply target.
--
-- The token vocabulary (@[\@#qq]@, @[↩#id]@, @[sticker#id]@, @[image#id]@,
-- @[face#id]@) is the existing model contract and does not change; this
-- module deliberately reuses the battle-tested grammar in
-- 'Max.Reply.parseReplyTokens' (legacy @[表情包#]@ opener, display-form
-- tails, attribute-group swallowing) and
-- 'OneBot.Segment.segmentMentions'/'rescueNameMentions' rather than
-- re-deriving it.  What is new is only the output shape: IR nodes instead
-- of OneBot segments.
--
-- Parsing normalises: adjacent text runs merge, edges trim (the seam left
-- by a stripped reply token), and exactly one space follows a converted
-- mention.  'emitModelChunk' is the inverse on that normal form —
-- @parse . emit ≡ id@ on parser output, which is the round-trip the
-- persisted-history contract needs.
module Max.IR.Prompt
  ( MentionRoster (..),
    parseModelChunk,
    emitModelChunk,
    promptText,
    promptCanonicalText,
  )
where

import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseMaybe)
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Max.IR
import Max.Platform.Types (NativeUserId (..), Platform (..), PrincipalIdentityId)
import Max.Reply (ReplyPiece (..), parseReplyTokens)
import OneBot.Segment (Segment (..), renderPlainText, rescueNameMentions, segmentMentions)
import OneBot.Types (UserId (..))

-- | Who may be mentioned.  'known' gates id conversion (hallucinated
-- numbers stay literal text); 'names' feeds the display-name rescue for
-- models that @-by-name instead of by token.
data MentionRoster = MentionRoster
  { known :: !(NativeUserId -> Bool),
    names :: ![(Text, NativeUserId)]
  }

parseModelChunk :: MentionRoster -> Text -> (Maybe Int64, Body 'ModelParsed)
parseModelChunk roster t0 =
  let rescued = rescueNameMentions legacyNames t0
      (replyTarget, pieces) = parseReplyTokens rescued
      body = trimEdges (mergeText (concatMap pieceNodes pieces))
   in (replyTarget, Body body)
  where
    legacyNames =
      [ (label, UserId uid)
      | (label, native) <- roster.names,
        Just uid <- [nativeNumericId native]
      ]
    knownLegacy (UserId uid) = roster.known (NativeUserId (T.pack (show uid)))
    pieceNodes = \case
      PieceText s -> mentionNodes s
      PieceSticker n -> [NMedia (RefSticker n) (mediaRefMeta MSticker Nothing)]
      PieceStickerDesc d -> [NMedia (RefStickerDesc d) (mediaRefMeta MSticker (Just d))]
      PieceImage n -> [NMedia (RefImage n) (mediaRefMeta MImage Nothing)]
      PieceFace n ->
        [ NEmote
            Emote
              { origin = PlatformQQ,
                nativeId = T.pack (show n),
                name = Nothing,
                raw = Nothing
              }
        ]
    segNode = \case
      SegText s -> NText s
      SegAt (UserId uid) ->
        let digits = T.pack (show uid)
            native = NativeUserId digits
            display = fromMaybe digits (lookup native [(member, label) | (label, member) <- roster.names])
         in NMention native display
      -- 'segmentMentions' only produces text and at segments; anything
      -- else would be a contract change upstream — degrade it readably.
      other -> NText (renderPlainText [other])

    -- The historical display form [@#id: name] predates the compact prompt
    -- emitter.  OneBot's parser intentionally ignores that suffix, so retain
    -- it here before delegating ordinary/bare mentions to the proven parser.
    mentionNodes input = case T.breakOn "[@#" input of
      (before, rest)
        | T.null rest -> map segNode (segmentMentions knownLegacy before)
        | Just (native, display, after) <- displayMention rest,
          roster.known native ->
            map segNode (segmentMentions knownLegacy before)
              <> (NMention native display : mentionTail after)
        | otherwise ->
            map segNode (segmentMentions knownLegacy (before <> "["))
              <> mentionNodes (T.drop 1 rest)

    displayMention token = do
      afterOpen <- T.stripPrefix "[@#" token
      let (digits, suffix) = T.span isDigit afterOpen
      if T.null digits then Nothing else do
        let native = NativeUserId digits
            rosterDisplay = fromMaybe digits (lookup native [(member, label) | (label, member) <- roster.names])
        case T.uncons suffix of
          Just (']', after) -> Just (native, rosterDisplay, after)
          Just (':', captionAndClose) ->
            let (caption, close) = T.breakOn "]" captionAndClose
             in if T.null close
                  then Nothing
                  else Just (native, fromMaybe rosterDisplay (nonBlank caption), T.drop 1 close)
          _ -> Nothing

    mentionTail after =
      let remaining = fromMaybe after (T.stripPrefix " " after)
       in case mentionNodes remaining of
            [] -> []
            NText text : nodes -> NText (" " <> text) : nodes
            nodes -> NText " " : nodes

    nonBlank value =
      let stripped = T.strip value
       in if T.null stripped then Nothing else Just stripped

mediaRefMeta :: MediaKind -> Maybe Text -> MediaMeta
mediaRefMeta kind description =
  MediaMeta
    { kind,
      mime = Nothing,
      sizeBytes = Nothing,
      name = Nothing,
      description,
      raw = Nothing
    }

nativeNumericId :: NativeUserId -> Maybe Int64
nativeNumericId (NativeUserId t) = case TR.signed TR.decimal t of
  Right (n, "") -> Just n
  _ -> Nothing

-- | The transcript/prompt projection of an ingest body — the text stored
-- as @rendered_text@ and read by prompts, history, search and embeddings.
--
-- The vocabulary deliberately reproduces 'OneBot.Segment.renderPlainText'
-- token for token (@[\@#qq] @, @[face#5: 惊讶]@, @[image]@, @[sticker]@,
-- @[file:name]@, @[video]@, @[card: …]@, @[forward]@): persisted history
-- and the model's learned round-trip contract must not notice the switch
-- from segment-derived to IR-derived rendering.  QQ ingest parity is
-- pinned by golden tests against 'renderPlainText'.
promptText :: Platform -> Body 'Ingest -> Text
promptText originPlatform = renderPromptBody (ingestMention originPlatform)

-- | Render stored IR directly for the model/runtime consumer. Mention
-- identities are resolved for the origin endpoint by the dispatch claim;
-- this deliberately shares the ingest projection codec.
promptCanonicalText :: Platform -> Map PrincipalIdentityId NativeUserId -> Body 'Canonical -> Text
promptCanonicalText originPlatform identities =
  renderPromptBody (canonicalMention originPlatform identities)

ingestMention :: Platform -> NativeUserId -> Text -> Text
ingestMention originPlatform (NativeUserId native) display
  | originPlatform == PlatformQQ,
    not (T.null native),
    T.all isDigit native =
      "[@#" <> native <> "] "
  | otherwise = "@" <> display

canonicalMention :: Platform -> Map PrincipalIdentityId NativeUserId -> MentionTarget -> Text -> Text
canonicalMention originPlatform identities target display = case target of
  MentionAll -> "@" <> display
  MentionIdentity identity -> case Map.lookup identity identities of
    Just native -> ingestMention originPlatform native display
    Nothing -> "@" <> display

renderPromptBody ::
  (XUnsupported p ~ Unsupported) =>
  (XMention p -> Text -> Text) ->
  Body p ->
  Text
renderPromptBody mentionToken body = T.concat (map node body.nodes)
  where
    node = \case
      NText t -> t
      NMention target display -> mentionToken target display
      NEmote e
        | Just sid <- rawId "sticker_id" e.raw ->
            "[sticker#" <> T.pack (show sid) <> maybe "" (": " <>) e.name <> "]"
        | e.origin == PlatformQQ ->
            "[face#" <> e.nativeId <> maybe "" (": " <>) e.name <> "]"
        | otherwise -> fallbackText (NEmote e :: Node 'Canonical)
      NMedia _ meta -> fromMaybe (mediaToken meta) (rawText "prompt_text" meta.raw)
      NCard c ->
        let parts =
              dedupAdjacent . catMaybes $
                [c.tag, c.title, T.take 80 <$> c.subtitle, c.url]
         in "[card: " <> T.intercalate " | " parts <> "]"
      NForward _ -> "[forward]"
      NUnsupported u -> "[" <> u.description <> "]"
    dedupAdjacent (a : b : rest)
      | a == b = dedupAdjacent (a : rest)
      | otherwise = a : dedupAdjacent (b : rest)
    dedupAdjacent xs = xs
    handle kind ident = "[" <> kind <> "#" <> T.pack (show ident) <> "]"
    mediaToken meta = case meta.kind of
      MImage -> maybe "[image]" (handle "image") (rawId "source_message_id" meta.raw)
      MSticker ->
        maybe "[sticker]"
          (\sid -> "[sticker#" <> T.pack (show sid) <> maybe "" (": " <>) meta.description <> "]")
          (rawId "sticker_id" meta.raw)
      MVideo -> "[video]"
      MAudio -> "[audio]"
      MFile -> "[file:" <> fromMaybe "" meta.name <> "]"

rawId :: Text -> Maybe Value -> Maybe Int64
rawId key raw = raw >>= parseMaybe (withObject "media prompt metadata" (.: Key.fromText key))

rawText :: Text -> Maybe Value -> Maybe Text
rawText key raw = raw >>= parseMaybe (withObject "media prompt metadata" (.: Key.fromText key))

-- | Inverse of 'parseModelChunk' on its normal form.  The reply token
-- leads the chunk; a converted mention carries no trailing space of its
-- own (the following text node holds it, exactly as parsing leaves it).
emitModelChunk :: Maybe Int64 -> Body 'ModelParsed -> Text
emitModelChunk replyTarget body =
  maybe "" (\rid -> "[↩#" <> T.pack (show rid) <> "] ") replyTarget
    <> T.concat (map nodeToken body.nodes)
  where
    nodeToken = \case
      NText t -> t
      NMention (NativeUserId native) _ -> "[@#" <> native <> "]"
      NEmote e -> "[face#" <> e.nativeId <> "]"
      NMedia ref _ -> case ref of
        RefSticker n -> "[sticker#" <> T.pack (show n) <> "]"
        RefStickerDesc d -> "[sticker#" <> d <> "]"
        RefImage n -> "[image#" <> T.pack (show n) <> "]"
      -- The model never authors cards; total anyway via the shared
      -- vocabulary.  NForward/NUnsupported are uninhabited in this phase
      -- and GHC's coverage checker already knows it.
      NCard c -> fallbackText (NCard c :: Node 'Canonical)
