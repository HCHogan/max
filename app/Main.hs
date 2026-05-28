module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Data.Text qualified as T
import Log
import Log.Backend.StandardOutput (withStdOutLogger)
import Max.Config (AppConfig (..), loadFromEnv)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.Handler (handleEvents)
import OneBot.Server (ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  cfg <- loadFromEnv
  withStdOutLogger $ \logger ->
    runLogT "max" logger LogInfo $ do
      let s = cfg.server
      logInfo "max-bot starting" $
        object
          [ "host" .= T.pack s.host,
            "port" .= s.port,
            "path" .= s.path,
            "db_url" .= cfg.db.url
          ]
      withRunInIO $ \run ->
        bracket (newDbPool cfg.db) closeDbPool $ \pool -> run $ do
          applied <- liftIO (runMigrations pool cfg.migrationsDir)
          unless (null applied) $
            logInfo "migrations applied" $ object ["files" .= applied]
          runServer s (handleEvents pool)
