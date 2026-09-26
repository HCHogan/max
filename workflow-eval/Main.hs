-- | Matched live-model serial/fan-out comparison using real source files,
-- process-owned child loops and shared execution boundary. The
-- read tool is frozen; this does not replay a historical production load.
module Main (main) where

import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeException, bracket, finally, mask_, try)
import Control.Monad (forM, forM_, forever, unless, void)
import Data.Aeson hiding (Options)
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Version (makeVersion)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent (runConcurrent)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Max.Agent.Execution
import Max.Agent.Runtime (executionAdmission, runAgentRuntime)
import Max.AgentEvent
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion, runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.Config (AppConfig (..), appConfigParser)
import Max.Conversation (newConversations)
import Max.DB.AgentTurn
import Max.DB.Connection
import Max.DB.Job (allocateJobId)
import Max.DB.Migrations (runMigrations)
import Max.Effects.Agent
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.LLM
import Max.Effects.Tools
import Max.Execution.Tools hiding (Interrupted)
import Max.Hash (jsonHash)
import Max.HttpRuntime (newHttpRuntime)
import Max.IR (Body (..), Node (NText))
import Max.Jobs qualified as Jobs
import Max.Log (withCompactLogger)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store.Endpoint (RegisteredEndpoint (endpointId))
import Max.Platform.Store.Ingest (IngestOptions (createDispatch, createMirrorDeliveries), IngestResult (Ingested), NewIngest (canonicalMessageId), defaultIngestOptions, ingestEnvelope)
import Max.Platform.Types
import Max.Skill.Contract (parseContract)
import Max.Task.Delegation (parseJobResult)
import Max.Task.State qualified as State
import Max.Task.ToolRuntime (taskTools)
import Max.Task.Types
import Max.Tasks (TaskRegistry, TurnRuntime, beginTurnRuntime, finishTurnRuntime, newTaskRegistry)
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Tools.Schema (stringParam, toolObject)
import Max.Turn.Continuity (toolCatalogFingerprint)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import OptEnvConf (Parser, help, long, metavar, option, optional, reader, runParser, setting, str)
import OptEnvConf qualified as Opt
import System.Environment (getEnvironment)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

data Options = Options {profile :: !Text, report :: !FilePath, seconds :: !Int, pairs :: !Int, mode :: !Text, snapshot :: !(Maybe FilePath)}

options :: Parser Options
options =
  Options
    <$> setting [option, reader str, long "eval-profile", metavar "NAME", help "Same production profile for every child"]
    <*> setting [option, reader str, long "eval-report", metavar "FILE", help "Public incremental measurement and reports"]
    <*> setting [option, reader Opt.auto, long "eval-seconds", metavar "SECONDS", Opt.value 300, help "Fixed whole-tree deadline, chosen before either arm"]
    <*> setting [option, reader Opt.auto, long "eval-pairs", metavar "COUNT", Opt.value 2, help "Counterbalanced matched pairs"]
    <*> setting [option, reader str, long "eval-mode", metavar "MODE", Opt.value "paired", help "paired scripts or ordinary single-agent baseline"]
    <*> optional (setting [option, reader str, long "eval-source-snapshot", metavar "FILE", help "Reuse a prior report's exact source_snapshot"])

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  environment <- getEnvironment
  unless (null [name | (name, _) <- environment, "MAX_LLM_" `T.isPrefixOf` T.pack name]) (die "unset MAX_LLM_* overrides")
  used <- newIORef Nothing
  (cfg, opts) <- runParser (makeVersion [0, 1, 0]) "max-workflow-eval" ((,) <$> appConfigParser used <*> options)
  unless (opts.seconds > 0 && opts.seconds <= 3000 && opts.pairs > 0 && opts.pairs <= 10) (die "invalid deadline/pair bound")
  unless (opts.mode `elem` ["paired", "ordinary"]) (die "eval-mode must be paired or ordinary")
  sources <- case opts.snapshot of
    Nothing -> Map.fromList <$> forM (concatMap snd questions) (\path -> (path,) <$> TIO.readFile (T.unpack path))
    Just path -> do
      value <- eitherDecodeFileStrict path >>= either die pure
      either die pure (parseEither (withObject "source snapshot" (.: "source_snapshot")) value)
  results <- newIORef []
  let save complete = readIORef results >>= \rows -> encodeFile opts.report (object ["complete" .= complete, "profile" .= opts.profile, "runtime" .= javaScriptRuntimeVersion, "deadline_seconds" .= opts.seconds, "controlled_read_tools" .= True, "historical_load_reproduced" .= False, "source_snapshot" .= sources, "parent_orchestration" .= (if opts.mode == "ordinary" then "ordinary_model_loop" else "host_authored_scripts" :: Text), "source_hashes" .= Map.map (jsonHash . String) sources, "cases" .= rows])
  save False
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    [Only database :: Only Text] <- withDb pool (query "SELECT current_database()" ())
    unless ("max_workflow_eval_" `T.isPrefixOf` database) (die "requires a disposable max_workflow_eval_* database")
    void (runMigrations pool cfg.migrationsDir)
    [Only empty] <- withDb pool (query "SELECT NOT EXISTS(SELECT 1 FROM messages)" ())
    unless empty (die "use a fresh evaluation database")
    let modes = concat [if odd n then [False, True] else [True, False] | n <- [1 .. opts.pairs]]
    forM_ (zip [930001 ..] (if opts.mode == "ordinary" then [False] else modes)) $ \(group, parallel) -> do
      row <- if opts.mode == "ordinary" then runOrdinary cfg opts pool sources group else runCase cfg opts pool sources group parallel
      modifyIORef' results (<> [row])
      save False
  save True

