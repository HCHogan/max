-- | Live model acceptance with durable production execution and synthetic data.
-- No network/chat runners are installed; only the configured LLM uses HTTP.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Version (makeVersion)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent (runConcurrent)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Max.Agent.Runtime (runDurableAgent)
import Max.AgentEvent
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Config (AppConfig (..), appConfigParser)
import Max.DB.AgentTurn (AgentTurnTerminal (..), finishAgentTurn, startAgentTurn)
import Max.DB.Connection
import Max.DB.Migrations (runMigrations)
import Max.DB.Task (claimFrontend)
import Max.Effects.Agent
import Max.Effects.Blob (runBlob)
import Max.Effects.LLM
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.Tools
import Max.HttpRuntime (newHttpRuntime)
import Max.IR (Body (..), Node (NText))
import Max.Log (withCompactLogger)
import Max.ModelCatalog (defaultModelName)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store
import Max.Platform.Types
import Max.Skill.Authoring
import Max.Skill.Package
import Max.Skill.Store (AuthoringScope (..), saveDraft)
import Max.Skill.ToolRuntime (skillAuthoringToolsWithDatabase)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills
import Max.Tasks (beginDurableTurnRuntime, finishTurnRuntime, newTaskRegistry)
import Max.Tool.Bundles (toolVisible)
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Tools.Schema (stringParam, toolObject)
import Max.Tools.Skills (skillToolsFor)
import Max.Toolset (skillToolDefinitions)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import OptEnvConf (Parser, help, long, metavar, option, optional, reader, runParser, setting, str)
import OptEnvConf qualified as Opt
import System.Exit (die, exitFailure)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

data EvalOptions = EvalOptions {profile :: !(Maybe Text), report :: !FilePath}

options :: Parser EvalOptions
options =
  EvalOptions
    <$> optional (setting [option, reader str, long "eval-profile", metavar "NAME", help "Frontend profile; defaults to llm.default"])
    <*> setting [option, reader str, long "eval-report", metavar "FILE", Opt.value "/tmp/max-skill-eval.json", help "JSON acceptance report"]

data Scenario = Scenario {name :: !Text, request :: !Text, heldOut :: !Value, expected :: !Value, readValue :: Text -> Either Text Value, seedDraft :: !(Maybe DraftContent)}

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  used <- newIORef Nothing
  (cfg, opts) <- runParser (makeVersion [0, 1, 0]) "max-skill-eval: isolated live frontend acceptance" ((,) <$> appConfigParser used <*> options)
  bracket (newDbPool cfg.db) closeDbPool $ \pool -> do
    -- Verify the connected database, not a substring of a supplied URL.
    [Only database :: Only Text] <- withDb pool (query "SELECT current_database()" ())
    unless ("max_skill_eval_" `T.isPrefixOf` database) (die "requires a dedicated database named max_skill_eval_*; production databases are refused")
    void (runMigrations pool cfg.migrationsDir)
    [Only empty] <- withDb pool (query "SELECT NOT EXISTS(SELECT 1 FROM messages) AND NOT EXISTS(SELECT 1 FROM skills) AND NOT EXISTS(SELECT 1 FROM skill_drafts)" ())
    unless empty (die "evaluation database must be empty; use a new database for each run")
    let selected = fromMaybe (defaultModelName cfg.llm) opts.profile
    rows <- traverse (runScenario cfg selected pool) (zip [920001 ..] scenarios)
    let passed = length (filter fst rows)
    encodeFile opts.report (object ["profile" .= selected, "runtime" .= javaScriptRuntimeVersion, "passed" .= passed, "total" .= length rows, "controlled_read_tools" .= True, "production_prompt" .= False, "cases" .= map snd rows])
    putStrLn (show passed <> "/" <> show (length rows) <> " passed; " <> opts.report)
    unless (passed == length rows) exitFailure

withDb :: DbPool -> Eff '[WithConnection, IOE] a -> IO a
withDb pool = runEff . runWithConnectionPool pool

