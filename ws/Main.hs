module Main (main) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVar, newTVarIO, readTVar, writeTVar, readTVarIO)
import Control.Monad (forever)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.WebSockets qualified as WS

main :: IO ()
main = do
  let port = 8000 :: Int
  putStrLn $ "listening on:" <> show port
  WS.runServer "127.0.0.1" port application

application :: WS.ServerApp
application pending = do
  conn <- WS.acceptRequest pending
  TIO.putStrLn "new client connected!"

  WS.withPingThread conn 30 (return ()) $ do
    forever $ do
      msg <- WS.receiveData conn :: IO Text
      TIO.putStrLn $ "received: " <> msg
      WS.sendTextData conn $ "echo: " <> msg

type Account = TVar Int

transfer :: Account -> Account -> Int -> STM ()
transfer from to amount = do
  v1 <- readTVar from
  v2 <- readTVar to
  writeTVar from (v1 - amount)
  writeTVar to (v2 + amount)

-- >>> do { acc1 <- newTVarIO 100; acc2 <- newTVarIO 0; atomically $ transfer acc1 acc2 10; readTVarIO acc2 }
-- 10

