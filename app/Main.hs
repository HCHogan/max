module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (TQueue, TVar, newTQueueIO, newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwTo)
import Control.Monad (forever, unless, when)
import Data.Foldable (for_)
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
import Max.Admin (adminServer)
import Max.Browser.Registry
  ( destroyAllBrowsers,
    newBrowserRegistry,
    reapStaleBrowsers,
  )
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.Calls (insertCall, pruneCalls, redactDataUrls)
import Max.DB.AgentTurn (ReclaimedTurns (..), addAgentTurnUsage, reclaimInterruptedTurns)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.DB.Monitor (reclaimExpiredMonitorFireClaims)
import Max.DB.TurnContinuity (pruneTurnArchiveReferences)
import Max.DB.Usage (insertUsage)
import Max.Effects.Agent (Agent, defaultLimits, runDurableAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Embedding (Embedding, runEmbedding)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (CallRecord (..), ChatCtx (..), LLM, TokenUsage (..), runLLM)
import Max.Effects.Outbound (Outbound, runOutbound)
import Max.Effects.PlatformApi (PlatformApi, qqBackend, runPlatformApi)
import Max.Embedder (embedWorker)
import Max.Embedding (newEmbedClient)
import Max.Env (BotEnv (..))
import Max.EpisodeScheduler (newEpisodeScheduler)
import Max.FetchQueue (FetchSignal, newFetchSignal)
import Max.Files (fileWorker)
import Max.Forward (forwardWorker)
import Max.Handler (dispatchMonitorFire, dispatchPendingWorker, dispatchProactive, handleEvents, planDriverFor, resumeInterruptedTurn)
import Max.Historian (historianWorker)
import Max.HttpRuntime (HttpRuntime, newHttpRuntime)
import Max.Images (imageWorker)
import Max.IMessage (iMessageDeliveryTransport, iMessageWorker)
import Max.Intent (IntentState, intentWorker, newIntentState)
import Max.Log (withCompactLogger)
import Max.LogBuffer (LogBuffer, newLogBuffer, pushLog)
import Max.Matrix (matrixDeliveryTransport, matrixWorker)
import Max.MediaCaption (mediaCaptionWorker)
import Max.MemoryExtract (dreamWorker)
import Max.ModelCatalog (ModelCatalog, defaultModelName, modelProfileNames)
import Max.Monitor (monitorWorker)
import Max.Plan.Worker (planWorker)
import Max.Platform.Delivery (DeliveryTransport, deliveryWorker, oneBotDeliveryTransport)
import Max.Platform.Types (Platform (..))
import Max.Sandbox.Registry
  ( gcExpiredSandboxes,
    newDurableSandboxRegistry,
    reconcileSandboxes,
  )
import Max.Session (newSessionRegistry)
import Max.Shutdown (ShutdownState, beginDrain, drainWorker, newShutdownState)
import Max.Skills (loadSkills, newSkillRegistry)
import Max.Stickers (stickerCaptionWorker)
import Max.Tasks (newTaskRegistry)
import Max.Toolset (allToolsFor)
import Max.Util (trySync)
import Max.WechatHook (wechatHookBackend, wechatHookWorker)
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
  httpRuntime <- newHttpRuntime
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    applied <- runMigrations pool cfg.migrationsDir
    -- Browser containers remain ephemeral.  Sandboxes are different: their
    -- named volumes are durable E0 state, so boot reconciles/adopts them and
    -- process exit deliberately leaves them intact.
    reapStaleBrowsers
    sandboxes <- newDurableSandboxRegistry pool
    browsers <- newBrowserRegistry httpRuntime cfg.browserProxy
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
          clientRef <- newTVarIO (Nothing :: Maybe Client)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          let mEmbed = newEmbedClient httpRuntime <$> cfg.embedding
          episodeScheduler <- traverse (const newEpisodeScheduler) cfg.memoryExtractProfile
          mIntentSt <- traverse (const newIntentState) cfg.intent
          startedAt <- getCurrentTime
          let env =
                BotEnv
                  { bePersona = cfg.persona,
                    beForceRawContext = cfg.forceRawContext,
                    beDebugDefault = cfg.debug,
                    beStickerDefault = cfg.stickersEnabled,
                    beDefaultModel = defaultModelName cfg.llm,
                    beTimeZone = cfg.timezone,
                    beTurnSilenceSeconds = cfg.turnSilenceSeconds,
                    beStartedAt = startedAt,
                    beSessions = sessions,
                    beSkills = skillReg,
                    beOwners = cfg.owners,
                    beAdminTarget = adminTargets,
                    beTasks = tasks,
                    beShutdown = shutdown,
                    beSandboxes = sandboxes,
                    beBrowsers = browsers,
                    beSearch = cfg.search,
                    beCliProxy = cfg.cliproxy,
                    beMemoryExtract = cfg.memoryExtractProfile,
                    beEpisodeScheduler = episodeScheduler,
                    beIntent = cfg.intent,
                    beEmbeddingEnabled = isJust mEmbed
                  }
              qqEdge = qqBackend clientRef
              wechatEdges =
                [ wechatpadBackend httpRuntime (runEff . runWithConnectionPool pool) wc
                | Just wc <- [cfg.wechatpad]
                ]
              wechatHookEdges =
                [ wechatHookBackend httpRuntime (runEff . runWithConnectionPool pool) wh
                | Just wh <- [cfg.wechathook]
                ]
              -- Every non-QQ backend the action router may resolve a target
              -- to.  Ownership stays canonical database state; this list only
              -- says which platforms this process can actually reach.
              foreignEdges = wechatEdges <> wechatHookEdges
              deliveryTransports =
                [oneBotDeliveryTransport PlatformQQ qqEdge]
                  <> [matrixDeliveryTransport httpRuntime matrixCfg | matrixCfg <- maybeToList cfg.matrix]
                  <> [iMessageDeliveryTransport httpRuntime iMessageCfg | iMessageCfg <- maybeToList cfg.imessage]
                  <> [ oneBotDeliveryTransport PlatformWeChatPad backend
                     | backend <- wechatEdges
                     ]
                  <> [ oneBotDeliveryTransport PlatformWeChatHook backend
                     | backend <- wechatHookEdges
                     ]
          runEff
            . runConcurrent
            . runLog "max" logger cfg.logLevel
            . runHttp httpRuntime
            . runEmbedding mEmbed
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runPlatformApi qqEdge foreignEdges
            . runOutbound
            -- Token accounting goes through its own pooled connection
            -- (a plain IO writer): the LLM interpreter sits outside
            -- the WithConnection effect and the eval harness has no
            -- database at all, so the dependency stays out of the
            -- effect stack.
            . runLLM
              httpRuntime
              ( \ctx profile u ->
                  runEff . runWithConnectionPool pool $ do
                    insertUsage ctx.ccGroup ctx.ccSource profile u.usagePrompt u.usageCompletion u.usageCachedPrompt
                    for_ ctx.ccAgentTurnId $ \turnId ->
                      addAgentTurnUsage turnId u.usagePrompt u.usageCompletion u.usageCachedPrompt
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
            . runDurableAgent defaultLimits (allToolsFor httpRuntime env)
            $ runApp httpRuntime cfg applied eventQ fetchSig mIntentSt logBuf clientRef deliveryTransports mainTid
      )
      `finally` destroyAllBrowsers browsers

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
    Embedding :> es,
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
  HttpRuntime ->
  AppConfig ->
  [String] ->
  TQueue Event ->
  FetchSignal ->
  Maybe IntentState ->
  -- | The log tail the admin panel serves; 'Nothing' when the panel
  -- is not configured, in which case nothing was captured either.
  Maybe LogBuffer ->
  TVar (Maybe Client) ->
  [DeliveryTransport] ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp httpRuntime cfg applied eventQ fetchSig mIntentSt logBuf clientRef deliveryTransports mainTid =
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
    let maintenanceOwner = "max/" <> T.pack (show env.beStartedAt) <> "/" <> T.pack (show mainTid)
    reclaimed <- reclaimInterruptedTurns (maintenanceOwner <> "/turn-recovery")
    archivePruneAt <- liftIO getCurrentTime
    reclaimedMonitorFires <- reclaimExpiredMonitorFireClaims archivePruneAt
    when (reclaimedMonitorFires > 0) $
      logAttention "monitor scheduler: expired claims reclaimed" $
        object ["fires" .= reclaimedMonitorFires]
    prunedArchives <- pruneTurnArchiveReferences archivePruneAt
    when (prunedArchives > 0) $
      logInfo "turn archives: expired/LRU references pruned" $
        object ["turns" .= prunedArchives]
    when (reclaimed.rrTurnsPendingResume > 0 || reclaimed.rrTurnsCrashed > 0 || reclaimed.rrExecutionsUnknown > 0) $
      logAttention "durable turn recovery: reclaimed interrupted work" $
        object
          [ "turns_pending_resume" .= reclaimed.rrTurnsPendingResume,
            "turns_crashed" .= reclaimed.rrTurnsCrashed,
            "executions_outcome_unknown" .= reclaimed.rrExecutionsUnknown
          ]
    -- The skill cache is authoritative once loaded (write-through, same
    -- rule as sessions), so it has to fill before the first dispatch or
    -- the admin server can consult it.
    nSkills <- loadSkills env.beSkills
    logInfo "skills loaded" $ object ["count" .= nSkills]
    for_ reclaimed.rrRecoveries resumeInterruptedTurn
    -- Long-lived siblings, then the server.  Config-disabled optional
    -- workers are omitted entirely; enabled optional features remain linked,
    -- while a clean exit is fatal only for the process's required services.
    let requiredWorkers =
          [ worker "image-fetch" RequiredWorker (imageWorker cfg.imageWorkers fetchSig),
            worker "forward-fetch" RequiredWorker (forwardWorker fetchSig),
            worker "file-fetch" RequiredWorker (fileWorker fetchSig),
            worker
              "monitor-scheduler"
              RequiredWorker
              (monitorWorker cfg.timezone (maintenanceOwner <> "/monitors") dispatchMonitorFire),
            worker "event-handler" RequiredWorker (handleEvents eventQ fetchSig mIntentSt),
            worker "canonical-dispatch" RequiredWorker (dispatchPendingWorker (maintenanceOwner <> "/dispatch") fetchSig mIntentSt),
            worker
              "plan-scheduler"
              RequiredWorker
              (planWorker (maintenanceOwner <> "/plans") (planDriverFor httpRuntime)),
            worker "platform-delivery" RequiredWorker (deliveryWorker (maintenanceOwner <> "/delivery") deliveryTransports)
          ]
        optionalWorkers =
          [ -- This one is always enabled, but unlike a permanent worker its
            -- clean return is intentional: it has already raised
            -- UserInterrupt on main to start graceful unwinding.
            worker "shutdown-drain" OptionalWorker (drainWorker cfg.shutdownDrainSeconds mainTid env.beShutdown)
          ]
            <> [ worker
                   "sandbox-gc"
                   OptionalWorker
                   ( forever $ do
                       threadDelay (60 * 60 * 1_000_000)
                       liftIO (reconcileSandboxes env.beSandboxes)
                       removed <- liftIO (gcExpiredSandboxes env.beSandboxes)
                       when (removed > 0) $
                         logInfo "sandbox TTL GC" (object ["removed" .= removed])
                   )
               ]
            <> [ worker "embeddings" OptionalWorker (embedWorker maintenanceOwner)
               | env.beEmbeddingEnabled
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
                   "historian"
                   OptionalWorker
                   (historianWorker profile cfg.historianTimeoutSeconds cfg.llm cfg.timezone env.beTasks (defaultModelName cfg.llm) scheduler)
               | (profile, scheduler) <- maybeToList ((,) <$> cfg.memoryExtractProfile <*> env.beEpisodeScheduler)
               ]
            <> [ worker "memory-dream" OptionalWorker (dreamWorker maintenanceOwner profile cfg.timezone)
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
            <> [ worker "wechatpad" OptionalWorker (wechatpadWorker wc)
               | wc <- maybeToList cfg.wechatpad
               ]
            <> [ worker "wechathook" OptionalWorker (wechatHookWorker httpRuntime wh)
               | wh <- maybeToList cfg.wechathook
               ]
            <> [ worker "matrix" OptionalWorker (matrixWorker httpRuntime matrixCfg env.beEpisodeScheduler)
               | matrixCfg <- maybeToList cfg.matrix
               ]
            <> [ worker "imessage" OptionalWorker (iMessageWorker httpRuntime iMessageCfg env.beEpisodeScheduler)
               | iMessageCfg <- maybeToList cfg.imessage
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