runScenario :: AppConfig -> Text -> DbPool -> (Int64, Scenario) -> IO (Bool, Value)
runScenario cfg selected pool (group, scenario) = do
  registry <- newSkillRegistry
  void (withDb pool (loadSkills registry))
  authored <- runTurn cfg selected pool registry group scenario True (scenario.request <> " 技能名必须为 " <> scenario.name <> "，入口 run。完成实际发布后再结束。")
  -- A new registry and a fresh durable turn prove persistence, not in-memory reuse.
  fresh <- newSkillRegistry
  void (withDb pool (loadSkills fresh))
  reused <- runTurn cfg selected pool fresh group scenario False ("使用已发布的 " <> scenario.name <> "/run 工作流处理这些新参数：" <> jsonText scenario.heldOut <> "。执行保存的版本并根据真实返回回答。")
  facts <- withDb pool (query "SELECT (SELECT count(*) FROM skill_publications WHERE group_id=? AND name=?),(SELECT count(*) FROM skill_validations WHERE group_id=? AND name=? AND report->>'passed'='false')" (group, scenario.name, group, scenario.name))
  let published = case facts of [(n :: Int, _ :: Int)] -> n > 0; _ -> False
      repaired = case scenario.seedDraft of Nothing -> True; Just _ -> case facts of [(_, n)] -> n > 0; _ -> False
      correct = any (\(args, value) -> field "workflow" args == String (scenario.name <> "/run") && field "args" args == scenario.heldOut && field "value" value == scenario.expected) reused.trCodeResults
      passed = published && repaired && correct && not authored.trAborted && not reused.trAborted
  putStrLn (T.unpack scenario.name <> ": " <> if passed then "PASS" else "FAIL")
  pure (passed, object ["name" .= scenario.name, "passed" .= passed, "published" .= published, "repair_observed" .= repaired, "held_out_correct" .= correct, "authoring" .= authored.trReport, "reuse" .= reused.trReport])

data TurnReport = TurnReport {trAborted :: !Bool, trCodeResults :: ![(Value, Value)], trReport :: !Value}

