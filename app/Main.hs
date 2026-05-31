module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Log.Backend.StandardOutput (withStdOutLogger)
import Max.Config (AppConfig (..), loadFromEnv)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Db (Db, runDb)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.NapCat (NapCat, runNapCat)
import Max.Forward (ForwardQueue, forwardWorker, newForwardQueue)
import Max.Handler (handleEvents)
import Max.Images (ImageQueue, imageWorker, newImageQueue)
import OneBot.Event (Event)
import OneBot.Server (Client, ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  cfg <- loadFromEnv
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    applied <- runMigrations pool cfg.migrationsDir
    withStdOutLogger $ \logger -> do
      eventQ <- newTQueueIO
      imgQ <- newImageQueue
      fwdQ <- newForwardQueue
      clientRef <- newTVarIO (Nothing :: Maybe Client)
      runEff
        . runLog "max" logger LogInfo
        . runHttp
        . runBlob cfg.imagesDir
        . runDb pool
        . runNapCat clientRef
        $ runApp cfg applied eventQ imgQ fwdQ clientRef

runApp ::
  (IOE :> es, Log :> es, Http :> es, Blob :> es, Db :> es, NapCat :> es) =>
  AppConfig -> [String] -> TQueue Event -> ImageQueue -> ForwardQueue -> TVar (Maybe Client) -> Eff es ()
runApp cfg applied eventQ imgQ fwdQ clientRef = do
  let s = cfg.server
  logInfo "max-bot starting" $
    object
      [ "host" .= T.pack s.host,
        "port" .= s.port,
        "path" .= s.path,
        "db_url" .= cfg.db.url,
        "images_dir" .= T.pack cfg.imagesDir,
        "image_workers" .= cfg.imageWorkers
      ]
  unless (null applied) $
    logInfo "migrations applied" $
      object ["files" .= applied]
  -- Three long-lived siblings + the server, all under withAsync so Ctrl+C
  -- (cancellation from above) takes them down cleanly together.
  withRunInIO $ \run ->
    withAsync (run (imageWorker cfg.imageWorkers imgQ)) $ \_ ->
      withAsync (run (forwardWorker imgQ fwdQ)) $ \_ ->
        withAsync (run (handleEvents eventQ imgQ fwdQ)) $ \_ ->
          run (runServer cfg.server eventQ clientRef)
