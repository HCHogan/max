-- | Production interpreter for agent output events. This boundary owns
-- presentation, reply budgets and canonical publication.
module Max.AgentOutput (AgentOutputContext (..), handleAgentEvent) where

import Control.Concurrent.STM (TVar, atomically, readTVarIO, writeTVar)
import Control.Monad (void, when)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Exception (throwIO)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.AgentEvent (AgentEvent (..), ToolDebugEvent (..))
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), sendRecorded)
import Max.IR (Body (..), Node (NText))
import Max.MessageKind (MessageKind (KindDebug))
import Max.Platform.Types (CanonicalMessageId)
import Max.ReplySend (ReplyPublication (..), ReplyPublicationException (..), ReplyTarget (..), SendBudget, canStream, freshBudget, sendAndPersistReply)
import Max.Turn.Types (nextTurnOutputLink)

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
        publication <- sendAndPersistReply ctx.aocReplyTarget budget body
        liftIO (atomically (writeTVar ctx.aocStreamBudget publication.budget))
        case publication.failure of
          Nothing -> pure True
          Just err -> throwIO (ReplyPublicationException err)
  where
    sendDebug :: Text -> Eff es ()
    sendDebug body = do
      turnOutput <- traverse (liftIO . nextTurnOutputLink) ctx.aocReplyTarget.rtTurnOutputContext
      void $
        sendRecorded
          OutboundRequest
            { orKind = KindDebug,
              orGroupId = ctx.aocReplyTarget.rtGroupId,
              orBody = Body [NText body],
              orReplyTo = Nothing,
              orDeliveryScope = DeliverSourceEndpoint ctx.aocSourceMessageId,
              orTurnOutput = turnOutput,
              orMonitorFireId = Nothing
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