withDb :: DbPool -> Eff '[WithConnection, IOE] a -> IO a
withDb pool = runEff . runWithConnectionPool pool

newRoot :: DbPool -> Options -> Int64 -> Text -> Value -> Bool -> IO (TaskRegistry, Jobs.Jobs, JobView)
newRoot pool opts group objective inputs structured = do
  (front, message, actor) <- seed pool group
  withDb pool (finishAgentTurn front TurnSucceeded 0 Nothing)
  tasks <- newTaskRegistry
  jobs <- Jobs.newJobs tasks
  identifier <- withDb pool allocateJobId
  now <- getCurrentTime
  let outputContract = if structured then Just (either (error . T.unpack) id (parseContract outputSchema)) else Nothing
      spec = JobSpec (GroupId group) actor message objective Basic (taskGrants Basic evalGrants) inputs Nothing outputContract False Nothing Nothing (addUTCTime (fromIntegral opts.seconds) now)
  Right _ <- Jobs.admitJob jobs Nothing identifier spec
  Jobs.LaunchJob root <- Jobs.takeJobWork jobs
  pure (tasks, jobs, root)

attach :: DbPool -> TaskRegistry -> Jobs.Jobs -> JobView -> IO (AgentTurnRef, TurnRuntime)
attach pool tasks jobs job = do
  turn <- withDb pool (startAgentTurn job.spec.group job.spec.source job.spec.principal)
  runtime <- beginTurnRuntime tasks turn job.spec.group (UserId 1) (Just job.spec.source)
  attached <- Jobs.attachJobTurn jobs job.run turn
  unless attached (die "evaluation job ended before launch")
  pure (turn, runtime)

release :: TaskRegistry -> Jobs.Jobs -> JobView -> TurnRuntime -> IO ()
release tasks jobs job runtime = do
  void (finishTurnRuntime tasks runtime)
  Jobs.detachJobTurn jobs job.run

