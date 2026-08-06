-- |
-- Turning one blob of model-authored text into the messages the group
-- actually sees: split into chunks, resolve outgoing placeholders,
-- send, and write each sent chunk back into @messages@.
--
-- == Why this is a module and not a function in "Max.Handler"
--
-- There are now two callers.  The handler sends the final reply; the
-- typed sink in "Max.AgentEvent" sends streamed paragraphs and progress
-- narration.  Every previous attempt to
-- give one of those its own copy of \"turn model text into messages\"
-- produced the same bug twice in one day (@a0faa5b@, @d7f8177@):
-- narration had a private copy, so it missed 'parseReplyTokens' and
-- then 'trimEdgeSegs', and a literal @[reply#111091811]@ went out as
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
-- 'Max.ToolContext.ToolContext': the agent loop imports this one,
-- and taking the context back would close the cycle.  Hence
-- 'ReplyTarget', which is the handful of fields both callers already
-- have.
module Max.ReplySend
  ( ReplyTarget (..),
    SendBudget (..),
    freshBudget,
    canStream,
    sendAndPersistReply,
    cleanModelText,
    stripStickerText,
    stripBareMarkers,
    messageImageNodes,
    chunkDelayMicros,

    -- * Exposed for tests
    capTo,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM, when)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.Ord (clamp)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.History (fetchMessageInScope)
import Max.DB.Media (StoredImage (..), fetchMessageImagesInScope)
import Max.MessageKind (MessageKind (..))
import Max.DB.Stickers (findStickerByCaption)
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), SendOutcome (..), sendRecorded)
import Max.IR
import Max.IR.Digest (digest)
import Data.Map.Strict qualified as Map
import Max.IR.Prompt (MentionRoster (..), parseModelChunk)
import Max.Platform.Store (resolveMentionIdentities)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId)
import Max.Render (renderTableImage)
import Max.Reply
  ( Chunk (..),
    chunkSource,
    maxChunks,
    planReply,
    stripHallucinatedTokens,
  )
import Max.Sticker (ResolvedSticker (..), resolveSticker)
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)
import System.Random (randomRIO)

