{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Max.Effects.AgentSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (fromException)
import Control.Monad (when)
import Data.Aeson (Value, object, (.=))
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Concurrent.Async (Concurrent, runConcurrent)
import Effectful.Log (Log, runLog)
import Log (LogLevel (LogAttention))
import Max.Agent.Execution (ExecutionAdmission (..), ExecutionInbox (..), ExecutionJournal (..))
import Max.Agent.Failure (AgentFailure (..))
import Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..))
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Effects.Agent (Agent, AgentContext (..), AgentLimits (..), AgentOutcome (..), AgentReply (..), AgentResult (..), agentTurn, runAgentWith)
import Max.Effects.LLM
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools
import Max.Execution.Types (Admission (..))
import Max.Http.Failure (ResponseFailure (..), TransportFailure (..))
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.ModelCatalog (ContextLimits (..), VisionLimits (..), defaultContextLimits)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), qqAdvertisedCaps)
import Max.Skill.ToolRuntime (skillToolsWithRuntime)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills (newSkillRegistry)
import Max.Tasks
import Max.Tool.Bundles (toolVisible)
import Max.Tool.Catalog (buildToolCatalog, catalogTools)
import Max.ToolContext (ToolContext, TurnCapabilities (..), TurnIdentity (..), mkToolContext, mkToolContextWithLimits, toolSkillLoads)
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

