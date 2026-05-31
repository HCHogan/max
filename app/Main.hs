module Main (main) where

import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, link, runConcurrent, withAsync)
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
        . runConcurrent
        . runLog "max" logger LogInfo
        . runHttp
        . runBlob cfg.imagesDir
        . runDb pool
        . runNapCat clientRef
        $ runApp cfg applied eventQ imgQ fwdQ clientRef

runApp ::
  ( IOE :> es,
    Log :> es,
    Http :> es,
    Blob :> es,
    Db :> es,
    NapCat :> es,
    Concurrent :> es
  ) =>
  AppConfig ->
  [String] ->
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  TVar (Maybe Client) ->
  Eff es ()
runApp cfg applied eventQ imgQ fwdQ clientRef =
  -- 'OneBot.Server.runServer' must hand a per-connection IO callback to
  -- websockets, which fires that callback in a fresh thread. The 'run'
  -- inside that callback needs ConcUnlift; otherwise SeqUnlift panics and
  -- websockets silently closes the connection (NapCat sees "socket hang
  -- up"). We could set this only around the runServer call, but setting
  -- globally is harmless and avoids surprise for any future cross-thread
  -- `withRunInIO` usage.
  withUnliftStrategy (ConcUnlift Persistent Unlimited) $ do
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
  -- Three long-lived siblings + the server. 'link' rethrows any worker
  -- exception into this thread so a worker silently dying takes the whole
  -- process down (systemd / supervisor restarts) rather than leaving a
  -- stuck queue. Ctrl+C still cascades via withAsync as usual.
  withAsync (imageWorker cfg.imageWorkers imgQ) $ \aImg -> do
    link aImg
    withAsync (forwardWorker imgQ fwdQ) $ \aFwd -> do
      link aFwd
      withAsync (handleEvents eventQ imgQ fwdQ) $ \aH -> do
        link aH
        runServer cfg.server eventQ clientRef
