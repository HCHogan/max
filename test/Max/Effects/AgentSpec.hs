{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Max.Effects.AgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
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
import Max.Effects.Tools (Tool (..))
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Tasks (newTaskRegistry)
import Max.ToolContext (ToolContext (..), TurnCapabilities (..), TurnIdentity (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
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

dispatchContext :: AgentContext
dispatchContext =
  AgentContext
    ( ToolContext
        (TurnIdentity (GroupId 7777) (MessageId 7413) (UserId 2001) (UserId 1000))
        (TurnCapabilities False True False)
    )
    Nothing

spec :: Spec
spec = describe "Agent full loop" $ do
  it "runs fake LLM + tool rounds and emits typed output events in memory" $ do
    events <- newIORef []
    calls <- newIORef 0
    tasks <- newTaskRegistry
    result <-
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff
          . runConcurrent
          . runLog "agent-test" logger LogAttention
          . runLLMWith (fakeLLM calls)
          . runAgent (AgentLimits {maxTurns = 4}) (const [echoTool]) tasks
          $ agentTurn dispatchContext "fake" [MsgUser "question"] (eventSink events)

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
