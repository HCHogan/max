module Max.StreamingSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Monad (void)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (link, runConcurrent, wait, withAsync)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertRawMessage, testTime, truncateAll)
import Max.Agent.Execution
import Max.AgentOutput (AgentOutputContext (..), handleAgentEvent)
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.Connection (DbPool)
import Max.Effects.Agent
import Max.Effects.Blob (runBlob)
import Max.Effects.LLM
import Max.Effects.Outbound (runOutbound)
import Max.Effects.Tools (buildToolRegistry)
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.Jobs (newJobs)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.ModelCatalog (defaultModelName)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Delivery (deliveryWorker, oneBotDeliveryTransport)
import Max.Platform.Types
import Max.ReplySend
import Max.Tasks
import Max.ToolContext
import Network.HTTP.Client qualified as HTTP
import OneBot.Action (Action (SendGroupMsg), Response (..))
import OneBot.Segment (renderPlainText)
import OneBot.Types (GroupId (..), UserId (..))
import System.Environment (withArgs)
import System.IO (hClose, hPutStr)
import System.IO.Temp (withSystemTempFile)
import System.Timeout (timeout)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "SSE to QQ publication" $
    it "delivers a plain sentence before provider EOS, then sends the final tail once" $
      withSystemTempFile "stream-config.yaml" $ \path handle -> do
        hPutStr handle "{}\n"
        hClose handle
        config <- withArgs ["--config-file", path, "--llm-api-key", "fixture", "--llm-base-url", "http://provider.test", "--llm-stream", "True"] loadConfig
        source <- CanonicalMessageId <$> insertRawMessage pool 100 900 123 9 testTime Nothing "question"
        received <- newTQueueIO
        finishProvider <- newEmptyMVar
        providerEnded <- newIORef False
        sendCount <- newIORef (0 :: Int)
        tasks <- newTaskRegistry
        jobs <- newJobs tasks
        turn <- beginTurnRuntime tasks (GroupId 900) (UserId 123) (Just source)
        budget <- newTVarIO freshBudget
        let first = "This is a deliberately long first sentence sent while the model is still generating."
            tailText = " The final sentence."
            frame text = "data: " <> LBS.toStrict (encode (object ["choices" .= [object ["delta" .= object ["content" .= (text :: Text)]]]])) <> "\n\n"
            initial = frame (first <> " The")
            final = frame " final sentence." <> "data: [DONE]\n\n"
            responseHead = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: " <> B8.pack (show (BS.length initial + BS.length final)) <> "\r\nConnection: close\r\n\r\n"
            managerSettings =
              HTTP.defaultManagerSettings
                { HTTP.managerRawConnection = pure $ \_ _ _ -> do
                    phase <- newIORef (0 :: Int)
                    HTTP.makeConnection
                      ( atomicModifyIORef' phase (\i -> (i + 1, i)) >>= \case
                          0 -> pure (responseHead <> initial)
                          1 -> takeMVar finishProvider >> writeIORef providerEnded True >> pure final
                          _ -> pure BS.empty
                      )
                      (const (pure ()))
                      (pure ()),
                  HTTP.managerRetryableException = const False
                }
            backend = PlatformBackend "qq" "stream-fixture" (const (pure (Right ()))) $ \action _ -> case action of
              SendGroupMsg (GroupId 900) segments -> do
                ended <- readIORef providerEnded
                index <- atomicModifyIORef' sendCount (\i -> (i + 1, i + 1))
                atomically (writeTQueue received (T.strip (renderPlainText segments), ended))
                pure (Right (Response "ok" 0 (object ["message_id" .= (1000 + index)]) ""))
              other -> expectationFailure ("unexpected QQ action: " <> show other) >> pure (Left "unexpected action")
            target = ReplyTarget (GroupId 900) [] Nothing False False False False False Nothing
            output = AgentOutputContext target source False budget
            agentContext =
              AgentContext
                ( mkToolContext
                    (TurnIdentity (GroupId 900) source (UserId 123) (UserId 9) (PrincipalId 1) Nothing Nothing)
                    (TurnCapabilities False False False qqAdvertisedCaps False Map.empty Nothing False)
                )
                Nothing
                Nothing
            admission = ExecutionAdmission (\_ -> pure True) (\_ -> pure True) (\_ _ _ _ -> pure Nothing)
            journal = ExecutionJournal (\_ _ -> pure ()) (\_ _ -> pure ()) (\_ _ -> pure ()) (\_ -> pure []) (\_ -> pure "") (\_ _ _ _ -> pure ())
        manager <- HTTP.newManager managerSettings
        let runtime = httpRuntimeFromManagers manager manager manager
            transport = oneBotDeliveryTransport runtime PlatformQQ backend
        outcome <- timeout 10_000_000 $
          withCompactLogger ColorNever Nothing $ \logger ->
            runEff
              . runConcurrent
              . runLog "stream-integration" logger LogAttention
              . runWithConnectionPool pool
              . runBlob "var/images"
              . runLLM runtime (\_ _ _ -> pure ()) (\_ -> pure ()) config.llm
              . runOutbound tasks jobs
              . runAgentWith admission journal (ExecutionInbox (const (pure ""))) Nothing (AgentLimits 2) (const (buildToolRegistry [] []))
              $ withAsync (deliveryWorker "stream-fixture" [transport])
              $ \sender -> do
                link sender
                withAsync (agentTurn turn agentContext (defaultModelName config.llm) [MsgUser "question"] (handleAgentEvent output)) $ \agent -> do
                  liftIO $ atomically (readTQueue received) `shouldReturn` (first, False)
                  liftIO (putMVar finishProvider ())
                  result <- wait agent
                  liftIO $ do
                    result.reply `shouldBe` Just (first <> tailText)
                    result.sentPrefix `shouldBe` first
                    result.aborted `shouldBe` Nothing
                  remainingBudget <- liftIO (readTVarIO budget)
                  publication <- sendAndPersistReply target remainingBudget (T.drop (T.length result.sentPrefix) (fromMaybe "" result.reply))
                  liftIO $ do
                    publication.failure `shouldBe` Nothing
                    atomically (readTQueue received) `shouldReturn` (T.strip tailText, True)
                    readIORef sendCount `shouldReturn` 2
        outcome `shouldBe` Just ()
        void (finishTurnRuntime tasks turn)
