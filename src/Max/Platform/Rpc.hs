-- | OneBot compatibility RPC edge. Domain callers use the narrow platform
-- effects; canonical content publication has its separate Outbound boundary.
module Max.Platform.Rpc
  ( PlatformRouter,
    platformRouter,
    callPlatform,
    sendPlatform,
    qqBackend,
    callQQActionOnGeneration,
    qqGenerationIsCurrent,
    withPendingCall,
  )
where

import Control.Concurrent.STM
  ( TMVar,
    TVar,
    atomically,
    modifyTVar',
    newEmptyTMVarIO,
    orElse,
    readTVar,
    readTVarIO,
    registerDelay,
    retry,
    takeTMVar,
  )
import Control.Exception (bracket_, try)
import Data.Aeson (Value, encode)
import Data.Bifunctor (first)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Platform (ActionAddress (..), PlatformBackend (..), actionAddress, backendForPlatform)
import Max.Platform.Failure (PlatformFailure (..))
import Max.Platform.Store (platformForLegacyConversation, platformForLegacyMessage)
import Network.WebSockets qualified as WS
import OneBot.Action (Action, Envelope (..), Response (..), encodeAction)
import OneBot.Server (Client (..), ClientSlot)

data PlatformRouter es = PlatformRouter !PlatformBackend !(Eff es [PlatformBackend])

-- | Resolve foreign backends from the caller's leased generation per call.
platformRouter :: PlatformBackend -> Eff es [PlatformBackend] -> PlatformRouter es
platformRouter = PlatformRouter

callPlatform :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Action -> Int -> Eff es (Either PlatformFailure Value)
callPlatform (PlatformRouter dflt resolve) action timeoutMs = do
  extras <- resolve
  resolveBackend dflt extras action >>= \case
    Left failure -> pure (Left failure)
    Right backend -> do
      response <- liftIO (backend.pbCall action timeoutMs)
      pure $ case response of
        Left message -> Left (PlatformTransportFailure message)
        Right value
          | value.retcode /= 0 -> Left (PlatformRejected value.retcode)
          | otherwise -> Right value.payload

sendPlatform :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Action -> Eff es (Either PlatformFailure ())
sendPlatform (PlatformRouter dflt resolve) action = do
  extras <- resolve
  resolveBackend dflt extras action >>= \case
    Left failure -> pure (Left failure)
    Right backend -> first PlatformTransportFailure <$> liftIO (backend.pbSend action)

-- | The NapCat (QQ) backend over the reverse-WS client that
-- 'OneBot.Server' publishes per connection.
qqBackend :: TVar ClientSlot -> PlatformBackend
qqBackend ref =
  PlatformBackend
    { pbPlatform = "qq",
      pbName = "napcat",
      pbSend = \a ->
        readTVarIO ref >>= \case
          Nothing -> pure (Left "no client connected")
          Just (_, c) -> sendIO c a,
      pbCall = \a t ->
        readTVarIO ref >>= \case
          Nothing -> pure (Left "no client connected")
          Just (_, c) -> callIO c a t
    }

resolveBackend ::
  (WithConnection :> es, IOE :> es) =>
  PlatformBackend ->
  [PlatformBackend] ->
  Action ->
  Eff es (Either PlatformFailure PlatformBackend)
resolveBackend dflt extras action = do
  let backends = dflt : extras
      configured = nub ((.pbPlatform) <$> backends)
  platform <- case actionAddress action of
    AccountAddress -> pure (Just "qq")
    ConversationAddress group -> platformForLegacyConversation group
    DirectAddress user -> platformForLegacyConversation (negate user)
    MessageAddress message -> platformForLegacyMessage message
  pure $ case platform of
    Nothing -> Left PlatformRouteMissing
    Just name -> case backendForPlatform name backends of
      Just backend -> Right backend
      Nothing -> Left (PlatformRouteUnavailable name configured)

-- | Issue a recovery action only on the websocket generation whose barrier
-- the handler is processing.  Re-reading after the response fences a call
-- whose connection was replaced while it was in flight.
callQQActionOnGeneration ::
  TVar ClientSlot ->
  Int ->
  Action ->
  Int ->
  IO (Either PlatformFailure Response)
callQQActionOnGeneration ref expected action timeoutMs =
  readTVarIO ref >>= \case
    Just (generation, client) | generation == expected -> do
      result <- callIO client action timeoutMs
      current <- qqGenerationIsCurrent ref expected
      pure $ if current then first PlatformTransportFailure result else Left PlatformGenerationChanged
    _ -> pure (Left PlatformGenerationChanged)

qqGenerationIsCurrent :: TVar ClientSlot -> Int -> IO Bool
qqGenerationIsCurrent ref expected =
  readTVarIO ref >>= \case
    Just (generation, _) -> pure (generation == expected)
    Nothing -> pure False

sendIO :: Client -> Action -> IO (Either Text ())
sendIO client a = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  let env = Envelope {action = a, echo = eid}
  eres <- try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Right () -> pure (Right ())
    Left e -> pure (Left ("send failed: " <> T.pack (show e)))

callIO :: Client -> Action -> Int -> IO (Either Text Response)
callIO client a timeoutMs = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  tm <- newEmptyTMVarIO
  withPendingCall client.pending eid tm $ do
    let env = Envelope {action = a, echo = eid}
    eres <- try (WS.sendTextData client.connection (encode (encodeAction env)))
    case eres :: Either WS.ConnectionException () of
      Left e -> pure (Left ("send failed: " <> T.pack (show e)))
      Right () -> awaitWithTimeout tm timeoutMs

-- | Register an in-flight call for exactly the lifetime of its send/wait
-- action.  'bracket_' masks the insertion and removal commit points while
-- restoring the caller's masking state for the body, so cancellation cannot
-- strand a pending entry.
withPendingCall ::
  TVar (Map.Map Text (TMVar (Either Text Response))) ->
  Text ->
  TMVar (Either Text Response) ->
  IO a ->
  IO a
withPendingCall pending eid tm =
  bracket_
    (atomically (modifyTVar' pending (Map.insert eid tm)))
    (atomically (modifyTVar' pending (Map.delete eid)))

awaitWithTimeout ::
  TMVar (Either Text Response) ->
  Int ->
  IO (Either Text Response)
awaitWithTimeout tm timeoutMs = do
  timer <- registerDelay (timeoutMs * 1000)
  atomically $
    takeTMVar tm
      `orElse` ( do
                   done <- readTVar timer
                   if done then pure (Left "timeout") else retry
               )
