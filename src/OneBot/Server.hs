module OneBot.Server
  ( ServerConfig (..),
    Client (..),
    runServer,
    send,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Exception (finally, try)
import Control.Monad (forever)
import Data.Aeson (Value (Object), decode, eitherDecode, encode)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Network.WebSockets qualified as WS
import OneBot.Action (Action, Envelope (..), Response, encodeAction)
import OneBot.Event (Event, parseEvent)

data ServerConfig = ServerConfig
  { host :: !String,
    port :: !Int,
    path :: !Text,
    accessToken :: !(Maybe Text)
  }
  deriving stock (Show)

-- | Handle to talk to a connected NapCat client. The MVP supports a single
-- connection at a time; later phases can swap this for a registry keyed by
-- @self_id@.
newtype Client = Client {connection :: WS.Connection}

-- | Start the reverse-WS server. The handler is invoked once per accepted
-- connection and receives both the 'Client' (for sending actions) and a queue
-- of decoded events.
runServer :: ServerConfig -> (Client -> TQueue Event -> IO ()) -> IO ()
runServer cfg handler =
  WS.runServer cfg.host cfg.port $ \pending -> do
    let req = WS.pendingRequest pending
        reqPath = TE.decodeUtf8Lenient (WS.requestPath req)
    if reqPath /= cfg.path
      then WS.rejectRequest pending "not found"
      else case checkToken cfg.accessToken (WS.requestHeaders req) of
        Left msg -> WS.rejectRequest pending (TE.encodeUtf8 msg)
        Right () -> do
          conn <- WS.acceptRequest pending
          WS.withPingThread conn 30 (pure ()) (runConn conn handler)

checkToken :: Maybe Text -> WS.Headers -> Either Text ()
checkToken Nothing _ = Right ()
checkToken (Just expected) hs =
  case lookup (CI.mk "Authorization") hs of
    Just v ->
      let decoded = TE.decodeUtf8Lenient v
       in if decoded == "Bearer " <> expected || decoded == expected
            then Right ()
            else Left "unauthorized"
    Nothing -> Left "unauthorized"

runConn :: WS.Connection -> (Client -> TQueue Event -> IO ()) -> IO ()
runConn conn handler = do
  eventQ <- newTQueueIO
  let client = Client {connection = conn}
  _ <- forkIO (handler client eventQ)
  readLoop conn eventQ
    `finally` WS.sendClose conn ("server shutting down" :: Text)

readLoop :: WS.Connection -> TQueue Event -> IO ()
readLoop conn q = forever $ do
  raw <- WS.receiveData conn :: IO LBS.ByteString
  case decode raw :: Maybe Value of
    Nothing ->
      putStrLn $ "warn: undecodable frame: " <> LBS8.unpack raw
    Just v
      | looksLikeResponse v -> logResponse raw
      | otherwise -> case parseEvent v of
          Left err ->
            putStrLn $
              "warn: event parse error: " <> err <> " in " <> LBS8.unpack raw
          Right ev -> atomically (writeTQueue q ev)

looksLikeResponse :: Value -> Bool
looksLikeResponse (Object o) = KM.member (K.fromString "retcode") o
looksLikeResponse _ = False

logResponse :: LBS.ByteString -> IO ()
logResponse bs = case eitherDecode bs :: Either String Response of
  Right r -> putStrLn $ "action response: " <> show r
  Left err -> putStrLn $ "warn: response parse error: " <> err

-- | Send an action over the connection. Returns the echo id that NapCat will
-- include in its response. The MVP does not block on the response.
send :: Client -> Action -> IO Text
send client a = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  let env = Envelope {action = a, echo = eid}
  eres <- try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Right () -> pure ()
    Left e -> putStrLn $ "warn: send failed: " <> show e
  pure eid
