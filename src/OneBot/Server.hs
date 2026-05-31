module OneBot.Server
  ( ServerConfig (..),
    Client (..),
    runServer,
    send,
    call,
  )
where

import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.STM
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    finally,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Data.Aeson (Value (Object), decode, eitherDecode, encode)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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
--
-- 'pending' correlates outbound action requests with NapCat's responses by
-- @echo@ id. Each entry holds a 'TMVar' the caller blocks on; the read loop
-- fills it on response, the disconnect path fills it with @Left@.
data Client = Client
  { connection :: !WS.Connection,
    pending :: !(TVar (Map Text (TMVar (Either Text Response))))
  }

-- | Start the reverse-WS server. Each accepted connection is given its own
-- @conn-N@ log domain so reconnect cycles stay readable in the log stream.
--
-- The @setClient@ callback is fired with @Just@ when a connection is
-- established and @Nothing@ when it tears down. App-lived workers that need
-- to issue actions ('call') route through this.
runServer ::
  ServerConfig ->
  (Maybe Client -> IO ()) ->
  (Client -> TQueue Event -> LogT IO ()) ->
  LogT IO ()
runServer cfg setClient handler = do
  counter <- liftIO (newIORef (0 :: Int))
  withRunInIO $ \run -> WS.runServer cfg.host cfg.port $ \pending -> do
    cid <- atomicModifyIORef' counter (\n -> let n' = n + 1 in (n', n'))
    run $
      localDomain ("conn-" <> T.pack (show cid)) $
        acceptConn cfg pending setClient handler

acceptConn ::
  ServerConfig ->
  WS.PendingConnection ->
  (Maybe Client -> IO ()) ->
  (Client -> TQueue Event -> LogT IO ()) ->
  LogT IO ()
acceptConn cfg pending setClient handler = do
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
        runConn conn setClient handler `catchSync` \e ->
          logAttention "connection terminated" $
            object ["error" .= T.pack (show e)]
        liftIO (closeQuietly conn)
        logInfo_ "ws closed"

-- | Build the per-connection 'Client', publish it via 'setClient', and tie
-- handler + read loop together. On exit we clear setClient and fail any
-- in-flight callers so they don't hang past the disconnect.
runConn ::
  WS.Connection ->
  (Maybe Client -> IO ()) ->
  (Client -> TQueue Event -> LogT IO ()) ->
  LogT IO ()
runConn conn setClient handler = do
  eventQ <- liftIO newTQueueIO
  pendingMap <- liftIO (newTVarIO Map.empty)
  let client = Client {connection = conn, pending = pendingMap}
  withRunInIO $ \run -> do
    setClient (Just client)
    ( WS.withPingThread conn 30 (pure ()) $
        concurrently_
          (run (handler client eventQ))
          (run (readLoop client eventQ))
      )
      `finally` ( do
                    setClient Nothing
                    abortPending pendingMap "connection closed"
                )

-- | Fill every pending 'TMVar' with a failure so callers stop blocking on
-- a connection that's gone.
abortPending :: TVar (Map Text (TMVar (Either Text Response))) -> Text -> IO ()
abortPending tv reason = atomically $ do
  m <- readTVar tv
  forM_ (Map.elems m) $ \tm -> tryPutTMVar tm (Left reason)
  writeTVar tv Map.empty

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

readLoop :: Client -> TQueue Event -> LogT IO ()
readLoop client q = loop
  where
    loop = do
      raw <- liftIO (WS.receiveData client.connection :: IO LBS.ByteString)
      case decode raw :: Maybe Value of
        Nothing ->
          logAttention "undecodable frame" $
            object ["raw" .= TE.decodeUtf8Lenient (LBS.toStrict raw)]
        Just v
          | looksLikeResponse v -> handleResponse client raw
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

-- | Route a response by 'echo' id to its waiting 'call'. Responses without
-- a matching pending entry (e.g. from one-way 'send' calls, or arriving
-- after timeout) are just logged.
handleResponse :: Client -> LBS.ByteString -> LogT IO ()
handleResponse client raw = case eitherDecode raw :: Either String Response of
  Left err ->
    logAttention "response parse error" $ object ["error" .= T.pack err]
  Right resp@(Response st rc _ ec) -> do
    delivered <- liftIO $ atomically $ do
      m <- readTVar client.pending
      case Map.lookup ec m of
        Nothing -> pure False
        Just tm -> do
          _ <- tryPutTMVar tm (Right resp)
          writeTVar client.pending (Map.delete ec m)
          pure True
    logInfo "action response" $
      object
        [ "status" .= st,
          "retcode" .= rc,
          "echo" .= ec,
          "delivered" .= delivered
        ]

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

-- | Fire-and-forget. Returns the echo id without registering for a
-- response — useful when the caller doesn't need NapCat's ack. For
-- request/response correlation use 'call'.
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

-- | Send an action and wait for NapCat's response, up to @timeoutMs@.
-- Returns @Left@ on send failure, timeout, or connection drop.
call :: Client -> Action -> Int -> IO (Either Text Response)
call client a timeoutMs = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  tm <- newEmptyTMVarIO
  atomically $ modifyTVar' client.pending (Map.insert eid tm)
  let env = Envelope {action = a, echo = eid}
  eres <-
    try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Left e -> do
      atomically $ modifyTVar' client.pending (Map.delete eid)
      pure (Left ("send failed: " <> T.pack (show e)))
    Right () -> do
      timer <- registerDelay (timeoutMs * 1000)
      res <-
        atomically $
          takeTMVar tm
            `orElse` ( do
                         done <- readTVar timer
                         if done then pure (Left "timeout") else retry
                     )
      case res of
        Left _ ->
          atomically (modifyTVar' client.pending (Map.delete eid))
            *> pure res
        Right _ -> pure res
