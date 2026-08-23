{-# LANGUAGE TypeFamilies #-}

module Max.Effects.PlatformApi
  ( PlatformApi,
    runPlatformApi,
    qqBackend,
    sendAction,
    callAction,
    callQQActionOnGeneration,
    qqGenerationIsCurrent,

    -- * Exposed for cancellation-safety tests
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
import Data.Aeson (encode)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log (Log, logAttention_)
import Effectful.PostgreSQL (WithConnection)
import Max.Platform (ActionAddress (..), PlatformBackend (..), actionAddress, backendForPlatform)
import Max.Platform.Store (platformForLegacyConversation, platformForLegacyMessage)
import Network.WebSockets qualified as WS
import OneBot.Action (Action, Envelope (..), Response, encodeAction)
import OneBot.Server (Client (..), ClientSlot)

data PlatformApi :: Effect where
  -- | Fire and forget. Silently drops if no client connected (logs).
  SendOp :: Action -> PlatformApi m ()
  -- | Send and await response. Times out per millisecond budget; returns
  -- @Left@ on send failure, timeout, or disconnect mid-flight.
  CallOp :: Action -> Int -> PlatformApi m (Either Text Response)

type instance DispatchOf PlatformApi = Dynamic

-- | Interpret compatibility actions through explicit canonical endpoint
-- ownership.  Targetless account operations remain QQ-only.
runPlatformApi ::
  (IOE :> es, Log :> es, WithConnection :> es) =>
  PlatformBackend -> -- default backend (QQ / NapCat)
  [PlatformBackend] -> -- foreign backends (WeChat, …)
  Eff (PlatformApi : es) a ->
  Eff es a
runPlatformApi dflt extras = interpret $ \_ -> \case
  SendOp a -> do
    resolveBackend dflt extras a >>= \case
      Left err -> logAttention_ err
      Right b ->
        liftIO (b.pbSend a) >>= \case
          Left err -> logAttention_ (b.pbName <> " send failed: " <> err)
          Right () -> pure ()
  CallOp a t -> do
    resolveBackend dflt extras a >>= \case
      Left err -> pure (Left err)
      Right b -> liftIO (b.pbCall a t)

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
  Eff es (Either Text PlatformBackend)
resolveBackend dflt extras action = do
  let backends = dflt : extras
      configured = nub ((.pbPlatform) <$> backends)
  platform <- case actionAddress action of
    AccountAddress -> pure (Just "qq")
    ConversationAddress group -> platformForLegacyConversation group
    DirectAddress user -> platformForLegacyConversation (negate user)
    MessageAddress message -> platformForLegacyMessage message
  pure $ case platform of
    Nothing -> Left "platform route unresolved: target has no canonical endpoint"
    Just name -> case backendForPlatform name backends of
      Just backend -> Right backend
      Nothing ->
        Left
          ( "platform route unavailable: endpoint requires "
              <> name
              <> ", configured="
              <> T.intercalate "," configured
          )

sendAction :: (PlatformApi :> es) => Action -> Eff es ()
sendAction a = send (SendOp a)

callAction :: (PlatformApi :> es) => Action -> Int -> Eff es (Either Text Response)
callAction a t = send (CallOp a t)

-- | Issue a recovery action only on the websocket generation whose barrier
-- the handler is processing.  Re-reading after the response fences a call
-- whose connection was replaced while it was in flight.
callQQActionOnGeneration ::
  TVar ClientSlot ->
  Int ->
  Action ->
  Int ->
  IO (Either Text Response)
callQQActionOnGeneration ref expected action timeoutMs =
  readTVarIO ref >>= \case
    Just (generation, client) | generation == expected -> do
      result <- callIO client action timeoutMs
      current <- qqGenerationIsCurrent ref expected
      pure $ if current then result else Left "connection generation changed"
    _ -> pure (Left "connection generation changed")

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
