{-# LANGUAGE TypeFamilies #-}

module Max.Effects.NapCat
  ( NapCat,
    runNapCat,
    qqBackend,
    sendAction,
    callAction,
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
import Control.Exception (try)
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

data NapCat :: Effect where
  -- | Fire and forget. Silently drops if no client connected (logs).
  SendOp :: Action -> NapCat m ()
  -- | Send and await response. Times out per millisecond budget; returns
  -- @Left@ on send failure, timeout, or disconnect mid-flight.
  CallOp :: Action -> Int -> NapCat m (Either Text Response)

type instance DispatchOf NapCat = Dynamic

-- | Interpret the action effect as a router over platform backends:
-- each op goes to the first extra backend claiming its target id
-- ('Max.Platform.routeAction'), falling back to the default (QQ).
-- The effect keeps its historical name — every call site speaks
-- 'sendAction'/'callAction' regardless of where the message lands.
runNapCat ::
  (IOE :> es, Log :> es) =>
  PlatformBackend -> -- default backend (QQ / NapCat)
  [PlatformBackend] -> -- foreign backends (WeChat, …)
  Eff (NapCat : es) a ->
  Eff es a
runNapCat dflt extras = interpret $ \_ -> \case
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
          Just c -> Right <$> sendIO c a,
      pbCall = \a t ->
        readTVarIO ref >>= \case
          Nothing -> pure (Left "no client connected")
          Just c -> callIO c a t
    }

sendAction :: NapCat :> es => Action -> Eff es ()
sendAction a = send (SendOp a)

callAction :: NapCat :> es => Action -> Int -> Eff es (Either Text Response)
callAction a t = send (CallOp a t)

sendIO :: Client -> Action -> IO ()
sendIO client a = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  let env = Envelope {action = a, echo = eid}
  eres <- try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Right () -> pure ()
    Left _ -> pure () -- read loop will detect disconnect

callIO :: Client -> Action -> Int -> IO (Either Text Response)
callIO client a timeoutMs = do
  eid <- T.pack . UUID.toString <$> UUID.nextRandom
  tm <- newEmptyTMVarIO
  atomically (modifyTVar' client.pending (Map.insert eid tm))
  let env = Envelope {action = a, echo = eid}
  eres <- try (WS.sendTextData client.connection (encode (encodeAction env)))
  case eres :: Either WS.ConnectionException () of
    Left e -> do
      atomically (modifyTVar' client.pending (Map.delete eid))
      pure (Left ("send failed: " <> T.pack (show e)))
    Right () -> awaitWithTimeout client tm eid timeoutMs

awaitWithTimeout ::
  Client ->
  TMVar (Either Text Response) ->
  Text ->
  Int ->
  IO (Either Text Response)
awaitWithTimeout client tm eid timeoutMs = do
  timer <- registerDelay (timeoutMs * 1000)
  res <-
    atomically $
      takeTMVar tm
        `orElse` ( do
                     done <- readTVar timer
                     if done then pure (Left "timeout") else retry
                 )
  case res of
    Left _ -> do
      atomically (modifyTVar' client.pending (Map.delete eid))
      pure res
    Right _ -> pure res
