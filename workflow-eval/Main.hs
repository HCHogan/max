-- | Matched live-model serial/fan-out comparison using real source files,
-- ordinary durable child loops, the production scheduler and journal. The
-- read tool is frozen; this does not replay a historical production load.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forM, forM_, forever, unless, void)
import Data.Aeson hiding (Options)
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Version (makeVersion)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent (runConcurrent)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Max.Agent.Execution
import Max.Agent.Runtime (durableExecutionAdmission, runDurableAgent)
import Max.AgentEvent
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion, runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.Config (AppConfig (..), appConfigParser)
import Max.DB.AgentTurn
import Max.DB.Connection
import Max.DB.Migrations (runMigrations)
import Max.DB.Task
import Max.Effects.Agent
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.LLM
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.HttpRuntime (newHttpRuntime)
import Max.IR (Body (..), Node (NText))
import Max.Log (withCompactLogger)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store hiding (capabilities, fingerprint)
import Max.Platform.Types
import Max.Task.Admission qualified as Admission
import Max.Task.Experience (fingerprint)
import Max.Task.State qualified as State
import Max.Task.ToolRuntime (taskToolsWithDatabase)
import Max.Task.Types
import Max.Task.WorkflowRuntime (taskWorkflowHost)
import Max.Tasks (beginDurableTurnRuntime, finishTurnRuntime, newTaskRegistry)
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
  let save complete = readIORef results >>= \rows -> encodeFile opts.report (object ["complete" .= complete, "profile" .= opts.profile, "runtime" .= javaScriptRuntimeVersion, "deadline_seconds" .= opts.seconds, "controlled_read_tools" .= True, "historical_load_reproduced" .= False, "source_snapshot" .= sources, "parent_orchestration" .= (if opts.mode == "ordinary" then "ordinary_model_loop" else "host_authored_scripts" :: Text), "source_hashes" .= Map.map (fingerprint . String) sources, "cases" .= rows])
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

