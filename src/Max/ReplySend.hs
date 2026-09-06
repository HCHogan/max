-- |
-- Turning one blob of model-authored text into the messages the group
-- actually sees: split into chunks, resolve outgoing placeholders,
-- send, and write each sent chunk back into @messages@.
--
-- == Why this is a module and not a function in "Max.Handler"
--
-- There are now two callers.  The handler sends the final reply; the
-- typed sink in "Max.AgentOutput" sends streamed paragraphs and progress
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
    ReplyPublication (..),
    ReplyPublicationException (..),
    freshBudget,
    canStream,
    sendAndPersistReply,
    prepareReplyChunk,
    cleanModelText,
    stripStickerText,
    stripBareMarkers,
    stripThinkSpans,
    messageImageNodes,
    chunkDelayMicros,

    -- * Exposed for tests
    capTo,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception (..), asyncExceptionFromException, asyncExceptionToException)
import Control.Monad (when)
import Data.Int (Int64)
import Data.Ord (clamp)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound
import Max.IR (Body, Phase (Canonical))
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Reply (Chunk (..), chunkSource, maxChunks, planReply)
import Max.Reply.Resolve (cleanModelText, messageImageNodes, stripBareMarkers, stripStickerText, stripThinkSpans)
import Max.Reply.Resolve qualified as Resolve
import Max.Turn.Types (TurnOutputContext, nextTurnOutputLink)
import OneBot.Types (GroupId)
import System.Random (randomRIO)

-- | Where a reply is going and what it may do when it gets there.
-- Everything here is fixed for the duration of one dispatch.
data ReplyTarget = ReplyTarget
  { rtGroupId :: !GroupId,
    -- | Display-name → principal, so @\@显示名@ can be rescued into the
    -- canonical @[\@#id]@ form small models keep forgetting to write.
    -- This is the roster the prompt actually showed, so the names the model
    -- may write are exactly the names it was given.
    rtRosterNames :: ![(T.Text, PrincipalId)],
    -- | The bot's own principal, so a self-mention the model copied out of
    -- the transcript is dropped instead of sent.
    rtSelfPrincipal :: !(Maybe PrincipalId),
    -- | Whether sticker sending is enabled for this group.
    rtStickers :: !Bool,
    -- | Portable endpoint gates.  The prompt is the friendly policy; these
    -- are the fail-closed execution boundary for hallucinated/old tokens.
    rtCanReply :: !Bool,
    rtCanMention :: !Bool,
    rtCanFace :: !Bool,
    rtCanImage :: !Bool,
    -- | Shared by every visible output path in this durable turn.
    rtTurnOutputContext :: !(Maybe TurnOutputContext)
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

-- | Rendering resolves canonical content without access to publication identity.
prepareReplyChunk ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget ->
  SendBudget ->
  Chunk ->
  Eff es (SendBudget, Maybe (Body 'Canonical, Maybe CanonicalMessageId, T.Text))
prepareReplyChunk rt budget chunk = do
  let context =
        Resolve.ResolveContext
          rt.rtGroupId
          rt.rtRosterNames
          rt.rtSelfPrincipal
          rt.rtStickers
          rt.rtCanReply
          rt.rtCanMention
          rt.rtCanFace
          rt.rtCanImage
  (seen, content) <- Resolve.prepareReplyChunk context budget.sbSentImages chunk
  pure (budget {sbSentImages = seen}, content)

-- | Receipts for the committed prefix. Failure stops the remainder; callers
-- must not retry the whole text with fresh output identities.
data ReplyPublication = ReplyPublication
  { budget :: !SendBudget,
    committed :: ![CanonicalMessageId],
    failure :: !(Maybe T.Text)
  }
  deriving stock (Show, Eq)

-- | Stream callback failure must escape provider retry/fallback catches: some
-- paragraphs may already be committed. The dispatch root records the failure.
newtype ReplyPublicationException = ReplyPublicationException T.Text
  deriving stock (Show)

instance Exception ReplyPublicationException where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

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
-- Chunks publish in order. Only committed chunks consume the send budget;
-- the first failure stops publication and returns the committed prefix.
sendAndPersistReply ::
  (Blob :> es, Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget -> SendBudget -> T.Text -> Eff es ReplyPublication
sendAndPersistReply rt initial rawBody = go initial [] 0 chunks
  where
    chunks = capTo initial.sbChunksLeft (planReply (cleanModelText rawBody))
    go b receipts _ [] = pure (ReplyPublication b (reverse receipts) Nothing)
    go b receipts i (chunk : rest) = do
      (prepared, mPlan) <- prepareReplyChunk rt b chunk
      case mPlan of
        Nothing -> go b receipts i rest
        Just (resolvedBody, replyTo, pacingText) -> do
          when (i > (0 :: Int)) $
            liftIO (threadDelay =<< chunkDelayMicros (T.length pacingText))
          turnOutput <- traverse (liftIO . nextTurnOutputLink) rt.rtTurnOutputContext
          outcome <-
            sendRecorded
              OutboundRequest
                { orKind = KindChat,
                  orGroupId = rt.rtGroupId,
                  orBody = resolvedBody,
                  orReplyTo = replyTo,
                  orDeliveryScope = DeliverConversation,
                  orTurnOutput = turnOutput,
                  orMonitorFireId = Nothing
                }
          case outcome of
            PublicationFailed err -> do
              logAttention "llm reply publication failed" $ object ["error" .= err, "chunk" .= i]
              pure (ReplyPublication b (reverse receipts) (Just err))
            Published canonical ->
              go prepared {sbChunksLeft = max 0 (b.sbChunksLeft - 1)} (canonical : receipts) (i + 1) rest

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
