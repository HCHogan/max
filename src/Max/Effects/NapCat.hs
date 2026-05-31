{-# LANGUAGE TypeFamilies #-}

module Max.Effects.NapCat
  ( NapCat,
    runNapCat,
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

-- | Build the NapCat interpreter on top of a 'TVar (Maybe Client)' that
-- 'OneBot.Server' publishes per connection.
runNapCat ::
  (IOE :> es, Log :> es) =>
  TVar (Maybe Client) ->
  Eff (NapCat : es) a ->
  Eff es a
runNapCat ref = interpret $ \_ -> \case
  SendOp a -> do
    mc <- liftIO (readTVarIO ref)
    case mc of
      Nothing -> logAttention_ "napcat send: no client connected"
      Just c -> liftIO (sendIO c a)
  CallOp a t -> do
    mc <- liftIO (readTVarIO ref)
    case mc of
      Nothing -> pure (Left "no client connected")
      Just c -> liftIO (callIO c a t)

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
