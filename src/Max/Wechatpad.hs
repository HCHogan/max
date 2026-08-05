-- |
-- WeChat backend over a WeChatPadPro relay.  Inbound frames enter the same
-- canonical envelope pipeline as every other adapter; outbound receives only
-- text nodes already lowered for this endpoint's honest text-only caps.
--
-- Protocol (verified against nekro-agent's adapter and the
-- WeChatPadPro API):
--
--   * inbound: WebSocket @ws://{host}/ws/GetSyncMsg?key={auth}@,
--     one JSON frame per message: @msg_id, from_user_name{str},
--     to_user_name{str}, msg_type, content{str}, create_time,
--     push_content, new_msg_id@.  Chatroom messages arrive with
--     @from_user_name = xxx\@chatroom@ and the sender prefixed into
--     the content as @wxid:\\ncontent@.
--   * outbound: POST @{base}/message/SendTextMessage?key={auth}@
--     with @{"MsgItem":[{"MsgType":1,"TextContent":…,"ToUserName":…}]}@;
--     @Code == 200@ in the envelope means accepted.
--
-- Ids are folded into max's bigint compatibility world only at the edge.
--
-- 已知风险：iPad 协议逆向，封号风险自担（跑小号）。
module Max.Wechatpad
  ( WechatpadConfig (..),
    wechatpadBackend,
    wechatpadWorker,
    parseFrameIds,
    platformName,
    wechatpadCapabilities,
    wechatInboundBody,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forever, unless)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger, toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.PlatformIds qualified as PlatformIds
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
  )
import Max.Platform (PlatformBackend (..))
import Max.IR
import Max.IR.Digest (digest)
import Max.IR.Lower (OutboundCaps, textOnlyCaps)
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.Store
  ( IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    RegisteredEndpoint (..),
    defaultIngestOptions,
    ensureConfiguredEndpoint,
    ingestEnvelope,
  )
import Max.Platform.Types
  ( ConversationKind (ConversationGroup),
    EndpointMode (EndpointStandalone),
    EventKind (EventMessage),
    NativeAccountId (..),
    NativeConversationId (..),
    NativeEventId (..),
    NativeUserId (..),
    Platform (PlatformWeChatPad),
  )
import Max.Util (catchSync)
import Network.HTTP.Client qualified as HTTP
import Network.WebSockets qualified as WS
import OneBot.Action (Action (..), Response (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), UserId (..))

platformName :: Text
platformName = "wechatpad"

-- | The relay's outbound contract is deliberately text-only. Every other
-- canonical node is folded by the shared lowerer before the OneBot-shaped
-- transport shim reaches this backend.
wechatpadCapabilities :: OutboundCaps
wechatpadCapabilities = textOnlyCaps

data WechatpadConfig = WechatpadConfig
  { -- | WeChatPadPro base URL, e.g. @http://127.0.0.1:8080@.  The WS
    -- endpoint is derived from it (demo assumes plain ws — run the
    -- relay locally).
    wpApiUrl :: !Text,
    wpAuthKey :: !Text,
    -- | The bot account's own wxid.
    wpSelfWxid :: !Text,
    -- | Display name used for \@-detection in group texts.
    wpBotName :: !Text,
    -- | Chatroom whitelist (@xxx\@chatroom@ ids); everything else is
    -- ignored.  DMs are ignored entirely in the demo.
    wpChatrooms :: ![Text]
  }
  deriving stock (Show)

--------------------------------------------------------------------------------
-- Outbound backend.

