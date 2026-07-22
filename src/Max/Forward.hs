module Max.Forward
  ( ForwardJob (..),
    ForwardQueue,
    newForwardQueue,
    enqueueForwards,
    forwardWorker,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.STM
  ( TQueue,
    atomically,
    newTQueueIO,
    readTQueue,
    writeTQueue,
  )
import Control.Exception (SomeException)
import Control.Monad (forever, unless)
import Data.Aeson (Value (Array, Object, String))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Object, Parser, parseEither, withObject, (.:), (.:?))
import Data.Foldable (for_, toList, traverse_)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Forward (ForwardNodeInsert (..), insertForwardNode)
import Max.Effects.NapCat (NapCat, callAction)
import Max.Images (ImageQueue, enqueueImagesFromNode)
import Max.Util (catchSync)
import OneBot.Action (Action (GetForwardMsg), Response (..))
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), parseIntId)

-- | Stop recursing inline content past this depth — sanity bound against
-- pathological NapCat responses. Anything deeper stays in jsonb.
maxDepth :: Int
maxDepth = 6

data ForwardJob = ForwardJob
  { containerMessageId :: !Int64,
    forwardId :: !Text,
    groupId :: !Int64,
    selfId :: !Int64
  }
  deriving stock (Show)

type ForwardQueue = TQueue ForwardJob

newForwardQueue :: IO ForwardQueue
newForwardQueue = newTQueueIO

-- | Enqueue every top-level forward chain in a real group message.
-- Nested forwards arrive inlined inside the @get_forward_msg@ response,
-- so we never enqueue more jobs from inside the worker.
enqueueForwards :: ForwardQueue -> GroupMessage -> IO ()
enqueueForwards q gm = do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId sid = gm.selfId
      jobs = mapMaybe (mkJob mid gid sid) gm.message
  atomically $ traverse_ (writeTQueue q) jobs

mkJob :: Int64 -> Int64 -> Int64 -> Segment -> Maybe ForwardJob
mkJob container gid sid = \case
  SegOther "forward" v -> do
    fid <- forwardIdFromValue v
    Just (ForwardJob container fid gid sid)
  _ -> Nothing

forwardIdFromValue :: Value -> Maybe Text
forwardIdFromValue (Object o) = case KM.lookup (K.fromText "id") o of
  Just (String s) | not (T.null s) -> Just s
  _ -> Nothing
forwardIdFromValue _ = Nothing

forwardWorker ::
  (Log :> es, NapCat :> es, WithConnection :> es, IOE :> es) =>
  ImageQueue ->
  ForwardQueue ->
  Eff es ()
forwardWorker imgQ q = localDomain "forward-worker" $ do
  logInfo_ "forward worker started"
  forever $ do
    job <- liftIO (atomically (readTQueue q))
    logInfo "forward expanding" $
      object
        [ "forward_id" .= job.forwardId,
          "container_message_id" .= job.containerMessageId
        ]
    processJob imgQ job
      `catchSync` \e ->
        logAttention "forward worker crash" $
          object
            [ "error" .= T.pack (show (e :: SomeException)),
              "forward_id" .= job.forwardId,
              "container_message_id" .= job.containerMessageId
            ]

processJob ::
  (Log :> es, NapCat :> es, WithConnection :> es, IOE :> es) =>
  ImageQueue ->
  ForwardJob ->
  Eff es ()
processJob imgQ job = do
  eres <- callAction (GetForwardMsg job.forwardId) timeoutMs
  case eres of
    Left err ->
      logAttention "get_forward_msg failed" $
        object ["error" .= err, "forward_id" .= job.forwardId]
    Right (Response _ rc _ _) | rc /= 0 ->
      logAttention "get_forward_msg bad retcode" $
        object ["retcode" .= rc, "forward_id" .= job.forwardId]
    Right (Response _ _ payload _) ->
      case parseEither nodesParser payload of
        Left perr ->
          logAttention "forward response parse error" $
            object ["error" .= T.pack perr, "forward_id" .= job.forwardId]
        Right nodes -> ingestNodes imgQ job nodes
  where
    timeoutMs = 30000

