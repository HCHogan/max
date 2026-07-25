module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwTo)
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
import Max.Effects.Agent (Agent, defaultLimits, runAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (LLM, LLMRegistry (..), runLLM)
import Max.Effects.NapCat (NapCat, qqBackend, runNapCat)
import Max.Embedder (embedWorker)
import Max.Embedding (newEmbedClient)
import Max.Env (BotEnv (..))
import Max.Reminder (newReminderScheduler, reminderWorker)
import Max.FetchQueue (FetchSignal, newFetchSignal)
import Max.Files (fileWorker)
import Max.Forward (forwardWorker)
import Max.Handler (dispatchProactive, handleEvents)
import Max.Wechatpad (wechatpadBackend, wechatpadWorker)
import Max.Images (imageWorker)
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
import Max.Toolset (allToolsFor)
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
    -- Container lifecycle, both ends.  Reaping first kills any
    -- 'max-sb-*' / browser containers left over from a prior unclean
    -- exit — we are the only writer of that namespace, so anything
    -- still standing is orphaned.  Destroying on the way out covers
    -- everything the registries know about, and fires on
    -- UserInterrupt (Ctrl+C / SIGTERM) too.
    reapStaleSandboxes
    reapStaleBrowsers
    sandboxes <- newSandboxRegistry
    browsers <- newBrowserRegistry cfg.browserProxy
    ( do
        withStdOutLogger $ \logger -> do
          eventQ <- newTQueueIO
          -- One bell for all three media workers: the jobs live in
          -- @fetch_jobs@ and each worker claims only its own kind, so a
          -- shared wakeup costs the other two one indexed query.
          fetchSig <- newFetchSignal
          sessions <- newSessionRegistry
          tasks <- newTaskRegistry
          reminders <- newReminderScheduler
          clientRef <- newTVarIO (Nothing :: Maybe Client)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          mEmbed <- traverse newEmbedClient cfg.embedding
          mIntentSt <- traverse (const newIntentState) cfg.intent
          startedAt <- getCurrentTime
          let env =
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
                    beReminders = reminders,
                    beSearch = cfg.search,
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
            . runReader env
            . runAgent defaultLimits (allToolsFor env) tasks
            $ runApp cfg applied eventQ fetchSig mIntentSt clientRef mainTid
      )
      `finally` (destroyAllSandboxes sandboxes >> destroyAllBrowsers browsers)

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
    Reader BotEnv :> es
  ) =>
  AppConfig ->
  [String] ->
  TQueue Event ->
  FetchSignal ->
  Maybe IntentState ->
  TVar (Maybe Client) ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp cfg applied eventQ fetchSig mIntentSt clientRef mainTid =
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
    env :: BotEnv <- ask
    -- Long-lived siblings, then the server.  An optional worker is an
    -- action that does nothing when its config is absent: the async
    -- completes immediately and linking a finished async is a no-op, so
    -- "off" needs no special case here.
    withLinkedWorkers
      [ imageWorker cfg.imageWorkers fetchSig,
        forwardWorker fetchSig,
        fileWorker fetchSig,
        for_ env.beEmbed embedWorker,
        -- Two caption loops under one worker: stickers and ordinary
        -- photos/videos poll separately, so a deep sticker backlog
        -- can't starve fresh chat media (and vice versa).  Either one
        -- crashing still takes the process down.
        for_ cfg.stickerCaptionProfile $ \p ->
          concurrently_
            (stickerCaptionWorker p cfg.imagesDir)
            (mediaCaptionWorker p cfg.imagesDir),
        reminderWorker cfg.timezone env.beReminders,
        for_ ((,) <$> cfg.intent <*> mIntentSt) $ \(ic, st) ->
          intentWorker ic cfg.persona cfg.llm.defaultName cfg.timezone env.beSessions dispatchProactive st,
        handleEvents eventQ fetchSig mIntentSt,
        for_ cfg.wechatpad $ \wc -> wechatpadWorker wc eventQ,
        -- Parked on the shutdown flag until SIGTERM, then waits out the
        -- in-flight dispatches before interrupting main.
        drainWorker cfg.shutdownDrainSeconds mainTid env.beShutdown
      ]
      (runServer cfg.server eventQ clientRef)

-- | Run @act@ with every worker alive alongside it.
--
-- 'link' rethrows a worker's exception into this thread, so one dying
-- silently takes the whole process down (systemd restarts it) instead
-- of leaving a stuck queue behind.  Ctrl+C still cascades through
-- 'withAsync' as usual.
--
-- A fold rather than a staircase of nested 'withAsync': the workers
-- differ only in which action they run, and stating "link it" once
-- keeps a new worker from quietly joining unlinked.
withLinkedWorkers :: Concurrent :> es => [Eff es ()] -> Eff es a -> Eff es a
withLinkedWorkers workers act = foldr step act workers
  where
    step w rest = withAsync w $ \a -> link a >> rest
