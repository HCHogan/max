module Main (main) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (TQueue, TVar, atomically, newEmptyTMVarIO, newTQueueIO, newTVarIO, putTMVar, readTMVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (UserInterrupt), bracket, evaluate, finally, throwIO, throwTo)
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
import Effectful.Exception (onException)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Effectful.Reader.Dynamic (Reader, ask, local, runReader)
import GHC.Clock (getMonotonicTime)
import Max.Admin (AdminConfig (..), adminServer)
import Max.Browser.Registry
  ( configureBrowserRegistry,
    destroyAllBrowsers,
    newBrowserRegistry,
    reapStaleBrowsers,
  )
import Max.Browser.Runtime (browserMaintenance)
import Max.Browser.Vault (loadBrowserVault)
import Max.Config (AppConfig (..), ConfigChange (..), configChanges, loadConfig, loadConfigCandidate, restartRequiredChanges, runtimeValuesFromConfig)
import Max.DB.AgentTurn (ReclaimedTurns (..), addAgentTurnUsage, reclaimInterruptedTurns)
import Max.DB.Calls (insertCall, pruneCalls, redactDataUrls)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.DB.Monitor (reclaimExpiredMonitorFireClaims)
import Max.DB.TurnContinuity (pruneTurnArchiveReferences)
import Max.DB.Usage (insertUsage)
import Max.Effects.Agent (Agent, defaultLimits, runDurableAgent)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.Embedding (Embedding, runRuntimeEmbedding)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (CallRecord (..), ChatCtx (..), LLM, TokenUsage (..), runRuntimeLLM, withLLMConfigGeneration)
import Max.Effects.Outbound (Outbound, runOutbound)
import Max.Effects.PlatformApi (PlatformApi, qqBackend, runRuntimePlatformApi)
import Max.Embedder (embedWorker)
import Max.Embedding (newEmbedClient)
import Max.Env (BotEnv (..), applyRuntimeSnapshot)
import Max.EpisodeScheduler (newEpisodeScheduler)
import Max.FetchQueue (FetchSignal, newFetchSignal)
import Max.Files (fileWorker)
import Max.Forward (forwardWorker)
import Max.Handler (dispatchMonitorFire, dispatchPendingWorker, dispatchProactive, durableTaskWorker, handleEvents, resumeInterruptedTurn)
import Max.Historian (historianWorker)
import Max.HttpRuntime (HttpRuntime, newHttpRuntime)
import Max.IMessage (iMessageDeliveryTransport, iMessageWorker)
import Max.Images (imageWorker)
import Max.Intent (IntentState, intentWorker, newIntentState)
import Max.Log (withCompactLoggerDynamic)
import Max.LogBuffer (LogBuffer, newLogBuffer, pushLog)
import Max.Matrix (matrixDeliveryTransport, matrixWorker)
import Max.MediaCaption (mediaCaptionWorker)
import Max.MemoryExtract (dreamWorker)
import Max.ModelCatalog (ModelCatalog, defaultModelName, modelProfileNames)
import Max.Monitor (monitorWorker)
import Max.Platform.Delivery (deliveryWorker, oneBotDeliveryTransport)
import Max.Platform.Types (Platform (..))
import Max.Reload (ReloadError (..), ReloadResponse (..), controlSocketPath, runReloadServer)
import Max.Reload.Prepare (preflightChangedListener)
import Max.RuntimeConfig (ConfigGeneration (..), RuntimeConfigStore, RuntimeResources (..), RuntimeSnapshot (..), RuntimeValues (..), acquireRuntimeConfigSTM, currentRuntimeSnapshot, leasedRuntimeSnapshot, newRuntimeConfigStore, publishRuntimeConfigSTM, releaseRuntimeConfigSTM)
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
import Max.Util (trySync, trySyncIO)
import Max.WechatHook (WechatHookConfig (..), wechatHookBackend, wechatHookWorker)
import Max.Worker (WorkerCriticality (..), withWorkers, worker)
import Max.Worker.Generation (PrepareFailure (..), RetireOutcome (..), abortGeneration, closeGenerationSupervisor, commitGeneration, newGenerationSupervisor, prepareGeneration)
import OneBot.Event (Event)
import OneBot.Server (ClientSlot, ServerConfig (..), runServer)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)
import System.Timeout (timeout)

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
  activeConfig <- newTVarIO cfg
  controlPath <- controlSocketPath
  httpRuntime <- newHttpRuntime
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    applied <- runMigrations pool cfg.migrationsDir
    -- Browser containers remain ephemeral.  Sandboxes are different: their
    -- named volumes are durable E0 state, so boot reconciles/adopts them and
    -- process exit deliberately leaves them intact.
    reapStaleBrowsers
    sandboxes <- newDurableSandboxRegistry pool
    browserKey <- loadBrowserVault cfg.browserStateKeyFile
    browsers <- configureBrowserRegistry browserKey cfg.browserIdleSeconds cfg.browserGraceSeconds <$> newBrowserRegistry httpRuntime
    ( do
        -- Keep the bounded ring alive across admin enable/disable handoffs.
        -- It is cheap, and allocating it once avoids losing the pre-failure
        -- lines precisely when an operator enables the panel to investigate.
        logBuf <- newLogBuffer logBufferLines
        withCompactLoggerDynamic cfg.logColor ((.logLevel) <$> readTVarIO activeConfig) (Just (pushLog logBuf)) $ \logger -> do
          eventQ <- newTQueueIO
          -- One bell for all three media workers: the jobs live in
          -- @fetch_jobs@ and each worker claims only its own kind, so a
          -- shared wakeup costs the other two one indexed query.
          fetchSig <- newFetchSignal
          sessions <- newSessionRegistry
          skillReg <- newSkillRegistry
          tasks <- newTaskRegistry
          clientRef <- newTVarIO (Nothing :: ClientSlot)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          episodeScheduler <- newEpisodeScheduler
          intentState <- newIntentState
          startedAt <- getCurrentTime
          let qqEdge = qqBackend clientRef
              resourcesFor candidate =
                let wechatHookEdges =
                      [ wechatHookBackend httpRuntime (runEff . runWithConnectionPool pool) wh
                      | Just wh <- [candidate.wechathook]
                      ]
                 in RuntimeResources
                      { rrEmbeddingClient = newEmbedClient httpRuntime <$> candidate.embedding,
                        rrForeignEdges = wechatHookEdges,
                        rrDeliveryTransports =
                          [oneBotDeliveryTransport PlatformQQ qqEdge]
                            <> [matrixDeliveryTransport httpRuntime matrixCfg | matrixCfg <- maybeToList candidate.matrix]
                            <> [iMessageDeliveryTransport httpRuntime iMessageCfg | iMessageCfg <- maybeToList candidate.imessage]
                            <> [ oneBotDeliveryTransport PlatformWeChatHook backend
                               | backend <- wechatHookEdges
                               ]
                      }
              prepareResources candidate = do
                let resources = resourcesFor candidate
                -- Force the complete small resource set before publication;
                -- a lazy constructor failure must be a preparation rejection,
                -- never a thunk first forced by a live generation.
                _ <- evaluate resources
                _ <- evaluate (length resources.rrForeignEdges)
                _ <- evaluate (length resources.rrDeliveryTransports)
                for_ resources.rrForeignEdges evaluate
                for_ resources.rrDeliveryTransports evaluate
                pure resources
          initialResources <- prepareResources cfg
          runtimeStore <- newRuntimeConfigStore (runtimeValuesFromConfig cfg) initialResources
          initialRuntime <- currentRuntimeSnapshot runtimeStore
          let env =
                BotEnv
                  { bePersona = cfg.persona,
                    beRuntimeSnapshot = initialRuntime,
                    beConfigGeneration = initialRuntime.rsGeneration,
                    beConfigStore = runtimeStore,
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
                    beMaxOps = cfg.maxops,
                    beCliProxy = cfg.cliproxy,
                    beBrowserProxy = cfg.browserProxy,
                    beMemoryExtract = cfg.memoryExtractProfile,
                    beEpisodeScheduler = Just episodeScheduler,
                    beIntent = cfg.intent,
                    beEmbeddingEnabled = isJust cfg.embedding
                  }
          runEff
            . runConcurrent
            . runLog "max" logger LogTrace
            . runHttp httpRuntime
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runOutbound
            -- Token accounting goes through its own pooled connection
            -- (a plain IO writer): the LLM interpreter sits outside
            -- the WithConnection effect and the eval harness has no
            -- database at all, so the dependency stays out of the
            -- effect stack.
            . runRuntimeLLM
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
                  readTVarIO activeConfig >>= \current ->
                    when (isJust current.admin) . runEff . runWithConnectionPool pool $
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
              runtimeStore
            . runReader cfg.llm
            . runReader env
            . runRuntimePlatformApi qqEdge
            . runRuntimeEmbedding
            . runDurableAgent defaultLimits (allToolsFor httpRuntime env)
            $ runApp httpRuntime cfg activeConfig runtimeStore prepareResources controlPath applied eventQ fetchSig intentState logBuf clientRef mainTid
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
  TVar AppConfig ->
  RuntimeConfigStore ->
  (AppConfig -> IO RuntimeResources) ->
  FilePath ->
  [String] ->
  TQueue Event ->
  FetchSignal ->
  IntentState ->
  LogBuffer ->
  TVar ClientSlot ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp httpRuntime cfg activeConfig runtimeStore prepareResources controlPath applied eventQ fetchSig intentState logBuf clientRef mainTid =
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
          "db_max_conns" .= cfg.db.maxConns,
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
    reclaimedMonitorFires <- reclaimExpiredMonitorFireClaims
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
    let generationText snapshot = T.pack (show snapshot.rsGeneration.unConfigGeneration)
        ownerFor snapshot suffix = maintenanceOwner <> "/g" <> generationText snapshot <> "/" <> suffix
        environmentFor _candidate snapshot = applyRuntimeSnapshot snapshot env
        runGeneration candidate snapshot onReady =
          let workerEnv = environmentFor candidate snapshot
              requiredWorkers =
                [ worker "image-fetch" RequiredWorker (imageWorker candidate.imageWorkers fetchSig),
                  worker "forward-fetch" RequiredWorker (forwardWorker fetchSig),
                  worker "file-fetch" RequiredWorker (fileWorker fetchSig),
                  worker
                    "monitor-scheduler"
                    RequiredWorker
                    (monitorWorker candidate.timezone (ownerFor snapshot "monitors") dispatchMonitorFire),
                  worker "canonical-dispatch" RequiredWorker (dispatchPendingWorker (ownerFor snapshot "dispatch") fetchSig (intentState <$ workerEnv.beIntent)),
                  worker "durable-tasks" RequiredWorker (durableTaskWorker (ownerFor snapshot "tasks")),
                  worker "browser-workspaces" RestartableWorker (forever (browserMaintenance workerEnv.beBrowsers >> threadDelay 15_000_000)),
                  worker
                    "platform-delivery"
                    RequiredWorker
                    (deliveryWorker (ownerFor snapshot "delivery") snapshot.rsResources.rrDeliveryTransports)
                ]
              optionalWorkers =
                [ worker "shutdown-drain" OptionalWorker (drainWorker candidate.shutdownDrainSeconds mainTid workerEnv.beShutdown)
                ]
                  <> [ worker "embeddings" RestartableWorker (embedWorker (ownerFor snapshot "embedding"))
                     | workerEnv.beEmbeddingEnabled
                     ]
                  <> [ worker
                         "media-captions"
                         RestartableWorker
                         (concurrently_ (stickerCaptionWorker profile) (mediaCaptionWorker profile))
                     | profile <- maybeToList candidate.stickerCaptionProfile
                     ]
                  <> [ worker
                         "historian"
                         RestartableWorker
                         (historianWorker profile candidate.historianTimeoutSeconds candidate.llm candidate.timezone workerEnv.beTasks (defaultModelName candidate.llm) scheduler)
                     | (profile, scheduler) <- maybeToList ((,) <$> candidate.memoryExtractProfile <*> workerEnv.beEpisodeScheduler)
                     ]
                  <> [ worker "memory-dream" RestartableWorker (dreamWorker (ownerFor snapshot "memory-dream") profile candidate.timezone)
                     | profile <- maybeToList candidate.memoryExtractProfile
                     ]
                  <> [ worker
                         "intent"
                         RestartableWorker
                         (intentWorker intentCfg candidate.persona (defaultModelName candidate.llm) candidate.timezone workerEnv.beSessions (dispatchProactive (Just intentState)) intentState)
                     | intentCfg <- maybeToList candidate.intent
                     ]
                  <> [ worker "admin-server" RestartableWorker (adminServer adminCfg workerEnv (modelProfileNames candidate.llm) logBuf)
                     | adminCfg <- maybeToList candidate.admin
                     ]
                  <> [ worker "call-pruner" RestartableWorker (callPruner candidate.adminCallRetentionDays)
                     | _ <- maybeToList candidate.admin
                     ]
                  <> [ worker "wechathook" RestartableWorker (wechatHookWorker httpRuntime wh)
                     | wh <- maybeToList candidate.wechathook
                     ]
                  <> [ worker "matrix" RestartableWorker (matrixWorker httpRuntime matrixCfg workerEnv.beEpisodeScheduler)
                     | matrixCfg <- maybeToList candidate.matrix
                     ]
                  <> [ worker "imessage" RestartableWorker (iMessageWorker httpRuntime iMessageCfg workerEnv.beEpisodeScheduler)
                     | iMessageCfg <- maybeToList candidate.imessage
                     ]
           in local (const workerEnv) . local (const snapshot.rsValues.rvModelCatalog) $
                withLLMConfigGeneration snapshot.rsGeneration $
                  withWorkers (requiredWorkers <> optionalWorkers) (liftIO onReady >> liftIO (atomically retry))

        -- A worker generation is another owner of its immutable snapshot, in
        -- addition to individual dispatch leases.  Holding this lease until
        -- the entire group exits keeps old model credentials/resources valid
        -- throughout the bounded retirement overlap.
        runGenerationLeased run candidate expectedGeneration ready =
          bracket
            (atomically (acquireRuntimeConfigSTM runtimeStore))
            (atomically . releaseRuntimeConfigSTM)
            ( \lease -> do
                let snapshot = leasedRuntimeSnapshot lease
                if snapshot.rsGeneration.unConfigGeneration /= expectedGeneration
                  then throwIO (userError "worker acquired an unexpected configuration generation")
                  else
                    run
                      ( runGeneration
                          candidate
                          snapshot
                          (for_ ready (atomically . (`putTMVar` ())))
                      )
            )

        sandboxGc =
          forever $ do
            threadDelay (60 * 60 * 1_000_000)
            liftIO (reconcileSandboxes env.beSandboxes)
            removed <- liftIO (gcExpiredSandboxes env.beSandboxes)
            when (removed > 0) $
              logInfo "sandbox TTL GC" (object ["removed" .= removed])

    withRunInIO $ \run ->
      bracket
        (newGenerationSupervisor 1 (runGenerationLeased run cfg 1 Nothing))
        closeGenerationSupervisor
        ( \supervisor ->
            run $
              withWorkers
                [ worker "reload-control" RequiredWorker (runReloadServer controlPath (performReload (runGenerationLeased run) supervisor)),
                  -- Ingress owns the in-memory OneBot frame once it dequeues
                  -- it. Keeping this consumer process-lived means a worker
                  -- handoff cannot cancel it between dequeue and durable
                  -- canonical ingest; it leases the current config per event.
                  worker "event-handler" RequiredWorker (handleEvents eventQ fetchSig (Just intentState) clientRef),
                  worker "sandbox-gc" RestartableWorker sandboxGc
                ]
                -- The accepted reverse websocket and its generation remain in
                -- this process-owned layer for every configuration reload.
                (runServer cfg.server eventQ clientRef)
        )
  where
    performReload runGenerationLeased supervisor = localDomain "reload" $ do
      started <- liftIO getMonotonicTime
      oldSnapshot <- liftIO (currentRuntimeSnapshot runtimeStore)
      let oldNumber = oldSnapshot.rsGeneration.unConfigGeneration
          reject err changed restartFields = do
            finished <- liftIO getMonotonicTime
            logAttention "configuration reload rejected" $
              object
                [ "generation" .= oldNumber,
                  "duration_ms" .= elapsedMillis started finished,
                  "changed_fields" .= changed,
                  "restart_fields" .= restartFields,
                  "error_category" .= T.pack (show err)
                ]
            pure (ReloadResponse False oldNumber oldNumber changed restartFields (Just err))
      logInfo "configuration reload started" (object ["generation" .= oldNumber])
      liftIO (timeout reloadCandidateTimeoutMicros loadConfigCandidate) >>= \case
        Nothing -> reject ReloadTimedOut [] []
        Just (Left _) -> reject ReloadConfigInvalid [] []
        Just (Right candidate) -> do
          current <- liftIO (readTVarIO activeConfig)
          let changes = configChanges current candidate
              changedFields = (.changeField) <$> changes
              restartFields = (.changeField) <$> restartRequiredChanges changes
          if not (null restartFields)
            then reject ReloadRestartRequired changedFields restartFields
            else
              if null changes
                then do
                  finished <- liftIO getMonotonicTime
                  logInfo "configuration reload completed" $
                    object
                      [ "old_generation" .= oldNumber,
                        "new_generation" .= oldNumber,
                        "duration_ms" .= elapsedMillis started finished,
                        "changed_fields" .= changedFields,
                        "worker_handoff" .= False
                      ]
                  pure (ReloadResponse True oldNumber oldNumber [] [] Nothing)
                else do
                  let nextNumber = oldNumber + 1
                  workerReady <- liftIO newEmptyTMVarIO
                  liftIO
                    ( timeout reloadPreparationTimeoutMicros . trySyncIO $ do
                        preflightReloadListeners current candidate
                        resources <- prepareResources candidate
                        prepared <- prepareGeneration nextNumber (pure (runGenerationLeased candidate nextNumber (Just workerReady)))
                        pure (resources, prepared)
                    )
                    >>= \case
                      Nothing -> reject ReloadTimedOut changedFields []
                      Just (Left _) -> reject ReloadPreparationFailed changedFields []
                      Just (Right (_, Left PrepareFailure)) -> reject ReloadPreparationFailed changedFields []
                      Just (Right (resources, Right prepared)) -> do
                        committed <-
                          ( trySync . liftIO $
                              commitGeneration supervisor prepared $ do
                                snapshots <- publishRuntimeConfigSTM runtimeStore (runtimeValuesFromConfig candidate) resources
                                writeTVar activeConfig candidate
                                pure snapshots
                          )
                            `onException` liftIO (abortGeneration prepared)
                        case committed of
                          Left _ -> do
                            liftIO (abortGeneration prepared)
                            reject ReloadInternalFailure changedFields []
                          Right ((_, published), retired) -> do
                            -- Serialized reload does not answer until the new
                            -- group owns its snapshot.  A subsequent request can
                            -- therefore never collect this generation before its
                            -- workers have started.
                            liftIO (atomically (readTMVar workerReady))
                            finished <- liftIO getMonotonicTime
                            when (retired == RetireTimedOut) $
                              logAttention "superseded worker generation did not retire before deadline" $
                                object ["generation" .= oldNumber]
                            let newNumber = published.rsGeneration.unConfigGeneration
                            logInfo "configuration reload completed" $
                              object
                                [ "old_generation" .= oldNumber,
                                  "new_generation" .= newNumber,
                                  "duration_ms" .= elapsedMillis started finished,
                                  "changed_fields" .= changedFields,
                                  "worker_handoff" .= True,
                                  "retired" .= (retired == Retired)
                                ]
                            pure (ReloadResponse True oldNumber newNumber changedFields [] Nothing)

    elapsedMillis before after = round ((after - before) * 1000) :: Int

    preflightReloadListeners old new = do
      preflightChangedListener
        ((\adminCfg -> (adminCfg.acHost, adminCfg.acPort)) <$> old.admin)
        ((\adminCfg -> (adminCfg.acHost, adminCfg.acPort)) <$> new.admin)
      preflightChangedListener
        ((\hookCfg -> (hookCfg.whListenHost, hookCfg.whListenPort)) <$> old.wechathook)
        ((\hookCfg -> (hookCfg.whListenHost, hookCfg.whListenPort)) <$> new.wechathook)

-- | Log lines the admin panel can look back over.  A busy dispatch
-- prints on the order of ten, so this is a few hundred dispatches —
-- past "what just happened", which is the question it answers.
-- Anything older is journalctl's job.
logBufferLines :: Int
logBufferLines = 2000

-- Parsing is local file IO and generation preparation allocates local handles;
-- five seconds each leaves ample room for bounded retirement and the 25-second
-- maxctl deadline.  Crucially, both deadlines end before publication.
reloadCandidateTimeoutMicros, reloadPreparationTimeoutMicros :: Int
reloadCandidateTimeoutMicros = 5 * 1_000_000
reloadPreparationTimeoutMicros = 5 * 1_000_000

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
