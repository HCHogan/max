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
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Max.IR
import Max.Platform.Types (NativeUserId (..), Platform (..))
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
      PieceText s -> map segNode (segmentMentions knownLegacy s)
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
         in NMention (NativeUserId digits) digits
      -- 'segmentMentions' only produces text and at segments; anything
      -- else would be a contract change upstream — degrade it readably.
      other -> NText (renderPlainText [other])

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
