{-# LANGUAGE GADTs #-}

module Max.ExecutionSpec (Max.ExecutionSpec.spec, withHost, hooks, DbEffects) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), bracket_, throwIO)
import Control.Monad (replicateM_, void, when)
import Data.Aeson (Value, decodeStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, liftIO, raise, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import ExecutionFixture
import Helpers (truncateAll, withDb)
import JobFixture (RunningJob (..), launchNext, runningJob, seed)
import Max.Agent.Runtime (executionAdmission, executionJournal, runAgentRuntime)
import Max.AgentEvent (AgentEvent (..))
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion, runJavaScript)
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Job (allocateJobId)
import Max.Effects.Agent qualified as Agent
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), LLMInterpreter (..), ToolCall (..), ToolSpec (..), runLLMWith)
import Max.Effects.ToolControl (activateSkills, runToolControl)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, drainInlineMedia, forkToolOutputQueue, newToolOutputQueue, queueInlineMedia, runToolOutput, runToolOutputRead)
import Max.Effects.Tools
import Max.Execution.Authority (callIsUsable)
import Max.Execution.Tools
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Memory.ToolRuntime (memoryToolsWithDatabase)
import Max.Node.Router qualified as Router
import Max.Platform.Types (noAdvertisedCaps)
import Max.Skill.Contract (Contract, parseContract)
import Max.Skill.Package
import Max.Skill.ToolRuntime (skillToolsWithRuntime)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills (newSkillRegistry)
import Max.Task.Policy (treeToolCalls)
import Max.Task.State (TaskStatus (Cancelled, Failed, Succeeded))
import Max.Task.ToolRuntime (taskTools)
import Max.Task.Types (JobResult (..), JobRun (..), JobSpec (..), JobView (..), TaskProfile (Basic, Sandbox))
import Max.Tasks (TaskCancelled (..), TurnRuntime, beginTurnRuntime, finishTurnRuntime, newTaskRegistry, turnAcceptsWork, turnRuntimeOutputContext, turnWasCancelled)
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion, toolVisible)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..), controlSkillLoads)
import Max.ToolContext
import Max.Turn.Types (AgentTurnRef (..), ExecutionOrdinal (..), newTurnOutputContext, resultHandleText)
import NodeWorkFixture qualified
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

type DbEffects = '[Blob, WithConnection, Log, Concurrent, IOE]

withHost :: DbPool -> Eff DbEffects a -> IO a
withHost pool action = withCompactLogger ColorNever Nothing $ \logger ->
  runEff . runConcurrent . runLog "execution-test" logger LogAttention . runWithConnectionPool pool . runBlob "var/test-codemode-blobs" $ action

hooks :: Jobs.Jobs -> TurnRuntime -> ExecutionHooks DbEffects
hooks jobs runtime =
  executionHooks
    (executionAdmission jobs)
    executionJournal
    (GroupId 900)
    runtime