-- | Build the outbound backend.  Runs its two DB lookups through the
-- effect runner the caller provides (Main closes it over the pool).
wechatpadBackend ::
  HttpRuntime ->
  (forall a. Eff '[WithConnection, IOE] a -> IO a) ->
  WechatpadConfig ->
  PlatformBackend
wechatpadBackend runtime runDb cfg =
  PlatformBackend
    { pbPlatform = platformName,
      pbName = platformName,
      pbSend = sendOut,
      pbCall = \a _timeoutMs ->
        sendOut a >>= \case
          Left err -> pure (Left err)
          Right () ->
            pure . Right $
              Response
                { status = "ok",
                  retcode = 0,
                  -- The relay acknowledges a send without returning any
                  -- identifier for it.  Reporting no @message_id@ is the
                  -- honest answer: the delivery parks as accepted-unconfirmed
                  -- until the bot's own message comes back on the sync stream
                  -- carrying WeChat's real id ('wechatpadWorker').  A
                  -- synthesised receipt would be worse than none — it is
                  -- indistinguishable from a real native id to every reply
                  -- and reaction that later resolves a target, and derived
                  -- from the text it collides across identical messages.
                  payload = object [],
                  echo = ""
                }
    }
  where
    sendOut :: Action -> IO (Either Text ())
    sendOut = \case
      SendGroupMsg (GroupId g) segs -> deliver "channel" g segs
      SendPrivateMsg (UserId u) segs -> deliver "user" u segs
      other -> pure (Left ("wechatpad: unsupported action: " <> T.take 60 (T.pack (show other))))

    deliver kind mapped segs = do
      mNative <- runDb (PlatformIds.nativeId platformName kind mapped)
      case mNative of
        Nothing -> pure (Left ("wechatpad: no native id for " <> T.pack (show mapped)))
        Just to -> do
          case wireText segs of
            Left err -> pure (Left err)
            Right body
              | T.null (T.strip body) -> pure (Right ())
              | otherwise -> postText runtime cfg to body

-- | Protocol emission only.  Any non-text segment is a violated lowering
-- contract, never an invitation for an adapter-local fallback.
wireText :: [Segment] -> Either Text Text
wireText = fmap T.concat . traverse go
  where
    go = \case
      SegText t -> Right t
      other -> Left ("wechatpad: lowering emitted non-text segment: " <> T.take 60 (T.pack (show other)))

postText :: HttpRuntime -> WechatpadConfig -> Text -> Text -> IO (Either Text ())
postText runtime cfg to content = do
  requestResult <-
    parseRequestEither (T.unpack (cfg.wpApiUrl <> "/message/SendTextMessage?key=" <> cfg.wpAuthKey))
  let payload =
        object
          [ "MsgItem"
              .= [ object
                     [ "MsgType" .= (1 :: Int),
                       "TextContent" .= content,
                       "ToUserName" .= to
                     ]
                 ]
          ]
  case requestResult of
    Left failure -> pure (Left ("wechatpad: " <> renderTransportFailure failure))
    Right request0 -> do
      let request =
            request0
              { HTTP.method = "POST",
                HTTP.requestBody = HTTP.RequestBodyLBS (encode payload),
                HTTP.requestHeaders = [("Content-Type", "application/json")]
              }
      runBuffered runtime StandardPool maxWechatpadResponseBytes statusPreviewBytes request >>= \case
        Left (HttpStatusFailure code _ responsePreview _) ->
          pure . Left $
            "wechatpad: HTTP "
              <> T.pack (show code)
              <> ": "
              <> T.take 300 (TE.decodeUtf8Lenient responsePreview)
        Left failure -> pure (Left ("wechatpad: " <> renderTransportFailure failure))
        Right response ->
          pure $ case decodeStrict' response.body >>= parseMaybe envelopeCode of
            Just 200 -> Right ()
            Just code -> Left ("wechatpad: API code " <> T.pack (show code))
            Nothing -> Left "wechatpad: unparseable API response"
  where
    envelopeCode = withObject "envelope" (.: "Code") :: Value -> Parser Int

maxWechatpadResponseBytes :: Int
maxWechatpadResponseBytes = 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 1024

--------------------------------------------------------------------------------
-- Inbound worker.

-- | Long-lived WS listener.  Every allowlisted room is registered as a
-- canonical endpoint before ingress opens; frames publish an 'InboundEnvelope'
-- and atomically create dispatch/mirror work in 'ingestEnvelope'.
wechatpadWorker ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  WechatpadConfig ->
  Eff es ()
wechatpadWorker cfg = localDomain "wechatpad" $ do
  logInfo "wechatpad worker started" $ object ["chatrooms" .= cfg.wpChatrooms]
  endpoints <- Map.fromList <$> forM cfg.wpChatrooms registerRoom
  forever $ do
    listenOnce endpoints `catchSync` \e ->
      logAttention "wechatpad: connection lost, retrying in 5s" $
        object ["error" .= T.pack (show e)]
    liftIO (threadDelay 5_000_000)
  where
    (host, port) = parseHostPort cfg.wpApiUrl
    wsPath = "/ws/GetSyncMsg?key=" <> T.unpack cfg.wpAuthKey

    registerRoom room = do
      legacy <- PlatformIds.mappedId platformName "channel" room
      endpoint <-
        ensureConfiguredEndpoint
          PlatformWeChatPad
          (NativeAccountId cfg.wpSelfWxid)
          (NativeConversationId room)
          ConversationGroup
          EndpointStandalone
          (Just legacy)
          wechatpadCapabilities
      pure (room, endpoint)

    listenOnce endpoints =
      withRunInIO $ \unlift ->
        WS.runClient host port wsPath $ \conn -> forever $ do
          raw <- WS.receiveData conn
          unlift (handleFrame endpoints raw)

    handleFrame endpoints raw =
      case decodeStrictText raw of
        Nothing -> pure ()
        Just frame -> for_ (parseMaybe frameParser frame) (translate endpoints frame)

    translate endpoints frame wm
      | not ("@chatroom" `T.isSuffixOf` wm.wmFrom) = pure ()
      | Nothing <- Map.lookup wm.wmFrom endpoints = pure ()
      | otherwise = do
          let (parsedSender, body0) = splitSender wm.wmContent
              senderWxid = if T.null parsedSender then wm.wmFrom else parsedSender
              -- The relay hands the bot's own messages back on the sync
              -- stream, and that echo is the only receipt WeChat ever gives:
              -- it carries the real native id the send call withheld.  Offer
              -- it as reconciliation evidence instead of discarding it, but
              -- never let it become a second copy of a message max already
              -- authored.
              selfEcho = senderWxid == cfg.wpSelfWxid
          received <- liftIO getCurrentTime
          let endpoint = endpoints Map.! wm.wmFrom
              nativeEvent = if wm.wmNewMsgId == 0 then wm.wmMsgId else T.pack (show wm.wmNewMsgId)
              content = wechatInboundBody cfg.wpSelfWxid cfg.wpBotName wm.wmMsgType body0
              options = defaultIngestOptions {reconcileEchoOnly = selfEcho}
              envelope =
                InboundEnvelope
                  { endpointId = endpoint.endpointId,
                    nativeEventId = NativeEventId nativeEvent,
                    senderNativeId = NativeUserId senderWxid,
                    senderDisplayName = pushNick wm.wmPushContent,
                    occurredAt =
                      if wm.wmCreateTime > 0
                        then posixSecondsToUTCTime (fromIntegral wm.wmCreateTime)
                        else received,
                    receivedAt = received,
                    eventKind = EventMessage,
                    content,
                    relations = [],
                    sourceCursor = Nothing,
                    rawPayload = Just frame
                  }
          unless selfEcho $
            logInfo "wechat message" $
              object
                [ "chatroom" .= wm.wmFrom,
                  "sender" .= senderWxid,
                  "len" .= T.length body0,
                  "create_time" .= wm.wmCreateTime
                ]
          ingestEnvelope options envelope >>= \case
            Ingested fresh ->
              logInfo "wechat event ingested" $
                object
                  [ "native_event_id" .= nativeEvent,
                    "canonical_message_id" .= fresh.canonicalMessageId,
                    "content" .= digest fresh.canonicalBody
                  ]
            AlreadyIngested {} -> pure ()
            DeliveryEcho canonical ->
              logInfo "wechat delivery confirmed by echo" $
                object
                  [ "native_event_id" .= nativeEvent,
                    "canonical_message_id" .= canonical
                  ]
            -- Every send whose echo does not match a delivery leaves that
            -- delivery accepted-unconfirmed: two identical texts in flight
            -- are deliberately ambiguous, and a mirror copy carries an
            -- attribution prefix the canonical body does not.
            EchoUnmatched ->
              logInfo "wechat self echo matched no delivery" $
                object ["native_event_id" .= nativeEvent, "len" .= T.length body0]

-- | Chatroom frames carry the sender folded into the content as
-- @wxid:\\ntext@; a frame without that shape belongs to the room
-- itself (system notices) and maps to an empty sender.
splitSender :: Text -> (Text, Text)
splitSender c = case T.breakOn ":\n" c of
  (w, rest)
    | not (T.null rest),
      not (T.any (`elem` (" \n" :: String)) w) ->
        (w, T.drop 2 rest)
  _ -> ("", c)

-- | Preserve the order of text and the only mention whose authenticated
-- native identity this adapter knows: the bot itself.  Other visible @names
-- remain text rather than being guessed into identities.
wechatBody :: Text -> Text -> Text -> Body 'Ingest
wechatBody selfWxid botName = Body . mergeText . go
  where
    token = "@" <> botName
    go input = case T.breakOn token input of
      (before, rest)
        | T.null rest -> [NText before | not (T.null before)]
        | otherwise ->
            [NText before | not (T.null before)]
              <> [NMention (NativeUserId selfWxid) botName]
              <> go (fromMaybe (T.drop (T.length token) rest) (T.stripPrefix " " (T.drop (T.length token) rest)))

-- | Preserve every room event even when this relay frame does not expose a
-- stable native media reference. Known non-text message kinds become explicit
-- unsupported nodes with a total human fallback and a bounded diagnostic
-- fragment; they can be inspected and mirrored instead of disappearing.
wechatInboundBody :: Text -> Text -> Int -> Text -> Body 'Ingest
wechatInboundBody selfWxid botName msgType content
  | msgType == 1 = wechatBody selfWxid botName content
  | otherwise =
      Body
        [ NUnsupported
            Unsupported
              { source = "wechatpad:" <> T.pack (show msgType),
                description = wechatMessageDescription msgType,
                raw =
                  Just
                    ( object
                        [ "msg_type" .= msgType,
                          "content_preview" .= T.take 2048 content
                        ]
                    )
              }
        ]

wechatMessageDescription :: Int -> Text
wechatMessageDescription = \case
  3 -> "微信图片消息"
  34 -> "微信语音消息"
  43 -> "微信视频消息"
  47 -> "微信表情消息"
  49 -> "微信分享或文件消息"
  msgType -> "微信消息（类型 " <> T.pack (show msgType) <> "）"

-- | push_content usually reads "昵称 : 内容" — harvest the nickname.
pushNick :: Text -> Maybe Text
pushNick pc = case T.breakOn " : " pc of
  (n, rest) | not (T.null rest), not (T.null (T.strip n)) -> Just (T.strip n)
  _ -> Nothing

--------------------------------------------------------------------------------
-- Frame model.

data WMsg = WMsg
  { wmMsgType :: !Int,
    wmFrom :: !Text,
    wmContent :: !Text,
    wmPushContent :: !Text,
    wmMsgId :: !Text,
    wmNewMsgId :: !Int64,
    -- | WeChat's own send timestamp (unix seconds).  We stamp
    -- @messages.received_at@ with our /ingest/ time, so this is the
    -- authoritative trace of when the sender actually sent it; it becomes
    -- the envelope's occurred_at while received_at records local ingest.
    wmCreateTime :: !Int64
  }

frameParser :: Value -> Parser WMsg
frameParser = withObject "frame" $ \o -> do
  ty <- o .:? "msg_type" .!= 1
  from <- strField o "from_user_name"
  content <- strField o "content"
  pc <- o .:? "push_content" .!= ""
  mi <- textField o "msg_id"
  nmi <- int64Field o "new_msg_id"
  ct <- o .:? "create_time" .!= 0
  pure (WMsg ty from content pc mi nmi ct)
  where
    strField o k =
      (o .:? k) >>= \case
        Just (Object inner) -> inner .:? "str" .!= ""
        Just (String s) -> pure s
        _ -> pure ""
    textField o k =
      (o .:? k) >>= \case
        Just (Object inner) -> textField inner "str"
        Just (String s) -> pure s
        Just (Number n) -> case (floatingOrInteger n :: Either Double Integer) of
          Right i -> pure (T.pack (show i))
          Left _ -> fail "message id must be an integer"
        _ -> pure ""
    int64Field o k =
      (o .:? k) >>= \case
        Just (Number n) -> pure (fromMaybe 0 (toBoundedInteger n))
        Just (String s) -> pure (either (const 0) fst (TR.signed TR.decimal s))
        Just (Object inner) -> int64Field inner "str"
        _ -> pure 0

parseFrameIds :: Value -> Maybe (Text, Int64)
parseFrameIds value = do
  frame <- parseMaybe frameParser value
  pure (frame.wmMsgId, frame.wmNewMsgId)

-- | "http://127.0.0.1:8080" → ("127.0.0.1", 8080).  Port defaults
-- to 8080 (WeChatPadPro's default) when absent or unparseable.
parseHostPort :: Text -> (String, Int)
parseHostPort url =
  let noScheme = fromMaybe url (T.stripPrefix "http://" url <|> T.stripPrefix "https://" url)
      authority = T.takeWhile (/= '/') noScheme
      (h, rest) = T.breakOn ":" authority
      p = case TR.decimal (T.drop 1 rest) of
        Right (n, _) -> n
        Left _ -> 8080
   in (T.unpack h, p)