runCase :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> Int64 -> Bool -> IO Value
runCase cfg opts pool sources group parallel = do
  (front, message, actor) <- seed pool group
  admission <- withDb pool (admitTaskReceipt front message actor "root" "Audit delegated-agent authority, budget and resume boundaries" Research Null (taskGrants Research grants))
  root <- either (die . T.unpack . Admission.admissionErrorText) pure admission
  void $ withDb pool (execute "UPDATE durable_tasks SET deadline=clock_timestamp()+?*interval '1 second' WHERE task_id=?" (opts.seconds, Admission.taskId root))
  [parentId] <- withDb pool (claimTask "workflow-eval")
  Just parent <- withDb pool (taskTurnRef parentId)
  output <- newTurnOutputContext parent
  let context = mkToolContext (TurnIdentity (GroupId group) message (UserId 1) (UserId 3) actor Nothing (Just output)) capabilities
      requests = [object ["objective" .= question, "profile" .= ("research" :: Text), "inputs" .= object ["files" .= files], "output_contract" .= contract] | (question, files) <- questions]
      script = "max.phase('source audit'); const requests=" <> json requests <> "; return " <> (if parallel then "max.batch(requests.map(agent=>({agent}))).map(max.value)" else "requests.map(agent)") <> ";"
      hooks = ExecutionHooks (pure ()) (durableExecutionAdmission.eaStartTool (GroupId group) parent) finishJournalExecution markJournalOutcomeUnknown (Just (taskWorkflowHost context parent))
      registry = either (error . show) id (buildToolRegistry (filter ((/= ToolRef "web_search") . (.tdRef)) definitions) [Tool name "host task marker" (toolObject [] []) (const (pure (Left "use the host primitive"))) | name <- ["task_start", "task_finish", "task_progress"]])
  calls <- newIORef []
  workers <- newIORef []
  let workerLoop = forever $ do
        claimed <- withDb pool (claimTask "workflow-eval-child")
        forM_ claimed $ \identifier -> do
          worker <- Async.async (runChild cfg opts pool sources identifier calls)
          modifyIORef' workers (worker :)
        threadDelay 20000
      renew = forever $ do
        turns <- withDb pool (query "SELECT turn_id FROM task_attempts JOIN durable_tasks USING(task_id) WHERE status='running' AND conversation_id=(SELECT conversation_id FROM durable_tasks WHERE task_id=?)" (Only (Admission.taskId root)))
        forM_ (turns :: [Only AgentTurnId]) (\(Only turn) -> void (withDb pool (renewTask turn)))
        threadDelay 1000000
      cleanup = readIORef workers >>= mapM_ Async.cancel
  started <- getCurrentTime
  attempted <-
    try @SomeException $
      Async.withAsync
        workerLoop
        ( \_ -> Async.withAsync renew $ \_ ->
            timeout
              (opts.seconds * 1000000)
              ( runEff . runConcurrent . runWithConnectionPool pool . runBlob "/tmp/max-workflow-eval-blobs" . runTools registry $ do
                  session <- newExecutionSession (Just 200)
                  runJavaScript session (hoistExecutionHooks raise hooks) (catalogTools (registryCatalog registry)) script
              )
        )
        `finally` cleanup
  let outcome = fromRight Nothing attempted
  finished <- getCurrentTime
  rows <- withDb pool (query "SELECT status,result FROM durable_tasks WHERE parent_task_id=? ORDER BY task_id" (Only (Admission.taskId root)))
  let children = rows :: [(Text, Maybe Value)]
      complete = maybe False ((== WasmCompleted) . (.cmExit)) outcome && length children == length questions && all ((== "succeeded") . fst) children
  if complete
    then do
      void (withDb pool (taskInbox parentId))
      accepted <- withDb pool (taskReportTyped parentId (State.TaskReport State.ReportSucceeded "All independent source audits completed" ["workflow:" <> fingerprint (String script)] [] Nothing Nothing Nothing))
      unless accepted (die "completed parent report rejected")
      withDb pool (finishAgentTurn parent TurnSucceeded 0 Nothing Nothing)
      [Only settled :: Only Text] <- withDb pool (query "SELECT status FROM durable_tasks WHERE task_id=?" (Only (Admission.taskId root)))
      unless (settled == "succeeded") (die "parent did not settle as succeeded")
    else do
      _ <- withDb pool (taskControl (GroupId group) actor False (Admission.taskId root) "cancel" Nothing (Just message) "evaluation deadline or incomplete workflow")
      withDb pool (finishAgentTurn parent TurnAborted 0 (Just "evaluation deadline or incomplete workflow") Nothing)
  [Only sourceReads :: Only Int] <- withDb pool (query "SELECT count(*) FROM execution_journal journal JOIN task_attempts attempt USING(turn_id) JOIN durable_tasks work USING(task_id) WHERE work.parent_task_id=? AND journal.tool_ref='web_search' AND journal.state='succeeded'" (Only (Admission.taskId root)))
  [(settledStatus, roundsReserved)] <- withDb pool (query "SELECT status,rounds_reserved FROM durable_tasks WHERE task_id=?" (Only (Admission.taskId root)))
  settledChildren <- withDb pool (query "SELECT status FROM durable_tasks WHERE parent_task_id=? ORDER BY task_id" (Only (Admission.taskId root)))
  records <- reverse <$> readIORef calls
  let usages = [usage | c <- records, Just usage <- [c.crUsage]]
  putStrLn ((if parallel then "parallel" else "serial") <> ": " <> show complete <> ", " <> show (diffUTCTime finished started))
  pure (object ["mode" .= (if parallel then "parallel" else "serial" :: Text), "completed" .= complete, "started_at" .= started, "seconds" .= (realToFrac (diffUTCTime finished started) :: Double), "model_calls" .= length records, "model_rounds_reserved" .= (roundsReserved :: Int), "usage_complete" .= (length usages == roundsReserved), "settled_parent_status" .= (settledStatus :: Text), "settled_child_statuses" .= [status | Only (status :: Text) <- settledChildren], "actual_models" .= Set.toList (Set.fromList (map (.crModel) records)), "usage_records" .= length usages, "prompt_tokens" .= sum (map (.usagePrompt) usages), "completion_tokens" .= sum (map (.usageCompletion) usages), "children" .= [object ["status" .= status, "report" .= result] | (status, result) <- children], "workflow_output" .= (outcome >>= (.cmOutput)), "source_reads" .= sourceReads])

