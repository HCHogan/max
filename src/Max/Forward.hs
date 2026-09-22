module Max.Forward
  ( ForwardJob (..),
    enqueueForwards,
    forwardWorker,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless)
import Data.Aeson (ToJSON (..), Value (Array, Object, String))
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
import Max.DB.MediaMissing (forwardExpanded, recordForwardExpansion)
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.PlatformQuery (PlatformQuery, queryForward)
import Max.FetchQueue (FetchPriority (..), FetchSignal, ForwardJob (..), JobKind (JobForward), enqueueFetch, notifyFetch, runFetchLoop)
import Max.IR (Body (..), ForwardRef (..), Node (NForward))
import Max.IR.Digest (digest)
import Max.Images (enqueueImages)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (Backfill))
import Max.Platform.Failure (renderPlatformFailure)
import Max.Platform.QQ (ensureQQEndpointFor, qqIngestBody)
import Max.Platform.Store.Endpoint (RegisteredEndpoint (..))
import Max.Platform.Store.Ingest
  ( IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    defaultIngestOptions,
    ingestEnvelope,
    loadDispatchMessage,
  )
import Max.Platform.Store.Relation
  ( compatibilityMessageIdForCanonical,
    nativeEventIdForCanonical,
  )
import Max.Platform.Types
  ( CanonicalMessageId (..),
    EventKind (EventMessage),
    MessageRelation (ContainedIn),
    NativeEventId (..),
    NativeUserId (..),
  )
import Max.Util (tshow)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), UserId (..), parseIntId)

-- | Stop recursing inline content past this depth — sanity bound against
-- pathological NapCat responses. Anything deeper stays in jsonb.
maxDepth :: Int
maxDepth = 6

-- | Enqueue every top-level canonical forward chain.
-- Nested forwards arrive inlined inside the @get_forward_msg@ response,
-- so we never enqueue more jobs from inside the worker.
enqueueForwards ::
  (IOE :> es) =>
  FetchPriority ->
  FetchSignal ->
  DispatchMessage ->
  Eff es ()
enqueueForwards priority sig gm = do
  let CanonicalMessageId mid = gm.canonicalId
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
      enqueueFetch sig priority JobForward (tshow j.containerMessageId <> ":" <> j.forwardId) j

forwardWorker ::
  (Log :> es, PlatformQuery :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  Eff es ()
forwardWorker sig = localDomain "forward-worker" $ do
  logInfo_ "forward worker started"
  runFetchLoop sig JobForward (processJob sig)

processJob ::
  (Log :> es, PlatformQuery :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  ForwardJob ->
  Eff es (Either Text ())
processJob sig job = do
  done <- forwardExpanded job
  if done then pure (Right ()) else expandForward sig job

expandForward :: (Log :> es, PlatformQuery :> es, WithConnection :> es, IOE :> es) => FetchSignal -> ForwardJob -> Eff es (Either Text ())
expandForward sig job = do
  logInfo "forward expanding" $
    object
      [ "forward_id" .= job.forwardId,
        "container_message_id" .= job.containerMessageId
      ]
  eres <- queryForward job.forwardId
  case eres of
    Left err ->
      pure (Left ("get_forward_msg failed (" <> job.forwardId <> "): " <> renderPlatformFailure err))
    Right payload ->
      case parseEither nodesParser payload of
        Left perr ->
          pure (Left ("forward response parse error (" <> job.forwardId <> "): " <> T.pack perr))
        Right nodes -> do
          endpoint <- ensureQQEndpointFor (UserId job.selfId) (GroupId job.groupId)
          received <- liftIO getCurrentTime
          ingestNodes sig endpoint received job nodes
          recordForwardExpansion job (length nodes)
          pure (Right ())

ingestNodes ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  FetchSignal ->
  RegisteredEndpoint ->
  UTCTime ->
  ForwardJob ->
  [ForwardNode] ->
  Eff es ()
ingestNodes sig endpoint received job nodes = do
  -- Relations use native IDs; the queue identifies the canonical container.
  NativeEventId containerNative <- nativeEventIdForCanonical (CanonicalMessageId job.containerMessageId)
  for_ (zip [0 ..] nodes) $ \(i, node) ->
    ingestNode sig endpoint received job containerNative 1 [i] i node

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
          <> tshow job.containerMessageId
          <> ":"
          <> job.forwardId
          <> ":"
          <> T.intercalate "." (tshow <$> path)
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
            senderNativeId = NativeUserId (tshow node.userId),
            senderDisplayName = if T.null node.nickname then Nothing else Just node.nickname,
            occurredAt = occurred,
            receivedAt = received,
            eventKind = EventMessage,
            ingestClass = Backfill,
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
  -- Use canonical node positions for media attachment keys.
  message <- loadDispatchMessage canonical
  for_ message (enqueueImages LiveFetch sig)
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
    EchoUnmatched -> pure ()
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
  -- Forward expansion always publishes; it never offers a node as
  -- reconcile-only echo evidence, which is the sole source of this answer.
  EchoUnmatched -> error "forward node ingest returned no canonical message"

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
