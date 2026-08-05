-- | The model-token codec (ADR 003 §4): the LLM prompt is the N+1th
-- platform, and this is its parse direction — model-authored text into
-- @'Body' \''ModelParsed'@ plus the chunk's reply target.
--
-- ADR 004 fixed the vocabulary this module speaks.  Every handle names a
-- canonical key verbatim, with no mapping table on either side:
--
--   * @[\@#\<principal_id\>]@ — a person, not an account.  Which account
--     carries the mention is the send path's problem.
--   * @[↩#\<canonical_message_id\>]@ — a quote.
--   * @[image#\<canonical_message_id\>(.\<seg\>)?]@ — a message's images,
--     or one of them; @(canonical_message_id, seg_index)@ is the primary
--     key of @message_images@.
--   * @[sticker#\<stickers.id\>]@, @[face#\<qq face id\>]@ — different
--     namespaces, unchanged: neither names a message or a person.
--
-- Before ADR 004 this module borrowed 'OneBot.Segment.segmentMentions',
-- whose bare @\@\<5-11 digits\>@ form is QQ's wire spelling of a mention.
-- Principal ids are not QQ numbers, so that form is gone and the mention
-- grammar lives here, platform-neutral like everything else the model
-- reads.  The reply/sticker/image token grammar still comes from
-- 'Max.Reply.parseReplyTokens' — that one was never platform-shaped.
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
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.Platform.Types
  ( CanonicalMessageId (..),
    Platform (..),
    PrincipalId (..),
    PrincipalIdentityId,
  )
import Max.Reply (ReplyPiece (..), parseReplyTokens)
import Max.Util (readIntegral, tshow)

-- | Display-name → principal, for the rescue pass that turns @\@显示名@
-- into the canonical token.  Small models @ people by name instead of by
-- id, and that would otherwise send as dead text.
--
-- There is no membership predicate any more: a principal the model made up
-- simply fails to resolve to an account at send time and the mention folds
-- back to @\@name@ text, which is the same answer the old whitelist gave
-- and one fewer thing to keep in sync with the platform.
newtype MentionRoster = MentionRoster
  { names :: [(Text, PrincipalId)]
  }

parseModelChunk :: MentionRoster -> Text -> (Maybe Int64, Body 'ModelParsed)
parseModelChunk roster t0 =
  let rescued = rescueNameMentions roster.names t0
      (replyTarget, pieces) = parseReplyTokens rescued
      body = trimEdges (mergeText (concatMap pieceNodes pieces))
   in (replyTarget, Body body)
  where
    pieceNodes = \case
      PieceText s -> mentionNodes s
      PieceSticker n -> [NMedia (RefSticker n) (mediaRefMeta MSticker Nothing)]
      PieceStickerDesc d -> [NMedia (RefStickerDesc d) (mediaRefMeta MSticker (Just d))]
      PieceImage n seg ->
        [NMedia (RefImage (CanonicalMessageId n) seg) (mediaRefMeta MImage Nothing)]
      PieceFace n ->
        [ NEmote
            Emote
              { origin = PlatformQQ,
                nativeId = tshow n,
                name = Nothing,
                raw = Nothing
              }
        ]

    -- The display form [@#id: name] predates the compact prompt emitter and
    -- is still what a model echoing an old line writes; the caption is
    -- accepted and used as the display.
    mentionNodes input = case T.breakOn "[@#" input of
      (before, rest)
        | T.null rest -> [NText before | not (T.null before)]
        | Just (principal, display, after) <- mentionToken' rest ->
            [NText before | not (T.null before)]
              <> (NMention principal display : mentionTail after)
        | otherwise ->
            let (opener, remaining) = T.splitAt 1 rest
             in case mentionNodes remaining of
                  NText text : nodes -> NText (before <> opener <> text) : nodes
                  nodes -> NText (before <> opener) : nodes

    mentionToken' token = do
      afterOpen <- T.stripPrefix "[@#" token
      let (digits, suffix) = T.span isDigit afterOpen
      if T.null digits
        then Nothing
        else do
          principal <- PrincipalId <$> readIntegral digits
          let rosterDisplay = fromMaybe digits (lookup principal flipped)
          case T.uncons suffix of
            Just (']', after) -> Just (principal, rosterDisplay, after)
            Just (':', captionAndClose) ->
              let (caption, close) = T.breakOn "]" captionAndClose
               in if T.null close
                    then Nothing
                    else Just (principal, fromMaybe rosterDisplay (nonBlank caption), T.drop 1 close)
            _ -> Nothing

    flipped = [(principal, label) | (label, principal) <- roster.names]

    -- A real @ is followed by a space on every platform whose client
    -- inserts one; we swallow whatever the author typed and re-emit
    -- exactly one, merged into the next text run so no two text nodes end
    -- up adjacent, and dropped when the mention ends the chunk.
    mentionTail after =
      let remaining = fromMaybe after (T.stripPrefix " " after)
       in case mentionNodes remaining of
            [] -> []
            NText text : nodes -> NText (" " <> text) : nodes
            nodes -> NText " " : nodes

-- | Rescue @\@显示名@ spans a model wrote instead of the canonical
-- @[\@#\<principal_id\>]@ token.  The span converts when the text right
-- after the @ starts with a roster display name (longest match wins; names
-- shorter than 2 characters or leading with a digit are ignored — too
-- collision-prone with ordinary prose and with the token form itself).
rescueNameMentions :: [(Text, PrincipalId)] -> Text -> Text
rescueNameMentions names0 t0
  | null usable = t0
  | otherwise = go t0
  where
    usable =
      sortOn (negate . T.length . fst) $
        [ (n, principal)
        | (n0, principal) <- names0,
          let n = T.strip n0,
          T.length n >= 2,
          maybe True (not . isDigit . fst) (T.uncons n),
          not ("@" `T.isInfixOf` n)
        ]
    go t = case T.breakOn "@" t of
      (before, rest)
        | T.null rest -> t
        | otherwise ->
            let cand = T.drop 1 rest
             in case [ (principal, T.drop (T.length n) cand)
                     | (n, principal) <- usable,
                       n `T.isPrefixOf` cand
                     ] of
                  ((PrincipalId principal, after) : _) ->
                    before <> "[@#" <> tshow principal <> "]" <> go after
                  [] -> before <> "@" <> go cand

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

-- | The pre-identity projection of an adapter-built body.  Mentions render
-- as @\@name@ because an ingest body names accounts, not people, and the
-- principal a canonical handle would spell is not known until the ingest
-- transaction resolves it.  That is the same degradation
-- 'promptCanonicalText' applies to an unresolvable mention, not a second
-- vocabulary.
promptText :: Body 'Ingest -> Text
promptText = renderPromptBody (\_ display -> mentionToken display)

-- | The transcript/prompt projection of stored IR — the text persisted as
-- @rendered_text@ and read by prompts, history, search and embeddings.
--
-- Mentions name the /person/ (ADR 004): the caller supplies the
-- identity → principal resolution, which is one always-defined join, and a
-- mention whose identity is missing from the map degrades to @\@name@
-- rather than inventing a handle.
promptCanonicalText :: Map PrincipalIdentityId PrincipalId -> Body 'Canonical -> Text
promptCanonicalText principals = renderPromptBody (canonicalMention principals)

-- | No trailing space, unlike the QQ wire form this replaces.  Every
-- adapter's mention node is followed by a text node that already begins with
-- the space the client inserted, so emitting one here produced a doubled
-- space on every mention in the ledger — and a line that ended in a mention
-- ended in whitespace, which 'trimEdges' cannot reach because the space is
-- not in a text node.  'parseModelChunk' has always normalised to exactly one
-- space, so this is also what makes the round trip exact.
canonicalMention :: Map PrincipalIdentityId PrincipalId -> MentionTarget -> Text -> Text
canonicalMention principals target display = case target of
  MentionAll -> mentionToken display
  MentionIdentity identity -> case Map.lookup identity principals of
    Just (PrincipalId principal) -> "[@#" <> tshow principal <> "]"
    Nothing -> mentionToken display

renderPromptBody ::
  (XUnsupported p ~ Unsupported) =>
  (XMention p -> Text -> Text) ->
  Body p ->
  Text
renderPromptBody mention body = T.concat (map node body.nodes)
  where
    node = \case
      NText t -> t
      NMention target display -> mention target display
      NEmote e
        | Just sid <- rawId "sticker_id" e.raw ->
            "[sticker#" <> tshow sid <> maybe "" (": " <>) e.name <> "]"
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
    mediaToken meta = case meta.kind of
      -- Only a resend carries a stored handle; inbound media has none,
      -- because the id it would name is assigned by the insert that stores
      -- this very text.  'Max.Prompt' tags those markers at render time.
      MImage -> fromMaybe "[image]" (storedImageHandle meta.raw)
      MSticker ->
        maybe
          "[sticker]"
          (\sid -> "[sticker#" <> tshow sid <> maybe "" (": " <>) meta.description <> "]")
          (rawId "sticker_id" meta.raw)
      MVideo -> "[video]"
      MAudio -> "[audio]"
      MFile -> "[file:" <> fromMaybe "" meta.name <> "]"

storedImageHandle :: Maybe Value -> Maybe Text
storedImageHandle raw = do
  canonical <- rawId "source_message_id" raw
  let seg = maybe "" (("." <>) . tshow) (rawId "source_seg_index" raw)
  pure ("[image#" <> tshow canonical <> seg <> "]")

rawId :: Text -> Maybe Value -> Maybe Int64
rawId key raw = raw >>= parseMaybe (withObject "media prompt metadata" (.: Key.fromText key))

rawText :: Text -> Maybe Value -> Maybe Text
rawText key raw = raw >>= parseMaybe (withObject "media prompt metadata" (.: Key.fromText key))

-- | Inverse of 'parseModelChunk' on its normal form.  The reply token
-- leads the chunk; a converted mention carries no trailing space of its
-- own (the following text node holds it, exactly as parsing leaves it).
emitModelChunk :: Maybe Int64 -> Body 'ModelParsed -> Text
emitModelChunk replyTarget body =
  maybe "" (\rid -> "[↩#" <> tshow rid <> "] ") replyTarget
    <> T.concat (map nodeToken body.nodes)
  where
    nodeToken = \case
      NText t -> t
      NMention (PrincipalId principal) _ -> "[@#" <> tshow principal <> "]"
      NEmote e -> "[face#" <> e.nativeId <> "]"
      NMedia ref _ -> case ref of
        RefSticker n -> "[sticker#" <> tshow n <> "]"
        RefStickerDesc d -> "[sticker#" <> d <> "]"
        RefImage (CanonicalMessageId n) seg ->
          "[image#" <> tshow n <> maybe "" (("." <>) . tshow) seg <> "]"
      -- The model never authors cards; total anyway via the shared
      -- vocabulary.  NForward/NUnsupported are uninhabited in this phase
      -- and GHC's coverage checker already knows it.
      NCard c -> fallbackText (NCard c :: Node 'Canonical)