-- One ordinary model loop over the full same objective is a stronger baseline
-- than serial delegation. It must be measured, not inferred from script timing.
runOrdinary :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> Int64 -> IO Value
runOrdinary cfg opts pool sources group = do
  (front, message, actor) <- seed pool group
  let inputs = object ["files" .= Map.keys sources, "output_contract" .= contract]
  admission <- withDb pool (admitTaskReceipt front message actor "ordinary" (T.intercalate "\n" (map fst questions)) Research inputs (taskGrants Research grants))
  root <- either (die . T.unpack . Admission.admissionErrorText) pure admission
  void $ withDb pool (execute "UPDATE durable_tasks SET deadline=clock_timestamp()+?*interval '1 second' WHERE task_id=?" (opts.seconds, Admission.taskId root))
  [identifier] <- withDb pool (claimTask "ordinary-eval")
  records <- newIORef []
  started <- getCurrentTime
  let renew = forever (void (withDb pool (renewTask identifier)) >> threadDelay 1000000)
  _ <- try @SomeException (Async.withAsync renew (\_ -> timeout (opts.seconds * 1000000) (runChild cfg opts pool sources identifier records)))
  finished <- getCurrentTime
  [(status, result, roundsReserved)] <- withDb pool (query "SELECT status,result,rounds_reserved FROM durable_tasks WHERE task_id=?" (Only (Admission.taskId root)))
  let complete = (status :: Text) == "succeeded"
  unless complete $ void $ withDb pool (taskControl (GroupId group) actor False (Admission.taskId root) "cancel" Nothing (Just message) "ordinary evaluation ended")
  [Only settledStatus :: Only Text] <- withDb pool (query "SELECT status FROM durable_tasks WHERE task_id=?" (Only (Admission.taskId root)))
  calls <- readIORef records
  [Only sourceReads :: Only Int] <- withDb pool (query "SELECT count(*) FROM execution_journal WHERE turn_id=? AND tool_ref='web_search' AND state='succeeded'" (Only identifier))
  let usages = [usage | call <- calls, Just usage <- [call.crUsage]]
      elapsed = realToFrac (diffUTCTime finished started) :: Double
  putStrLn ("ordinary: " <> show complete <> ", " <> show elapsed)
  pure (object ["mode" .= ("ordinary" :: Text), "completed" .= complete, "seconds" .= elapsed, "started_at" .= started, "result" .= (result :: Maybe Value), "model_calls" .= length calls, "model_rounds_reserved" .= (roundsReserved :: Int), "usage_complete" .= (length usages == roundsReserved), "settled_parent_status" .= settledStatus, "source_reads" .= sourceReads, "actual_models" .= Set.toList (Set.fromList (map (.crModel) calls)), "prompt_tokens" .= sum (map (.usagePrompt) usages), "completion_tokens" .= sum (map (.usageCompletion) usages), "usage_records" .= length usages])

