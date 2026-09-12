-- | Max owns the durable observer and its admission; maxops owns the remote
-- job. This adapter never reconstructs a deployment state machine.
module Max.MaxOps.TaskRuntime (admitMaxOpsTask, isMaxOpsTask, runMaxOpsTask) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Exception (throwIO)
import Effectful.PostgreSQL (WithConnection)
import Max.Agent.Execution (ExecutionAdmission (..))
import Max.Agent.Runtime (durableExecutionAdmission)
import Max.DB.AgentTurn (finishJournalExecution)
import Max.DB.Task qualified as DB
import Max.Effects.Blob (Blob)
import Max.Effects.ToolControl (ToolControl, yieldFrontend)
import Max.Execution.Types
import Max.MaxOps.Client (MaxOpsClient (..))
import Max.MaxOps.Protocol
import Max.MaxOps.Types
import Max.Task.Admission (TaskAdmissionReceipt (..), admissionErrorText)
import Max.Task.State
import Max.Task.Types (TaskProfile (Operations), taskGrants, taskHandle)
import Max.Tasks (TaskCancelled (..))
import Max.Tool.Bundles (skillLoadVersion)
import Max.ToolContext
import Max.Turn.Types (turnOutputAgentTurn)

binding :: MaxOpsConfig -> Text
binding = skillLoadVersion . T.pack . show

admitMaxOpsTask :: (ToolControl :> es, WithConnection :> es, IOE :> es) => ToolContext -> MaxOpsConfig -> Operation -> Value -> Eff es (Either Text Value)
admitMaxOpsTask context config operation params = case (toolInvocationIdentity context, turnOutputAgentTurn <$> toolTurnOutputContext context) of
  (Just key, Just turn) -> do
    let inputs =
          object
            [ "maxops_job_v1"
                .= object
                  [ "catalog" .= object ["version" .= (2 :: Int), "operations" .= [operation.wireValue]],
                    "params" .= params,
                    "key" .= key,
                    "binding" .= binding config
                  ]
            ]
    admitted <-
      DB.admitTaskReceipt
        turn
        (toolCanonicalId context)
        (toolAuthorPrincipalId context)
        key
        ("执行并核实 maxops " <> operation.name)
        Operations
        inputs
        (taskGrants Operations (toolCatalogGrants context))
    case admitted of
      Left failure -> pure (Left (admissionErrorText failure))
      Right receipt -> do
        unless (toolCapabilities context).tcBackground $
          yieldFrontend ("运维操作已交给 " <> taskHandle receipt.taskId <> "，完成后会转述结果。")
        pure
          ( Right
              ( object
                  [ "kind" .= ("max_task" :: Text),
                    "task" .= taskHandle receipt.taskId,
                    "task_id" .= receipt.taskId,
                    "status" .= receipt.status,
                    "remote_operation" .= operation.name,
                    "observation" .= ("host_managed" :: Text),
                    "next_action" .= ("宿主会自动提交并等待；这是 Max task，不是 maxops job_id。结果将自动回传，不要轮询或重复提交。" :: Text)
                  ]
              )
          )
  _ -> pure (Left "maxops submissions require a durable host invocation")

-- The model-facing task_start accepts context as a string and resources as a
-- separate object. It cannot write this reserved top-level host receipt.
isMaxOpsTask :: Value -> Bool
isMaxOpsTask (Object fields) = KeyMap.member "maxops_job_v1" fields
isMaxOpsTask _ = False