runCase :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> Int64 -> Bool -> IO Value
runCase cfg opts pool sources group parallel = do
  (tasks, jobs, root) <- newRoot pool opts group "Audit delegated-agent authority, budget and steering boundaries" Null False
  (parent, parentRuntime) <- attach pool tasks jobs root
  output <- newTurnOutputContext parent
  let context = mkToolContext (TurnIdentity root.spec.group root.spec.source (UserId 1) (UserId 3) root.spec.principal Nothing (Just output)) capabilities
      requests = [object ["objective" .= question, "profile" .= ("basic" :: Text), "inputs" .= object ["files" .= files], "output_contract" .= outputSchema] | (question, files) <- questions]
      script = "await max.phase('source audit'); const requests=" <> json requests <> "; " <> (if parallel then "return await Promise.all(requests.map(agent));" else "const reports = []; for (const request of requests) reports.push(await agent(request)); return reports;")
      hooks = (executionHooks (executionAdmission jobs) (ExecutionJournal recordModelNote enrichSandboxJournalStart recordJournalExecution) root.spec.group parentRuntime) {ehAcquireGuest = liftIO (Jobs.acquireGuestSlot jobs parent.atrTurnId)}
      registry = either (error . show) id (buildToolRegistry (filter ((/= ToolRef "web_search") . (.tdRef)) definitions) (filter (\tool -> tool.toolName `elem` ["agent", "agent_progress"]) (taskTools jobs context)))
  calls <- newIORef []
  workers <- newIORef []
  let workerLoop =
        forever $
          mask_ $
            Jobs.takeJobWork jobs >>= \case
              Jobs.LaunchJob child -> do
                worker <- Async.asyncWithUnmask (\unmask -> unmask (runChild cfg opts pool sources tasks jobs child calls))
                modifyIORef' workers (worker :)
              Jobs.PublishJobNotice job _ _ -> Jobs.releaseJobNotice jobs job.run
              Jobs.RecordMonitorResult _ -> die "unexpected reminder in source audit"
      cleanup = readIORef workers >>= mapM_ Async.cancel
  started <- getCurrentTime
  attempted <-
    try @SomeException $
      Async.withAsync
        workerLoop
        ( \_ -> timeout (opts.seconds * 1000000) $
            runEff . runConcurrent . runWithConnectionPool pool . runBlob "/tmp/max-workflow-eval-blobs" . runTools registry $ do
              session <- newExecutionSession (Just 200)
              runJavaScript session (hoistExecutionHooks raise hooks) (catalogTools (registryCatalog registry)) script
        )
        `finally` cleanup
  finished <- getCurrentTime
  children <- filter ((== Just root.run) . (.spec.parent)) <$> Jobs.listJobs jobs root.spec.group
  let outcome = fromRight Nothing attempted
      complete = maybe False ((== WasmCompleted) . (.cmExit)) outcome && length children == length questions && all ((== State.Succeeded) . (.status)) children
  Jobs.completeJob jobs root.run (if complete then State.Succeeded else State.Failed) (JobResult (if complete then "All independent source audits completed" else "evaluation deadline or incomplete workflow") Nothing)
  withDb pool (finishAgentTurn parent (if complete then TurnSucceeded else TurnFailed) 0 Nothing)
  release tasks jobs root parentRuntime
  Just settled <- Jobs.lookupJob jobs root.spec.group root.run.jobId
  [Only sourceReads :: Only Int] <- withDb pool (query "SELECT count(*) FROM execution_journal journal JOIN agent_turns turn USING(turn_id) JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND journal.tool_ref='web_search' AND journal.state='succeeded'" (Only group))
  records <- reverse <$> readIORef calls
  let usages = [usage | c <- records, Just usage <- [c.crUsage]]
  putStrLn ((if parallel then "parallel" else "serial") <> ": " <> show complete <> ", " <> show (diffUTCTime finished started))
  pure (object ["mode" .= (if parallel then "parallel" else "serial" :: Text), "completed" .= complete, "started_at" .= started, "seconds" .= (realToFrac (diffUTCTime finished started) :: Double), "model_calls" .= length records, "model_rounds_reserved" .= settled.rounds, "usage_complete" .= (length usages == settled.rounds), "settled_parent_status" .= settled.status, "settled_child_statuses" .= map (.status) children, "actual_models" .= Set.toList (Set.fromList (map (.crModel) records)), "usage_records" .= length usages, "prompt_tokens" .= sum (map (.usagePrompt) usages), "completion_tokens" .= sum (map (.usageCompletion) usages), "children" .= children, "workflow_output" .= (outcome >>= (.cmOutput)), "source_reads" .= sourceReads])

