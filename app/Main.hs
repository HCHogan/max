module Main (main) where

import Data.Text qualified as T
import Max.Config (AppConfig (..), loadFromEnv)
import Max.Handler (handleEvents)
import OneBot.Server (ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  cfg <- loadFromEnv
  let s = cfg.server
  putStrLn $
    "max-bot listening on ws://"
      <> s.host
      <> ":"
      <> show s.port
      <> T.unpack s.path
  runServer s handleEvents
