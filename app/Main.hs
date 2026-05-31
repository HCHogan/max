module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (bracket)
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.IO.Unlift (withRunInIO)
import Data.Text qualified as T
import Log
import Log.Backend.StandardOutput (withStdOutLogger)
import Max.Config (AppConfig (..), loadFromEnv)
import Max.DB.Connection (DbConfig (..), DbPool, closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.Deps (AppDeps (..))
import Max.Forward (forwardWorker, newForwardQueue)
import Max.Handler (handleEvents)
import Max.Images (imageWorker, newImageQueue)
import OneBot.Server (ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  cfg <- loadFromEnv
  withStdOutLogger $ \logger ->
    runLogT "max" logger LogInfo (runApp cfg)

runApp :: AppConfig -> LogT IO ()
runApp cfg = do
  let s = cfg.server
  logInfo "max-bot starting" $
    object
      [ "host" .= T.pack s.host,
        "port" .= s.port,
        "path" .= s.path,
        "db_url" .= cfg.db.url,
        "images_dir" .= T.pack cfg.imagesDir
      ]
  withRunInIO $ \run ->
    bracket (newDbPool cfg.db) closeDbPool $ \pool ->
      run (runWithPool cfg pool)

runWithPool :: AppConfig -> DbPool -> LogT IO ()
runWithPool cfg pool = do
  applied <- liftIO (runMigrations pool cfg.migrationsDir)
  unless (null applied) $
    logInfo "migrations applied" $
      object ["files" .= applied]
  imgQ <- liftIO newImageQueue
  fwdQ <- liftIO newForwardQueue
  clientRef <- liftIO (newTVarIO Nothing)
  let deps =
        AppDeps
          { db = pool,
            imageQ = imgQ,
            forwardQ = fwdQ,
            clientRef = clientRef
          }
      setClient mc = atomically (writeTVar clientRef mc)
  withRunInIO $ \run ->
    withAsync (run (imageWorker cfg.imagesDir pool imgQ)) $ \_ ->
      withAsync (run (forwardWorker clientRef pool imgQ fwdQ)) $ \_ ->
        run (runServer cfg.server setClient (handleEvents deps))
