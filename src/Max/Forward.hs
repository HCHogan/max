module Max.Forward
  ( ForwardJob (..),
    enqueueForwards,
    forwardWorker,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (Array, Object, String))
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
import Max.DB.FetchQueue (JobKind (JobForward), enqueueJob)
import Max.DB.Forward (ForwardNodeInsert (..), insertForwardNode)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.FetchQueue (FetchSignal, notifyFetch, runFetchLoop)
import Max.Images (enqueueImagesFromNode)
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

-- Persisted in @fetch_jobs@, so this is a stored format rather than a
-- wire one: named fields, decodable by a binary that no longer writes
-- them the same way.
instance ToJSON ForwardJob where
  toJSON j =
    object
      [ "container_message_id" .= j.containerMessageId,
        "forward_id" .= j.forwardId,
        "group_id" .= j.groupId,
        "self_id" .= j.selfId
      ]

instance FromJSON ForwardJob where
  parseJSON = withObject "ForwardJob" $ \o ->
    ForwardJob
      <$> o .: "container_message_id"
      <*> o .: "forward_id"
      <*> o .: "group_id"
      <*> o .: "self_id"

-- | Enqueue every top-level forward chain in a real group message.
-- Nested forwards arrive inlined inside the @get_forward_msg@ response,
-- so we never enqueue more jobs from inside the worker.
enqueueForwards ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  GroupMessage ->
  Eff es ()
enqueueForwards sig gm = do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId sid = gm.selfId
      jobs = mapMaybe (mkJob mid gid sid) gm.message
  traverse_ enqueueOne jobs
  liftIO (notifyFetch sig)
  where
    -- The same chain can be forwarded into several messages, so the
    -- container is part of the key: each lands its own set of nodes.
    enqueueOne j =
      enqueueJob JobForward (T.pack (show j.containerMessageId) <> ":" <> j.forwardId) j

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

-- | One expansion is a single RPC plus a burst of inserts, so a batch
-- of a few keeps the round-trips down without holding leases long.
forwardLeaseSeconds :: Int
forwardLeaseSeconds = 300

forwardWorker ::
  (Log :> es, PlatformApi :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  Eff es ()
forwardWorker sig = localDomain "forward-worker" $ do
  logInfo_ "forward worker started"
  runFetchLoop sig JobForward forwardLeaseSeconds 4 (processJob sig)

processJob ::
  (Log :> es, PlatformApi :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  ForwardJob ->
  Eff es (Either Text ())
processJob sig job = do
  logInfo "forward expanding" $
    object
      [ "forward_id" .= job.forwardId,
        "container_message_id" .= job.containerMessageId
      ]
  eres <- callAction (GetForwardMsg job.forwardId) timeoutMs
  case eres of
    Left err ->
      pure (Left ("get_forward_msg failed (" <> job.forwardId <> "): " <> err))
    Right (Response _ rc _ _)
      | rc /= 0 ->
          -- Usually a chain QQ has since expired; the attempt budget
          -- turns that into a few retries and then a parked row.
          pure (Left ("get_forward_msg retcode " <> T.pack (show rc) <> " (" <> job.forwardId <> ")"))
    Right (Response _ _ payload _) ->
      case parseEither nodesParser payload of
        Left perr ->
          pure (Left ("forward response parse error (" <> job.forwardId <> "): " <> T.pack perr))
        Right nodes -> Right <$> ingestNodes sig job nodes
  where
    timeoutMs = 30000

ingestNodes ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  ForwardJob ->
  [ForwardNode] ->
  Eff es ()
ingestNodes sig job nodes =
  for_ (zip [0 ..] nodes) $ \(i, node) ->
    ingestNode sig job.containerMessageId job.groupId job.selfId 1 i node

ingestNode ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  Int64 -> -- containerSid
  Int64 -> -- groupId
  Int64 -> -- selfId
  Int -> -- depth (1-based)
  Int -> -- position
  ForwardNode ->
  Eff es ()
ingestNode sig containerSid gid sid depth pos node = do
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
  enqueueImagesFromNode sig insSid (Just gid) node.segments
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
        ingestNode sig insSid gid sid (depth + 1) i child

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