runMaxOpsTask :: (Blob :> es, WithConnection :> es, IOE :> es) => MaxOpsClient -> MaxOpsConfig -> IO MaxOpsConfig -> ToolContext -> DB.TaskExecution -> Eff es TaskReport
runMaxOpsTask client config currentConfig context execution = case parseEither parseInput execution.teInputs of
  Left _ -> pure (failed "无效的宿主运维任务记录")
  Right (saved, params, key, configBinding)
    | execution.teRevision /= 1
        || configBinding /= binding config
        || not (maxOpsAllowed config execution.teGroup)
        || not (Map.member "maxops_execute" (toolCatalogGrants context)) ->
        pure (failed "运维配置或授权已变化，未提交远端操作")
    | otherwise -> do
        discovered <- liftIO (client.discoverOperations config ManagementCatalog)
        case discovered >>= parseCatalog of
          Left err -> pure (failed err)
          Right catalog -> case (find ((== saved.name) . (.name)) catalog.operations, find ((== "jobs.wait") . (.name)) catalog.operations) of
            (Just current, Just waitOperation) | current.wireValue == saved.wireValue && saved.requiresKey -> do
              let start =
                    JournalStart
                      key
                      (operationToolName saved)
                      1
                      (skillLoadVersion (render (operationSchema saved)))
                      params
                      (toJSON [object ["kind" .= ("write" :: Text), "domain" .= ("fleet.management" :: Text)]])
                      "idempotent"
              journal <- durableExecutionAdmission.eaStartTool execution.teGroup execution.teTurn (ExecutionWork ReserveCall) start
              submitted <- submit current params key 0
              case submitted of
                Left err -> do
                  -- A rejected/ambiguous submission is evidence, not permission
                  -- for the model to mint a new identity and submit it again.
                  mapM_ (\row -> finishJournalExecution row (JournalOutcomeUnknown "maxops_submission" err)) journal
                  pure (failed err)
                Right value -> do
                  mapM_ (\row -> finishJournalExecution row (JournalCommitted value)) journal
                  case value of
                    Object fields | Just (String identifier) <- KeyMap.lookup "job_id" fields -> observe saved.name (find ((== (if saved.name == "diagnostics.collect" then "jobs.result" else "jobs.logs")) . (.name)) catalog.operations) waitOperation identifier Nothing
                    _ -> pure (failed "maxops 没有返回持久化 job handle；不能重复提交")
            _ -> pure (failed "maxops 操作契约已变化或缺少 jobs.wait；未提交操作")
  where
    parseInput = withObject "host task" $ \fields -> do
      receipt <- fields .: "maxops_job_v1"
      withObject
        "host receipt"
        ( \values -> do
            raw <- values .: "catalog"
            catalog <- either (fail . T.unpack) pure (parseCatalog raw)
            operation <- case catalog.operations of [entry] -> pure entry; _ -> fail "one operation required"
            (,,,) operation <$> values .: "params" <*> values .: "key" <*> values .: "binding"
        )
        receipt

    check = do
      authorized <- durableExecutionAdmission.eaCheck execution.teTurn
      unless authorized (throwIO TaskCancelled)
      current <- liftIO currentConfig
      unless (current == config && maxOpsAllowed current execution.teGroup) (throwIO TaskCancelled)

    -- Submission retries reuse the exact durable key and immutable arguments.
    -- Only transient transport errors retry; HTTP conflicts require decisions.
    submit operation params key attempt = do
      check
      result <- liftIO (client.invokeOperation config operation params (Just key))
      case result of
        Left detail | attempt < (5 :: Int) && transient detail -> do
          liftIO (threadDelay (min 30 (2 ^ attempt) * 1_000_000))
          submit operation params key (attempt + 1)
        _ -> pure result

    observe remoteOperation logsOperation operation identifier revision = do
      check
      response <-
        liftIO $
          client.invokeOperation
            config
            operation
            (object ["job_id" .= identifier, "after_revision" .= revision, "timeout_seconds" .= (10 :: Int)])
            Nothing
      case response of
        Left detail | transient detail -> liftIO (threadDelay 2_000_000) >> observe remoteOperation logsOperation operation identifier revision
        Left detail -> pure ((failed detail) {evidence = ["maxops job " <> identifier]})
        Right value -> case parseEither
          ( withObject "wait" $ \fields -> do
              job <- fields .: "job"
              withObject
                "job"
                ( \fields' -> do
                    handle <- fields' .: "handle"
                    withObject "handle" (\handleFields -> (,,) job <$> handleFields .: "state" <*> handleFields .: "revision") handle
                )
                job
          )
          value of
          Left _ -> pure ((failed "maxops 返回了无效的等待结果") {evidence = ["maxops job " <> identifier]})
          Right (job, state :: Text, next :: Int) ->
            if state `elem` ["succeeded", "failed", "cancelled", "timed_out", "outcome_unknown"]
              then do
                output <- case logsOperation of
                  Nothing -> pure Nothing
                  Just logs -> do
                    check
                    let arguments =
                          object
                            ( ["job_id" .= identifier, "limit" .= (8192 :: Int)]
                                <> ["pointer" .= ("/diagnostic" :: Text) | remoteOperation == "diagnostics.collect"]
                            )
                    result <- liftIO (client.invokeOperation config logs arguments Nothing)
                    pure (Just (either (\detail -> object ["unavailable" .= detail]) id result))
                let assessment = case job of
                      Object fields -> KeyMap.lookup "evidence_status" fields
                      _ -> Nothing
                    outputUnavailable = case output of
                      Nothing -> True
                      Just (Object fields) -> KeyMap.member "unavailable" fields
                      _ -> False
                    processOnly = remoteOperation == "exec.run" && state == "succeeded"
                    status
                      | state == "outcome_unknown" = ReportWaiting
                      | state /= "succeeded" || assessment == Just (String "failed") = ReportFailed
                      | processOnly || (remoteOperation == "diagnostics.collect" && (assessment /= Just (String "complete") || outputUnavailable)) = ReportPartial
                      | otherwise = ReportSucceeded
                    unresolved
                      | processOnly = ["远端进程退出成功；诊断目标与输出尚待所属 operations 任务核实，不能据退出码认定取证完成。"]
                      | status == ReportPartial || assessment == Just (String "failed") = ["诊断证据不完整；检查 missing_evidence 与各项输出，不能把缺失当作正常。"]
                      | state == "outcome_unknown" = ["远端效果未知，需要核实；不能以新键重复提交"]
                      | otherwise = []
                    report = object (["job" .= job, "result_scope" .= (if processOnly then "process_exit" else "operation" :: Text)] <> ["output" .= logs | Just logs <- [output]])
                pure
                  ( TaskReport
                      status
                      ("maxops 作业结果（远端证据，输出有界；仅汇报，由所属 operations 任务继续后续工作）：\n" <> render report)
                      ["maxops job " <> identifier]
                      unresolved
                      Nothing
                      (Just report)
                      Nothing
                  )
              else observe remoteOperation logsOperation operation identifier (Just next)

    transient detail = any (`T.isPrefixOf` detail) ["maxops transport", "maxops request timed out", "maxops connection timed out", "maxops HTTP 5", "maxops HTTP 429"]
    failed detail = TaskReport ReportFailed detail [] ["操作未被确认完成"] Nothing Nothing Nothing
    render = TE.decodeUtf8 . LBS.toStrict . encode