-- | Where a reply is going and what it may do when it gets there.
-- Everything here is fixed for the duration of one dispatch.
data ReplyTarget = ReplyTarget
  { rtGroupId :: !GroupId,
    -- | The bot's own QQ id, for attributing the persisted rows.
    rtSelfId :: !UserId,
    -- | Display-name → principal, so @\@显示名@ can be rescued into the
    -- canonical @[\@#id]@ form small models keep forgetting to write.
    -- This is the roster the prompt actually showed, so the names the model
    -- may write are exactly the names it was given.
    rtRosterNames :: ![(T.Text, PrincipalId)],
    -- | The bot's own principal, so a self-mention the model copied out of
    -- the transcript is dropped instead of sent.
    rtSelfPrincipal :: !PrincipalId,
    -- | Whether sticker sending is enabled for this group.
    rtStickers :: !Bool,
    -- | Portable endpoint gates.  The prompt is the friendly policy; these
    -- are the fail-closed execution boundary for hallucinated/old tokens.
    rtCanReply :: !Bool,
    rtCanMention :: !Bool,
    rtCanFace :: !Bool,
    rtCanImage :: !Bool
  }

-- | What one logical reply has spent so far.  Threaded across calls so
-- that a reply split by streaming is bounded exactly like an unsplit
-- one; see the module header.
data SendBudget = SendBudget
  { -- | Images already resent this reply, keyed the way the model names
    -- them: a whole message, or one @(message, seg_index)@ picture of it.
    sbSentImages :: !(Set (Int64, Maybe Int)),
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
--   * a leading @[reply#\<id\>]@ becomes the chunk's 'SegReply' quote —
--     nothing is auto-quoted, the model decides;
--   * @[sticker#\<id\>]@ becomes a sticker segment ('resolveSticker'),
--     an unknown id is dropped rather than failing the reply;
--   * @[image#\<id\>(.\<seg\>)?]@ resends that message's stored images, or
--     the one picture named; duplicates are dropped across the whole reply;
--   * @[face#\<id\>]@ becomes a QQ built-in face segment;
--   * @[\@#\<principal_id\>]@ becomes a real mention when that person has an
--     account in this conversation, and folds to @\@name@ text when they do
--     not — which is also what a principal id the model invented does.
--
-- A chunk that resolves to no content (a lone @[reply#id]@, or only a bad
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
  (Blob :> es, Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget ->
  SendBudget ->
  T.Text ->
  Eff es SendBudget
sendAndPersistReply rt budget rawBody
  -- Nothing left to say.  'planReply' plans this to no chunks on its
  -- own, so the guard is belt-and-braces — but the case is routine, not
  -- exotic: a streamed reply released down to its last paragraph leaves
  -- exactly nothing for the final send.
  | T.null (T.strip body) = pure budget
  | otherwise = foldM sendOne budget' (zip [0 :: Int ..] chunks)
  where
    body = cleanModelText rawBody

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
        Just (resolvedBody, replyTo, pacingText) -> do
          -- Typing-pace delay between chunks: instant multi-message
          -- bursts read as a bot.  The first chunk of a call needs none
          -- — either the LLM round-trip was its "typing time", or (when
          -- streaming) the wait for the paragraph to complete was.
          when (i > 0) $
            liftIO (threadDelay =<< chunkDelayMicros (T.length pacingText))
          sendRecorded
            OutboundRequest
              { orKind = KindChat,
                orGroupId = rt.rtGroupId,
                orBody = resolvedBody,
                orReplyTo = replyTo,
                orDeliveryScope = DeliverConversation
              }
            >>= \case
              SendFailed err ->
                logAttention "llm reply send failed" $ object ["error" .= err, "chunk" .= i]
              SentUnrecorded {} -> pure ()
              SentRecorded {} -> pure ()
          pure b'

    -- One chunk becomes one ingest-phase body plus an envelope reply.
    -- Model-only handles are resolved before publication, and image handles
    -- are deduplicated across the complete streamed reply.
    planChunk b (TableChunk src) = do
      rendered <- liftIO (renderTableImage src)
      case rendered of
        Right png -> do
          blob <- putBlob png
          case mediaBlobRef (blobRefSha256 blob) of
            Nothing -> do
              logAttention "table render produced an invalid blob reference" $ object []
              pure (b, Just (Body [NText src], Nothing, src))
            Just source ->
              pure
                ( b,
                  Just
                    ( Body
                        [ NMedia
                            (Just source)
                            MediaMeta
                              { kind = MImage,
                                mime = Just "image/png",
                                sizeBytes = Just (fromIntegral (BS.length png)),
                                name = Just "table.png",
                                description = Nothing,
                                raw = Just (object ["prompt_text" .= src])
                              }
                        ],
                      Nothing,
                      src
                    )
                )
        Left err -> do
          logAttention "table render failed, sending source" $ object ["error" .= err]
          pure (b, Just (Body [NText src], Nothing, src))
    planChunk b (TextChunk t) = do
      let (mReplyId, parsed0) = parseModelChunk mentionRoster t
          (seen', parsed) = dedupeModelImages b.sbSentImages parsed0
          b' = b {sbSentImages = seen'}
      mentions <-
        if rt.rtCanMention && not (isPrivateChat rt.rtGroupId)
          then resolveMentionIdentities conversationId [p | NMention p _ <- parsed.nodes]
          else pure Map.empty
      logInfo "model chunk parsed" $ object ["content" .= digest parsed0]
      mReplyId' <- case mReplyId of
        _ | not rt.rtCanReply -> pure Nothing
        Nothing -> pure Nothing
        Just rid ->
          fetchMessageInScope conversation rid >>= \case
            Just _ -> pure (Just rid)
            Nothing -> do
              logAttention "reply placeholder outside conversation" $
                object ["message_id" .= rid]
              pure Nothing
      resolved <- concat <$> traverse (resolveModelNode mentions) parsed.nodes
      let content = trimEdges (mergeText resolved)
      pure
        ( b',
          if null content
            then Nothing
            else Just (Body content, CanonicalMessageId <$> mReplyId', t)
        )

    mentionRoster = MentionRoster {names = rt.rtRosterNames, selfPrincipal = Just rt.rtSelfPrincipal}

    resolveModelNode mentions = \case
      NText text -> pure [NText text]
      NMention principal display -> case Map.lookup principal mentions of
        Just identity -> pure [NMention (MentionIdentity identity) display]
        Nothing -> pure [NText (mentionToken display)]
      NEmote emote
        | rt.rtCanFace -> pure [NEmote emote]
        | otherwise -> pure []
      NMedia ref _ -> resolveModelMedia ref
      NCard card -> pure [NCard card]

    resolveModelMedia = \case
      RefSticker _ | not rt.rtStickers -> pure []
      RefStickerDesc _ | not rt.rtStickers -> pure []
      RefStickerDesc caption ->
        findStickerByCaption caption >>= \case
          Just stickerId -> resolveModelMedia (RefSticker stickerId)
          Nothing -> do
            logAttention "sticker caption unresolved" $ object ["caption" .= caption]
            pure []
      RefSticker stickerId ->
        resolveSticker stickerId >>= \case
          Right sticker -> pure [sticker.node]
          Left err -> do
            logAttention "sticker placeholder unresolved" $
              object ["id" .= stickerId, "error" .= err]
            pure []
      RefImage _ _ | not rt.rtCanImage -> pure []
      RefImage (CanonicalMessageId messageId) seg -> do
        images <- messageImageNodes conversation messageId seg
        when (null images) $
          logAttention "image placeholder unresolved" $
            object ["canonical_message_id" .= messageId, "seg_index" .= seg]
        pure images

    conversation = conversationScopeFor rt.rtGroupId
    GroupId conversationId = rt.rtGroupId

dedupeModelImages ::
  Set (Int64, Maybe Int) -> Body 'ModelParsed -> (Set (Int64, Maybe Int), Body 'ModelParsed)
dedupeModelImages seen0 body =
  let (seen, kept) = foldl' step (seen0, []) body.nodes
   in (seen, Body (reverse kept))
  where
    step (seen, kept) node = case node of
      NMedia (RefImage (CanonicalMessageId messageId) seg) _
        | Set.member (messageId, seg) seen || Set.member (messageId, Nothing) seen -> (seen, kept)
        | otherwise -> (Set.insert (messageId, seg) seen, node : kept)
      _ -> (seen, node : kept)

-- | Everything model text must lose before it can become visible.  Kept in
-- the same module as sending so streamed final text, progress narration, and
-- the final remainder cannot drift into subtly different grammars.
cleanModelText :: T.Text -> T.Text
cleanModelText = T.strip . stripBareMarkers . stripStickerText . stripHallucinatedTokens

-- | Drop bare display markers echoed from transcript context.  Id-carrying
-- send tokens remain intact for 'sendAndPersistReply' to resolve.
stripBareMarkers :: T.Text -> T.Text
stripBareMarkers t =
  foldl'
    (\acc marker -> T.replace marker "" acc)
    t
    ["[image]", "[sticker]", "[动画表情]", "[mface]", "[face]", "[forward]"]

-- | Drop hallucinated sticker-caption display spans while preserving the
-- real @[sticker#id]@ / legacy @[表情包#id]@ send forms.
stripStickerText :: T.Text -> T.Text
stripStickerText t0 = foldl' stripOpener t0 ["[sticker:", "[sticker：", "[表情包"]
  where
    stripOpener t1 opener = go t1
      where
        go t = case T.breakOn opener t of
          (before, rest)
            | T.null rest -> t
            | otherwise ->
                let afterOpener = T.drop (T.length opener) rest
                 in if isSendToken afterOpener
                      then before <> opener <> go afterOpener
                      else case T.breakOn "]" afterOpener of
                        (_, close)
                          | T.null close -> before
                          | otherwise -> before <> go (T.drop 1 close)
    isSendToken s = case T.uncons s of
      Just ('#', r) -> maybe False (isDigit . fst) (T.uncons r)
      _ -> False

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
  pure (clamp (200_000, 2_000_000) (round (fromIntegral nChars * 35_000 * f)))

-- | Resolve a model-authored image handle to canonical blob-backed nodes.
-- The delivery worker owns blob loading and permanent-failure policy; the
-- publication path records only content addresses and never re-encodes bytes.
messageImageNodes ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Maybe Int ->
  Eff es [Node 'Canonical]
messageImageNodes scope mid seg = do
  rows <- fetchMessageImagesInScope scope mid seg
  fmap concat . traverse node $ rows
  where
    node image = case mediaBlobRef image.storedImageSha256 of
      Nothing -> do
        logAttention "image resend: invalid blob ref" $ object ["sha256" .= image.storedImageSha256]
        pure []
      Just source ->
        pure
          [ NMedia
              (Just source)
              MediaMeta
                { kind = MImage,
                  mime = Just image.storedImageMime,
                  sizeBytes = Nothing,
                  name = Nothing,
                  description = Nothing,
                  -- The handle this picture is known by, carried so the
                  -- resend's own transcript line names the same picture the
                  -- model pointed at rather than a bare [image] marker.
                  raw =
                    Just
                      ( object
                          [ "source_message_id" .= mid,
                            "source_seg_index" .= image.storedImageSegIndex
                          ]
                      )
                }
          ]
