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
import Data.Either (rights)
import Data.Foldable (for_, toList, traverse_)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.FetchQueue (JobKind (JobForward), enqueueJob)
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.FetchQueue (FetchSignal, notifyFetch, runFetchLoop)
import Max.Images (enqueueImagesFromNode)
import Max.IR (Body (..), ForwardRef (..), Node (NForward))
import Max.IR.Digest (digest)
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.QQ (ensureQQEndpointFor, qqIngestBody)
import Max.Platform.Store
  ( IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    RegisteredEndpoint (..),
    compatibilityMessageIdForCanonical,
    defaultIngestOptions,
    ingestEnvelope,
  )
import Max.Platform.Types
  ( CanonicalMessageId,
    EventKind (EventMessage),
    MessageRelation (ContainedIn),
    NativeEventId (..),
    NativeUserId (..),
  )
import OneBot.Action (Action (GetForwardMsg), Response (..))
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

-- | Enqueue every top-level canonical forward chain.
-- Nested forwards arrive inlined inside the @get_forward_msg@ response,
-- so we never enqueue more jobs from inside the worker.
enqueueForwards ::
  (WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueForwards sig gm = do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId sid = gm.selfId
      jobs =
        [ ForwardJob mid forward.nativeId gid sid
        | NForward forward <- gm.body.nodes
        ]
  traverse_ enqueueOne jobs
  liftIO (notifyFetch sig)
  where
    -- The same chain can be forwarded into several messages, so the
    -- container is part of the key: each lands its own set of nodes.
    enqueueOne j =
      enqueueJob JobForward (T.pack (show j.containerMessageId) <> ":" <> j.forwardId) j

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
        Right nodes -> do
          endpoint <- ensureQQEndpointFor (UserId job.selfId) (GroupId job.groupId)
          received <- liftIO getCurrentTime
          Right <$> ingestNodes sig endpoint received job nodes
  where
    timeoutMs = 30000

ingestNodes ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  RegisteredEndpoint ->
  UTCTime ->
  ForwardJob ->
  [ForwardNode] ->
  Eff es ()
ingestNodes sig endpoint received job nodes =
  for_ (zip [0 ..] nodes) $ \(i, node) ->
    ingestNode sig endpoint received job (decimal job.containerMessageId) 1 [i] i node

ingestNode ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  RegisteredEndpoint ->
  UTCTime ->
  ForwardJob ->
  Text -> -- parent native event id
  Int -> -- depth (1-based)
  [Int] -> -- stable path from the top-level forward marker
  Int -> -- position
  ForwardNode ->
  Eff es ()
ingestNode sig endpoint received job parentNative depth path pos node = do
  let childNative =
        "forward:"
          <> decimal job.containerMessageId
          <> ":"
          <> job.forwardId
          <> ":"
          <> T.intercalate "." (decimal <$> path)
      occurred = maybe received (posixSecondsToUTCTime . fromIntegral) node.time
      raw =
        object
          [ "forward_id" .= job.forwardId,
            "path" .= path,
            "user_id" .= node.userId,
            "nickname" .= node.nickname,
            "time" .= node.time,
            "message_id" .= node.originalId,
            "message" .= node.segments
          ]
      envelope =
        InboundEnvelope
          { endpointId = endpoint.endpointId,
            nativeEventId = NativeEventId childNative,
            senderNativeId = NativeUserId (decimal node.userId),
            senderDisplayName = if T.null node.nickname then Nothing else Just node.nickname,
            occurredAt = occurred,
            receivedAt = received,
            eventKind = EventMessage,
            content = qqIngestBody node.segments,
            relations = [ContainedIn (NativeEventId parentNative) pos],
            sourceCursor = Nothing,
            rawPayload = Just raw
          }
      options =
        defaultIngestOptions
          { createDispatch = False,
            createMirrorDeliveries = False,
            transcriptKind = "chat",
            qqProvenanceSegments = Just (toJSON node.segments)
          }
  ingestResult <- ingestEnvelope options envelope
  let canonical = canonicalFromResult ingestResult
  compatibilityId <- compatibilityMessageIdForCanonical canonical
  enqueueImagesFromNode sig compatibilityId (Just job.groupId) node.segments
  let inlineChildren = concatMap extractInlineNodes node.segments
  case ingestResult of
    Ingested fresh ->
      logInfo "forward node ingested" $
        object
          [ "container_message_id" .= job.containerMessageId,
            "canonical_message_id" .= canonical,
            "compatibility_message_id" .= compatibilityId,
            "position" .= pos,
            "depth" .= depth,
            "sender_user_id" .= node.userId,
            "inline_nested" .= length inlineChildren,
            "content" .= digest fresh.canonicalBody
          ]
    AlreadyIngested {} -> pure ()
    DeliveryEcho {} -> pure ()
  if depth >= maxDepth
    then
      unless (null inlineChildren) $
        logInfo "inline nested forwards skipped (max depth)" $
          object
            [ "depth" .= depth,
              "skipped" .= length inlineChildren,
              "canonical_message_id" .= canonical
            ]
    else for_ (zip [0 ..] inlineChildren) $ \(i, child) ->
      ingestNode sig endpoint received job childNative (depth + 1) (path <> [i]) i child

canonicalFromResult :: IngestResult -> CanonicalMessageId
canonicalFromResult = \case
  Ingested fresh -> fresh.canonicalMessageId
  AlreadyIngested canonical -> canonical
  DeliveryEcho canonical -> canonical

-- | Pull nested-forward children inlined in a @forward@ segment's
-- @data.content@ (NapCat-style; whole tree comes in one @get_forward_msg@
-- response rather than per-id RPCs).
extractInlineNodes :: Segment -> [ForwardNode]
extractInlineNodes (SegOther "forward" (Object o)) =
  case KM.lookup (K.fromText "content") o of
    Just (Array arr) ->
      let parsedEach = map (parseEither nodeParser) (toList arr)
       in rights parsedEach
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

decimal :: Show a => a -> Text
decimal = T.pack . show
