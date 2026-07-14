module Main (main) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), bracket, bracket_, throwTo)
import Control.Monad (unless)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, link, runConcurrent, withAsync)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Effectful.Reader.Dynamic (Reader, runReader)
import Effectful.Wreq (runWreq)
import Log.Backend.StandardOutput (withStdOutLogger)
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.Effects.Agent (Agent, DispatchContext (..), defaultLimits, runAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (LLM, LLMRegistry (..), runLLM)
import Max.Effects.NapCat (NapCat, runNapCat)
import Max.Env (BotEnv (..))
import Max.Persistence (PersistMode (Persisted))
import Max.Files (FileQueue, fileWorker, newFileQueue)
import Max.Forward (ForwardQueue, forwardWorker, newForwardQueue)
import Max.Handler (handleEvents)
import Max.Images (ImageQueue, imageWorker, newImageQueue)
import Max.Browser.Registry
  ( destroyAllBrowsers,
    newBrowserRegistry,
    reapStaleBrowsers,
  )
import Max.Sandbox.Registry
  ( destroyAllSandboxes,
    newSandboxRegistry,
    reapStaleSandboxes,
  )
import Max.Session (newSessionRegistry)
import Max.Tasks (newTaskRegistry)
import Max.Tools (builtinsFor)
import Max.Tools.Browser (browserToolsFor)
import Max.Tools.Files (fileToolsFor)
import Max.Tools.Memory (memoryToolsFor)
import Max.Tools.Sandbox (sandboxToolsFor)
import Max.Tools.Search (searchToolsFor)
import OneBot.Event (Event)
import OneBot.Server (Client, ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  -- Convert SIGTERM (e.g. from systemd) into the same UserInterrupt
  -- async exception Ctrl+C produces, so all our 'bracket' cleanups
  -- — DB pool, sandbox reaper — fire on graceful shutdown.
  mainTid <- myThreadId
  _ <- installHandler sigTERM (Catch (throwTo mainTid UserInterrupt)) Nothing

  cfg <- loadConfig
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    applied <- runMigrations pool cfg.migrationsDir
    -- Sandbox registry + lifecycle:
    --   * reapStaleSandboxes on entry kills any 'max-sb-*' containers
    --     left over from a prior unclean exit (we're the only writer
    --     of that namespace).
    --   * destroyAllSandboxes on exit kills everything the registry
    --     knows about — fires on UserInterrupt (Ctrl+C / SIGTERM) too.
    bracket_ (reapStaleSandboxes >> reapStaleBrowsers) (pure ()) $ do
      sandboxes <- newSandboxRegistry
      browsers <- newBrowserRegistry
      bracket_ (pure ()) (destroyAllSandboxes sandboxes >> destroyAllBrowsers browsers) $ do
        withStdOutLogger $ \logger -> do
          eventQ <- newTQueueIO
          imgQ <- newImageQueue
          fwdQ <- newForwardQueue
          fileQ <- newFileQueue
          sessions <- newSessionRegistry
          tasks <- newTaskRegistry
          clientRef <- newTVarIO (Nothing :: Maybe Client)
          let toolFactory dc =
                builtinsFor dc
                  <> memoryToolsFor dc
                  <> sandboxToolsFor dc.dcGroupId sandboxes
                  <> fileToolsFor dc.dcGroupId cfg.imagesDir sandboxes
                  <> maybe [] searchToolsFor cfg.search
                  -- Browser toolset only for multimodal profiles (per config).
                  <> (if dc.dcMultimodal then browserToolsFor dc.dcGroupId browsers else [])
              env =
                BotEnv
                  { bePersona = cfg.persona,
                    beHistoryWindow = cfg.historyWindow,
                    beBlobRoot = cfg.imagesDir,
                    beDebugDefault = cfg.debug,
                    beDefaultModel = cfg.llm.defaultName,
                    beSessions = sessions,
                    beTasks = tasks,
                    beSandboxes = sandboxes,
                    beBrowsers = browsers
                  }
          runEff
            . runConcurrent
            . runLog "max" logger LogInfo
            . runHttp
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runNapCat clientRef
            . runWreq
            . runLLM cfg.llm
            . runReader Persisted -- default mode; !btw scopes Volatile on top
            . runReader env
            . runAgent defaultLimits toolFactory tasks
            $ runApp cfg applied eventQ imgQ fwdQ fileQ clientRef

runApp ::
  ( IOE :> es,
    Log :> es,
    Http :> es,
    Blob :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es
  ) =>
  AppConfig ->
  [String] ->
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  FileQueue ->
  TVar (Maybe Client) ->
  Eff es ()
runApp cfg applied eventQ imgQ fwdQ fileQ clientRef =
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
        withAsync (fileWorker fileQ) $ \aFile -> do
          link aFile
          withAsync (handleEvents eventQ imgQ fwdQ fileQ) $ \aH -> do
            link aH
            runServer cfg.server eventQ clientRef
