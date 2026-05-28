module OneBot.Server
  ( ServerConfig (..),
    Client (..),
    runServer,
    send,
  )
where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    fromException,
    throwIO,
    try,
  )
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Data.Aeson (Value (Object), decode, eitherDecode, encode)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Log
import Network.WebSockets qualified as WS
import OneBot.Action (Action, Envelope (..), Response (..), encodeAction)
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

-- | Start the reverse-WS server. Each accepted connection is given its own
-- @conn-N@ log domain so reconnect cycles stay readable in the log stream.
runServer :: ServerConfig -> (Client -> TQueue Event -> LogT IO ()) -> LogT IO ()
runServer cfg handler = do
  counter <- liftIO (newIORef (0 :: Int))
  withRunInIO $ \run -> WS.runServer cfg.host cfg.port $ \pending -> do
    cid <- atomicModifyIORef' counter (\n -> let n' = n + 1 in (n', n'))
    run $
      localDomain ("conn-" <> T.pack (show cid)) $
        acceptConn cfg pending handler

acceptConn ::
  ServerConfig ->
  WS.PendingConnection ->
  (Client -> TQueue Event -> LogT IO ()) ->
  LogT IO ()
acceptConn cfg pending handler = do
  let req = WS.pendingRequest pending
      reqPath = TE.decodeUtf8Lenient (WS.requestPath req)
  if reqPath /= cfg.path
    then do
      logAttention "rejecting unknown path" $ object ["path" .= reqPath]
      liftIO $ WS.rejectRequest pending "not found"
    else case checkToken cfg.accessToken (WS.requestHeaders req) of
      Left msg -> do
        logAttention "rejecting unauthorized" $ object ["reason" .= msg]
        liftIO $ WS.rejectRequest pending (TE.encodeUtf8 msg)
      Right () -> do
        conn <- liftIO (WS.acceptRequest pending)
        logInfo_ "ws connected"
        runConn conn handler `catchSync` \e ->
          logAttention "connection terminated" $
            object ["error" .= T.pack (show e)]
        liftIO (closeQuietly conn)
        logInfo_ "ws closed"

-- | Run handler and read loop tied together. Either exiting cancels the
-- other; an exception in either propagates so the caller logs and cleans up.
runConn ::
  WS.Connection ->
  (Client -> TQueue Event -> LogT IO ()) ->
  LogT IO ()
runConn conn handler = do
  eventQ <- liftIO newTQueueIO
  let client = Client {connection = conn}
  withRunInIO $ \run ->
    WS.withPingThread conn 30 (pure ()) $
      concurrently_
        (run (handler client eventQ))
        (run (readLoop conn eventQ))

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

readLoop :: WS.Connection -> TQueue Event -> LogT IO ()
readLoop conn q = loop
  where
    loop = do
      raw <- liftIO (WS.receiveData conn :: IO LBS.ByteString)
      case decode raw :: Maybe Value of
        Nothing ->
          logAttention "undecodable frame" $
            object ["raw" .= TE.decodeUtf8Lenient (LBS.toStrict raw)]
        Just v
          | looksLikeResponse v -> logResponse raw
          | otherwise -> case parseEvent v of
              Left err ->
                logAttention "event parse error" $
                  object
                    [ "error" .= T.pack err,
                      "raw" .= TE.decodeUtf8Lenient (LBS.toStrict raw)
                    ]
              Right ev -> liftIO (atomically (writeTQueue q ev))
      loop

looksLikeResponse :: Value -> Bool
looksLikeResponse (Object o) = KM.member (K.fromString "retcode") o
looksLikeResponse _ = False

logResponse :: LBS.ByteString -> LogT IO ()
logResponse bs = case eitherDecode bs :: Either String Response of
  Right (Response st rc _payload ec) ->
    logInfo "action response" $
      object
        [ "status" .= st,
          "retcode" .= rc,
          "echo" .= ec
        ]
  Left err ->
    logAttention "response parse error" $ object ["error" .= T.pack err]

closeQuietly :: WS.Connection -> IO ()
closeQuietly conn =
  WS.sendClose conn ("bye" :: Text)
    `catch` \(_ :: SomeException) -> pure ()

-- | Catch only synchronous exceptions; re-raise anything tagged
-- 'SomeAsyncException' so cancellation and signals propagate normally.
catchSync :: LogT IO a -> (SomeException -> LogT IO a) -> LogT IO a
catchSync act h = withRunInIO $ \run ->
  run act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> run (h e)

-- | Send an action over the connection. Returns the echo id NapCat will
-- include in its response. Send failures are logged, not thrown — the
-- read loop's disconnect detection will tear the connection down anyway.
send :: Client -> Action -> LogT IO Text
send client a = do
  eid <- liftIO (T.pack . UUID.toString <$> UUID.nextRandom)
  let env = Envelope {action = a, echo = eid}
  eres <-
    liftIO $
      try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Right () -> pure ()
    Left e ->
      logAttention "send failed" $ object ["error" .= T.pack (show e)]
  pure eid