ingestNodes ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  ImageQueue ->
  ForwardJob ->
  [ForwardNode] ->
  Eff es ()
ingestNodes imgQ job nodes =
  for_ (zip [0 ..] nodes) $ \(i, node) ->
    ingestNode imgQ job.containerMessageId job.groupId job.selfId 1 i node

ingestNode ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  ImageQueue ->
  Int64 -> -- containerSid
  Int64 -> -- groupId
  Int64 -> -- selfId
  Int -> -- depth (1-based)
  Int -> -- position
  ForwardNode ->
  Eff es ()
ingestNode imgQ containerSid gid sid depth pos node = do
  let ins =
        ForwardNodeInsert
          { containerMessageId = containerSid,
            groupId = gid,
            selfId = sid,
            position = pos,
            senderUserId = node.userId,
            senderNickname = node.nickname,
            originalMessageId = node.originalId,
            originalSentAt = node.time,
            segments = node.segments
          }
  insSid <- insertForwardNode ins
  liftIO (enqueueImagesFromNode imgQ insSid (Just gid) node.segments)
  let inlineChildren = concatMap extractInlineNodes node.segments
  logInfo "forward node ingested" $
    object
      [ "container_message_id" .= containerSid,
        "synthetic_message_id" .= insSid,
        "position" .= pos,
        "depth" .= depth,
        "sender_user_id" .= node.userId,
        "inline_nested" .= length inlineChildren
      ]
  if depth >= maxDepth
    then
      unless (null inlineChildren) $
        logInfo "inline nested forwards skipped (max depth)" $
          object
            [ "depth" .= depth,
              "skipped" .= length inlineChildren,
              "synthetic_message_id" .= insSid
            ]
    else
      for_ (zip [0 ..] inlineChildren) $ \(i, child) ->
        ingestNode imgQ insSid gid sid (depth + 1) i child

-- | Pull nested-forward children inlined in a @forward@ segment's
-- @data.content@ (NapCat-style; whole tree comes in one @get_forward_msg@
-- response rather than per-id RPCs).
extractInlineNodes :: Segment -> [ForwardNode]
extractInlineNodes (SegOther "forward" (Object o)) =
  case KM.lookup (K.fromText "content") o of
    Just (Array arr) ->
      let parsedEach = map (parseEither nodeParser) (toList arr)
       in [n | Right n <- parsedEach]
    _ -> []
extractInlineNodes _ = []

data ForwardNode = ForwardNode
  { userId :: !Int64,
    nickname :: !Text,
    time :: !(Maybe Int64),
    originalId :: !(Maybe Int64),
    segments :: ![Segment]
  }
  deriving stock (Show)

nodesParser :: Value -> Parser [ForwardNode]
nodesParser = withObject "ForwardResponse" $ \o -> do
  ms <- o .: "messages" :: Parser [Value]
  traverse nodeParser ms

nodeParser :: Value -> Parser ForwardNode
nodeParser = withObject "ForwardNode" $ \o -> do
  uid <- o .: "user_id" >>= parseIntId "user_id"
  mTop <- o .:? "nickname"
  mSender <- o .:? "sender" :: Parser (Maybe Object)
  let senderNick = mSender >>= lookupStringIn "nickname"
      nick = fromMaybe "" (mTop <|> senderNick)
  t <- o .:? "time"
  oid <- o .:? "message_id"
  segs <- (o .: "message") <|> (o .: "content") <|> pure []
  pure
    ForwardNode
      { userId = uid,
        nickname = nick,
        time = t,
        originalId = oid,
        segments = segs
      }

lookupStringIn :: Text -> Object -> Maybe Text
lookupStringIn k o = case KM.lookup (K.fromText k) o of
  Just (String s) -> Just s
  _ -> Nothing
