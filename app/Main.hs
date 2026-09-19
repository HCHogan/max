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
import Max.Admin (AdminConfig (..), adminServer)
import Max.Agent.Runtime (runAgentRuntime)
import Max.Browser.Registry
  ( configureBrowserRegistry,
    destroyAllBrowsers,
    newBrowserRegistry,
    reapStaleBrowsers,
  )
import Max.Browser.Runtime (browserMaintenance)
import Max.Browser.Vault (loadBrowserVault)
import Max.Config (AppConfig (..), loadConfig)
import Max.Conversation (newConversations)
import Max.DB.AgentTurn (addAgentTurnUsage, reclaimInterruptedTurns)
import Max.DB.Calls (insertCall, pruneCalls, redactDataUrls)
import Max.DB.Connection (DbConfig (..), closeDbPool, newDbPool)
import Max.DB.Migrations (runMigrations)
import Max.DB.Monitor (reclaimExpiredMonitorFireClaims)
import Max.DB.Usage (insertUsage)
import Max.Effects.Agent (Agent, defaultLimits)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.BlobHost (BlobHost, runBlobHost)
import Max.Effects.Embedding (Embedding, runRuntimeEmbedding)
import Max.Effects.Http (Http, runHttp)
import Max.Effects.LLM (CallRecord (..), ChatCtx (..), LLM, TokenUsage (..), runLLM)
import Max.Effects.Outbound (Outbound, runOutbound)
import Max.Effects.PlatformAccount (PlatformAccount)
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Embedder (embedWorker)
import Max.Embedding (newEmbedClient)
import Max.Embedding.Maintenance (newEmbeddingLock)
import Max.Env (BotEnv (..))
import Max.EpisodeScheduler (newEpisodeScheduler)
import Max.FetchQueue (FetchSignal, newFetchSignal)
import Max.Files (fileWorker)
import Max.Forward (forwardWorker)
import Max.Handler (dispatchMonitorFire, dispatchProactive, handleEvents, ingressWorker, jobsWorker)
import Max.Historian (historianWorker)
import Max.HttpRuntime (HttpRuntime, newHttpRuntime)
import Max.IMessage (iMessageDeliveryTransport, iMessageWorker)
import Max.Images (imageWorker)
import Max.Intent (IntentState, intentWorker, newIntentState)
import Max.Jobs (newJobs)
import Max.Log (withCompactLogger)
import Max.LogBuffer (LogBuffer, newLogBuffer, pushLog)
import Max.Matrix (matrixDeliveryTransport, matrixWorker)
import Max.Media (mediaDiscoveryWorker)
import Max.MediaCaption (mediaCaptionWorker)
import Max.Memory.Expiry (expiryWorker)
import Max.ModelCatalog (ModelCatalog, defaultModelName, modelProfileNames)
import Max.Monitor (monitorWorker)
import Max.Platform.Delivery (DeliveryTransport, deliveryWorker, oneBotDeliveryTransport)
import Max.Platform.Delivery.Queue (newDeliveryQueue)
import Max.Platform.Ingress (newIngress)
import Max.Platform.Runtime (qqBackend, runPlatforms)
import Max.Platform.Store (deliveryProcessBoundary)
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
import Max.Worker (WorkerCriticality (..), withWorkers, worker)
import OneBot.Event (Event)
import OneBot.Server (ClientSlot, ServerConfig (..), runServer)
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
    browserKey <- loadBrowserVault cfg.browserStateKeyFile
    browsers <- configureBrowserRegistry browserKey cfg.browserIdleSeconds cfg.browserGraceSeconds <$> newBrowserRegistry httpRuntime
    ( do
        logBuf <- newLogBuffer logBufferLines
        withCompactLogger cfg.logColor (Just (pushLog logBuf)) $ \logger -> do
          eventQ <- newTQueueIO
          fetchSig <- newFetchSignal
          sessions <- newSessionRegistry
          skillReg <- newSkillRegistry
          tasks <- newTaskRegistry
          jobs <- newJobs tasks
          clientRef <- newTVarIO (Nothing :: ClientSlot)
          adminTargets <- newTVarIO (mempty :: Map.Map Int64 Int64)
          episodeScheduler <- newEpisodeScheduler
          intentState <- newIntentState
          conversations <- newConversations
          boundary <- runEff . runWithConnectionPool pool $ deliveryProcessBoundary
          deliveries <- newDeliveryQueue boundary
          ingress <- newIngress deliveries
          embeddingLock <- newEmbeddingLock
          startedAt <- getCurrentTime
          let qqEdge = qqBackend clientRef
              foreignEdges =
                [ wechatHookBackend httpRuntime (runEff . runWithConnectionPool pool) hook
                | hook <- maybeToList cfg.wechathook
                ]
              deliveryTransports =
                [oneBotDeliveryTransport httpRuntime PlatformQQ qqEdge]
                  <> [matrixDeliveryTransport httpRuntime matrixCfg | matrixCfg <- maybeToList cfg.matrix]
                  <> [iMessageDeliveryTransport httpRuntime iMessageCfg | iMessageCfg <- maybeToList cfg.imessage]
                  <> [oneBotDeliveryTransport httpRuntime PlatformWeChatHook backend | backend <- foreignEdges]
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
                    beWebhookBaseUrl = cfg.admin >>= (.acWebhookBaseUrl),
                    beTasks = tasks,
                    beConversations = conversations,
                    beIngress = ingress,
                    beFetch = fetchSig,
                    beDeliveries = deliveries,
                    beJobs = jobs,
                    beShutdown = shutdown,
                    beSandboxes = sandboxes,
                    beBrowsers = browsers,
                    beSearch = cfg.search,
                    beCliProxy = cfg.cliproxy,
                    beBrowserProxy = cfg.browserProxy,
                    beMemoryExtract = cfg.memoryExtractProfile,
                    beEpisodeScheduler = Just episodeScheduler,
                    beIntent = cfg.intent,
                    beEmbeddingEnabled = isJust cfg.embedding,
                    beEmbeddingLock = embeddingLock
                  }
          runEff
            . runConcurrent
            . runLog "max" logger cfg.logLevel
            . runHttp httpRuntime
            . runBlobHost cfg.imagesDir
            . runBlob cfg.imagesDir
            . runWithConnectionPool pool
            . runOutbound tasks jobs deliveries
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
            . runPlatforms qqEdge foreignEdges
            . runRuntimeEmbedding (pure (newEmbedClient httpRuntime <$> cfg.embedding))
            . runAgentRuntime jobs conversations defaultLimits (allToolsFor httpRuntime env)
            $ runApp httpRuntime cfg deliveryTransports applied eventQ fetchSig intentState logBuf clientRef mainTid
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
    BlobHost :> es,
    Blob :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    PlatformAccount :> es,
    Outbound :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es
  ) =>
  HttpRuntime ->
  AppConfig ->
  [DeliveryTransport] ->
  [String] ->
  TQueue Event ->
  FetchSignal ->
  IntentState ->
  LogBuffer ->
  TVar ClientSlot ->
  -- | Main thread, for 'drainWorker' to interrupt once drained.
  ThreadId ->
  Eff es ()
