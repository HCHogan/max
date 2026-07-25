-- |
-- WeChat backend over a WeChatPadPro relay (0.4 slice B — minimal
-- demo: text in, text out, whitelisted chatrooms only).
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
-- Ids are folded into max's bigint world via "Max.DB.PlatformIds".
-- Degradations (WeChat has no reactions / reply segments / pokes):
-- reactions and pokes silently no-op; reply/at segments render into
-- plain text; non-text media renders as a bracket marker.
--
-- 已知风险：iPad 协议逆向，封号风险自担（跑小号）。
module Max.Wechatpad
  ( WechatpadConfig (..),
    wechatpadBackend,
    wechatpadWorker,
    platformName,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TQueue, atomically, writeTQueue)
import Control.Monad (forever, unless)
import Data.Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text.Read qualified as TR
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.PlatformIds (mappedId, nativeId)
import Max.Platform (PlatformBackend (..), isForeignId)
import Max.Util (catchSync)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS (newTlsManager)
import Network.WebSockets qualified as WS
import OneBot.Action (Action (..), Response (..))
import OneBot.Event (Event (..), GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

platformName :: Text
platformName = "wechatpad"

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
  (forall a. Eff '[WithConnection, IOE] a -> IO a) ->
  WechatpadConfig ->
  PlatformBackend
wechatpadBackend runDb cfg =
  PlatformBackend
    { pbName = platformName,
      pbOwnsId = isForeignId,
      pbSend = \a -> sendOut a >>= either (pure . Left) (const (pure (Right ()))),
      pbCall = \a _timeoutMs ->
        sendOut a >>= \case
          Left err -> pure (Left err)
          Right mid ->
            pure . Right $
              Response
                { status = "ok",
                  retcode = 0,
                  payload = object ["message_id" .= mid],
                  echo = ""
                }
    }
  where
    sendOut :: Action -> IO (Either Text Int64)
    sendOut = \case
      SendGroupMsg (GroupId g) segs -> deliver "channel" g segs
      SendPrivateMsg (UserId u) segs -> deliver "user" u segs
      -- WeChat has no reactions or pokes: swallow silently — these
      -- fire on every command ack / silence and would spam the log.
      SetMsgEmojiLike {} -> pure (Right 0)
      SendPoke {} -> pure (Right 0)
      other -> pure (Left ("wechatpad: unsupported action: " <> T.take 60 (T.pack (show other))))

    deliver kind mapped segs = do
      mNative <- runDb (nativeId platformName kind mapped)
      case mNative of
        Nothing -> pure (Left ("wechatpad: no native id for " <> T.pack (show mapped)))
        Just to -> do
          let body = renderOutbound segs
          if T.null (T.strip body)
            then pure (Right 0)
            else
              postText cfg to body >>= \case
                Left err -> pure (Left err)
                Right () -> do
                  -- Allocate a synthetic id for the sent message so
                  -- the caller can persist the bot's own line.
                  mid <- runDb (mappedId platformName "message" ("sent:" <> to <> ":" <> T.take 32 body))
                  pure (Right mid)

-- | Flatten outbound segments to WeChat text.  Reply/at have no
-- native form; media falls back to a marker.
renderOutbound :: [Segment] -> Text
renderOutbound = T.concat . map go
  where
    go = \case
      SegText t -> t
      SegAt _ -> ""
      SegReply _ -> ""
      SegImage _ -> "[图片]"
      other -> renderPlainText [other]

postText :: WechatpadConfig -> Text -> Text -> IO (Either Text ())
postText cfg to content = do
  mgr <- newTlsManager
  req0 <- HTTP.parseRequest (T.unpack (cfg.wpApiUrl <> "/message/SendTextMessage?key=" <> cfg.wpAuthKey))
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
      req =
        req0
          { HTTP.method = "POST",
            HTTP.requestBody = HTTP.RequestBodyLBS (encode payload),
            HTTP.requestHeaders = [("Content-Type", "application/json")]
          }
  resp <- HTTP.httpLbs req mgr
  pure $ case decode (HTTP.responseBody resp) >>= parseMaybe envelopeCode of
    Just 200 -> Right ()
    Just c -> Left ("wechatpad: API code " <> T.pack (show c))
    Nothing -> Left "wechatpad: unparseable API response"
  where
    envelopeCode = withObject "envelope" (.: "Code") :: Value -> Parser Int

--------------------------------------------------------------------------------
-- Inbound worker.

-- | Long-lived WS listener: parse sync frames, translate whitelisted
-- chatroom text messages into 'EvGroupMessage's on the shared queue.
-- Reconnects forever with a fixed backoff.
wechatpadWorker ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  WechatpadConfig ->
  TQueue Event ->
  Eff es ()
wechatpadWorker cfg q = localDomain "wechatpad" $ do
  logInfo "wechatpad worker started" $ object ["chatrooms" .= cfg.wpChatrooms]
  selfMapped <- mappedId platformName "user" cfg.wpSelfWxid
  forever $ do
    listenOnce selfMapped `catchSync` \e ->
      logAttention "wechatpad: connection lost, retrying in 5s" $
        object ["error" .= T.pack (show e)]
    liftIO (threadDelay 5_000_000)
  where
    (host, port) = parseHostPort cfg.wpApiUrl
    wsPath = "/ws/GetSyncMsg?key=" <> T.unpack cfg.wpAuthKey

    listenOnce selfMapped =
      withRunInIO $ \unlift ->
        WS.runClient host port wsPath $ \conn -> forever $ do
          raw <- WS.receiveData conn
          unlift (handleFrame selfMapped raw)

    handleFrame selfMapped raw =
      case decodeStrictText raw of
        Nothing -> pure ()
        Just frame -> case parseMaybe frameParser frame of
          Nothing -> pure ()
          Just wm -> translate selfMapped wm

    translate selfMapped wm
      -- Demo scope: whitelisted chatroom text messages only.
      | wm.wmMsgType /= 1 = pure ()
      | not ("@chatroom" `T.isSuffixOf` wm.wmFrom) = pure ()
      | wm.wmFrom `notElem` cfg.wpChatrooms = pure ()
      | otherwise = do
          let (senderWxid, body0) = splitSender wm.wmContent
          -- The bot's own messages echo back on the sync stream.
          unless (senderWxid == cfg.wpSelfWxid) $ do
            gid <- mappedId platformName "channel" wm.wmFrom
            uid <- mappedId platformName "user" senderWxid
            mid <- mappedId platformName "message" (T.pack (show wm.wmNewMsgId))
            let (mentioned, body) = detectMention cfg.wpBotName body0
                segs =
                  [SegAt (UserId selfMapped) | mentioned]
                    <> [SegText body]
                nick = pushNick wm.wmPushContent
                gm =
                  GroupMessage
                    { selfId = UserId selfMapped,
                      groupId = GroupId gid,
                      userId = UserId uid,
                      messageId = MessageId mid,
                      message = segs,
                      rawMessage = wm.wmContent,
                      sender = Sender (UserId uid) nick Nothing
                    }
            logInfo "wechat message" $
              object
                [ "chatroom" .= wm.wmFrom,
                  "sender" .= senderWxid,
                  "len" .= T.length body,
                  "create_time" .= wm.wmCreateTime
                ]
            liftIO (atomically (writeTQueue q (EvGroupMessage gm)))

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

-- | \@-detection by display name: "@名字" (with the usual trailing
-- space or end) triggers; the token is stripped so the model sees a
-- clean body plus a synthesized 'SegAt'.
detectMention :: Text -> Text -> (Bool, Text)
detectMention name t =
  let token = "@" <> name
   in if token `T.isInfixOf` t
        then (True, T.strip (T.replace token "" t))
        else (False, t)

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
    wmNewMsgId :: !Int64,
    -- | WeChat's own send timestamp (unix seconds).  We stamp
    -- @messages.received_at@ with our /ingest/ time, so this is the
    -- only trace of when the sender actually sent it — logged rather
    -- than stored, which is enough to spot delivery lag or a relay
    -- whose clock has drifted.
    wmCreateTime :: !Int64
  }

frameParser :: Value -> Parser WMsg
frameParser = withObject "frame" $ \o -> do
  ty <- o .:? "msg_type" .!= 1
  from <- strField o "from_user_name"
  content <- strField o "content"
  pc <- o .:? "push_content" .!= ""
  nmi <- o .:? "new_msg_id" .!= 0
  ct <- o .:? "create_time" .!= 0
  pure (WMsg ty from content pc nmi ct)
  where
    strField o k =
      (o .:? k) >>= \case
        Just (Object inner) -> inner .:? "str" .!= ""
        Just (String s) -> pure s
        _ -> pure ""

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
