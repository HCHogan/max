{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Max.Effects.AgentSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (fromException)
import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Concurrent.Async (runConcurrent)
import Effectful.Log (runLog)
import Log (LogLevel (LogAttention))
import Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..))
import Max.Effects.Agent (AgentContext (..), AgentLimits (..), AgentResult (..), agentTurn, runAgent)
import Max.Effects.LLM
  ( ChatMessage (..),
    ChatResponse (..),
    ContentBlock (..),
    LLMInterpreter (..),
    ToolCall (..),
    runLLMWith,
  )
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolAuthority (..),
    ToolDeadline (..),
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
    buildToolCatalog,
  )
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), qqAdvertisedCaps)
import Max.Tasks
  ( Note (..),
    NoteVerb (..),
    TaskCancelled,
    TaskRegistry,
    TurnCompletion (..),
    beginTurnRuntime,
    cancelTask,
    finishTurnRuntime,
    listTasks,
    newTaskRegistry,
    pushToLatest,
    turnRuntimeTaskId,
  )
import Max.ToolContext (TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

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
  TaskRegistry ->
  IORef Bool ->
  IORef [SeenEvent] ->
  AgentEventSink (Eff es)
lateFeedbackSink tasks injected events event = do
  when (case event of AgentFinalStreamText _ -> True; _ -> False) $ do
    first <- liftIO $ atomicModifyIORef' injected (\seen -> (True, not seen))
    when first $ do
      _ <- liftIO $ pushToLatest tasks (GroupId 7777) Nothing Nothing (Note "流式期间补充" Nothing NoteSteer)
      pure ()
  eventSink events event

fakeLLM :: (IOE :> es) => IORef Int -> LLMInterpreter es
fakeLLM calls =
  LLMInterpreter
    { liChat = \_ctx _profile _messages _tools mSink -> do
        callNo <- liftIO $ atomicModifyIORef' calls (\n -> (n + 1, n))
        case callNo of
          0 ->
            pure $
              Right $
                ToolCallsResp
                  (object ["role" .= ("assistant" :: Text)])
                  "我先查一下"
                  [ToolCall "call-1" "echo" (object ["value" .= (7 :: Int)])]
          1 -> do
            for_ mSink $ \sink -> do
              sink "第一段"
              sink "第一段\n\n第二段"
            pure (Right (ContentResp "第一段\n\n第二段"))
          _ -> pure (Left "unexpected extra LLM call")
    }

echoTool :: (ToolOutput :> es) => Tool es
echoTool =
  Tool
    { toolName = "echo",
      toolDescription = "echo test input",
      toolSchema = object ["type" .= ("object" :: Text)],
      toolRun = \args -> do
        _ <- queueInlineMedia (InlineMedia "[tool image]:" "data:image/png;base64,AA==")
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
      tdFailuresPrecedeEffects = False
    }

dispatchContext :: AgentContext
dispatchContext =
  AgentContext
    ( mkToolContext
        (TurnIdentity (GroupId 7777) (CanonicalMessageId 7413) (UserId 2001) (UserId 1000) (PrincipalId 2001) Nothing Nothing)
        (TurnCapabilities False True False qqAdvertisedCaps True Map.empty Nothing False)
    )
    Nothing
    Nothing

spec :: Spec
spec = describe "Agent full loop" $ do
  it "yields the frontend immediately after durable task admission" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let startDefinition = echoDefinition {tdRef = ToolRef "task_start", tdParallelism = SequentialOnly}
        startTool = Tool "task_start" "admit background task" (object ["type" .= ("object" :: Text)]) (\_ -> pure (Right (object ["task_id" .= (42 :: Int)])))
        provider =
          LLMInterpreter
            { liChat = \_ _ _ _ _ -> do
                liftIO (modifyIORef' calls (+ 1))
                pure (Right (ToolCallsResp (object []) "" [ToolCall "start" "task_start" (object [])]))
            }
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff
        . runConcurrent
        . runLog "agent-test" logger LogAttention
        . runLLMWith provider
        . runAgent (AgentLimits 4) (const (buildToolCatalog [startDefinition] [startTool]))
        $ agentTurn turn dispatchContext "fake" [MsgUser "long work"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef calls `shouldReturn` 1
    result.reply `shouldSatisfy` maybe False (T.isInfixOf "task#42")

  it "preserves a streamed prefix while returning an explicit interruption" $ do
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let interrupted = LLMInterpreter {liChat = \_ _ _ _ sink -> do
          for_ sink ($ "第一段\n\n第二段")
          pure (Right (InterruptedResp "第一段\n\n第二段没写完" "stream timed out"))}
    result <- withCompactLogger ColorNever Nothing $ \logger ->
      runEff . runConcurrent . runLog "agent-test" logger LogAttention
        . runLLMWith interrupted
        . runAgent (AgentLimits {maxTurns = 4}) (const (buildToolCatalog [] [])) $
          agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    result.sentPrefix `shouldBe` "第一段\n\n"
    result.reply `shouldBe` Just "第一段\n\n第二段没写完"
    result.aborted `shouldBe` Just "LLM stream interrupted: stream timed out"
    readIORef events `shouldReturn` [SeenFinalStream "第一段\n\n"]

  it "runs fake LLM + tool rounds and emits typed output events in memory" $ do
    events <- newIORef []
    calls <- newIORef (0 :: Int)
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith (fakeLLM calls)
          . runAgent (AgentLimits {maxTurns = 4}) (const (buildToolCatalog [echoDefinition] [echoTool]))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn

    result.reply `shouldBe` Just "第一段\n\n第二段"
    result.sentPrefix `shouldBe` "第一段\n\n"
    result.turnsUsed `shouldBe` 2
    result.aborted `shouldBe` Nothing
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
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let counted :: (IOE :> es) => Tool es
        counted =
          Tool
            { toolName = "echo",
              toolDescription = "counted echo test input",
              toolSchema = object ["type" .= ("object" :: Text)],
              toolRun = \args -> do
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
          . runAgent (AgentLimits {maxTurns = 4}) (const (buildToolCatalog [echoDefinition] [counted]))
          $ agentTurn turn childContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef toolCalls `shouldReturn` 0
    result.appended
      `shouldSatisfy` any
        ( \case
            MsgTool _ body -> "工具调用额度已经用满" `T.isInfixOf` body
            _ -> False
        )

  for_ ["task_finish", "request_finish"] $ \returnName ->
    it ("treats " <> T.unpack returnName <> " as a terminal round and suppresses sibling calls") $ do
      events <- newIORef []
      siblingCalls <- newIORef (0 :: Int)
      tasks <- newTaskRegistry
      turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
      let returnDefinition = echoDefinition {tdRef = ToolRef returnName}
          returnTool :: Tool es
          returnTool =
            Tool
              { toolName = returnName,
                toolDescription = "return a typed child result",
                toolSchema = object ["type" .= ("object" :: Text)],
                toolRun = \args -> pure (Right args)
              }
          countedEcho :: (IOE :> es) => Tool es
          countedEcho =
            Tool
              { toolName = "echo",
                toolDescription = "must not run beside a return",
                toolSchema = object ["type" .= ("object" :: Text)],
                toolRun = \args -> do
                  liftIO (modifyIORef' siblingCalls (+ 1))
                  pure (Right args)
              }
          returningLLM =
            LLMInterpreter
              { liChat = \_ _ _ _ _ ->
                  pure . Right $
                    ToolCallsResp
                      (object ["role" .= ("assistant" :: Text)])
                      ""
                      [ ToolCall "return-1" returnName (object ["reply" .= ("typed reply" :: Text)]),
                        ToolCall "echo-1" "echo" (object ["value" .= (7 :: Int)])
                      ]
              }
      result <-
        withCompactLogger ColorNever Nothing $ \logger ->
          runEff
            . runConcurrent
            . runLog "agent-test" logger LogAttention
            . runLLMWith returningLLM
            . runAgent
              (AgentLimits {maxTurns = 4})
              (const (buildToolCatalog [returnDefinition, echoDefinition] [returnTool, countedEcho]))
            $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
      _ <- finishTurnRuntime tasks turn
      readIORef siblingCalls `shouldReturn` 0
      result.turnsUsed `shouldBe` 1
      result.aborted `shouldBe` Nothing
      when (returnName == "request_finish") (result.reply `shouldBe` Just "typed reply")
      result.appended
        `shouldSatisfy` any
          ( \case
              MsgTool "echo-1" body -> "同一轮的其他工具调用已拒绝" `T.isInfixOf` body
              _ -> False
          )

  it "serializes a tool-call round when any declared effect is unsafe to parallelize" $ do
    order <- newIORef ([] :: [Text])
    calls <- newIORef (0 :: Int)
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    let recordedTool name =
          Tool
            { toolName = name,
              toolDescription = "record execution order",
              toolSchema = object ["type" .= ("object" :: Text)],
              toolRun = \_ -> do
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
              tdFailuresPrecedeEffects = False
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
          . runAgent
            (AgentLimits {maxTurns = 4})
            (const (buildToolCatalog [readDef, writeDef] [recordedTool "read", recordedTool "write"]))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn
    readIORef order
      `shouldReturn` ["start:read", "end:read", "start:write", "end:write"]

  it "drains feedback through the explicit runtime before the next LLM node" $ do
    seenMessages <- newIORef ([] :: [[ChatMessage]])
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    _ <- pushToLatest tasks (GroupId 7777) Nothing Nothing (Note "改成方案 B" Nothing NoteSteer)
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
          . runAgent (AgentLimits {maxTurns = 2}) (const (buildToolCatalog [] []))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    completion <- finishTurnRuntime tasks turn

    map show result.appended `shouldBe` map show [MsgUser "[feedback]: 改成方案 B", MsgAssistant "done"]
    map (map show) <$> readIORef seenMessages
      `shouldReturn` [map show [MsgUser "question", MsgUser "[feedback]: 改成方案 B"]]
    length completion.tcUnservedNotes `shouldBe` 0
    (null <$> listTasks tasks (Just (GroupId 7777))) `shouldReturn` True

  it "labels an ambient line by where it came from, not by what it means" $ do
    -- Both verbs reach the model at the same place; only the label differs,
    -- and it reports provenance.  One tag for both would tell the model to act
    -- on 「顺便说一句」, and the model would be right to, because that is what
    -- [feedback] means — nothing upstream classifies these any more, so the
    -- label must not claim a reading nobody made.
    seenMessages <- newIORef ([] :: [[ChatMessage]])
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
    _ <- pushToLatest tasks (GroupId 7777) Nothing Nothing (Note "改成方案 B" Nothing NoteSteer)
    _ <- pushToLatest tasks (GroupId 7777) Nothing Nothing (Note "顺便说一句我明天休假" Nothing NoteAmbient)
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
          . runAgent (AgentLimits {maxTurns = 2}) (const (buildToolCatalog [] []))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (eventSink events)
    _ <- finishTurnRuntime tasks turn

    -- One message, two labelled lines, steer first: they arrived together and
    -- splitting them into two turns would double the round the notes were
    -- meant to ride along with.
    map show result.appended
      `shouldBe` map
        show
        [ MsgUser "[feedback]: 改成方案 B\n[群里新消息]（你开始做事之后进来的）: 顺便说一句我明天休假",
          MsgAssistant "done"
        ]

  it "propagates !kill as asynchronous cancellation and still permits root cleanup" $ do
    entered <- newEmptyMVar
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
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
              . runAgent (AgentLimits {maxTurns = 2}) (const (buildToolCatalog [] []))
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

  it "requeues feedback that races a streamed final paragraph for root redispatch" $ do
    events <- newIORef []
    tasks <- newTaskRegistry
    turn <- beginTurnRuntime tasks (GroupId 7777) (UserId 2001) (Just (CanonicalMessageId 7413))
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
          . runAgent (AgentLimits {maxTurns = 2}) (const (buildToolCatalog [] []))
          $ agentTurn turn dispatchContext "fake" [MsgUser "question"] (lateFeedbackSink tasks injected events)
    completion <- finishTurnRuntime tasks turn

    result.sentPrefix `shouldBe` "第一段\n\n"
    map (.noteLine) completion.tcUnservedNotes `shouldBe` ["流式期间补充"]
    (null <$> listTasks tasks (Just (GroupId 7777))) `shouldReturn` True
