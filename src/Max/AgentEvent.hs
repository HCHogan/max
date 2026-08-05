{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Typed output events emitted by the agent loop, plus the production sink
-- that turns them into visible chat messages.
--
-- The GADT keeps backpressure honest: progress and debug notifications are
-- best-effort and return @()@, while a streamed final paragraph returns
-- 'Bool' so the loop advances its sent-prefix watermark only when the reply
-- budget accepted it.
--
-- This is deliberately outside "Max.Effects.Agent".  The loop describes
-- /what happened/; this module owns whether that event is visible, how
-- model-authored text is rendered, and how it reaches 'Outbound'.
module Max.AgentEvent
  ( AgentEvent (..),
    AgentEventSink,
    ToolDebugEvent (..),
    AgentOutputContext (..),
    handleAgentEvent,
  )
where

import Control.Concurrent.STM (TVar, atomically, readTVarIO, writeTVar)
import Control.Monad (void, when)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.MessageKind (MessageKind (KindDebug))
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), sendRecorded)
import Max.IR (Body (..), Node (NText))
import Max.ReplySend (ReplyTarget (..), SendBudget, canStream, freshBudget, sendAndPersistReply)
import Max.Platform.Types (CanonicalMessageId)

-- | Debug facts emitted by the loop without deciding whether debug output is
-- enabled or how the values should be formatted for chat.
data ToolDebugEvent
  = ToolCallsStarted ![(Text, Value)]
  | ToolCallFinished !Text !(Either Text Value)
  deriving stock (Show, Eq)

-- | Events crossing from the agent orchestrator to its output boundary.
data AgentEvent a where
  AgentProgressText :: !Text -> AgentEvent ()
  AgentToolDebug :: !ToolDebugEvent -> AgentEvent ()
  AgentFinalStreamText :: !Text -> AgentEvent Bool

-- | A natural transformation from typed agent events into some carrier.
type AgentEventSink m = forall a. AgentEvent a -> m a

-- | Everything fixed while one dispatch's events are interpreted.
data AgentOutputContext = AgentOutputContext
  { aocReplyTarget :: !ReplyTarget,
    -- | Canonical id of the inbound event that started this dispatch. Debug
    -- UI is operational output, so it must return only to that event's
    -- endpoint instead of being mirrored as conversation text.
    aocSourceMessageId :: !CanonicalMessageId,
    aocDebug :: !Bool,
    -- | Shared only by final-stream events and the final remainder.  Progress
    -- narration is a separate utterance and receives its own bounded budget.
    aocStreamBudget :: !(TVar SendBudget)
  }

-- | Production event sink.  Model-authored text always takes the ReplySend
-- path; non-model debug UI goes straight to Outbound as 'KindDebug'.
handleAgentEvent ::
  forall es a.
  (Blob :> es, Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AgentOutputContext ->
  AgentEvent a ->
  Eff es a
handleAgentEvent ctx = \case
  AgentProgressText body ->
    void (sendAndPersistReply ctx.aocReplyTarget freshBudget body)
  AgentToolDebug event ->
    when ctx.aocDebug (mapM_ sendDebug (renderToolDebug event))
  AgentFinalStreamText body -> do
    budget <- liftIO (readTVarIO ctx.aocStreamBudget)
    if not (canStream budget)
      then pure False
      else do
        budget' <- sendAndPersistReply ctx.aocReplyTarget budget body
        liftIO (atomically (writeTVar ctx.aocStreamBudget budget'))
        pure True
  where
    sendDebug :: Text -> Eff es ()
    sendDebug body =
      void $
        sendRecorded
          OutboundRequest
            { orKind = KindDebug,
              orGroupId = ctx.aocReplyTarget.rtGroupId,
              orBody = Body [NText body],
              orReplyTo = Nothing,
              orDeliveryScope = DeliverSourceEndpoint ctx.aocSourceMessageId
            }

-- | Render zero or one debug message.  Visible-output tools are silent here:
-- their own output is already the progress users need.
renderToolDebug :: ToolDebugEvent -> Maybe Text
renderToolDebug = \case
  ToolCallsStarted calls ->
    let visible = [(name, args) | (name, args) <- calls, name `notElem` silentTools]
        line (name, args) = "⚙ " <> name <> " " <> previewValue debugPreviewChars args
     in case visible of
          [] -> Nothing
          _ -> Just (T.intercalate "\n" (map line visible))
  ToolCallFinished name result
    | name `elem` silentTools -> Nothing
    | otherwise ->
        Just $
          "↳ "
            <> name
            <> " "
            <> case result of
              Right value -> previewValue debugPreviewChars value
              Left err -> "✗ " <> err

silentTools :: [Text]
silentTools = ["send_image_from_sandbox", "send_file_from_sandbox"]

debugPreviewChars :: Int
debugPreviewChars = 1000

previewValue :: Int -> Value -> Text
previewValue n value =
  let collapsed = T.unwords . T.words . TE.decodeUtf8 . LBS.toStrict $ encode value
   in if T.length collapsed <= n
        then collapsed
        else T.take n collapsed <> "…"