runOrdinary :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> Int64 -> IO Value
runOrdinary cfg opts pool sources group = do
  (tasks, jobs, root) <- newRoot pool opts group (T.intercalate "\n" (map fst questions)) (object ["files" .= Map.keys sources]) True
  records <- newIORef []
  started <- getCurrentTime
  _ <- try @SomeException (timeout (opts.seconds * 1000000) (runChild cfg opts pool sources tasks jobs root records))
  finished <- getCurrentTime
  Just settled <- Jobs.lookupJob jobs root.spec.group root.run.jobId
  let complete = settled.status == State.Succeeded
  calls <- readIORef records
  [Only sourceReads :: Only Int] <- withDb pool (query "SELECT count(*) FROM execution_journal journal JOIN agent_turns turn USING(turn_id) JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND journal.tool_ref='web_search' AND journal.state='succeeded'" (Only group))
  let usages = [usage | call <- calls, Just usage <- [call.crUsage]]
      elapsed = realToFrac (diffUTCTime finished started) :: Double
  putStrLn ("ordinary: " <> show complete <> ", " <> show elapsed)
  pure (object ["mode" .= ("ordinary" :: Text), "completed" .= complete, "seconds" .= elapsed, "started_at" .= started, "result" .= settled.result, "model_calls" .= length calls, "model_rounds_reserved" .= settled.rounds, "usage_complete" .= (length usages == settled.rounds), "settled_parent_status" .= settled.status, "source_reads" .= sourceReads, "actual_models" .= Set.toList (Set.fromList (map (.crModel) calls)), "prompt_tokens" .= sum (map (.usagePrompt) usages), "completion_tokens" .= sum (map (.usageCompletion) usages), "usage_records" .= length usages])

runChild :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> TaskRegistry -> Jobs.Jobs -> JobView -> IORef [CallRecord] -> IO ()
runChild cfg opts pool sources tasks jobs job records =
  bracket (attach pool tasks jobs job) cleanup $ \(turn, taskRuntime) -> do
    conversations <- newConversations
    output <- newTurnOutputContext turn
    runtime <- newHttpRuntime
    let context = mkToolContext (TurnIdentity job.spec.group job.spec.source (UserId 1) (UserId 3) job.spec.principal Nothing (Just output)) capabilities {tcEffectCeiling = Just job.spec.grants}
        messages = [MsgSystem "Read every provided file using web_search(query=exact file path). It returns frozen repository source with source:path as its citation. Analyze the objective using those reads. End with one JSON value matching output_contract: claims contains concrete findings, sources contains every source:path read. Never delegate or run_code. Shape does not establish correctness; acknowledge insufficient evidence in the claims. Do not claim deployment or measured performance benefits.", MsgUser (job.spec.objective <> "\n" <> json job.spec.inputs <> "\noutput_contract: " <> json job.spec.contract)]
    result <- withCompactLogger cfg.logColor Nothing $ \logger -> runEff . runConcurrent . runLog "max-workflow-eval" logger LogAttention . runWithConnectionPool pool . runBlob "/tmp/max-workflow-eval-blobs" . runLLM runtime (\_ _ _ -> pure ()) (\call -> atomicModifyIORef' records (\xs -> (call : xs, ()))) cfg.llm . runAgentRuntime jobs conversations (AgentLimits 12) (factory jobs sources) $ agentTurn taskRuntime (AgentContext context Nothing (Just 24) Nothing) opts.profile messages silentSink
    let answer = case result.outcome of
          Answered reply -> parseJobResult job.spec reply.body
          Interrupted _ _ -> Left "agent interrupted"
          Failed _ _ -> Left "agent failed"
    case answer of
      Right value -> Jobs.completeJob jobs job.run State.Succeeded value
      Left detail -> Jobs.completeJob jobs job.run State.Failed (JobResult detail Nothing)
    withDb pool (finishAgentTurn turn (either (const TurnFailed) (const TurnSucceeded) answer) result.turnsUsed Nothing)
  where
    cleanup (turn, taskRuntime) =
      ( do
          Jobs.completeJob jobs job.run State.Failed (JobResult "evaluation interrupted" Nothing)
          withDb pool (finishAgentTurn turn TurnCancelled 0 (Just "evaluation ended"))
      )
        `finally` release tasks jobs job taskRuntime

factory :: (WithConnection :> es, Blob :> es, IOE :> es) => Jobs.Jobs -> Map.Map Text Text -> ToolContext -> Either ToolCatalogError (ToolRegistry es)
factory jobs sources context = buildToolRegistry definitions (readerTool : filter (\tool -> tool.toolName `elem` ["agent", "agent_progress"]) (taskTools jobs context))
  where
    readerTool = legacyTool "web_search" "Read frozen repository source. query must equal an input file path." (toolObject [("query", stringParam "Exact file path")] ["query"]) $ \args -> pure $ do
      path <- either (Left . T.pack) Right (parseEither (withObject "source read" (.: "query")) args)
      body <- maybe (Left "file outside the frozen evidence set") Right (Map.lookup path sources)
      Right (object ["source" .= ("source:" <> path), "body" .= body, "fingerprint" .= jsonHash (String body)])

definitions :: [ToolDefinition]
definitions = [ToolDefinition (ToolRef name) (SchemaVersion 1) (Set.singleton (if name == "web_search" then EffectRead "source" else EffectWrite "task.db")) parallelism (if name == "web_search" then RetrySafe else RetryUnsafe) (Set.singleton CurrentConversation) (ToolDeadline deadline) True mode (if name == "agent" then AsyncTool else ShortTool) | (name, mode, parallelism, deadline) <- [("web_search", WorkCall, SequentialOnly, 30), ("agent", WorkCall, ParallelIndependent, 21600), ("agent_progress", CheckpointCall, SequentialOnly, 30)]]

evalGrants :: Map.Map Text Text
evalGrants = Map.fromList [(entry.tdRef.unToolRef, toolCatalogFingerprint [entry]) | entry <- definitions]

capabilities :: TurnCapabilities
capabilities =
  TurnCapabilities
    { tcMultimodal = False,
      tcStickers = False,
      tcSkills = False,
      tcOutput = noAdvertisedCaps,
      tcMonitorArming = False,
      tcCatalogGrants = evalGrants,
      tcEffectCeiling = Just evalGrants,
      tcBackground = True
    }

outputSchema :: Value
outputSchema = object ["type" .= ("object" :: Text), "properties" .= object ["claims" .= strings, "sources" .= strings], "required" .= (["claims", "sources"] :: [Text]), "additionalProperties" .= False]
  where
    strings = object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text), "minLength" .= (1 :: Int)], "minItems" .= (1 :: Int)]