runApp httpRuntime cfg deliveryTransports applied eventQ fetchSig intentState logBuf clientRef mainTid =
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
    reclaimed <- reclaimInterruptedTurns
    reclaimedMonitorFires <- reclaimExpiredMonitorFireClaims
    when (reclaimedMonitorFires > 0) $
      logAttention "monitor scheduler: expired claims reclaimed" $
        object ["fires" .= reclaimedMonitorFires]
    when (reclaimed > 0) $
      logAttention "interrupted turns ended" (object ["turns_crashed" .= reclaimed])
    -- The skill cache is authoritative once loaded (write-through, same
    -- rule as sessions), so it has to fill before the first dispatch or
    -- the admin server can consult it.
    nSkills <- loadSkills env.beSkills
    logInfo "skills loaded" $ object ["count" .= nSkills]
    let ownerFor suffix = maintenanceOwner <> "/" <> suffix
        permanentWorkers =
          [ worker "image-fetch" RequiredWorker (imageWorker cfg.imageWorkers fetchSig),
            worker "forward-fetch" RequiredWorker (forwardWorker fetchSig),
            worker "file-fetch" RequiredWorker (fileWorker fetchSig),
            worker
              "monitor-scheduler"
              RequiredWorker
              (monitorWorker cfg.timezone (ownerFor "monitors") dispatchMonitorFire),
            worker "media-discovery" RequiredWorker (mediaDiscoveryWorker fetchSig),
            worker "canonical-dispatch" RequiredWorker (ingressWorker fetchSig (intentState <$ env.beIntent)),
            worker "jobs" RequiredWorker jobsWorker,
            worker "browser-workspaces" RequiredWorker (forever (browserMaintenance env.beBrowsers >> threadDelay 15_000_000)),
            worker
              "platform-delivery"
              RequiredWorker
              (deliveryWorker env.beDeliveries deliveryTransports)
          ]
        configuredWorkers =
          [ worker "shutdown-drain" OptionalWorker (drainWorker cfg.shutdownDrainSeconds mainTid env.beShutdown)
          ]
            <> [ worker "embeddings" RequiredWorker (embedWorker env.beEmbeddingLock)
               | env.beEmbeddingEnabled
               ]
            <> [ worker
                   "media-captions"
                   RequiredWorker
                   (concurrently_ (stickerCaptionWorker profile) (mediaCaptionWorker profile))
               | profile <- maybeToList cfg.stickerCaptionProfile
               ]
            <> [ worker
                   "historian"
                   RequiredWorker
                   (historianWorker profile cfg.historianTimeoutSeconds cfg.llm cfg.timezone env.beTasks (defaultModelName cfg.llm) scheduler)
               | (profile, scheduler) <- maybeToList ((,) <$> cfg.memoryExtractProfile <*> env.beEpisodeScheduler)
               ]
            <> [worker "memory-expiry" RequiredWorker expiryWorker]
            <> [ worker
                   "intent"
                   RequiredWorker
                   (intentWorker intentCfg cfg.persona (defaultModelName cfg.llm) cfg.timezone env.beSessions (dispatchProactive (Just intentState)) intentState)
               | intentCfg <- maybeToList cfg.intent
               ]
            <> [ worker "admin-server" RequiredWorker (adminServer adminCfg env (modelProfileNames cfg.llm) logBuf)
               | adminCfg <- maybeToList cfg.admin
               ]
            <> [ worker "call-pruner" RequiredWorker (callPruner cfg.adminCallRetentionDays)
               | _ <- maybeToList cfg.admin
               ]
            <> [ worker "wechathook" RequiredWorker (wechatHookWorker httpRuntime wh env.beIngress)
               | wh <- maybeToList cfg.wechathook
               ]
            <> [ worker "matrix" RequiredWorker (matrixWorker httpRuntime matrixCfg env.beEpisodeScheduler env.beIngress)
               | matrixCfg <- maybeToList cfg.matrix
               ]
            <> [ worker "imessage" RequiredWorker (iMessageWorker httpRuntime iMessageCfg env.beEpisodeScheduler env.beIngress env.beDeliveries)
               | iMessageCfg <- maybeToList cfg.imessage
               ]

        sandboxGc = forever $ do
          threadDelay (60 * 60 * 1_000_000)
          liftIO (reconcileSandboxes env.beSandboxes)
          removed <- liftIO (gcExpiredSandboxes env.beSandboxes)
          when (removed > 0) $
            logInfo "sandbox TTL GC" (object ["removed" .= removed])

    withWorkers
      ( permanentWorkers
          <> configuredWorkers
          <> [ worker "event-handler" RequiredWorker (handleEvents eventQ fetchSig (Just intentState) clientRef),
               worker "sandbox-gc" RequiredWorker sandboxGc
             ]
      )
      (runServer cfg.server eventQ clientRef)

-- | Log lines the admin panel can look back over.  A busy dispatch
-- prints on the order of ten, so this is a few hundred dispatches —
-- past "what just happened", which is the question it answers.
-- Anything older is journalctl's job.
logBufferLines :: Int
logBufferLines = 2000

-- | Prune expired call bodies at startup and hourly to keep deletes small.
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