runTurn :: AppConfig -> Text -> DbPool -> SkillRegistry -> Int64 -> Scenario -> Bool -> Text -> IO TurnReport
runTurn cfg selected pool registry group scenario authoring prompt = do
  (durable, message, actor) <- seedTurn pool group (if authoring then 1 else 2) prompt
  output <- newTurnOutputContext durable
  case (authoring, scenario.seedDraft) of
    (True, Just draft) -> do
      saved <- withDb pool (saveDraft (AuthoringScope (GroupId group) actor message (Just durable.atrTurnId)) draft 0)
      either (die . T.unpack) (const (pure ())) saved
    _ -> pure ()
  tasks <- newTaskRegistry
  turn <- beginDurableTurnRuntime tasks durable (GroupId group) (UserId 1) (Just message)
  runtime <- newHttpRuntime
  calls <- newIORef []
  let context = mkToolContext (TurnIdentity (GroupId group) message (UserId 1) (UserId 3) actor Nothing (Just output)) (TurnCapabilities False False True noAdvertisedCaps True Map.empty Nothing False)
      system = "你是 Max，完成用户要求的可复用工作流。技能按需加载；工具的真实返回是唯一执行证据。可用技能：skill-authoring（创建、测试和发布本群技能），codemode（JS SDK），" <> scenario.name <> "（若已发布）。eval_read 是受控只读数据源，无需依赖技能。不要把查询结果硬编码进程序；失败时检查工具反馈并修复。"
      record c = modifyIORef' calls (c :) >> putStrLn (T.unpack scenario.name <> (if authoring then " author" else " reuse") <> " model call: " <> show c.crDurationMs <> " ms")
  started <- getCurrentTime
  result <- withCompactLogger cfg.logColor Nothing $ \logger ->
    timeout (1800 * 1000000)
      $ runEff
        . runConcurrent
        . runLog "max-skill-eval" logger LogAttention
        . runWithConnectionPool pool
        . runBlob "/tmp/max-skill-eval-blobs"
        . runLLM runtime (\_ _ _ -> pure ()) record cfg.llm
        . runDurableAgent (AgentLimits 24) (factory registry scenario)
      $ agentTurn turn (AgentContext context Nothing (Just 100)) selected [MsgSystem system, MsgUser prompt] silentSink
  void (finishTurnRuntime tasks turn)
  let failed = maybe True (isJust . (.aborted)) result
  withDb pool (finishAgentTurn durable (if failed then TurnFailed else TurnSucceeded) (maybe 0 (.turnsUsed) result) Nothing Nothing)
  finished <- getCurrentTime
  records <- reverse <$> readIORef calls
  let messages = maybe [] (.appended) result
      codes = [(tc.callArguments, value) | MsgAssistantToolCalls _ tcs <- messages, tc <- tcs, tc.callName == "run_code", MsgTool identifier body <- messages, identifier == tc.callId, Right value <- [eitherDecodeStrict' (TE.encodeUtf8 body)]]
      usages = [usage | c <- records, Just usage <- [c.crUsage]]
  pure (TurnReport failed codes (object ["aborted" .= failed, "seconds" .= (realToFrac (diffUTCTime finished started) :: Double), "model_calls" .= length records, "usage_records" .= length usages, "prompt_tokens" .= sum (map (.usagePrompt) usages), "completion_tokens" .= sum (map (.usageCompletion) usages), "transcript" .= messages, "errors" .= [err | c <- records, Just err <- [c.crError]]]))

silentSink :: (Applicative m) => AgentEventSink m
silentSink (AgentFinalStreamText _) = pure True
silentSink (AgentProgressText _) = pure ()
silentSink (AgentToolDebug _) = pure ()

factory :: (WithConnection :> es, IOE :> es, ToolControl :> es) => SkillRegistry -> Scenario -> ToolContext -> Either ToolCatalogError (ToolRegistry es)
factory registry scenario context = do
  let leaf = Tool "eval_read" "读取一个命名资源。参数 key；返回结构由本次工作流任务说明给定；offline 返回工具失败。" (toolObject [("key", stringParam "主机或查询名")] ["key"]) (pure . (either (Left . T.pack) scenario.readValue . parseEither (withObject "args" (.: "key"))))
      leafDefinition = ToolDefinition (ToolRef "eval_read") (SchemaVersion 1) (Set.singleton (EffectRead "eval.data")) ParallelSafe RetrySafe (Set.singleton CurrentConversation) (ToolDeadline 30) True WorkCall
  leaves <- buildToolRegistry [leafDefinition] [leaf]
  let catalog = catalogTools (registryCatalog leaves)
      runners = leaf : (skillToolsFor registry context (const (pure (Right Nothing))) (bindWorkflowContracts javaScriptRuntimeVersion (toolSkillLoads context) catalog) <> skillAuthoringToolsWithDatabase registry context (Right catalog))
      visible name = toolVisible (toolSkillLoads context) name
  buildToolRegistry (leafDefinition : filter (visible . (.tdRef.unToolRef)) skillToolDefinitions) (filter (visible . (.toolName)) runners)

seedTurn :: DbPool -> Int64 -> Int64 -> Text -> IO (AgentTurnRef, CanonicalMessageId, PrincipalId)
seedTurn pool group ordinal prompt = withDb pool $ do
  now <- liftIO getCurrentTime
  endpoint <- ensureQQEndpointFor (UserId 3) (GroupId group)
  let envelope = InboundEnvelope endpoint.endpointId (NativeEventId (T.pack (show (group * 10 + ordinal)))) (NativeUserId "1") Nothing now now EventMessage LiveDelivery (Body [NText prompt]) [] Nothing Nothing
  result <- ingestEnvelope defaultIngestOptions {createDispatch = False, createMirrorDeliveries = False} envelope
  message <- case result of Ingested row -> pure row.canonicalMessageId; _ -> error "fresh evaluation ingest was not new"
  actors <- query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
  actor <- case actors of [Only identifier] -> pure identifier; _ -> error "evaluation message has no principal"
  turn <- startAgentTurn (GroupId group) message (PrincipalId actor)
  claimed <- claimFrontend turn
  unless claimed (error "fresh evaluation frontend was not claimed")
  pure (turn, message, PrincipalId actor)

jsonText :: (ToJSON a) => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode

field :: Key -> Value -> Value
field key (Object fields) = fromMaybe Null (KM.lookup key fields)
field _ _ = Null

scenarios :: [Scenario]
scenarios =
  [ Scenario
      "eval-fleet-summary"
      "创建并发布群内可复用的主机失败服务汇总技能。输入 {hosts:[字符串]}，逐主机 eval_read({key:host}) 返回 {units:[{name,state}]}。输出 {failed:[{host,units:[服务名]}],unavailable:[主机名]}；仅保留 state=failed 的服务，服务名去重按字典序，failed 只含有失败服务的主机并保持输入顺序；工具报错的主机仅进 unavailable。训练主机 alpha、beta、offline 可查询；自己编写模拟 fixtures 覆盖正常和部分失败，再完成发布。"
      (object ["hosts" .= (["gamma", "offline"] :: [Text])])
      (object ["failed" .= [object ["host" .= ("gamma" :: Text), "units" .= (["cache.service"] :: [Text])]], "unavailable" .= (["offline"] :: [Text])])
      fleetRead
      Nothing,
    Scenario
      "eval-search-urls"
      "创建并发布一个批量查询 URL 去重技能。输入 {queries:[字符串]}，每个 query 调 eval_read({key:query}) 返回 {results:[{title,url}]}。输出 {urls:[字符串]}，按输入查询顺序和每个结果顺序合并 URL，精确去重保留首次出现，不输出标题。训练查询 alpha、beta 可查；自己写 fixtures 覆盖空数组和重复 URL，再发布。"
      (object ["queries" .= (["delta", "epsilon"] :: [Text])])
      (object ["urls" .= (["https://example.test/a", "https://example.test/b", "https://example.test/c"] :: [Text])])
      searchRead
      Nothing,
    Scenario
      "eval-numeric-sort"
      "修复已有草稿 eval-numeric-sort。它应接受 {values:[整数]}，返回 {values:[去重后的整数，按数值升序]}。先运行现有 revision=1 的校验，观察失败，再检查源码、修复并发布。不要削弱原 fixture 的期望；应补充空输入等测试。"
      (object ["values" .= ([30, -2, 4, 30, 0] :: [Int])])
      (object ["values" .= ([-2, 0, 4, 30] :: [Int])])
      (const (Left "this workflow requires no tools"))
      (Just brokenSort)
  ]

fleetRead :: Text -> Either Text Value
fleetRead "offline" = Left "host unavailable"
fleetRead name = Right (object ["units" .= (if name == "beta" then [] else [unit "cache.service" "failed", unit "max.service" "active", unit "cache.service" "failed"])])
  where
    unit name' state = object ["name" .= (name' :: Text), "state" .= (state :: Text)]

searchRead :: Text -> Either Text Value
searchRead key = Right (object ["results" .= [object ["title" .= ("result" :: Text), "url" .= ("https://example.test/" <> suffix)] | suffix <- (if key `elem` ["alpha", "delta"] then ["a", "b"] else ["b", "c"] :: [Text])]])

brokenSort :: DraftContent
brokenSort =
  DraftContent
    "eval-numeric-sort"
    "Sort and deduplicate integers"
    "Run eval-numeric-sort/run with values."
    (SkillPackage [] (Map.singleton "run" (Workflow "Sort integers" "return {values:[...new Set(args.values)].sort()};" contract contract [])))
    [Fixture "run" (object ["values" .= ([10, 2, 2] :: [Int])]) [] (object ["values" .= ([2, 10] :: [Int])])]
  where
    contract = object ["type" .= ("object" :: Text), "properties" .= object ["values" .= object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("integer" :: Text)]]], "required" .= (["values"] :: [Text]), "additionalProperties" .= False]
