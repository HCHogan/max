-- | Shared publication path for final replies, streamed text and progress.
-- Resolve placeholders, publish chunks in order and persist their visible form.
-- SendState carries image deduplication across calls;
-- whole-reply callers start with emptySendState. ReplyTarget keeps this boundary
-- independent of ToolContext.
module Max.ReplySend
  ( ReplyTarget (..),
    SendState (..),
    ReplyPublication (..),
    ReplyPublicationException (..),
    emptySendState,
    sendAndPersistReply,
    prepareReplyChunk,
    cleanModelText,
    stripStickerText,
    stripBareMarkers,
    stripThinkSpans,
    messageImageNodes,
    chunkDelayMicros,
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
import Max.Reply (Chunk (..), planReply)
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
    -- | Shared by every visible output path in this turn.
    rtTurnOutputContext :: !(Maybe TurnOutputContext)
  }

-- | Images already resent across streamed chunks and the final remainder.
newtype SendState = SendState
  { -- | Images already resent this reply, keyed the way the model names
    -- them: a whole message, or one @(message, seg_index)@ picture of it.
    ssSentImages :: Set (Int64, Maybe Int)
  }
  deriving stock (Show, Eq)

emptySendState :: SendState
emptySendState = SendState {ssSentImages = Set.empty}

-- | Rendering resolves canonical content without access to publication identity.
prepareReplyChunk ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget ->
  SendState ->
  Chunk ->
  Eff es (SendState, Maybe (Body 'Canonical, Maybe CanonicalMessageId, T.Text))
prepareReplyChunk rt state chunk = do
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
  (seen, content) <- Resolve.prepareReplyChunk context state.ssSentImages chunk
  pure (state {ssSentImages = seen}, content)

-- | Receipts for the committed prefix. Failure stops the remainder; callers
-- must not retry the whole text with fresh output identities.
data ReplyPublication = ReplyPublication
  { sendState :: !SendState,
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

-- | Plan, resolve and publish chunks in order. Tables render as images with
-- markdown fallback; empty resolved chunks are skipped. Persist the resolved
-- surface form, or the source markdown for tables, for subsequent context.
-- Image deduplication spans the SendState. Only committed chunks update it;
-- the first failure stops publication and returns the committed prefix.
-- See parseReplyTokens for placeholder syntax.
sendAndPersistReply ::
  (Blob :> es, Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ReplyTarget -> SendState -> T.Text -> Eff es ReplyPublication
sendAndPersistReply rt initial rawBody = go initial [] 0 chunks
  where
    chunks = planReply (cleanModelText rawBody)
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
              go prepared (canonical : receipts) (i + 1) rest

-- | How long to pause before a follow-up chunk, roughly scaled to how
-- long a human would take to type it: ~35ms per character with ±30%
-- jitter, clamped to [200ms, 2s].
chunkDelayMicros :: Int -> IO Int
chunkDelayMicros nChars = do
  f <- randomRIO (0.7, 1.3 :: Double)
  pure (clamp (200_000, 2_000_000) (round (fromIntegral nChars * 35_000 * f)))