runChild :: AppConfig -> Options -> DbPool -> Map.Map Text Text -> AgentTurnId -> IORef [CallRecord] -> IO ()
runChild cfg opts pool sources identifier records = do
  Just task <- withDb pool (loadTaskExecution identifier)
  output <- newTurnOutputContext task.teTurn
  tasks <- newTaskRegistry
  turn <- beginDurableTurnRuntime tasks task.teTurn task.teGroup (UserId 1) (Just task.teSeed)
  runtime <- newHttpRuntime
  let context = mkToolContext (TurnIdentity task.teGroup task.teSeed (UserId 1) (UserId 3) task.tePrincipal Nothing (Just output)) capabilities {tcEffectCeiling = Just task.teGrants}
      messages = [MsgSystem "You are Max's bounded research child. Read every provided file using web_search(query=exact file path); this tool returns a frozen real repository source, with source:path as its citation. Analyze the objective using those reads. Return task_finish with status, summary, evidence, unresolved, and payload as a native JSON object (never a JSON-encoded string) matching output_contract: claims contains concrete findings about implementation, sources contains every source:path read. Never delegate or run_code. Shape does not establish correctness; report partial if evidence is insufficient. Do not claim a production deployment or performance benefit.", MsgUser (task.teObjective <> "\n" <> json task.teInputs)]
  result <- withCompactLogger cfg.logColor Nothing $ \logger -> runEff . runConcurrent . runLog "max-workflow-eval" logger LogAttention . runWithConnectionPool pool . runBlob "/tmp/max-workflow-eval-blobs" . runLLM runtime (\_ _ _ -> pure ()) (\call -> atomicModifyIORef' records (\xs -> (call : xs, ()))) cfg.llm . runDurableAgent (AgentLimits 12) (factory sources) $ agentTurn turn (AgentContext context Nothing (Just 24)) opts.profile messages silentSink
  void (finishTurnRuntime tasks turn)
  withDb pool (finishAgentTurn task.teTurn (if isNothing result.aborted then TurnSucceeded else TurnFailed) result.turnsUsed Nothing Nothing)

factory :: (WithConnection :> es, Blob :> es, IOE :> es, ToolControl :> es) => Map.Map Text Text -> ToolContext -> Either ToolCatalogError (ToolRegistry es)
factory sources context = buildToolRegistry definitions (readerTool : filter (\tool -> tool.toolName `elem` ["task_start", "task_finish", "task_progress"]) (taskToolsWithDatabase context))
  where
    readerTool = Tool "web_search" "Read frozen repository source. query must equal an input file path." (toolObject [("query", stringParam "Exact file path")] ["query"]) $ \args -> pure $ do
      path <- either (Left . T.pack) Right (parseEither (withObject "source read" (.: "query")) args)
      body <- maybe (Left "file outside the frozen evidence set") Right (Map.lookup path sources)
      Right (object ["source" .= ("source:" <> path), "body" .= body, "fingerprint" .= fingerprint (String body)])

definitions :: [ToolDefinition]
definitions = [ToolDefinition (ToolRef name) (SchemaVersion 1) (Set.singleton (if name == "web_search" then EffectRead "source" else EffectWrite "task.db")) SequentialOnly (if name == "web_search" then RetrySafe else RetryUnsafe) (Set.singleton CurrentConversation) (ToolDeadline 30) True mode | (name, mode) <- [("web_search", WorkCall), ("task_start", WorkCall), ("task_finish", FinishCall), ("task_progress", CheckpointCall)]]

grants :: Map.Map Text Text
grants = Map.fromList [(entry.tdRef.unToolRef, toolCatalogFingerprint [entry]) | entry <- definitions]

capabilities :: TurnCapabilities
capabilities = TurnCapabilities False False False noAdvertisedCaps False grants (Just grants) True

contract :: Value
contract = object ["type" .= ("object" :: Text), "properties" .= object ["claims" .= strings, "sources" .= strings], "required" .= (["claims", "sources"] :: [Text]), "additionalProperties" .= False]
  where
    strings = object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text), "minLength" .= (1 :: Int)], "minItems" .= (1 :: Int)]

questions :: [(Text, [Text])]
questions =
  [ ("Audit whether agent() can widen its parent's authority. Identify the actual rejection and intersection points and any limits of the evidence.", ["src/Max/DB/Task/Workflow.hs", "src/Max/Task/Types.hs"]),
    ("Audit whether two awaited siblings can overspend the shared call/round budget and whether waiting parents can deadlock task capacity. Cite actual locks and counters.", ["src/Max/DB/Task/Authorization.hs", "src/Max/DB/Task/Scheduling.hs", "src/Max/DB/Task/Record.hs", "src/Max/DB/Task/Admission.hs", "src/Max/DB/ConversationLock.hs"]),
    ("Audit cache reuse, invalidation and steering boundaries. Explain what editing a source step reuses, and identify any cancellation or provenance gaps.", ["src/Max/Task/WorkflowRuntime.hs", "src/Max/CodeMode/Execution.hs", "src/Max/DB/Task/Workflow.hs", "src/Max/Task/Delegation.hs"])
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
