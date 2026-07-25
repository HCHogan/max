module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), bracket, bracket_, throwTo)
import Control.Monad (unless)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Concurrent.Async (Concurrent, concurrently_, link, runConcurrent, withAsync)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Effectful.Reader.Dynamic (Reader, ask, runReader)
import Effectful.Wreq (runWreq)
import Log.Backend.StandardOutput (withStdOutLogger)
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.Effects.Agent (Agent, DispatchContext (..), defaultLimits, runAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (LLM, LLMRegistry (..), runLLM)
import Max.Effects.NapCat (NapCat, qqBackend, runNapCat)
import Max.Embedder (embedWorker)
import Max.Embedding (EmbedClient, newEmbedClient)
import Max.Env (BotEnv (..))
import Max.Persistence (PersistMode (Persisted))
import Max.Reminder (ReminderScheduler, newReminderScheduler, reminderWorker)
import Max.Files (FileQueue, fileWorker, newFileQueue)
import Max.Forward (ForwardQueue, forwardWorker, newForwardQueue)
import Max.Handler (dispatchProactive, handleEvents)
import Max.Wechatpad (wechatpadBackend, wechatpadWorker)
import Max.Images (ImageQueue, imageWorker, newImageQueue)
import Max.Intent (IntentState, intentWorker, newIntentState)
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
import Max.Shutdown (ShutdownState, beginDrain, drainWorker, newShutdownState)
import Max.MediaCaption (mediaCaptionWorker)
import Max.Stickers (stickerCaptionWorker)
import Max.Tasks (newTaskRegistry)
import Max.Tools (builtinsFor)
import Max.Tools.Bilibili (bilibiliToolsFor)
import Max.Tools.Browser (browserToolsFor)
import Max.Tools.Files (fileToolsFor)
import Max.Tools.Group (groupToolsFor)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Memory (memoryToolsFor)
import Max.Tools.Pins (pinToolsFor)
import Max.Tools.Reminder (reminderToolsFor)
import Max.Tools.Sandbox (sandboxToolsFor)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Stickers (stickerToolsFor)
import Max.Tools.Video (videoToolsFor)
import OneBot.Event (Event)
import OneBot.Server (Client, ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  mainTid <- myThreadId
  shutdown <- newShutdownState
  -- SIGTERM (e.g. from systemd) starts a graceful drain: no new agent
  -- dispatches, wait out the running ones, then raise the same
  -- UserInterrupt Ctrl+C produces so all our 'bracket' cleanups — DB
  -- pool, sandbox reaper — fire exactly as they always have.  Ctrl+C
  -- itself keeps GHC's immediate default: an interactive run wants out
  -- now, not in two minutes.
  _ <- installHandler sigTERM (Catch (drainOrInterrupt mainTid shutdown)) Nothing

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
      browsers <- newBrowserRegistry cfg.browserProxy
      bracket_ (pure ()) (destroyAllSandboxes sandboxes >> destroyAllBrowsers browsers) $ do
        withStdOutLogger $ \logger -> do
          eventQ <- newTQueueIO
          imgQ <- newImageQueue
          fwdQ <- newForwardQueue
          fileQ <- newFileQueue
          sessions <- newSessionRegistry
          tasks <- newTaskRegistry
          reminders <- newReminderScheduler
          clientRef <- newTVarIO (Nothing :: Maybe Client)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          mEmbed <- traverse newEmbedClient cfg.embedding
          mIntentSt <- traverse (const newIntentState) cfg.intent
          startedAt <- getCurrentTime
          let toolFactory dc =
                builtinsFor cfg.timezone mEmbed dc
                  <> reminderToolsFor cfg.timezone reminders dc
                  <> groupToolsFor dc
                  <> imageToolsFor cfg.timezone cfg.imagesDir dc
                  <> memoryToolsFor mEmbed dc
                  <> pinToolsFor sessions cfg.llm.defaultName dc
                  <> bilibiliToolsFor cfg.timezone dc
                  <> sandboxToolsFor cfg.timezone dc.dcGroupId sandboxes
                  <> fileToolsFor cfg.timezone dc.dcGroupId cfg.imagesDir sandboxes
                  <> (if dc.dcStickers then stickerToolsFor mEmbed else [])
                  <> maybe [] searchToolsFor cfg.search
                  -- Browser + video toolsets only for multimodal profiles.
                  <> (if dc.dcMultimodal then browserToolsFor dc.dcGroupId browsers else [])
                  <> (if dc.dcMultimodal then videoToolsFor cfg.imagesDir dc else [])
              env =
                BotEnv
                  { bePersona = cfg.persona,
                    beHistoryWindow = cfg.historyWindow,
                    beBlobRoot = cfg.imagesDir,
                    beDebugDefault = cfg.debug,
                    beStickerDefault = cfg.stickersEnabled,
                    beDefaultModel = cfg.llm.defaultName,
                    beTimeZone = cfg.timezone,
                    beStartedAt = startedAt,
                    beSessions = sessions,
                    beOwners = cfg.owners,
                    beAdminTarget = adminTargets,
                    beTasks = tasks,
                    beShutdown = shutdown,
                    beSandboxes = sandboxes,
                    beBrowsers = browsers,
                    beMemoryExtract = cfg.memoryExtractProfile,
                    beIntent = cfg.intent,
                    beEmbed = mEmbed
                  }
          runEff
            . runConcurrent
            . runLog "max" logger LogInfo
            . runHttp
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runNapCat
              (qqBackend clientRef)
              [ wechatpadBackend (runEff . runWithConnectionPool pool) wc
              | Just wc <- [cfg.wechatpad]
              ]
            . runWreq
            . runLLM cfg.llm
            . runReader Persisted -- default mode; !btw scopes Volatile on top
            . runReader env
            . runAgent defaultLimits toolFactory tasks
            $ runApp cfg applied mEmbed reminders eventQ imgQ fwdQ fileQ mIntentSt clientRef mainTid

-- | SIGTERM handler.  Deliberately does no waiting itself: it flips the
-- drain flag and returns, leaving the wait (and its logging) to
-- 'drainWorker' out on the effect stack.  Until that worker is up —
-- config load, migrations, container reaping — the flag just sits set
-- and is honoured the moment it starts, which is what the second
-- SIGTERM's escape hatch is for.
drainOrInterrupt :: ThreadId -> ShutdownState -> IO ()
drainOrInterrupt mainTid st = do
  first <- beginDrain st
  unless first (throwTo mainTid UserInterrupt)

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
  Maybe EmbedClient ->
  ReminderScheduler ->
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  FileQueue ->
  Maybe IntentState ->
  TVar (Maybe Client) ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp cfg applied mEmbed reminders eventQ imgQ fwdQ fileQ mIntentSt clientRef mainTid =
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
          -- No embedding config → this async completes immediately;
          -- linking a successfully-finished async is a no-op.
          withAsync (for_ mEmbed embedWorker) $ \aE -> do
            link aE
            -- Same trick: no caption profile → immediate no-op async.
            -- Two independent caption loops under one async: stickers
            -- and ordinary photos/videos poll separately, so a deep
            -- sticker backlog can't starve fresh chat media (and vice
            -- versa); either one crashing still takes the process down
            -- via the link.
            withAsync
              ( for_ cfg.stickerCaptionProfile $ \p ->
                  concurrently_
                    (stickerCaptionWorker p cfg.imagesDir)
                    (mediaCaptionWorker p cfg.imagesDir)
              )
              $ \aCap -> do
                link aCap
                withAsync (reminderWorker cfg.timezone reminders) $ \aRem -> do
                  link aRem
                  -- No intent config → immediate no-op async, same trick
                  -- as the caption worker above.
                  env :: BotEnv <- ask
                  withAsync
                    ( for_ ((,) <$> cfg.intent <*> mIntentSt) $ \(ic, st) ->
                        intentWorker ic cfg.persona cfg.llm.defaultName cfg.timezone env.beSessions dispatchProactive st
                    )
                    $ \aInt -> do
                      link aInt
                      withAsync (handleEvents eventQ imgQ fwdQ fileQ mIntentSt) $ \aH -> do
                        link aH
                        -- WeChat inbound (no-op async when unconfigured,
                        -- same trick as the caption worker).
                        withAsync (for_ cfg.wechatpad (\wc -> wechatpadWorker wc eventQ)) $ \aWx -> do
                          link aWx
                          -- Parked on the shutdown flag until SIGTERM,
                          -- then waits out the in-flight dispatches
                          -- before interrupting main.
                          withAsync (drainWorker cfg.shutdownDrainSeconds mainTid env.beShutdown) $ \aDrain -> do
                            link aDrain
                            runServer cfg.server eventQ clientRef
