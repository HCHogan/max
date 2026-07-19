module OneBot.Server
  ( ServerConfig (..),
    Client (..),
    runServer,
  )
where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (void)
import Data.Foldable (for_)
import Data.Aeson (Value (Object), decode, eitherDecode)
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
import Effectful
import Effectful.Log
import Max.Util (catchSync, trySyncIO)
import Network.WebSockets qualified as WS
import OneBot.Action (Response (..))
import OneBot.Event (Event, parseEvent)

data ServerConfig = ServerConfig
  { host :: !String,
    port :: !Int,
    path :: !Text,
    accessToken :: !(Maybe Text)
  }
  deriving stock (Show)

-- | Handle to talk to a connected NapCat client. Carries the websocket plus
-- a pending-call registry (echo id → TMVar) shared between the read loop
-- (which fills incoming responses) and the NapCat effect's 'call' (which
-- creates entries and waits on them).
data Client = Client
  { connection :: !WS.Connection,
    pending :: !(TVar (Map Text (TMVar (Either Text Response))))
  }

-- | Run the reverse-WS server. Each accepted connection gets its own
-- @conn-N@ log domain. Decoded events are pushed onto 'eventQ' for the
-- app-lived handler to consume. The current 'Client' (if any) is
-- published on 'clientRef' for the NapCat effect to read.
runServer ::
  (Log :> es, IOE :> es) =>
  ServerConfig ->
  TQueue Event ->
  TVar (Maybe Client) ->
  Eff es ()
runServer cfg eventQ clientRef = do
  counter <- liftIO (newIORef (0 :: Int))
  withRunInIO $ \run ->
    WS.runServer cfg.host cfg.port $ \pending -> do
      cid <- atomicModifyIORef' counter (\n -> let n' = n + 1 in (n', n'))
      run $
        localDomain ("conn-" <> T.pack (show cid)) $
          acceptConn cfg pending eventQ clientRef

acceptConn ::
  (Log :> es, IOE :> es) =>
  ServerConfig ->
  WS.PendingConnection ->
  TQueue Event ->
  TVar (Maybe Client) ->
  Eff es ()
acceptConn cfg pending eventQ clientRef = do
  let req = WS.pendingRequest pending
      reqPath = TE.decodeUtf8Lenient (WS.requestPath req)
  if reqPath /= cfg.path
    then do
      logAttention "rejecting unknown path" $ object ["path" .= reqPath]
      liftIO (WS.rejectRequest pending "not found")
    else case checkToken cfg.accessToken (WS.requestHeaders req) of
      Left msg -> do
        logAttention "rejecting unauthorized" $ object ["reason" .= msg]
        liftIO (WS.rejectRequest pending (TE.encodeUtf8 msg))
      Right () -> do
        conn <- liftIO (WS.acceptRequest pending)
        logInfo_ "ws connected"
        runConn conn eventQ clientRef `catchSync` \e ->
          logAttention "connection terminated" $
            object ["error" .= T.pack (show e)]
        liftIO (closeQuietly conn)
        logInfo_ "ws closed"

-- | Build the per-connection 'Client', publish on 'clientRef', and run
-- the read loop. On exit clear 'clientRef' and abort any in-flight
-- 'call's so callers don't hang past the disconnect.
runConn ::
  (Log :> es, IOE :> es) =>
  WS.Connection ->
  TQueue Event ->
  TVar (Maybe Client) ->
  Eff es ()
runConn conn eventQ clientRef = do
  pendingMap <- liftIO (newTVarIO Map.empty)
  let client = Client {connection = conn, pending = pendingMap}
  withRunInIO $ \run -> do
    atomically (writeTVar clientRef (Just client))
    WS.withPingThread conn 30 (pure ()) (run (readLoop client eventQ))
      `finally` ( do
                    atomically (writeTVar clientRef Nothing)
                    abortPending pendingMap "connection closed"
                )

abortPending ::
  TVar (Map Text (TMVar (Either Text Response))) ->
  Text ->
  IO ()
abortPending tv reason = atomically $ do
  m <- readTVar tv
  for_ (Map.elems m) $ \tm -> tryPutTMVar tm (Left reason)
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

readLoop ::
  (Log :> es, IOE :> es) =>
  Client ->
  TQueue Event ->
  Eff es ()
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

handleResponse ::
  (Log :> es, IOE :> es) =>
  Client ->
  LBS.ByteString ->
  Eff es ()
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
  void $ trySyncIO $ WS.sendClose conn ("bye" :: Text)
