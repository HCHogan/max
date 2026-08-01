{-# LANGUAGE TypeFamilies #-}

module Max.Effects.PlatformApi
  ( PlatformApi,
    runPlatformApi,
    qqBackend,
    sendAction,
    callAction,

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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log (Log, logAttention_)
import Max.Platform (PlatformBackend (..), routeAction)
import Network.WebSockets qualified as WS
import OneBot.Action (Action, Envelope (..), Response, encodeAction)
import OneBot.Server (Client (..))

data PlatformApi :: Effect where
  -- | Fire and forget. Silently drops if no client connected (logs).
  SendOp :: Action -> PlatformApi m ()
  -- | Send and await response. Times out per millisecond budget; returns
  -- @Left@ on send failure, timeout, or disconnect mid-flight.
  CallOp :: Action -> Int -> PlatformApi m (Either Text Response)

type instance DispatchOf PlatformApi = Dynamic

-- | Interpret the action effect as a router over platform backends:
-- each op goes to the first extra backend claiming its target id
-- ('Max.Platform.routeAction'), falling back to the default (QQ).
-- The capability name is backend-neutral; every call site speaks
-- 'sendAction'/'callAction' regardless of where the message lands.
runPlatformApi ::
  (IOE :> es, Log :> es) =>
  PlatformBackend -> -- default backend (QQ / NapCat)
  [PlatformBackend] -> -- foreign backends (WeChat, …)
  Eff (PlatformApi : es) a ->
  Eff es a
runPlatformApi dflt extras = interpret $ \_ -> \case
  SendOp a -> do
    let b = routeAction extras dflt a
    liftIO (b.pbSend a) >>= \case
      Left err -> logAttention_ (b.pbName <> " send failed: " <> err)
      Right () -> pure ()
  CallOp a t -> do
    let b = routeAction extras dflt a
    liftIO (b.pbCall a t)

-- | The NapCat (QQ) backend over the reverse-WS client that
-- 'OneBot.Server' publishes per connection.
qqBackend :: TVar (Maybe Client) -> PlatformBackend
qqBackend ref =
  PlatformBackend
    { pbName = "napcat",
      -- Default backend: routing falls through to it, so it never
      -- needs to claim ids.
      pbOwnsId = const False,
      pbSend = \a ->
        readTVarIO ref >>= \case
          Nothing -> pure (Left "no client connected")
          Just c -> sendIO c a,
      pbCall = \a t ->
        readTVarIO ref >>= \case
          Nothing -> pure (Left "no client connected")
          Just c -> callIO c a t
    }

sendAction :: (PlatformApi :> es) => Action -> Eff es ()
sendAction a = send (SendOp a)

callAction :: (PlatformApi :> es) => Action -> Int -> Eff es (Either Text Response)
callAction a t = send (CallOp a t)

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
  res <-
    atomically $
      takeTMVar tm
        `orElse` ( do
                     done <- readTVar timer
                     if done then pure (Left "timeout") else retry
                 )
  pure res
