module OneBot.ServerSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, isEmptyTQueue, newTQueueIO, newTVarIO, readTQueue, readTVar, readTVarIO, writeTVar)
import Control.Exception (bracket)
import Control.Monad (replicateM)
import Data.Aeson (Value, encode, object, (.=))
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Effectful
import Effectful.Log (LogLevel (LogAttention), runLog)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Network.Socket (Family (AF_INET), SockAddr (SockAddrInet), SocketType (Stream), bind, close, defaultProtocol, getSocketName, socket, tupleToHostAddress)
import Network.WebSockets qualified as WS
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Server (ServerConfig (..), clearClientGeneration, publishClientGeneration, runServer)
import OneBot.Types (MessageId (..))
import Test.Hspec

spec :: Spec
spec = describe "OneBot client publication" $ do
  it "lets an owner clear its own generation" $
    clearClientGeneration 1 (Just (1, "old" :: String))
      `shouldBe` Nothing

  it "does not let a stale connection clear its replacement" $
    clearClientGeneration 1 (Just (2, "new" :: String))
      `shouldBe` Just (2, "new")

  it "publishes a generation together with its queue barrier" $ do
    eventQueue <- newTQueueIO
    clientRef <- newTVarIO Nothing
    let connectedAt = posixSecondsToUTCTime 100
    publishClientGeneration 7 connectedAt (error "client must not be forced") eventQueue clientRef
    (event, slot) <- atomically ((,) <$> readTQueue eventQueue <*> readTVar clientRef)
    case (event, slot) of
      (EvConnectionReady 7 observedAt, Just (7, _)) -> observedAt `shouldBe` connectedAt
      other -> expectationFailure ("barrier and client generation diverged: " <> showBarrier other)

  it "keeps one websocket generation and admits frames exactly once across reload publication" $ do
    port <- unusedPort
    eventQueue <- newTQueueIO
    clientRef <- newTVarIO Nothing
    runtimeGeneration <- newTVarIO (1 :: Int)
    let cfg = ServerConfig "127.0.0.1" port "/onebot" Nothing
    withCompactLogger ColorNever Nothing $ \logger -> do
      server <-
        async
          ( runEff . runLog "onebot-reload-test" logger LogAttention $
              withUnliftStrategy (ConcUnlift Persistent Unlimited) (runServer cfg eventQueue clientRef)
          )
      threadDelay 30_000
      events <-
        WS.runClient "127.0.0.1" port "/onebot" $ \connection -> do
          WS.sendTextData connection (encode (messageEvent 9001))
          -- This is the only operation ordinary Max reload performs at the
          -- OneBot boundary: publish another runtime generation elsewhere.
          atomically (writeTVar runtimeGeneration 2)
          WS.sendTextData connection (encode (messageEvent 9002))
          WS.sendTextData connection (encode (messageEvent 9003))
          observed <- replicateM 4 (atomically (readTQueue eventQueue))
          readTVarIO clientRef >>= \case
            Just (connectionGeneration, _) -> connectionGeneration `shouldBe` 1
            Nothing -> expectationFailure "websocket disappeared during runtime publication"
          readTVarIO runtimeGeneration `shouldReturn` 2
          pure observed
      cancel server
      [generation | EvConnectionReady generation _ <- events] `shouldBe` [1]
      [messageId | EvGroupMessage _ _ message <- events, let MessageId messageId = message.messageId]
        `shouldBe` [9001, 9002, 9003]
      atomically (isEmptyTQueue eventQueue) `shouldReturn` True
  where
    showBarrier (event, slot) =
      show event <> ", slot=" <> case slot of
        Nothing -> "empty"
        Just (generation, _) -> show generation

messageEvent :: Int -> Value
messageEvent messageId =
  object
    [ "post_type" .= ("message" :: Text),
      "message_type" .= ("group" :: Text),
      "self_id" .= (1000 :: Int),
      "group_id" .= (7777 :: Int),
      "user_id" .= (2001 :: Int),
      "message_id" .= messageId,
      "message" .= ([] :: [Value]),
      "raw_message" .= ("hi" :: Text),
      "sender" .= object ["user_id" .= (2001 :: Int), "nickname" .= ("Alice" :: Text)]
    ]

unusedPort :: IO Int
unusedPort = bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
  bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  getSocketName sock >>= \case
    SockAddrInet port _ -> pure (fromIntegral port)
    other -> error ("expected an IPv4 socket, got " <> show other)
