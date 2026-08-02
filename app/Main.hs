module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwTo)
import Control.Monad (forever, unless, when)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, maybeToList)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Concurrent (threadDelay)
import Effectful.Concurrent.Async (Concurrent, concurrently_, runConcurrent)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Effectful.Reader.Dynamic (Reader, ask, runReader)
import Effectful.Wreq (runWreq)
import Max.Admin (adminServer)
import Max.Browser.Registry
  ( destroyAllBrowsers,
    newBrowserRegistry,
    reapStaleBrowsers,
  )
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.Calls (insertCall, pruneCalls, redactDataUrls)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.DB.Usage (insertUsage)
import Max.Effects.Agent (Agent, defaultLimits, runAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (CallRecord (..), ChatCtx (..), LLM, TokenUsage (..), runLLM)
import Max.Effects.Outbound (Outbound, runOutbound)
import Max.Effects.PlatformApi (PlatformApi, qqBackend, runPlatformApi)
import Max.Embedder (embedWorker)
import Max.Embedding (newEmbedClient)
import Max.Env (BotEnv (..))
import Max.FetchQueue (FetchSignal, newFetchSignal)
import Max.Files (fileWorker)
import Max.Forward (forwardWorker)
import Max.Handler (dispatchProactive, handleEvents)
import Max.Images (imageWorker)
import Max.Intent (IntentState, intentWorker, newIntentState)
import Max.Log (withCompactLogger)
import Max.LogBuffer (LogBuffer, newLogBuffer, pushLog)
import Max.MediaCaption (mediaCaptionWorker)
import Max.MemoryExtract (dreamWorker, memxWorker, newMemxScheduler)
import Max.ModelCatalog (ModelCatalog, defaultModelName, modelProfileNames)
import Max.Reminder (newReminderScheduler, reminderWorker)
import Max.Sandbox.Registry
  ( destroyAllSandboxes,
    newSandboxRegistry,
    reapStaleSandboxes,
  )
import Max.Session (newSessionRegistry)
import Max.Shutdown (ShutdownState, beginDrain, drainWorker, newShutdownState)
import Max.Skills (loadSkills, newSkillRegistry)
import Max.Stickers (stickerCaptionWorker)
import Max.Tasks (newTaskRegistry)
import Max.Toolset (allToolsFor)
import Max.Util (trySync)
import Max.Wechatpad (wechatpadBackend, wechatpadWorker)
import Max.Worker (WorkerCriticality (..), withWorkers, worker)
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
        -- The panel's log view reads this ring; it fills only when
        -- the admin API is configured, so a bot without a panel pays
        -- nothing for it.
        logBuf <- traverse (const (newLogBuffer logBufferLines)) cfg.admin
        withCompactLogger cfg.logColor (pushLog <$> logBuf) $ \logger -> do
          eventQ <- newTQueueIO
          -- One bell for all three media workers: the jobs live in
          -- @fetch_jobs@ and each worker claims only its own kind, so a
          -- shared wakeup costs the other two one indexed query.
          fetchSig <- newFetchSignal
          sessions <- newSessionRegistry
          skillReg <- newSkillRegistry
          tasks <- newTaskRegistry
          reminders <- newReminderScheduler
          clientRef <- newTVarIO (Nothing :: Maybe Client)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          mEmbed <- traverse newEmbedClient cfg.embedding
          memxSched <- traverse (const newMemxScheduler) cfg.memoryExtractProfile
          mIntentSt <- traverse (const newIntentState) cfg.intent
          startedAt <- getCurrentTime
          let env =
                BotEnv
                  { bePersona = cfg.persona,
                    beHistoryWindow = cfg.historyWindow,
                    beHistoryMax = cfg.historyMax,
                    beDebugDefault = cfg.debug,
                    beStickerDefault = cfg.stickersEnabled,
                    beDefaultModel = defaultModelName cfg.llm,
                    beTimeZone = cfg.timezone,
                    beStartedAt = startedAt,
                    beSessions = sessions,
                    beSkills = skillReg,
                    beOwners = cfg.owners,
                    beAdminTarget = adminTargets,
                    beTasks = tasks,
                    beShutdown = shutdown,
                    beSandboxes = sandboxes,
                    beBrowsers = browsers,
                    beReminders = reminders,
                    beSearch = cfg.search,
                    beCliProxy = cfg.cliproxy,
                    beMemoryExtract = cfg.memoryExtractProfile,
                    beMemx = memxSched,
                    beIntent = cfg.intent,
                    beEmbed = mEmbed
                  }
          runEff
            . runConcurrent
            . runLog "max" logger cfg.logLevel
            . runHttp
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runPlatformApi
              (qqBackend clientRef)
              [ wechatpadBackend (runEff . runWithConnectionPool pool) wc
              | Just wc <- [cfg.wechatpad]
              ]
            . runOutbound
            . runWreq
            -- Token accounting goes through its own pooled connection
            -- (a plain IO writer): the LLM interpreter sits outside
            -- the WithConnection effect and the eval harness has no
            -- database at all, so the dependency stays out of the
            -- effect stack.
            . runLLM
              ( \ctx profile u ->
                  runEff . runWithConnectionPool pool $
                    insertUsage ctx.ccGroup ctx.ccSource profile u.usagePrompt u.usageCompletion u.usageCachedPrompt
              )
              -- The full-body log only exists when the panel does:
              -- without somewhere to read it, it would be disk spent
              -- on nothing.
              ( \(rec :: CallRecord) ->
                  when (isJust cfg.admin) . runEff . runWithConnectionPool pool $
                    insertCall
                      rec.crCtx.ccGroup
                      rec.crCtx.ccSource
                      rec.crProfile
                      rec.crModel
                      rec.crStreamed
                      rec.crDurationMs
                      (redactDataUrls rec.crRequest)
                      rec.crResponse
                      rec.crError
                      ( (\u -> (u.usagePrompt, u.usageCompletion, u.usageCachedPrompt))
                          <$> rec.crUsage
                      )
              )
              cfg.llm
            . runReader cfg.llm
            . runReader env
            . runAgent defaultLimits (allToolsFor env) tasks
            $ runApp cfg applied eventQ fetchSig mIntentSt logBuf clientRef mainTid
      )
      `finally` (destroyAllSandboxes sandboxes `finally` destroyAllBrowsers browsers)

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
    PlatformApi :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es
  ) =>
  AppConfig ->
  [String] ->
  TQueue Event ->
  FetchSignal ->
  Maybe IntentState ->
  -- | The log tail the admin panel serves; 'Nothing' when the panel
  -- is not configured, in which case nothing was captured either.
  Maybe LogBuffer ->
  TVar (Maybe Client) ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp cfg applied eventQ fetchSig mIntentSt logBuf clientRef mainTid =
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
          "image_workers" .= cfg.imageWorkers,
          -- Which file the settings came from, or that none was
          -- found.  Every value above can also come from a flag or an
          -- env var that silently outranks the file, so knowing the
          -- file was read at all is the first thing you need when one
          -- of them looks wrong.
          "config_file" .= maybe "(none)" T.pack cfg.configFileUsed
        ]
    unless (null applied) $
      logInfo "migrations applied" $
        object ["files" .= applied]
    env :: BotEnv <- ask
    -- The skill cache is authoritative once loaded (write-through, same
    -- rule as sessions), so it has to fill before the first dispatch or
    -- the admin server can consult it.
    nSkills <- loadSkills env.beSkills
    logInfo "skills loaded" $ object ["count" .= nSkills]
    -- Long-lived siblings, then the server.  Config-disabled optional
    -- workers are omitted entirely; enabled optional features remain linked,
    -- while a clean exit is fatal only for the process's required services.
    let requiredWorkers =
          [ worker "image-fetch" RequiredWorker (imageWorker cfg.imageWorkers fetchSig),
            worker "forward-fetch" RequiredWorker (forwardWorker fetchSig),
            worker "file-fetch" RequiredWorker (fileWorker fetchSig),
            worker "reminders" RequiredWorker (reminderWorker cfg.timezone env.beReminders),
            worker "event-handler" RequiredWorker (handleEvents eventQ fetchSig mIntentSt)
          ]
        optionalWorkers =
          [ -- This one is always enabled, but unlike a permanent worker its
            -- clean return is intentional: it has already raised
            -- UserInterrupt on main to start graceful unwinding.
            worker "shutdown-drain" OptionalWorker (drainWorker cfg.shutdownDrainSeconds mainTid env.beShutdown)
          ]
            <> [ worker "embeddings" OptionalWorker (embedWorker embed)
               | embed <- maybeToList env.beEmbed
               ]
            <> [ worker
                   "media-captions"
                   OptionalWorker
                   -- Two caption loops under one worker: stickers and
                   -- ordinary photos/videos poll separately, so a deep
                   -- sticker backlog cannot starve fresh chat media.
                   ( concurrently_
                       (stickerCaptionWorker profile)
                       (mediaCaptionWorker profile)
                   )
               | profile <- maybeToList cfg.stickerCaptionProfile
               ]
            <> [ worker
                   "memory-extract"
                   OptionalWorker
                   (memxWorker profile env.beEmbed cfg.timezone env.beSessions (defaultModelName cfg.llm) scheduler)
               | (profile, scheduler) <- maybeToList ((,) <$> cfg.memoryExtractProfile <*> env.beMemx)
               ]
            <> [ worker "memory-dream" OptionalWorker (dreamWorker profile cfg.timezone)
               | profile <- maybeToList cfg.memoryExtractProfile
               ]
            <> [ worker
                   "intent"
                   OptionalWorker
                   (intentWorker intentCfg cfg.persona (defaultModelName cfg.llm) cfg.timezone env.beSessions (dispatchProactive (Just intentState)) intentState)
               | (intentCfg, intentState) <- maybeToList ((,) <$> cfg.intent <*> mIntentSt)
               ]
            <> [ worker "admin-server" OptionalWorker (adminServer adminCfg env (modelProfileNames cfg.llm) buffer)
               | (adminCfg, buffer) <- maybeToList ((,) <$> cfg.admin <*> logBuf)
               ]
            <> [ worker "call-pruner" OptionalWorker (callPruner cfg.adminCallRetentionDays)
               | _ <- maybeToList cfg.admin
               ]
            <> [ worker "wechatpad" OptionalWorker (wechatpadWorker wc eventQ)
               | wc <- maybeToList cfg.wechatpad
               ]
    withWorkers
      (requiredWorkers <> optionalWorkers)
      (runServer cfg.server eventQ clientRef)

-- | Log lines the admin panel can look back over.  A busy dispatch
-- prints on the order of ten, so this is a few hundred dispatches —
-- past "what just happened", which is the question it answers.
-- Anything older is journalctl's job.
logBufferLines :: Int
logBufferLines = 2000

-- | Roll the @llm_calls@ bodies off on a schedule.
--
-- Once an hour rather than on a timer tied to the retention window:
-- the deletion is a single indexed range delete, and running it often
-- keeps each one small instead of letting a day's worth pile up for
-- one long transaction.  Runs once at startup too, so a bot that was
-- down over the weekend cleans up as soon as it is back rather than
-- an hour later.
callPruner :: (WithConnection :> es, Log :> es, Concurrent :> es, IOE :> es) => Int -> Eff es ()
callPruner days = localDomain "calls" . forever $ do
  r <- trySync (pruneCalls days)
  case r of
    Left e ->
      logAttention "calls: prune failed" $ object ["error" .= T.pack (show e)]
    Right 0 -> pure ()
    Right n ->
      logInfo "calls: pruned" $ object ["rows" .= n, "older_than_days" .= days]
  threadDelay (3600 * 1_000_000)
