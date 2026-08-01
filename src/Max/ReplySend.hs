-- |
-- Turning one blob of model-authored text into the messages the group
-- actually sees: split into chunks, resolve outgoing placeholders,
-- send, and write each sent chunk back into @messages@.
--
-- == Why this is a module and not a function in "Max.Handler"
--
-- There are now two callers.  The handler sends the final reply; the
-- agent loop sends paragraphs as they stream in, and the progress
-- narration that rides alongside tool calls.  Every previous attempt to
-- give one of those its own copy of \"turn model text into messages\"
-- produced the same bug twice in one day (@a0faa5b@, @d7f8177@):
-- narration had a private copy, so it missed 'parseReplyTokens' and
-- then 'trimEdgeSegs', and a literal @[↩#111091811]@ went out as
-- visible text.  One implementation, two callers.
--
-- == Splitting a reply across calls
--
-- Streaming means one logical reply arrives as several calls here, and
-- two of the guarantees a single call used to give for free are
-- per-reply, not per-call:
--
--   * 'Max.Reply.maxChunks' bounds how long the bot may monopolise a
--     group.  Applied per call, a reply split in three could send three
--     times the cap.
--   * 'dedupeImagePieces' stops a repeated @[image#\<id\>]@ from
--     resending the same picture.  Its @seen@ set has to survive the
--     split or the dedupe only works within a fragment.
--
-- So both ride in a 'SendBudget' the caller threads through.  A caller
-- that sends a whole reply in one go just passes 'freshBudget' and
-- discards the result.
--
-- This module deliberately does __not__ import
-- 'Max.Effects.Agent.DispatchContext': the agent loop imports this one,
-- and taking the context back would close the cycle.  Hence
-- 'ReplyTarget', which is the handful of fields both callers already
-- have.
module Max.ReplySend
  ( ReplyTarget (..),
    SendBudget (..),
    freshBudget,
    canStream,
    sendAndPersistReply,
    modelTextSegs,
    messageImageSegs,
    chunkDelayMicros,

    -- * Exposed for tests
    capTo,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Exception (SomeException)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Message (MessageKind (..))
import Max.DB.Stickers (findStickerByCaption)
import Max.Effects.Outbound (Outbound, OutboundRequest (..), SendOutcome (..), sendRecorded)
import Max.Render (renderTableImage)
import Max.Reply
  ( Chunk (..),
    ReplyPiece (..),
    chunkSource,
    dedupeImagePieces,
    maxChunks,
    parseReplyTokens,
    planReply,
  )
import Max.Sticker (resolveSticker)
import Max.Util (trySync)
import OneBot.Segment (Segment (..), imageSeg, rescueNameMentions, segmentMentions, trimEdgeSegs)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)
import System.FilePath ((</>))
import System.Random (randomRIO)

-- | Where a reply is going and what it may do when it gets there.
-- Everything here is fixed for the duration of one dispatch.
data ReplyTarget = ReplyTarget
  { rtGroupId :: !GroupId,
    -- | The bot's own QQ id, for attributing the persisted rows.
    rtSelfId :: !UserId,
    -- | The group's member ids: the whitelist for turning a raw
    -- @\@\<qq\>@ span into a real at-segment.  'Nothing' when
    -- unavailable (private chat, roster fetch failed) — conversion then
    -- checks syntax only, rather than silently refusing to @ anyone.
    rtMentionable :: !(Maybe (Set UserId)),
    -- | Display-name → id, so @\@显示名@ can be rescued into the
    -- canonical @[\@#id]@ form small models keep forgetting to write.
    rtRosterNames :: ![(T.Text, UserId)],
    -- | Blob store root, for resolving sticker and image resends.
    rtBlobRoot :: !FilePath,
    -- | Whether sticker sending is enabled for this group.
    rtStickers :: !Bool
  }

-- | What one logical reply has spent so far.  Threaded across calls so
-- that a reply split by streaming is bounded exactly like an unsplit
-- one; see the module header.
data SendBudget = SendBudget
  { -- | Message ids whose images have already been resent this reply.
    sbSentImages :: !(Set Int64),
    -- | Chunks still allowed before the rest is folded into one.
    sbChunksLeft :: !Int
  }
  deriving stock (Show, Eq)

freshBudget :: SendBudget
freshBudget = SendBudget {sbSentImages = Set.empty, sbChunksLeft = maxChunks}

-- | May a streaming sink still send, or must it hold what it has for
-- the final send?
--
-- The last slot is reserved on purpose.  'sendAndPersistReply' folds an
-- over-budget reply into one last message rather than dropping its tail
-- — right for a call that sends a whole reply, and a hole when a reply
-- arrives as N calls, because each one then gets that fold for free and
-- the ceiling stops existing.  Production found it immediately: a
-- 12-paragraph answer went out as 12 messages against a cap of 10, with
-- the fold landing in the /middle/ of the reply.
--
-- Stopping at one leaves exactly the room 'Max.Reply.capChunks' would
-- have used, so a streamed reply and an unstreamed one produce the same
-- number of messages, and anything the sink declines accumulates into
-- that final merged message where it belongs.
canStream :: SendBudget -> Bool
canStream b = b.sbChunksLeft > 1

-- | Send the model's text as planned by 'planReply' — one message per
-- blank-line paragraph, markdown tables rendered to a PNG via typst
-- (falling back to the markdown source when rendering fails) — and
-- persist each sent chunk into the messages table (so future dispatches
-- read this back as the bot's own turn, and a reply to /any/ chunk
-- resolves as reply-to-bot).
--
-- Outgoing placeholders are resolved per chunk ('parseReplyTokens'),
-- which is what lets the model quote a different message from each
-- paragraph and drop a sticker inline:
--
--   * a leading @[↩#\<id\>]@ becomes the chunk's 'SegReply' quote —
--     nothing is auto-quoted, the model decides;
--   * @[sticker#\<id\>]@ becomes a sticker segment ('resolveSticker'),
--     an unknown id is dropped rather than failing the reply;
--   * @[image#\<id\>]@ resends that message's stored images; duplicate
--     ids are dropped across the whole reply — a multi-image message
--     tags all its markers with one id, so an echo would otherwise
--     resend N images N times;
--   * @[face#\<id\>]@ becomes a QQ built-in face segment;
--   * raw @\@\<qq\>@ spans become real at-segments when the id passes
--     the membership check ('segmentMentions').
--
-- A chunk that resolves to no content (a lone @[↩#id]@, or only a bad
-- sticker token) is skipped.  Each chunk persists with its /resolved/
-- surface form as @rendered_text@ (sticker tokens normalised to
-- @[sticker#\<id\>: \<caption\>]@, image tokens keeping their
-- @[image#\<id\>]@ form, the reply token dropped — it lives in the
-- @reply_to_message_id@ column), so what the model reads back next turn
-- matches what it wrote.  A table chunk persists with its markdown
-- source.
--
-- Chunks are sent sequentially, so ordering is guaranteed.  Every
-- failure only logs: a message that went out but couldn't be written
-- down leaves the record incomplete, which is bad; failing the dispatch
-- over it is worse.
sendAndPersistReply ::
  (Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget ->
  SendBudget ->
  T.Text ->
  Eff es SendBudget
sendAndPersistReply rt budget body
  -- Nothing left to say.  'planReply' plans this to no chunks on its
  -- own, so the guard is belt-and-braces — but the case is routine, not
  -- exotic: a streamed reply released down to its last paragraph leaves
  -- exactly nothing for the final send.
  | T.null (T.strip body) = pure budget
  | otherwise = foldM sendOne budget' (zip [0 :: Int ..] chunks)
  where
    -- Apply the reply-wide chunk ceiling here rather than inside
    -- 'planReply': only this layer knows how much of the budget an
    -- earlier fragment of the same reply already spent.
    planned = planReply body
    chunks = capTo budget.sbChunksLeft planned
    budget' = budget {sbChunksLeft = max 0 (budget.sbChunksLeft - length chunks)}

    sendOne b (i, chunk) = do
      (b', mPlan) <- planChunk b chunk
      case mPlan of
        Nothing -> pure b'
        Just (segs, rendered) -> do
          -- Typing-pace delay between chunks: instant multi-message
          -- bursts read as a bot.  The first chunk of a call needs none
          -- — either the LLM round-trip was its "typing time", or (when
          -- streaming) the wait for the paragraph to complete was.
          when (i > 0) $
            liftIO (threadDelay =<< chunkDelayMicros (T.length rendered))
          sendRecorded
            OutboundRequest
              { orKind = KindChat,
                orGroupId = rt.rtGroupId,
                orSelfId = rt.rtSelfId,
                orRenderedText = Just (T.strip rendered),
                orSegments = segs,
                orTimeoutMs = 30000
              }
            >>= \case
              SendFailed err ->
                logAttention "llm reply send failed" $ object ["error" .= err, "chunk" .= i]
              SentUnrecorded {} -> pure ()
              SentRecorded {} -> pure ()
          pure b'

    -- One chunk → 'Just' (segments to send, rendered_text to store) or
    -- 'Nothing' to skip; threads the set of already-resent image
    -- message ids so a duplicated [image#<id>] never resends.
    planChunk b (TableChunk src) = do
      rendered <- liftIO (renderTableImage src)
      case rendered of
        Right png ->
          pure (b, Just ([imageSeg ("base64://" <> TE.decodeASCII (B64.encode png))], src))
        Left err -> do
          logAttention "table render failed, sending source" $ object ["error" .= err]
          pure (b, Just ([SegText src], src))
    planChunk b (TextChunk t) = do
      let (mReplyId, pieces0) = parseReplyTokens t
          (seen', pieces) = dedupeImagePieces b.sbSentImages pieces0
          b' = b {sbSentImages = seen'}
      (content, rendered) <- resolvePieces pieces
      pure . (b',) $
        if null content
          then Nothing
          else
            let prefix = [SegReply (MessageId rid) | Just rid <- [mReplyId]]
             in Just (prefix <> trimEdgeSegs content, T.strip rendered)

    -- Resolve parsed pieces into (segments, normalised rendered text).
    resolvePieces pieces = do
      parts <- traverse resolve pieces
      pure (concatMap fst parts, T.concat (map snd parts))
      where
        resolve (PieceText t0) =
          -- "@显示名" → canonical [@#id] first (small models skip the
          -- roster lookup), then the usual mention conversion.
          let t = rescueNameMentions rt.rtRosterNames t0
           in pure (mentionSegs t, t)
        -- Sticker sending disabled for this group: drop the token
        -- (the model shouldn't emit one, but never leak it as text).
        resolve (PieceSticker _) | not rt.rtStickers = pure ([], "")
        resolve (PieceStickerDesc _) | not rt.rtStickers = pure ([], "")
        -- Caption in the id slot ('PieceStickerDesc'): resolve it
        -- against the library, then proceed as if the id had been
        -- written.  No match → drop, same rule as an unknown id.
        resolve (PieceStickerDesc d) =
          findStickerByCaption d >>= \case
            Just sid -> resolve (PieceSticker sid)
            Nothing -> do
              logAttention "sticker caption unresolved" $ object ["caption" .= d]
              pure ([], "")
        resolve (PieceSticker sid) =
          resolveSticker rt.rtBlobRoot sid >>= \case
            Right (desc, segs) ->
              pure (segs, "[sticker#" <> T.pack (show sid) <> ": " <> T.take 80 desc <> "]")
            Left err -> do
              logAttention "sticker placeholder unresolved" $
                object ["id" .= sid, "error" .= err]
              pure ([], "")
        resolve (PieceImage mid) = do
          segs <- messageImageSegs rt.rtBlobRoot mid
          if null segs
            then do
              logAttention "image placeholder unresolved" $ object ["message_id" .= mid]
              pure ([], "")
            else
              -- Keep the id in the persisted form: the model reads
              -- back the same [image#<id>] handle it wrote (and can
              -- resend from it again), instead of a bare [image] it
              -- was told is a hallucination.
              pure (segs, "[image#" <> T.pack (show mid) <> "]")
        resolve (PieceFace fid) =
          pure ([SegFace fid Nothing], "[face#" <> T.pack (show fid) <> "]")

    -- Private chats keep raw text: NapCat renders private
    -- at-segments poorly.
    mentionSegs t
      | isPrivateChat rt.rtGroupId = [SegText t]
      | otherwise = segmentMentions (\u -> maybe True (Set.member u) rt.rtMentionable) t

-- | Model-authored text → the segments of __one__ message, for the
-- senders that build their message inline instead of going through
-- 'sendAndPersistReply': progress narration
-- ('Max.Effects.Agent.narrationSegments'), and the caption a tool posts
-- alongside an image.
--
-- Every such sender is a place the placeholder handling can drift out
-- of, and every one of them has: narration leaked @[↩#111091811]@ into
-- a group, then @send_image_from_sandbox@'s caption leaked
-- @[↩#493645310]@ into another, months apart, for the same reason both
-- times.  The text arrives carrying the same tokens a reply does
-- because the format guide is written once, for all of it.
--
-- The quote target comes back separately from the body because the
-- callers disagree about an empty body: narration with nothing left to
-- say sends nothing at all, while a caption rides with an image that
-- goes out either way, so its quote still counts.
--
-- Sticker and image placeholders are dropped rather than resolved —
-- either needs a DB round-trip apiece and neither sender is worth one.
-- Dropping loses something invisible; leaking the raw token is the bug
-- this exists to prevent.  Faces are pure, so they survive.
--
-- Note this handles /tokens/, not /chunking/: @[split]@ is
-- 'planReply''s job, and a caller that can only send one message has to
-- decide what to do with it before calling here.
modelTextSegs ::
  -- | Private chat?  NapCat renders private at-segments poorly, so
  -- mentions stay as plain text there.
  Bool ->
  -- | Mentionable ids, as in 'rtMentionable' — 'Nothing' checks syntax
  -- only rather than refusing to @ anyone.
  Maybe (Set UserId) ->
  T.Text ->
  (Maybe MessageId, [Segment])
modelTextSegs private mentionable raw =
  (MessageId <$> mQuoted, trimEdgeSegs (concatMap piece pieces))
  where
    (mQuoted, pieces) = parseReplyTokens (T.strip raw)
    piece = \case
      PieceText t
        | private -> [SegText t]
        | otherwise -> segmentMentions (\u -> maybe True (Set.member u) mentionable) t
      PieceFace fid -> [SegFace fid Nothing]
      PieceSticker _ -> []
      PieceStickerDesc _ -> []
      PieceImage _ -> []

-- | Fold everything past the remaining allowance into one last message,
-- the same way 'Max.Reply.capChunks' does within a single call — loud
-- but bounded beats truncated, and the bot's own history still records
-- what it said.  An exhausted budget still sends one merged chunk
-- rather than silently dropping the tail.
capTo :: Int -> [Chunk] -> [Chunk]
capTo n cs
  | length cs <= n = cs
  | otherwise = keep <> [TextChunk (T.intercalate "\n\n" (map chunkSource spill))]
  where
    (keep, spill) = splitAt (max 0 (n - 1)) cs

-- | How long to pause before a follow-up chunk, roughly scaled to how
-- long a human would take to type it: ~35ms per character with ±30%
-- jitter, clamped to [200ms, 2s].
chunkDelayMicros :: Int -> IO Int
chunkDelayMicros nChars = do
  f <- randomRIO (0.7, 1.3 :: Double)
  pure (max 200_000 (min 2_000_000 (round (fromIntegral nChars * 35_000 * f))))

-- | Load a stored message's images back off disk as outgoing segments.
-- A blob that can't be read is skipped, not fatal: resending N-1 of N
-- pictures beats failing the reply.
messageImageSegs ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath ->
  Int64 ->
  Eff es [Segment]
messageImageSegs blobRoot mid = do
  rows <-
    query
      "SELECT i.local_path \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.message_id = ? \
      \  ORDER BY mi.seg_index"
      (Only mid)
  fmap concat . traverse loadOne $ (rows :: [Only T.Text])
  where
    loadOne (Only path) =
      trySync (liftIO (BS.readFile (blobRoot </> T.unpack path))) >>= \case
        Left e -> do
          logAttention "image resend: blob read failed" $
            object ["path" .= path, "error" .= T.pack (show (e :: SomeException))]
          pure []
        Right bytes ->
          pure [imageSeg ("base64://" <> TE.decodeUtf8 (B64.encode bytes))]
