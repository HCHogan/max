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
    TVar,
    atomically,
    newTQueueIO,
    readTQueue,
    readTVarIO,
    writeTQueue,
  )
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, throwIO)
import Control.Monad (forM_, forever)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Data.Aeson (Value (Object, String))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither, withObject, (.!=), (.:), (.:?))
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Log
import Max.DB.Connection (DbPool)
import Max.DB.Forward (ForwardNodeInsert (..), insertForwardNode)
import Max.Images (ImageQueue, enqueueImagesFromNode)
import OneBot.Action (Action (GetForwardMsg), Response (..))
import OneBot.Event (GroupMessage (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), parseIntId)
import OneBot.Server (Client, call)

-- | Maximum recursion depth for nested forwards. Anything deeper is left
-- as @[forward (deep, not expanded)]@ in the parent's jsonb so the loop
-- can't run away if NapCat returns pathological data.
maxDepth :: Int
maxDepth = 3

-- | One forward chain awaiting expansion via @get_forward_msg@.
data ForwardJob = ForwardJob
  { -- | The row this forward segment is contained in.
    containerMessageId :: !Int64,
    -- | NapCat's opaque forward id (from @forward@ segment's @data.id@).
    forwardId :: !Text,
    -- | 1-based depth; the top-level forward inside a real message is 1.
    depth :: !Int,
    groupId :: !Int64,
    selfId :: !Int64
  }
  deriving stock (Show)

type ForwardQueue = TQueue ForwardJob

newForwardQueue :: IO ForwardQueue
newForwardQueue = newTQueueIO

-- | Walk segments of a real group message and enqueue every top-level
-- forward chain (depth=1). Nested forwards are discovered later when the
-- worker parses each chain.
enqueueForwards :: ForwardQueue -> GroupMessage -> IO ()
enqueueForwards q gm = do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId sid = gm.selfId
      jobs = mapMaybe (mkJob mid gid sid 1) gm.message
  atomically $ mapM_ (writeTQueue q) jobs

mkJob :: Int64 -> Int64 -> Int64 -> Int -> Segment -> Maybe ForwardJob
mkJob container gid sid d = \case
  SegOther "forward" v -> do
    fid <- forwardIdFromValue v
    Just (ForwardJob container fid d gid sid)
  _ -> Nothing

forwardIdFromValue :: Value -> Maybe Text
forwardIdFromValue (Object o) = case KM.lookup (K.fromText "id") o of
  Just (String s) | not (T.null s) -> Just s
  _ -> Nothing
forwardIdFromValue _ = Nothing

-- | Long-lived worker. Reads jobs, calls @get_forward_msg@ via the
-- currently-published 'Client', flattens nodes into 'messages', and
-- enqueues nested forwards and image segments discovered along the way.
forwardWorker ::
  TVar (Maybe Client) ->
  DbPool ->
  ImageQueue ->
  ForwardQueue ->
  LogT IO ()
forwardWorker clientRef pool imgQ q = forever $ do
  job <- liftIO (atomically (readTQueue q))
  processJob clientRef pool imgQ q job
    `catchSync` \e ->
      logAttention "forward worker crash" $
        object
          [ "error" .= T.pack (show e),
            "forward_id" .= job.forwardId,
            "container_message_id" .= job.containerMessageId
          ]

processJob ::
  TVar (Maybe Client) ->
  DbPool ->
  ImageQueue ->
  ForwardQueue ->
  ForwardJob ->
  LogT IO ()
processJob clientRef pool imgQ fwdQ job
  | job.depth > maxDepth = do
      logInfo "forward depth exceeded" $
        object ["depth" .= job.depth, "forward_id" .= job.forwardId]
  | otherwise = do
      mc <- liftIO (readTVarIO clientRef)
      case mc of
        Nothing ->
          logAttention "forward: no client connected" $
            object ["forward_id" .= job.forwardId]
        Just client -> do
          eres <- liftIO (call client (GetForwardMsg job.forwardId) timeoutMs)
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
                Right nodes -> ingestNodes pool imgQ fwdQ job nodes
  where
    timeoutMs = 30000

ingestNodes ::
  DbPool ->
  ImageQueue ->
  ForwardQueue ->
  ForwardJob ->
  [ForwardNode] ->
  LogT IO ()
ingestNodes pool imgQ fwdQ job nodes =
  forM_ (zip [0 ..] nodes) $ \(i, node) -> do
    let ins =
          ForwardNodeInsert
            { containerMessageId = job.containerMessageId,
              groupId = job.groupId,
              selfId = job.selfId,
              position = i,
              senderUserId = node.userId,
              senderNickname = node.nickname,
              originalMessageId = node.originalId,
              originalSentAt = node.time,
              segments = node.segments
            }
    sid <- liftIO (insertForwardNode pool ins)
    -- Recurse into nested forwards under this synthetic id.
    let nested = mapMaybe (mkJob sid job.groupId job.selfId (job.depth + 1)) node.segments
    liftIO $ atomically $ mapM_ (writeTQueue fwdQ) nested
    -- And feed image / mface segments to the image worker against this
    -- synthetic id (so message_images links to the right row).
    liftIO $ enqueueImagesFromNode imgQ sid node.segments
    logTrace "forward node ingested" $
      object
        [ "container_message_id" .= job.containerMessageId,
          "synthetic_message_id" .= sid,
          "position" .= i,
          "nested_forwards" .= length nested
        ]

-- | Parsed shape of one entry in @get_forward_msg@'s @messages@ array.
data ForwardNode = ForwardNode
  { userId :: !Int64,
    nickname :: !Text,
    -- | Unix seconds when the forwarded message was originally sent.
    time :: !(Maybe Int64),
    originalId :: !(Maybe Int64),
    segments :: ![Segment]
  }
  deriving stock (Show)

nodesParser :: Value -> Parser [ForwardNode]
nodesParser = withObject "ForwardResponse" $ \o -> do
  ms <- o .: "messages" :: Parser [Value]
  mapM (parseEitherToP nodeParser) ms
  where
    parseEitherToP :: (Value -> Parser a) -> Value -> Parser a
    parseEitherToP p v = p v

nodeParser :: Value -> Parser ForwardNode
nodeParser = withObject "ForwardNode" $ \o -> do
  uid <- o .: "user_id" >>= parseIntId "user_id"
  nick <- o .:? "nickname" .!= ""
  t <- o .:? "time"
  oid <- o .:? "message_id"
  -- NapCat uses @message@; OneBot v11 legacy sometimes uses @content@.
  segs <- (o .: "message") <|> (o .: "content") <|> pure []
  pure
    ForwardNode
      { userId = uid,
        nickname = nick,
        time = t,
        originalId = oid,
        segments = segs
      }

catchSync :: LogT IO a -> (SomeException -> LogT IO a) -> LogT IO a
catchSync act h = withRunInIO $ \run ->
  run act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> run (h e)