questions :: [(Text, [Text])]
questions =
  [ ("Audit whether agent() can widen its parent's authority. Identify the actual rejection and intersection points and any limits of the evidence.", ["src/Max/Effects/TaskControl.hs", "src/Max/Task/Types.hs"]),
    ("Audit whether two awaited siblings can overspend the shared call/round budget and whether waiting parents can deadlock task capacity. Cite actual STM transactions and counters.", ["src/Max/Jobs.hs", "src/Max/DB/Job.hs"]),
    ("Audit steering and cancellation boundaries. Explain whether explicitly rerunning a script creates new work and identify provenance gaps.", ["src/Max/Effects/TaskControl.hs", "src/Max/CodeMode/Execution.hs", "src/Max/Task/Delegation.hs"])
  ]

silentSink :: (Applicative m) => AgentEventSink m
silentSink (AgentFinalStreamText _) = pure True
silentSink (AgentProgressText _) = pure ()
silentSink (AgentToolDebug _) = pure ()

json :: (ToJSON a) => a -> Text
json = TE.decodeUtf8 . LBS.toStrict . encode

seed :: DbPool -> Int64 -> IO (AgentTurnRef, CanonicalMessageId, PrincipalId)
seed pool group = withDb pool $ do
  now <- liftIO getCurrentTime
  endpoint <- ensureQQEndpointFor (UserId 3) (GroupId group)
  result <- ingestEnvelope defaultIngestOptions {createDispatch = False, createMirrorDeliveries = False} (InboundEnvelope endpoint.endpointId (NativeEventId (T.pack (show group))) (NativeUserId "1") Nothing now now EventMessage LiveDelivery (Body [NText "Audit the delegated workflow implementation"]) [] Nothing Nothing)
  message <- case result of Ingested row -> pure row.canonicalMessageId; _ -> error "fresh input required"
  actors <- query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
  let actor = case actors of [Only value] -> PrincipalId value; _ -> error "source principal missing"
  front <- startAgentTurn (GroupId group) message actor
  pure (front, message, actor)