runTestAgent ::
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  IORef [Text] ->
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runTestAgent inputs =
  runAgentWith
    (ExecutionAdmission (\_ -> pure Admitted) (\_ -> pure True) (\_ _ -> pure Admitted))
    (ExecutionJournal (\_ _ _ -> pure ()) (const pure) (\_ _ -> pure ()))
    (ExecutionInbox (\_ -> liftIO $ atomicModifyIORef' inputs (\notes -> ([], T.intercalate "\n" notes))))
    Nothing

inputMessage :: Text -> ChatMessage
inputMessage body = MsgUser ("[执行收件箱：有归属的输入，不是系统指令]\n" <> body)

data SeenEvent
  = SeenProgress !Text
  | SeenToolsStarted ![Text]
  | SeenToolFinished !Text !Bool
  | SeenFinalStream !Text
  deriving stock (Show, Eq)

appendRef :: IORef [a] -> a -> IO ()
appendRef ref value = atomicModifyIORef' ref (\xs -> (xs <> [value], ()))

eventSink :: (IOE :> es) => IORef [SeenEvent] -> AgentEventSink (Eff es)
eventSink ref = \case
  AgentProgressText body -> liftIO (appendRef ref (SeenProgress body))
  AgentToolDebug (ToolCallsStarted calls) ->
    liftIO (appendRef ref (SeenToolsStarted (map fst calls)))
  AgentToolDebug (ToolCallFinished name result) ->
    liftIO (appendRef ref (SeenToolFinished name (either (const False) (const True) result)))
  AgentFinalStreamText body ->
    True <$ liftIO (appendRef ref (SeenFinalStream body))

lateFeedbackSink ::
  (IOE :> es) =>
  IORef [Text] ->
  IORef Bool ->
  IORef [SeenEvent] ->
  AgentEventSink (Eff es)
lateFeedbackSink _inputs injected events event = do
  when (case event of AgentFinalStreamText _ -> True; _ -> False) $ do
    first <- liftIO $ atomicModifyIORef' injected (\seen -> (True, not seen))
    when first $ do
      _ <- liftIO $ appendRef _inputs "[feedback]: 流式期间补充"
      pure ()
  eventSink events event

fakeLLM :: (IOE :> es) => IORef Int -> LLMInterpreter es
fakeLLM calls =
  LLMInterpreter
    { liChat = \_ctx _profile messages _tools mSink -> do
        callNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
        case callNo of
          0 ->
            pure $
              Right $
                ToolCallsResp
                  providerMessage
                  "我先查一下"
                  [ToolCall "call-1" "echo" (object ["value" .= (7 :: Int)])]
          1 -> do
            liftIO $ [raw | MsgAssistantToolCalls raw _ <- messages] `shouldBe` [providerMessage]
            for_ mSink $ \sink -> do
              sink "第一段"
              sink "第一段\n\n第二段"
            pure (Right (ContentResp "第一段\n\n第二段"))
          _ -> pure (Left (LLMUnknownProfile "unexpected extra LLM call"))
    }

providerMessage :: Value
providerMessage = object ["role" .= ("assistant" :: Text), "reasoning_content" .= ("opaque provider state" :: Text)]

echoTool :: (ToolOutput :> es) => Tool es
echoTool =
  Tool
    { toolName = "echo",
      toolDescription = "echo test input",
      toolSchema = object ["type" .= ("object" :: Text)],
      toolRunner = LegacyRunner $ \args -> do
        _ <- queueInlineMedia (InlineMedia "[tool image]:" "data:image/png;base64,AA==" Nothing)
        pure (Right (object ["echo" .= args]))
    }

echoDefinition :: ToolDefinition
echoDefinition =
  ToolDefinition
    { tdRef = ToolRef "echo",
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = Set.singleton (EffectRead "test.echo"),
      tdParallelism = ParallelSafe,
      tdRetryClass = RetrySafe,
      tdAuthorities = Set.singleton CurrentConversation,
      tdDeadline = ToolDeadline 30,
      tdFailuresPrecedeEffects = False,
      tdCallMode = WorkCall
    }

dispatchContext :: AgentContext
dispatchContext =
  AgentContext
    ( mkToolContext
        (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
        ( TurnCapabilities
            { tcMultimodal = False,
              tcStickers = True,
              tcSkills = False,
              tcOutput = qqAdvertisedCaps,
              tcMonitorArming = True,
              tcCatalogGrants = Map.empty,
              tcEffectCeiling = Nothing,
              tcBackground = False
            }
        )
    )
    Nothing
    Nothing
    Nothing

-- Each call attaches a distinct 12288-token video rendition.
clipTool :: (ToolOutput :> es, IOE :> es) => IORef Int -> Tool es
clipTool counter =
  Tool
    { toolName = "clip",
      toolDescription = "attach a clip",
      toolSchema = object ["type" .= ("object" :: Text)],
      toolRunner = LegacyRunner $ \_ -> do
        n <- liftIO (atomicModifyIORef' counter (\k -> (k + 1, k + 1)))
        _ <- queueInlineMedia (InlineMedia "[clip]:" ("data:video/mp4;base64,clip" <> T.pack (show n)) (Just 12288))
        pure (Right (object ["attached" .= True]))
    }

clipDefinition :: ToolDefinition
clipDefinition = echoDefinition {tdRef = ToolRef "clip"}

-- Room for one 12288-token video per request.
visionContext :: AgentContext
visionContext =
  dispatchContext
    { acTools =
        mkToolContextWithLimits
          defaultContextLimits {visionLimits = Just (VisionLimits 16384 16384 600 768 25165824)}
          (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
          (TurnCapabilities True True False qqAdvertisedCaps True Map.empty Nothing False)
    }

videosIn :: [ChatMessage] -> [Text]
videosIn messages = [url | MsgUserBlocks blocks <- messages, VideoDataUrl url _ <- blocks]

runVisionTurn :: LLMInterpreter '[Log, Concurrent, IOE] -> IO AgentResult
runVisionTurn provider = do
  counter <- newIORef 0
  inputs <- newIORef []
  events <- newIORef []
  tasks <- newTaskRegistry
  turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
  result <-
    withCompactLogger ColorNever Nothing $ \logger ->
      runEff
        . runConcurrent
        . runLog "vision-test" logger LogAttention
        . runLLMWith provider
        . runTestAgent inputs (AgentLimits {maxTurns = 4}) (const (buildToolRegistry [clipDefinition] [clipTool counter]))
        $ agentTurn turn visionContext "fake" [MsgUser "question"] (eventSink events)
  _ <- finishTurnRuntime tasks turn
  pure result

spec :: Spec
spec = describe "Agent full loop" $ do
  it "evicts the turn's oldest media when a request would exceed the vision envelope" $ do
    calls <- newIORef (0 :: Int)
    seen <- newIORef []
    let clip = ToolCallsResp providerMessage "" [ToolCall "call" "clip" (object [])]
        provider =
          LLMInterpreter
            { liChat = \_ _ messages _ _ -> do
                n <- liftIO (atomicModifyIORef' calls (\k -> (k + 1, k)))
                liftIO (appendRef seen messages)
                pure (Right (if n < 2 then clip else ContentResp "done"))
            }
    result <- runVisionTurn provider
    result.outcome `shouldBe` Answered (AgentReply "done" "")
    requests <- readIORef seen
    map videosIn requests `shouldBe` [[], ["data:video/mp4;base64,clip1"], ["data:video/mp4;base64,clip2"]]
    T.concat [text | MsgUserBlocks blocks <- last requests, TextBlock text <- blocks] `shouldSatisfy` T.isInfixOf "这个附件已移出上下文"

  it "retries without media when the server still rejects them" $ do
    calls <- newIORef (0 :: Int)
    seen <- newIORef []
    let provider =
          LLMInterpreter
            { liChat = \_ _ messages _ _ -> do
                n <- liftIO (atomicModifyIORef' calls (\k -> (k + 1, k)))
                liftIO (appendRef seen messages)
                pure $ case n of
                  0 -> Right (ToolCallsResp providerMessage "" [ToolCall "call" "clip" (object [])])
                  1 -> Left (LLMResponseFailure (ResponseDecode "HTTP 400: {\"error\":{\"code\":\"media_budget_exceeded\"}}"))
                  _ -> Right (ContentResp "done")
            }
    result <- runVisionTurn provider
    result.outcome `shouldBe` Answered (AgentReply "done" "")
    map videosIn <$> readIORef seen `shouldReturn` [[], ["data:video/mp4;base64,clip1"], []]

  it "loads codemode, invokes JavaScript with the round catalog, and preserves media and later skill activation" $ do
    registry <- newSkillRegistry
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    leaves <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let executionContext =
          dispatchContext
            { acTools =
                mkToolContext
                  (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
                  ( TurnCapabilities
                      { tcMultimodal = False,
                        tcStickers = False,
                        tcSkills = True,
                        tcOutput = qqAdvertisedCaps,
                        tcMonitorArming = True,
                        tcCatalogGrants = Map.empty,
                        tcEffectCeiling = Nothing,
                        tcBackground = False
                      }
                  )
            }
        factory current =
          buildToolRegistry
            ( [echoDefinition, echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}]
                <> [echoDefinition {tdRef = ToolRef "web_search"} | toolVisible (toolSkillLoads current) "web_search"]
            )
            ( [ legacyTool
                  "echo"
                  "echo with steering"
                  (object ["type" .= ("object" :: Text)])
                  ( \args -> do
                      liftIO $ readIORef calls `shouldReturn` 2
                      leaf <- liftIO $ atomicModifyIORef' leaves (\n -> (n + 1, n))
                      when (leaf == 0) $ liftIO $ do
                        _ <- appendRef _inputs "[feedback]: 下一轮改成方案 B"
                        pure ()
                      toolRun echoTool args
                  )
              ]
                <> skillToolsWithRuntime registry current (const (pure (Right Nothing))) Right
                <> [echoTool {toolName = "web_search"} | toolVisible (toolSkillLoads current) "web_search"]
            )
        provider =
          LLMInterpreter
            { liChat = \_ _ messages specs _ -> do
                roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                let names = map (.specName) specs
                    respond name args = pure (Right (ToolCallsResp (object []) "" [ToolCall (T.pack (show roundNo)) name args]))
                case roundNo of
                  0 -> do
                    liftIO $ names `shouldNotContain` ["run_code"]
                    respond "use_skill" (object ["name" .= ("codemode" :: Text)])
                  1 -> do
                    liftIO $ [text | MsgUser text <- messages, "[当前已加载宿主技能]" `T.isPrefixOf` text] `shouldBe` []
                    liftIO $ names `shouldContain` ["run_code"]
                    liftIO $ names `shouldNotContain` ["web_search"]
                    respond "run_code" (object ["code" .= ("const value = await tools.echo({value:7}); await tools.echo({value:8}); await tools.use_skill({name:'web'}); return {answer:value.echo.value, hidden:!max.names.includes('web_search')};" :: Text)])
                  _ -> do
                    liftIO $ readIORef leaves `shouldReturn` 2
                    liftIO $ case reverse messages of
                      MsgUser note : MsgUserBlocks _ : MsgTool "1" _ : _ -> show (MsgUser note) `shouldBe` show (inputMessage "[feedback]: 下一轮改成方案 B")
                      other -> expectationFailure ("input did not follow the complete code result: " <> show other)
                    liftIO $ names `shouldContain` ["web_search", "run_code"]
                    liftIO $
                      [text | MsgUser text <- messages, "[当前已加载宿主技能]" `T.isPrefixOf` text]
                        `shouldSatisfy` (\frames -> any (T.isInfixOf "[skill: web]") frames && not (any (T.isInfixOf "[skill: codemode]") frames))
                    liftIO $ any (\case MsgTool "1" body -> "\"answer\":7" `T.isInfixOf` body && "\"hidden\":true" `T.isInfixOf` body; _ -> False) messages `shouldBe` True
                    liftIO $ any (\case MsgUserBlocks blocks -> any (\case ImageDataUrl _ -> True; _ -> False) blocks; _ -> False) messages `shouldBe` True
                    pure (Right (ContentResp "done"))
            }
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "codemode-model-test" logger LogAttention . runLLMWith provider . runTestAgent _inputs (AgentLimits 4) factory $
        agentTurn turn executionContext "fake" [MsgUser "compose"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.outcome `shouldBe` Answered (AgentReply "done" "")
    readIORef calls `shouldReturn` 3

  it "loads and runs a saved workflow through the model loop on the next round" $ do
    registry <- newSkillRegistry
    events <- newIORef []
    rounds <- newIORef (0 :: Int)
    leaves <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let searchDefinition = echoDefinition {tdRef = ToolRef "web_search"}
        searchSchema = object ["type" .= ("object" :: Text)]
        searchTool = legacyTool "web_search" "search" searchSchema $ \_ -> do
          leaf <- liftIO $ atomicModifyIORef' leaves (\n -> (n + 1, n))
          when (leaf == 0) $ liftIO $ do
            _ <- appendRef _inputs "[feedback]: 之后只保留官方来源"
            pure ()
          pure (Right (object ["results" .= ([] :: [Value])]))
        executionContext =
          dispatchContext
            { acTools =
                mkToolContext
                  (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
                  ( TurnCapabilities
                      { tcMultimodal = False,
                        tcStickers = False,
                        tcSkills = True,
                        tcOutput = qqAdvertisedCaps,
                        tcMonitorArming = True,
                        tcCatalogGrants = Map.empty,
                        tcEffectCeiling = Nothing,
                        tcBackground = False
                      }
                  )
            }
    available <- either (fail . show) pure (buildToolCatalog [searchDefinition] [ToolSpec "web_search" "search" searchSchema])
    let factory current =
          buildToolRegistry
            ( [echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}]
                <> [searchDefinition | toolVisible (toolSkillLoads current) "web_search"]
            )
            ( skillToolsWithRuntime registry current (const (pure (Right Nothing))) (bindWorkflowContracts javaScriptRuntimeVersion (catalogTools available))
                <> [searchTool | toolVisible (toolSkillLoads current) "web_search"]
            )
        provider =
          LLMInterpreter
            { liChat = \_ _ messages specs _ -> do
                roundNo <- liftIO $ atomicModifyIORef' rounds (\n -> (n + 1, n))
                let respond name args = pure (Right (ToolCallsResp (object []) "" [ToolCall (T.pack (show roundNo)) name args]))
                case roundNo of
                  0 -> do
                    liftIO $ map (.specName) specs `shouldNotContain` ["run_code"]
                    liftIO $ map (.specName) specs `shouldNotContain` ["web_search"]
                    respond "use_skill" (object ["name" .= ("batch-search" :: Text)])
                  1 -> do
                    liftIO $ map (.specName) specs `shouldContain` ["web_search", "run_code"]
                    respond "run_code" (object ["workflow" .= ("batch-search/search" :: Text), "args" .= object ["queries" .= (["one", "two"] :: [Text]), "limit" .= (2 :: Int)]])
                  _ -> do
                    liftIO $ readIORef leaves `shouldReturn` 2
                    liftIO $ case reverse messages of
                      MsgUser note : MsgTool "1" body : _ -> do
                        show (MsgUser note) `shouldBe` show (inputMessage "[feedback]: 之后只保留官方来源")
                        body `shouldSatisfy` T.isInfixOf "batch-search/search"
                        body `shouldSatisfy` T.isInfixOf "run_ref"
                      other -> expectationFailure ("saved workflow lost its complete result/input boundary: " <> show other)
                    pure (Right (ContentResp "done"))
            }
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "saved-workflow-model" logger LogAttention . runLLMWith provider . runTestAgent _inputs (AgentLimits 4) factory $
        agentTurn turn executionContext "fake" [MsgUser "batch search"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.outcome `shouldBe` Answered (AgentReply "done" "")
    readIORef rounds `shouldReturn` 3

  it "loads a complete skill next round, rejects same-batch hidden calls, and isolates requests" $ do
    registry <- newSkillRegistry
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    effects <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let executionContext =
          dispatchContext
            { acTools =
                mkToolContext
                  (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
                  ( TurnCapabilities
                      { tcMultimodal = False,
                        tcStickers = False,
                        tcSkills = True,
                        tcOutput = qqAdvertisedCaps,
                        tcMonitorArming = True,
                        tcCatalogGrants = Map.empty,
                        tcEffectCeiling = Nothing,
                        tcBackground = False
                      }
                  )
            }
        factory current =
          buildToolRegistry
            ( [echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}]
                <> [echoDefinition {tdRef = ToolRef "web_search"} | toolVisible (toolSkillLoads current) "web_search"]
            )
            ( skillToolsWithRuntime registry current (const (pure (Right Nothing))) Right
                <> [ legacyTool
                       "web_search"
                       "search"
                       (object ["type" .= ("object" :: Text)])
                       (\_ -> liftIO (modifyIORef' effects (+ 1)) >> pure (Right (object ["result" .= T.replicate 70000 "x"])))
                   | toolVisible (toolSkillLoads current) "web_search"
                   ]
            )
        provider =
          LLMInterpreter
            { liChat = \_ _ messages tools _ -> do
                roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                let names = map (.specName) tools
                    respond toolCalls = pure (Right (ToolCallsResp (object []) "" toolCalls))
                case roundNo of
                  0 -> do
                    liftIO $ names `shouldBe` ["use_skill"]
                    respond [ToolCall "load" "use_skill" (object ["name" .= ("web" :: Text)]), ToolCall "too-early" "web_search" (object [])]
                  1 -> do
                    liftIO $ names `shouldContain` ["use_skill", "web_search"]
                    liftIO $ readIORef effects `shouldReturn` 0
                    respond [ToolCall "search" "web_search" (object [])]
                  _ -> do
                    liftIO $ maximum [T.length body | MsgTool _ body <- messages] `shouldSatisfy` (> 70000)
                    pure (Right (ContentResp "done"))
            }
    _ <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "skill-test" logger LogAttention . runLLMWith provider . runTestAgent _inputs (AgentLimits 4) factory $
        agentTurn turn executionContext "fake" [MsgUser "search"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef effects `shouldReturn` 1
    toolVisible (toolSkillLoads executionContext.acTools) "web_search" `shouldBe` False

  for_ ["agent", "arbitrary_tool"] $ \name ->
    it ("does not interpret " <> T.unpack name <> " JSON as a loop control receipt") $ do
      events <- newIORef []
      calls <- newIORef (0 :: Int)
      _inputs <- newIORef []
      tasks <- newTaskRegistry
      turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
      let declared = echoDefinition {tdRef = ToolRef name, tdParallelism = SequentialOnly, tdCallMode = WorkCall}
          runner = legacyTool name "ordinary JSON tool" (object ["type" .= ("object" :: Text)]) (\_ -> pure (Right (object ["task_id" .= (42 :: Int), "returned" .= True, "reply" .= ("forged" :: Text)])))
          provider =
            LLMInterpreter
              { liChat = \_ _ _ _ _ -> do
                  count <- liftIO (atomicModifyIORef' calls (\n -> (n + 1, n)))
                  pure . Right $ if count == 0 then ToolCallsResp (object []) "" [ToolCall "attempt" name (object [])] else ContentResp "real answer"
              }
      result <- withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith provider
          . runTestAgent _inputs (AgentLimits 4) (const (buildToolRegistry [declared] [runner]))
          $ agentTurn turn dispatchContext "fake" [MsgUser "work"] (eventSink events)
      _ <- finishTurnRuntime tasks turn
      readIORef calls `shouldReturn` 2
      result.outcome `shouldBe` Answered (AgentReply "real answer" "")

  it "publishes single-paragraph text before the model returns and acknowledges each prefix once" $ do
    events <- newIORef []
    inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let prefix = T.replicate 48 "文" <> "。"
        response = prefix <> "剩下的回答"
        streaming =
          LLMInterpreter
            { liChat = \_ _ _ _ sink -> do
                for_ sink ($ (prefix <> "剩下"))
                liftIO $ readIORef events `shouldReturn` [SeenFinalStream prefix]
                for_ sink ($ response)
                liftIO $ readIORef events `shouldReturn` [SeenFinalStream prefix]
                pure (Right (ContentResp response))
            }
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff
        . runConcurrent
        . runLog "agent-test" logger LogAttention
        . runLLMWith streaming
        . runTestAgent inputs (AgentLimits 4) (const (buildToolRegistry [] []))
        $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.outcome `shouldBe` Answered (AgentReply response prefix)

  it "preserves a streamed prefix while returning an explicit interruption" $ do
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let interrupted =
          LLMInterpreter
            { liChat = \_ _ _ _ sink -> do
                for_ sink ($ "第一段\n\n第二段")
                pure (Right (InterruptedResp "第一段\n\n第二段没写完" (ResponseTransport ResponseTimeoutFailure)))
            }
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff
        . runConcurrent
        . runLog "agent-test" logger LogAttention
        . runLLMWith interrupted
        . runTestAgent _inputs (AgentLimits {maxTurns = 4}) (const (buildToolRegistry [] []))
        $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.outcome `shouldBe` Interrupted (AgentStreamInterrupted (ResponseTransport ResponseTimeoutFailure)) (AgentReply "第一段\n\n第二段没写完" "第一段\n\n")
    readIORef events `shouldReturn` [SeenFinalStream "第一段\n\n"]

  it "runs fake LLM + tool rounds and emits typed output events in memory" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith (fakeLLM calls)
          . runTestAgent _inputs (AgentLimits {maxTurns = 4}) (const (buildToolRegistry [echoDefinition] [echoTool]))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn

    result.outcome `shouldBe` Answered (AgentReply "第一段\n\n第二段" "第一段\n\n")
    result.turnsUsed `shouldBe` 2
    case result.appended of
      [ MsgAssistantToolCalls _ [tc],
        MsgTool callId payload,
        MsgUserBlocks [TextBlock label, ImageDataUrl dataUrl],
        MsgAssistant final
        ] -> do
          tc.callName `shouldBe` "echo"
          callId `shouldBe` "call-1"
          payload `shouldSatisfy` T.isInfixOf "\"value\":7"
          label `shouldBe` "[tool image]:"
          dataUrl `shouldBe` "data:image/png;base64,AA=="
          final `shouldBe` "第一段\n\n第二段"
      other -> expectationFailure ("unexpected appended conversation: " <> show other)
    readIORef calls `shouldReturn` 2
    readIORef events
      `shouldReturn` [ SeenProgress "我先查一下",
                       SeenToolsStarted ["echo"],
                       SeenToolFinished "echo" True,
                       SeenFinalStream "第一段\n\n"
                     ]

  it "enforces a child tool-call budget before invoking the runner" $ do
    events <- newIORef []
    llmCalls <- newIORef (0 :: Int)
    toolCalls <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let counted :: (IOE :> es) => Tool es
        counted =
          Tool
            { toolName = "echo",
              toolDescription = "counted echo test input",
              toolSchema = object ["type" .= ("object" :: Text)],
              toolRunner = LegacyRunner $ \args -> do
                liftIO (modifyIORef' toolCalls (+ 1))
                pure (Right args)
            }
        childContext = dispatchContext {acMaxToolCalls = Just 0}
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith (fakeLLM llmCalls)
          . runTestAgent _inputs (AgentLimits {maxTurns = 4}) (const (buildToolRegistry [echoDefinition] [counted]))
          $ agentTurn turn childContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef toolCalls `shouldReturn` 0
    result.appended
      `shouldSatisfy` any
        ( \case
            MsgTool _ body -> "工具调用预算已经用完" `T.isInfixOf` body
            _ -> False
        )

  it "serializes a tool-call round when any declared effect is unsafe to parallelize" $ do
    order <- newIORef ([] :: [Text])
    calls <- newIORef (0 :: Int)
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let recordedTool name =
          Tool
            { toolName = name,
              toolDescription = "record execution order",
              toolSchema = object ["type" .= ("object" :: Text)],
              toolRunner = LegacyRunner $ \_ -> do
                liftIO (appendRef order ("start:" <> name))
                liftIO (threadDelay 20000)
                liftIO (appendRef order ("end:" <> name))
                pure (Right (object ["name" .= name]))
            }
        readDef = echoDefinition {tdRef = ToolRef "read"}
        writeDef =
          ToolDefinition
            { tdRef = ToolRef "write",
              tdSchemaVersion = SchemaVersion 1,
              tdEffects = Set.singleton (EffectWrite "test.db"),
              tdParallelism = SequentialOnly,
              tdRetryClass = RetryUnsafe,
              tdAuthorities = Set.singleton CurrentConversation,
              tdDeadline = ToolDeadline 30,
              tdFailuresPrecedeEffects = False,
              tdCallMode = WorkCall
            }
        twoCallLLM =
          LLMInterpreter
            { liChat = \_ _ _ _ _ -> do
                callNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                pure $ case callNo of
                  0 ->
                    Right $
                      ToolCallsResp
                        (object ["role" .= ("assistant" :: Text)])
                        ""
                        [ ToolCall "read-1" "read" (object []),
                          ToolCall "write-1" "write" (object [])
                        ]
                  _ -> Right (ContentResp "done")
            }
    _ <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith twoCallLLM
          . runTestAgent
            _inputs
            (AgentLimits {maxTurns = 4})
            (const (buildToolRegistry [readDef, writeDef] [recordedTool "read", recordedTool "write"]))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef order
      `shouldReturn` ["start:read", "end:read", "start:write", "end:write"]

  it "drains feedback in arrival order before the next LLM node" $ do
    seenMessages <- newIORef ([] :: [[ChatMessage]])
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let feedback = ["[feedback]: 改成方案 B", "[feedback]: 保留测试"]
        body = T.intercalate "\n" feedback
    for_ feedback (appendRef _inputs)
    let llm =
          LLMInterpreter
            { liChat = \_ _ messages _ _ -> do
                liftIO (appendRef seenMessages messages)
                pure (Right (ContentResp "done"))
            }
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith llm
          . runTestAgent _inputs (AgentLimits {maxTurns = 2}) (const (buildToolRegistry [] []))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    finishTurnRuntime tasks turn

    map show result.appended `shouldBe` map show [inputMessage body, MsgAssistant "done"]
    map (map show) <$> readIORef seenMessages
      `shouldReturn` [map show [MsgUser "question", inputMessage body]]
    readIORef _inputs `shouldReturn` []
    (null <$> listTasks tasks (Just (GroupId 7777))) `shouldReturn` True

  it "appends steering after every result in a native tool batch" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let runner =
          legacyTool
            "echo"
            "echo with steering"
            (object ["type" .= ("object" :: Text)])
            ( \args -> do
                _ <- liftIO $ appendRef _inputs "[feedback]: next"
                pure (Right args)
            )
        provider =
          LLMInterpreter
            ( \_ _ messages _ _ -> do
                roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                if roundNo == 0
                  then pure (Right (ToolCallsResp (object []) "" [ToolCall "a" "echo" (object []), ToolCall "b" "echo" (object [])]))
                  else do
                    liftIO $ case reverse messages of
                      MsgUser _ : MsgTool "b" _ : MsgTool "a" _ : MsgAssistantToolCalls _ _ : _ -> pure ()
                      other -> expectationFailure ("unpaired tool results: " <> show other)
                    pure (Right (ContentResp "done"))
            )
    _ <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "steering-test" logger LogAttention . runLLMWith provider . runTestAgent _inputs (AgentLimits 3) (const (buildToolRegistry [echoDefinition] [runner])) $
        agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef calls `shouldReturn` 2

  it "writes a tool-free report instead of stopping when the tree's budget is spent" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    ran <- newIORef (0 :: Int)
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let provider =
          LLMInterpreter
            ( \_ _ messages tools _ -> do
                roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                if roundNo == 0
                  then pure (Right (ToolCallsResp providerMessage "" [ToolCall "call-1" "echo" (object [])]))
                  else do
                    liftIO $ do
                      length tools `shouldBe` 0
                      case reverse messages of
                        MsgUser note : _ -> note `shouldSatisfy` T.isInfixOf "预算已经用完"
                        other -> expectationFailure ("missing wrap-up note: " <> show other)
                    pure (Right (ContentResp "partial findings"))
            )
        counted :: (IOE :> es) => Tool es
        counted =
          Tool
            { toolName = "echo",
              toolDescription = "counted echo test input",
              toolSchema = object ["type" .= ("object" :: Text)],
              toolRunner = LegacyRunner $ \args -> liftIO (modifyIORef' ran (+ 1)) >> pure (Right args)
            }
        admission = ExecutionAdmission (\_ -> pure Admitted) (\_ -> pure True) (\_ _ -> pure OverBudget)
        journal = ExecutionJournal (\_ _ _ -> pure ()) (const pure) (\_ _ -> pure ())
        inputs = ExecutionInbox (\_ -> liftIO $ atomicModifyIORef' _inputs (\notes -> ([], T.intercalate "\n" notes)))
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "budget-test" logger LogAttention . runLLMWith provider . runAgentWith admission journal inputs Nothing (AgentLimits 4) (const (buildToolRegistry [echoDefinition] [counted])) $
        agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef ran `shouldReturn` 0
    result.outcome `shouldBe` Interrupted AgentBudgetExhausted (AgentReply "partial findings" "")

  it "asks again, at most twice, when the caller rejects the final answer" $ do
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    let nonEmpty body = if T.null (T.strip body) then Just "报告是空的" else Nothing
        context = dispatchContext {acAnswerCheck = Just nonEmpty}
        run answers = do
          calls <- newIORef (0 :: Int)
          turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
          let provider =
                LLMInterpreter
                  ( \_ _ messages _ _ -> do
                      roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                      when (roundNo > 0) . liftIO $ case reverse messages of
                        MsgUser note : rest -> do
                          note `shouldSatisfy` T.isInfixOf "报告是空的"
                          [() | MsgAssistant "" <- rest] `shouldBe` []
                        other -> expectationFailure ("missing correction: " <> show other)
                      pure (Right (ContentResp (answers !! min roundNo (length answers - 1))))
                  )
          result <- withCompactLogger ColorNever Nothing $ \logger ->
            runEff . runConcurrent . runLog "answer-check" logger LogAttention . runLLMWith provider . runTestAgent _inputs (AgentLimits 8) (const (buildToolRegistry [] [])) $
              agentTurn turn context "fake" [MsgUser "question"] (eventSink events)
          _ <- finishTurnRuntime tasks turn
          (,) result.outcome <$> readIORef calls
    run ["", "report"] `shouldReturn` (Answered (AgentReply "report" ""), 2)
    run [""] `shouldReturn` (Answered (AgentReply "" ""), 3)

  it "reconsiders an unpublished final draft when feedback arrives during generation" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    inbox <- newIORef ""
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) Nothing
    let provider =
          LLMInterpreter
            ( \_ _ messages _ _ -> do
                roundNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
                if roundNo == 0
                  then do
                    liftIO (modifyIORef' inbox (const "late correction"))
                    pure (Right (ContentResp "draft"))
                  else do
                    liftIO $ case reverse messages of
                      MsgUser note : MsgAssistant "draft" : _ -> note `shouldSatisfy` T.isInfixOf "late correction"
                      other -> expectationFailure ("missing late correction: " <> show other)
                    pure (Right (ContentResp "corrected"))
            )
        admission = ExecutionAdmission (\_ -> pure Admitted) (\_ -> pure True) (\_ _ -> pure Admitted)
        journal = ExecutionJournal (\_ _ _ -> pure ()) (const pure) (\_ _ -> pure ())
        inputs = ExecutionInbox (\_ -> liftIO $ atomicModifyIORef' inbox ("",))
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "steering-test" logger LogAttention . runLLMWith provider . runAgentWith admission journal inputs Nothing (AgentLimits 3) (const (buildToolRegistry [] [])) $
        agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.outcome `shouldBe` Answered (AgentReply "corrected" "")

  it "propagates !kill as asynchronous cancellation and still permits root cleanup" $ do
    entered <- newEmptyMVar
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let blockingLLM =
          LLMInterpreter
            { liChat = \_ _ _ _ _ -> do
                liftIO (putMVar entered ())
                liftIO (threadDelay 5000000)
                pure (Right (ContentResp "too late"))
            }
        runTurn =
          withCompactLogger ColorNever Nothing $ \logger ->
            runEff
              . runConcurrent
              . runLog "agent-test" logger LogAttention
              . runLLMWith blockingLLM
              . runTestAgent _inputs (AgentLimits {maxTurns = 2}) (const (buildToolRegistry [] []))
              $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    worker <- Async.async runTurn
    takeMVar entered
    cancelTask tasks (turnRuntimeTaskId turn) `shouldReturn` True
    outcome <- Async.waitCatch worker
    case outcome of
      Left err -> case fromException err :: Maybe TaskCancelled of
        Just _ -> pure ()
        Nothing -> expectationFailure ("unexpected exception: " <> show err)
      Right _ -> expectationFailure "killed Agent turn completed normally"
    _ <- finishTurnRuntime tasks turn
    (null <$> listTasks tasks (Just (GroupId 7777))) `shouldReturn` True

  it "leaves input that races a streamed final paragraph unread for the next queued turn" $ do
    events <- newIORef []
    _inputs <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (AgentTurnRef (AgentTurnId 1) (TurnOrdinal 1)) (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    injected <- newIORef False
    let streamingLLM =
          LLMInterpreter
            { liChat = \_ _ _ _ mSink -> do
                for_ mSink (\sink -> sink "第一段\n\n还在生成")
                pure (Right (ContentResp "第一段\n\n还在生成"))
            }
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith streamingLLM
          . runTestAgent _inputs (AgentLimits {maxTurns = 2}) (const (buildToolRegistry [] []))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (lateFeedbackSink _inputs injected events)
    finishTurnRuntime tasks turn

    Answered reply <- pure result.outcome
    reply.publishedPrefix `shouldBe` "第一段\n\n"
    readIORef _inputs `shouldReturn` ["[feedback]: 流式期间补充"]
    (null <$> listTasks tasks (Just (GroupId 7777))) `shouldReturn` True