-- Lift the assembly callbacks into the local validated Tools interpreter.
hostHooks :: Jobs.Jobs -> TurnRuntime -> ExecutionHooks (Tools : DbEffects)
hostHooks jobs = hoistExecutionHooks raise . hooks jobs

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "native and Wasm execution with real journal" $ do
  it "steers a background native await through node events and rejoins its original future" $ do
    let grants = Map.singleton "sandbox_exec" "fixture"
    running <- runningJob pool Sandbox grants
    entered <- newEmptyMVar
    release <- newEmptyMVar
    calls <- newIORef (0 :: Int)
    leaves <- newIORef (0 :: Int)
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 99) running.job.spec.principal Nothing (Just (turnRuntimeOutputContext running.runtime)))
            (TurnCapabilities False False False noAdvertisedCaps False grants (Just grants) True)
        factory _ =
          buildToolRegistry
            [echoDefinition {tdRef = ToolRef "sandbox_exec", tdAwait = AsyncTool}]
            [ echoTool
                { toolName = "sandbox_exec",
                  toolRunner = LegacyRunner $ \value -> liftIO $ do
                    modifyIORef' leaves (+ 1)
                    putMVar entered ()
                    takeMVar release
                    pure (Right value)
                }
            ]
        provider = LLMInterpreter $ \_ _ messages specs _ -> do
          n <- liftIO (atomicModifyIORef' calls (\value -> (value + 1, value)))
          let respond call name arguments = pure (Right (ToolCallsResp (object []) "" [ToolCall call name arguments]))
          case n of
            0 -> respond "slow" "sandbox_exec" (object ["value" .= (42 :: Int)])
            1 -> do
              liftIO $ messages `shouldSatisfy` any (\case MsgUser body -> "keep waiting" `T.isInfixOf` body; _ -> False)
              liftIO $ map (.specName) specs `shouldContain` ["execution_wait"]
              ref <- liftIO $ case [ref :: Text | MsgTool "slow" body <- messages, Just value <- [decodeStrict' (TE.encodeUtf8 body)], Just ref <- [parseMaybe (withObject "running call" (.: "result")) value]] of
                [ref] -> pure ref
                refs -> expectationFailure ("expected one running call reference, got " <> show refs) >> fail "missing running call reference"
              liftIO (putMVar release ())
              respond "joined" "execution_wait" (object ["result" .= ref])
            _ -> do
              liftIO $ messages `shouldSatisfy` any (\case MsgTool "joined" body -> "\"value\":42" `T.isInfixOf` body; _ -> False)
              pure (Right (ContentResp "42 after steering"))
        run =
          withHost pool . runLLMWith provider . runAgentRuntime running.jobs (Agent.AgentLimits 4) factory $
            Agent.agentTurn running.runtime (Agent.AgentContext context Nothing Nothing Nothing) "fixture" [MsgUser "slow work"] (\case AgentFinalStreamText _ -> pure False; AgentProgressText _ -> pure (); AgentToolDebug _ -> pure ())
    Async.withAsync run $ \worker -> do
      timeout 1000000 (takeMVar entered) `shouldReturn` Just ()
      Jobs.steerJob running.jobs (GroupId 900) running.job.spec.principal Nothing running.job.run.jobId "keep waiting" `shouldReturn` Right ()
      Just result <- timeout 10000000 (Async.wait worker)
      result.outcome `shouldBe` Agent.Answered (Agent.AgentReply "42 after steering" "")
    readIORef calls `shouldReturn` 3
    readIORef leaves `shouldReturn` 1
    states running.turn `shouldReturn` [("sandbox_exec", "succeeded")]
    finishTurnRuntime running.tasks running.runtime

  it "cancels an actual agent call and its descendants when its guest returns from a race" $ do
    running <- runningJob pool Basic (Map.singleton "agent" "fixture")
    release <- newEmptyMVar
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 99) running.job.spec.principal Nothing (Just (turnRuntimeOutputContext running.runtime)))
            (TurnCapabilities False False False noAdvertisedCaps False running.job.spec.grants (Just running.job.spec.grants) True)
        agentDefinition = echoDefinition {tdRef = ToolRef "agent", tdEffects = Set.singleton (EffectWrite "task.db"), tdParallelism = ParallelIndependent, tdRetryClass = RetryUnsafe, tdAwait = AsyncTool}
        winner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (takeMVar release) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [agentDefinition, echoDefinition] (winner : filter ((== "agent") . (.toolName)) (taskTools running.jobs context)))
    let run = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          runJavaScript session (hostHooks running.jobs running.runtime) (views registry) "return await Promise.race([agent({objective:'child',profile:'basic'}), tools.echo({value:7})]);"
    Async.withAsync run $ \worker -> do
      Just child <- timeout 10000000 (launchNext pool running.tasks running.jobs)
      identifier <- withDb pool allocateJobId
      Right _ <- Jobs.admitJob running.jobs (Just child.turn.atrTurnId) identifier child.job.spec {parent = Just child.job.run, awaited = False, objective = "grandchild"}
      grandchild <- launchNext pool running.tasks running.jobs
      putMVar release ()
      Just result <- timeout 10000000 (Async.wait worker)
      result.cmExit `shouldBe` WasmCompleted
      result.cmOutput `shouldBe` Just (object ["value" .= (7 :: Int)])
      sort (map (.ccOutcome) result.cmCalls) `shouldBe` ["outcome-unknown", "succeeded"]
      Just cancelledChild <- Jobs.lookupJob running.jobs (GroupId 900) child.job.run.jobId
      Just cancelledGrandchild <- Jobs.lookupJob running.jobs (GroupId 900) grandchild.job.run.jobId
      map (.status) [cancelledChild, cancelledGrandchild] `shouldBe` [Cancelled, Cancelled]
      atomically (turnWasCancelled child.runtime) `shouldReturn` True
      atomically (turnWasCancelled grandchild.runtime) `shouldReturn` True
      atomically (turnWasCancelled running.runtime) `shouldReturn` False
      states running.turn `shouldReturn` [("host:wasm/v2", "succeeded"), ("agent", "outcome-unknown"), ("echo", "succeeded")]
      finishTurnRuntime grandchild.tasks grandchild.runtime
      finishTurnRuntime child.tasks child.runtime
    finishTurnRuntime running.tasks running.runtime

  it "runs codemode through an awaited background agent's model loop and returns its actual report" $ do
    let grants = Map.fromList [("web_search", "fixture"), ("use_skill", "fixture")]
    parent <- runningJob pool Basic grants
    identifier <- withDb pool allocateJobId
    let childSpec = parent.job.spec {parent = Just parent.job.run, awaited = True, objective = "compute with codemode"}
    Right child <- Jobs.admitJob parent.jobs (Just parent.turn.atrTurnId) identifier childSpec
    running <- launchNext pool parent.tasks parent.jobs
    running.job.run `shouldBe` child.run
    skills <- newSkillRegistry
    calls <- newIORef (0 :: Int)
    leaves <- newIORef (0 :: Int)
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) child.spec.source (UserId 1) (UserId 99) child.spec.principal Nothing (Just (turnRuntimeOutputContext running.runtime)))
            (TurnCapabilities False False True noAdvertisedCaps False grants (Just grants) True)
        agentContext = Agent.AgentContext context Nothing Nothing Nothing
    Async.withAsync (Jobs.awaitJob parent.jobs parent.turn.atrTurnId child.run) $ \waiting -> do
      timeout 20000 (Async.wait waiting) `shouldReturn` Nothing
      let factory current =
            buildToolRegistry
              ([echoDefinition {tdRef = ToolRef "web_search"} | toolVisible (toolSkillLoads current) "web_search"] <> [echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}])
              ( [ echoTool
                    { toolName = "web_search",
                      toolRunner = LegacyRunner $ \value -> do
                        liftIO $ do
                          fmap (const ()) <$> Async.poll waiting `shouldReturn` Nothing
                          modifyIORef' leaves (+ 1)
                        pure (Right value)
                    }
                | toolVisible (toolSkillLoads current) "web_search"
                ]
                  <> skillToolsWithRuntime skills current (const (pure (Right Nothing))) Right
              )
          provider = LLMInterpreter $ \_ _ messages specs _ -> do
            n <- liftIO (atomicModifyIORef' calls (\value -> (value + 1, value)))
            let respond call name value = pure (Right (ToolCallsResp (object []) "" [ToolCall call name value]))
            case n of
              0 -> do
                liftIO $ map (.specName) specs `shouldNotContain` ["run_code"]
                pure (Right (ToolCallsResp (object []) "" [ToolCall name "use_skill" (object ["name" .= name]) | name <- ["web", "codemode"]]))
              1 -> do
                liftIO $ map (.specName) specs `shouldContain` ["run_code"]
                respond "code" "run_code" (object ["code" .= ("return (await tools.web_search({value:6})).value * 7;" :: Text)])
              _ -> do
                liftIO $ messages `shouldSatisfy` any (\case MsgTool "code" body -> "\"value\":42" `T.isInfixOf` body; _ -> False)
                pure (Right (ContentResp "42"))
      Just result <-
        timeout 10000000 $
          withHost pool . runLLMWith provider . runAgentRuntime running.jobs (Agent.AgentLimits 4) factory $
            Agent.agentTurn running.runtime agentContext "fixture" [MsgUser child.spec.objective] (\case AgentFinalStreamText _ -> pure False; AgentProgressText _ -> pure (); AgentToolDebug _ -> pure ())
      result.outcome `shouldBe` Agent.Answered (Agent.AgentReply "42" "")
      readIORef calls `shouldReturn` 3
      readIORef leaves `shouldReturn` 1
      states running.turn `shouldReturn` [("use_skill", "succeeded"), ("use_skill", "succeeded"), ("host:wasm/v2", "succeeded"), ("web_search", "succeeded")]
      Jobs.completeJob running.jobs child.run Succeeded (JobResult "42" Nothing)
      Just (Right reported) <- timeout 1000000 (Async.wait waiting)
      reported.result `shouldBe` Just (JobResult "42" Nothing)
    finishTurnRuntime running.tasks running.runtime
    finishTurnRuntime parent.tasks parent.runtime

  it "keeps a detached native call alive through task finish and journals its actual result" $ do
    (turn, message, principal) <- seed pool 900 1
    tasks <- newTaskRegistry
    jobs <- Jobs.newJobs tasks
    runtime <- beginTurnRuntime tasks turn (GroupId 900) (UserId 1) (Just message)
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) message (UserId 1) (UserId 99) principal Nothing Nothing)
            (TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing False)
    origin <- Jobs.resultOrigin jobs runtime context
    entered <- newEmptyMVar
    release <- newEmptyMVar
    steering <- newTVarIO False
    let media = InlineMedia "late result" "data:image/png;base64,AA==" Nothing
        runner =
          echoTool
            { toolRunner = LegacyRunner $ \value -> do
                liftIO (putMVar entered () >> takeMVar release)
                _ <- queueInlineMedia media
                pure (Right value)
            }
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition {tdAwait = AsyncTool}] [runner])
    outputQueue <- runEff (newToolOutputQueue 8)
    let lower :: forall x. Eff (ToolOutput : DbEffects) x -> Eff DbEffects (x, LoopControl, [InlineMedia])
        lower action = do
          scoped <- forkToolOutputQueue outputQueue
          value <- runToolOutput scoped action
          attachments <- runToolOutputRead scoped drainInlineMedia
          pure (value, ContinueLoop, attachments)
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ -> do
      _ <- withHost pool . runToolsWithMedia lower (pure registry) $ do
        session <- newExecutionSession Nothing
        setExecutionResultSink session (\ref invocation -> atomically (Router.deliverResult jobs.resultRouter origin ref (outcomeEnvelope invocation.tiOutcome) invocation.tiMedia))
        executeToolBatch session (hostHooks jobs runtime) {ehInterrupt = readTVar steering >>= check} (views registry) [ToolRequest "detached" "echo" args]
      atomically (Router.closeTask jobs.resultRouter origin.target)
      withDb pool (finishAgentTurn turn TurnSucceeded 1 Nothing)
      Async.withAsync (finishTurnRuntime tasks runtime) $ \closing -> do
        timeout 1000000 (atomically (turnAcceptsWork tasks turn.atrTurnId >>= check . not)) `shouldReturn` Just ()
        Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly) `shouldReturn` True
        Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork ReserveCall) `shouldReturn` False
        Jobs.authorizeJobStep jobs turn.atrTurnId ExecutionCheckpoint `shouldReturn` False
        timeout 20000 (Async.wait closing) `shouldReturn` Nothing
        putMVar release ()
        timeout 3000000 (Async.wait closing) `shouldReturn` Just ()
      states turn `shouldReturn` [("echo", "succeeded")]
      Just (Right (Router.NativeResult relay)) <- timeout 1000000 (NodeWorkFixture.takeWork jobs)
      relay.value `shouldBe` outcomeEnvelope (ToolSucceeded args)
      relay.media `shouldBe` [media]
      relay.origin.turn `shouldBe` turn.atrTurnId
      relay.reference `shouldBe` resultHandleText turn.atrTurnOrdinal (ExecutionOrdinal 1)
      atomically (Router.releaseRelay jobs.resultRouter relay)
      Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly) `shouldReturn` False

  it "lets an admitted native memory write commit after turn closure and revokes its call authority on return" $ do
    running <- runningJob pool Basic Map.empty
    output <- newTurnOutputContext running.turn
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 99) running.job.spec.principal Nothing (Just output))
            (TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing True)
        definition = echoDefinition {tdRef = ToolRef "memory_save", tdAwait = AsyncTool, tdEffects = Set.singleton (EffectWrite "memory"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe, tdFailuresPrecedeEffects = False}
        input = object ["scope" .= ("group" :: Text), "content" .= ("retained explicit fact" :: Text)]
    entered <- newEmptyMVar
    release <- newEmptyMVar
    steering <- newTVarIO False
    captured <- newIORef Nothing
    let factory authority = do
          liftIO (writeIORef captured authority)
          let bound = maybe context (`withToolCallAuthority` context) authority
              runners =
                [ runner
                    { toolRunner = LegacyRunner $ \value -> do
                        liftIO (putMVar entered () >> takeMVar release)
                        toolRun runner value
                    }
                | runner <- memoryToolsWithDatabase bound,
                  runner.toolName == "memory_save"
                ]
          either (liftIO . fail . show) pure (buildToolRegistry [definition] runners)
        lower action = (,,) <$> action <*> pure ContinueLoop <*> pure []
    registry <- withHost pool (factory Nothing)
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ -> do
      _ <- withHost pool . runToolsScoped lower factory $ do
        session <- newExecutionSession Nothing
        executeToolBatch session (hostHooks running.jobs running.runtime) {ehInterrupt = readTVar steering >>= check} (views registry) [ToolRequest "save" "memory_save" input]
      Just authority <- readIORef captured
      callIsUsable authority `shouldReturn` True
      Jobs.completeJob running.jobs running.job.run Succeeded (JobResult "write still running" Nothing)
      withDb pool (finishAgentTurn running.turn TurnSucceeded 1 Nothing)
      Async.withAsync (finishTurnRuntime running.tasks running.runtime) $ \closing -> do
        timeout 1000000 (atomically (turnAcceptsWork running.tasks running.turn.atrTurnId >>= check . not)) `shouldReturn` Just ()
        putMVar release ()
        timeout 3000000 (Async.wait closing) `shouldReturn` Just ()
      states running.turn `shouldReturn` [("memory_save", "committed")]
      withDb pool (query "SELECT content FROM memories" ()) `shouldReturn` [Only ("retained explicit fact" :: Text)]
      callIsUsable authority `shouldReturn` False
      reused <- withHost pool . runToolsScoped lower factory $ invokeToolWithAuthority (Just authority) "memory_save" input
      reused.tiOutcome `shouldSatisfy` (\case ToolRejected fault -> fault.tfCode == "call_authority_revoked"; _ -> False)
      withDb pool (query "SELECT count(*) FROM memory_mutations" ()) `shouldReturn` [Only (1 :: Int)]

  it "revokes a queued native result and its publication when the producing job is replaced" $ do
    running <- runningJob pool Basic Map.empty
    let context =
          mkToolContext
            (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 99) running.job.spec.principal Nothing Nothing)
            (TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing True)
    origin <- Jobs.resultOrigin running.jobs running.runtime context
    atomically (Router.closeTask running.jobs.resultRouter origin.target >> Router.deliverResult running.jobs.resultRouter origin "r1" (toJSON ("obsolete" :: Text)) [])
    relay <- atomically (Router.takeRelay running.jobs.resultRouter)
    (frontend, _, _) <- seed pool 900 1
    Jobs.bindResultRelay running.jobs frontend.atrTurnId relay
    Jobs.authorizeJobPublication running.jobs frontend.atrTurnId `shouldReturn` True
    Jobs.replaceJob running.jobs (GroupId 900) running.job.spec.principal False running.job.run.jobId "replacement" `shouldReturn` Right ()
    atomically (Router.relayIsCurrent relay) `shouldReturn` False
    Jobs.authorizeJobPublication running.jobs frontend.atrTurnId `shouldReturn` False
    Jobs.detachJobNotice running.jobs frontend.atrTurnId
    atomically (Router.referencedOwners running.jobs.resultRouter) `shouldReturn` Set.empty

  it "allows an admitted background call to checkpoint and settle after the model task finishes" $ do
    running <- runningJob pool Basic Map.empty
    entered <- newEmptyMVar
    release <- newEmptyMVar
    steering <- newTVarIO False
    let runner =
          echoTool
            { toolRunner = LegacyRunner $ \value -> do
                liftIO (putMVar entered () >> takeMVar release)
                allowed <- liftIO (Jobs.authorizeJobStep running.jobs running.turn.atrTurnId (ExecutionWork CheckOnly))
                pure (if allowed then Right value else Left "admitted background call was revoked by normal completion")
            }
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition {tdAwait = AsyncTool}] [runner])
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ -> do
      _ <- withHost pool . runTools registry $ do
        session <- newExecutionSession Nothing
        executeToolBatch session (hostHooks running.jobs running.runtime) {ehInterrupt = readTVar steering >>= check} (views registry) [ToolRequest "detached" "echo" args]
      Jobs.completeJob running.jobs running.job.run Succeeded (JobResult "call still running" Nothing)
      withDb pool (finishAgentTurn running.turn TurnSucceeded 1 Nothing)
      Async.withAsync (finishTurnRuntime running.tasks running.runtime) $ \closing -> do
        timeout 1000000 (atomically (turnAcceptsWork running.tasks running.turn.atrTurnId >>= check . not)) `shouldReturn` Just ()
        Jobs.authorizeJobStep running.jobs running.turn.atrTurnId (ExecutionWork ReserveCall) `shouldReturn` False
        putMVar release ()
        timeout 3000000 (Async.wait closing) `shouldReturn` Just ()
      states running.turn `shouldReturn` [("echo", "succeeded")]
      Jobs.authorizeJobStep running.jobs running.turn.atrTurnId (ExecutionWork CheckOnly) `shouldReturn` False

  it "revokes an interrupted call before waiting on diagnostic persistence" $ do
    (jobs, turn, runtime) <- fixture
    captured <- newIORef Nothing
    recording <- newEmptyMVar
    release <- newEmptyMVar
    let runner = echoTool {toolRunner = LegacyRunner $ \_ -> liftIO (throwIO ThreadKilled)}
        base = hostHooks jobs runtime
        bound =
          base
            { ehCallAuthority = \name -> do
                authority <- base.ehCallAuthority name
                liftIO (writeIORef captured authority)
                pure authority,
              ehFinish = \row outcome -> do
                liftIO (putMVar recording () >> takeMVar release)
                base.ehFinish row outcome
            }
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    Async.withAsync
      ( withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          executeToolBatch session bound (views registry) [ToolRequest "interrupted" "echo" args]
      )
      $ \worker -> do
        timeout 1000000 (takeMVar recording) `shouldReturn` Just ()
        Just authority <- readIORef captured
        callIsUsable authority `shouldReturn` False
        Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly) `shouldReturn` True
        putMVar release ()
        outcome <- timeout 3000000 (Async.waitCatch worker)
        outcome `shouldSatisfy` maybe False isLeft
    states turn `shouldReturn` [("echo", "outcome-unknown")]

  it "gives JavaScript leaves separate call authority and revokes it while the owning turn remains live" $ do
    (jobs, turn, runtime) <- fixture
    captured <- newIORef []
    let factory authority = do
          let runner =
                echoTool
                  { toolRunner = LegacyRunner $ \value -> do
                      liftIO $ case authority of
                        Nothing -> expectationFailure "JavaScript leaf has no call authority"
                        Just call -> do
                          callIsUsable call `shouldReturn` True
                          atomicModifyIORef' captured (\calls -> (call : calls, ()))
                      pure (Right value)
                  }
          either (liftIO . fail . show) pure (buildToolRegistry [echoDefinition] [runner])
        lower action = (,,) <$> action <*> pure ContinueLoop <*> pure []
    registry <- withHost pool (factory Nothing)
    result <- withHost pool . runToolsScoped lower factory $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "return await Promise.all([1,2].map(value => tools.echo({value})));"
    result.cmExit `shouldBe` WasmCompleted
    authorities <- readIORef captured
    length authorities `shouldBe` 2
    mapM callIsUsable authorities `shouldReturn` [False, False]
    Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork CheckOnly) `shouldReturn` True
    states turn `shouldReturn` [("host:wasm/v2", "succeeded"), ("echo", "succeeded"), ("echo", "succeeded")]

  it "records a JavaScript syntax failure before any leaf as failed-before-effect" $ do
    (jobs, turn, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "return ("
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "failed-before-effect"
    states turn `shouldReturn` [("host:wasm/v2", "failed")]
    callCount jobs turn `shouldReturn` 0

  it "journals real JavaScript batches and source evidence without charging the container" $ do
    (jobs, turn, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    let source = "return await Promise.all([1,2].map(value => tools.echo({value})));"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session (hostHooks jobs runtime) (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    states turn `shouldReturn` [("host:wasm/v2", "succeeded"), ("echo", "succeeded"), ("echo", "succeeded")]
    callCount jobs turn `shouldReturn` 2
    sourceRows <- withDb pool $ query "SELECT normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v2'" (Only turn.atrTurnId)
    sourceRows `shouldBe` [Only source]

  it "retains committed JavaScript leaves and partial failure evidence without replay" $ do
    (jobs, turn, runtime) <- fixture
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "await tools.echo({value:1}); throw new Error('after commit');"
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    map (.ccOutcome) result.cmCalls `shouldBe` ["committed"]
    states turn `shouldReturn` [("host:wasm/v2", "outcome-unknown"), ("echo", "committed")]
    callCount jobs turn `shouldReturn` 1
    readIORef count `shouldReturn` 1

  it "cancels a JavaScript host call with no leaked worker or later effect" $ do
    (jobs, turn, runtime) <- fixture
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    worker <- Async.async . withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "await tools.echo({value:1}); await tools.echo({value:2});"
    reached <- timeout 30000000 (takeMVar entered)
    reached `shouldBe` Just ()
    timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    states turn `shouldReturn` [("host:wasm/v2", "outcome-unknown"), ("echo", "outcome-unknown")]
    callCount jobs turn `shouldReturn` 1

  it "records identical leaf outcomes, schemas, input and results through both adapters" $ do
    (jobs, turn, runtime) <- fixture
    let readFail = echoTool {toolName = "read_fail", toolRunner = LegacyRunner $ \_ -> pure (Left "read failed")}
        write = echoTool {toolName = "write"}
        unknown = echoTool {toolName = "unknown", toolRunner = LegacyRunner $ \_ -> pure (Left "ambiguous effect")}
        readDefinition = echoDefinition {tdRef = ToolRef "read_fail"}
        writeDefinition name = echoDefinition {tdRef = ToolRef name, tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        calls = [("echo", args), ("echo", object []), ("hidden", args), ("read_fail", args), ("write", args), ("unknown", args)]
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition, readDefinition, writeDefinition "write", writeDefinition "unknown"] [echoTool, readFail, write, unknown])
    binary <- guestCalls [request name value | (name, value) <- calls] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest ("native:" <> name) name value | (name, value) <- calls]
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    rows <- withDb pool $ query "SELECT state,tool_ref,schema_hash,normalized_input,result_inline,failure_code FROM execution_journal WHERE turn_id=? AND tool_ref<>'host:wasm/v2' ORDER BY execution_ordinal" (Only turn.atrTurnId)
    let facts = rows :: [(Text, Text, Text, Value, Maybe Value, Maybe Text)]
    take 6 facts `shouldBe` drop 6 facts
    map (\(state, _, _, _, _, _) -> state) (take 6 facts) `shouldBe` ["succeeded", "rejected", "rejected", "failed", "committed", "outcome-unknown"]
    callCount jobs turn `shouldReturn` 12
    labels <- withDb pool $ query "SELECT call_id FROM execution_journal WHERE turn_id=? AND call_id LIKE 'wasm:%/call:%'" (Only turn.atrTurnId)
    length (labels :: [Only Text]) `shouldBe` 6

  it "persists trusted skill controls from either path even when the guest later traps" $ do
    (jobs, turn, runtime) <- fixture
    let load = SkillLoad "web" (skillLoadVersion "trusted skill") "trusted skill" Nothing Nothing
        runner = echoTool {toolName = "use_skill", toolRunner = LegacyRunner $ \value -> activateSkills [load] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "use_skill" args, request "hidden" args] "unreachable"
    result <- withHost pool . runToolsWith runToolControl (pure registry) $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "use_skill" args]
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    result.cmControl `shouldBe` LoadSkills [load]
    map (.ccOutcome) result.cmCalls `shouldBe` ["succeeded", "rejected"]
    withDb pool (query "SELECT observed_manifest->'skill_loads' FROM execution_journal WHERE turn_id=? AND tool_ref='use_skill' ORDER BY execution_ordinal" (Only turn.atrTurnId)) `shouldReturn` [Only (toJSON [load]), Only (toJSON [load])]

  it "uses an exact loaded workflow and journals its version and output contract failure" $ do
    (jobs, turn, runtime) <- fixture
    let contract = checkedContract $ object ["type" .= ("object" :: Text), "additionalProperties" .= True]
        workflow = Workflow "saved" "await tools.echo(args); return 'wrong shape';" contract contract ["echo"]
        package = SkillPackage [] (Map.singleton "run" workflow)
        raw = SkillLoad "saved" "" "saved instructions" Nothing (Just (PinnedPackage 1 package Map.empty Nothing TrustedSkill))
        writeDefinition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    effectRegistry <- either (fail . show) pure (buildToolRegistry [writeDefinition] [echoTool])
    [pinned] <- either (fail . show) pure (bindWorkflowContracts javaScriptRuntimeVersion (views effectRegistry) [raw])
    let loader = echoTool {toolName = "use_skill", toolRunner = LegacyRunner $ \value -> activateSkills [pinned] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [loader])
    loaded <- withHost pool . runToolsWith runToolControl (pure registry) $ do
      session <- newExecutionSession Nothing
      executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "load" "use_skill" args]
    let active = concatMap (controlSkillLoads . (.tiControl)) loaded.tbInvocations
    active `shouldBe` [pinned]
    result <- withHost pool . runTools effectRegistry $ do
      session <- newExecutionSession Nothing
      executeModelBatch
        True
        (Map.fromList [(l.slName, l) | l <- active])
        session
        (hostHooks jobs runtime)
        (views effectRegistry)
        [ToolRequest "saved-code" "run_code" (object ["workflow" .= ("saved/run" :: Text), "args" .= args])]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["outcome-unknown"]
    states turn `shouldReturn` [("use_skill", "succeeded"), ("host:wasm/v2", "outcome-unknown"), ("echo", "committed")]
    evidence <- withDb pool $ query "SELECT normalized_input->'program'->'workflow'->>'version', normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v2'" (Only turn.atrTurnId)
    evidence `shouldBe` [(pinned.slVersion, workflow.wfSource)]

  it "refuses the loser before effect when sessions race for the last shared call" $ do
    (jobs, turn, runtime) <- fixture
    replicateM_ (treeToolCalls - 1) (Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork ReserveCall) >>= (`shouldBe` True))
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    let native = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          batch <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "echo" args]
          pure (batch.tbOverBudget, map (outcomeName . (.tiOutcome)) batch.tbInvocations)
        guest = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          result <- runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
          pure (result.cmOverBudget, map (.ccOutcome) result.cmCalls)
    -- Neither side is cancelled: the loser's call is rejected and flagged.
    (a, b) <- Async.concurrently native guest
    sort [a, b] `shouldBe` [(False, ["succeeded"]), (True, ["rejected"])]
    callCount jobs turn `shouldReturn` treeToolCalls
    rows <- withDb pool $ query "SELECT state FROM execution_journal WHERE turn_id=? AND tool_ref='echo'" (Only turn.atrTurnId)
    rows `shouldBe` [Only ("succeeded" :: Text)]

  it "returns committed outcomes when diagnostic storage fails without replaying either adapter" $ do
    (jobs, turn, runtime) <- fixture
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "echo" args] ""
    (native, guest) <- bracket_
      (withDb pool (execute "ALTER TABLE execution_journal ADD CONSTRAINT test_no_echo CHECK (tool_ref IS DISTINCT FROM 'echo')" ()))
      (withDb pool (execute "ALTER TABLE execution_journal DROP CONSTRAINT test_no_echo" ()))
      $ withHost pool . runTools registry
      $ do
        session <- newExecutionSession Nothing
        native <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "echo" args]
        guest <- runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
        pure (native, guest)
    map (outcomeName . (.tiOutcome)) native.tbInvocations `shouldBe` ["committed"]
    map (.ccOutcome) guest.cmCalls `shouldBe` ["committed"]
    readIORef count `shouldReturn` 2
    states turn `shouldReturn` [("host:wasm/v2", "succeeded")]
    callCount jobs turn `shouldReturn` 2

  it "retains a committed leaf after a guest trap and never retries the container" $ do
    (jobs, turn, runtime) <- fixture
    effects <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' effects (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "echo" args] "unreachable"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    rows <- states turn
    rows `shouldBe` [("host:wasm/v2", "outcome-unknown"), ("echo", "committed")]
    readIORef effects `shouldReturn` 1
    callCount jobs turn `shouldReturn` 1
    Just job <- Jobs.jobForTurn jobs turn.atrTurnId
    Jobs.completeJob jobs job.run Failed (JobResult "guest trapped" Nothing)
    withDb pool (finishAgentTurn turn TurnFailed 0 Nothing)
    _ <- NodeWorkFixture.takeWork jobs -- one result notice, never another execution
    timeout 20000 (NodeWorkFixture.takeWork jobs) `shouldReturn` Nothing

  it "settles cancellation during a host call and leaves later calls unstarted" $ do
    -- Exercise both adapters against separate turns and the same DB interpreter.
    mapM_
      ( \guest -> do
          truncateAll pool
          (jobs, turn, runtime) <- fixture
          entered <- newEmptyMVar
          admitted <- newEmptyMVar
          blocked <- newEmptyMVar
          let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
              definition = echoDefinition {tdParallelism = SequentialOnly}
          registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
          binary <- guestCalls [request "echo" args, request "echo" args] ""
          let base = hostHooks jobs runtime
              bound =
                base
                  { ehStart = \step start -> do
                      row <- base.ehStart step start
                      when (start.jsCallId == "two") (liftIO (putMVar admitted ()))
                      pure row
                  }
          worker <- Async.async . withHost pool . runTools registry $ do
            session <- newExecutionSession Nothing
            if guest
              then void (runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary)
              else void (executeToolBatch session bound (views registry) [ToolRequest "one" "echo" args, ToolRequest "two" "echo" args])
          takeMVar entered
          when (not guest) (takeMVar admitted)
          withDb pool (query "SELECT count(*) FROM execution_journal WHERE turn_id=?" (Only turn.atrTurnId)) `shouldReturn` [Only (0 :: Int)]
          timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
          rows <- states turn
          rows `shouldBe` ([("host:wasm/v2", "outcome-unknown") | guest] <> [("echo", "outcome-unknown")] <> [("echo", "rejected") | not guest])
          callCount jobs turn `shouldReturn` (if guest then 1 else 2)
      )
      [False, True]

  it "fences both paths after replacement without replaying completed calls" $ do
    (jobs, old, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    Just job <- Jobs.jobForTurn jobs old.atrTurnId
    Jobs.replaceJob jobs job.spec.group job.spec.principal False job.run.jobId "replacement" `shouldReturn` Right ()
    let stale wasm = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          if wasm
            then void (runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary)
            else void (executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "stale" "echo" args])
    stale False `shouldThrow` (\TaskCancelled -> True)
    stale True `shouldThrow` (\TaskCancelled -> True)
    rows <- states old
    rows `shouldBe` [("host:wasm/v2", "succeeded"), ("echo", "succeeded")]
    Just replaced <- Jobs.lookupJob jobs job.spec.group job.run.jobId
    replaced.calls `shouldBe` 1
    timeout 20000 (NodeWorkFixture.takeWork jobs) `shouldReturn` Nothing
  where
    fixture = do
      running <- runningJob pool Basic Map.empty
      pure (running.jobs, running.turn, running.runtime)
    callCount jobs turn = do
      Just job <- Jobs.jobForTurn jobs turn.atrTurnId
      pure job.calls
    states turn = withDb pool (query "SELECT tool_ref,state FROM execution_journal WHERE turn_id=? ORDER BY execution_ordinal" (Only turn.atrTurnId)) :: IO [(Text, Text)]
    args = object ["value" .= (7 :: Int)]

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

request :: Text -> Value -> Value
request name args = object ["tool" .= name, "args" .= args]

checkedContract :: Value -> Contract
checkedContract = either (error . show) id . parseContract
