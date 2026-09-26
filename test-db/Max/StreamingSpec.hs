module Max.StreamingSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Concurrent.STM qualified as STM
import Control.Monad (void)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent.Async (link, runConcurrent, wait, withAsync)
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.Agent.Execution
import Max.AgentOutput (AgentOutputContext (..), handleAgentEvent)
import Max.Config (AppConfig (..), loadConfig)
import Max.DB.AgentTurn (startAgentTurn)
import Max.DB.Connection (DbPool)
import Max.Effects.Agent
import Max.Effects.Blob (runBlob)
import Max.Effects.LLM
import Max.Effects.Outbound (runOutbound)
import Max.Effects.Tools (buildToolRegistry)
import Max.Execution.Types (Admission (..))
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.Jobs (newJobs)
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.ModelCatalog (defaultModelName)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Delivery (deliveryWorker, oneBotDeliveryTransport)
import Max.Platform.Delivery.Queue (newDeliveryQueue)
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
        deliveries <- newDeliveryQueue (DeliveryId 0)
        [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only source.unCanonicalMessageId)
        ref <- withDb pool (startAgentTurn (GroupId 900) source (PrincipalId principal))
        turn <- beginTurnRuntime tasks ref (GroupId 900) (UserId 123) (Just source)
        state <- newTVarIO emptySendState
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
            target = ReplyTarget (GroupId 900) [] Nothing False False False False False (Just (turnRuntimeOutputContext turn))
            output = AgentOutputContext target source False state
            agentContext =
              AgentContext
                ( mkToolContext
                    (TurnIdentity (GroupId 900) source (UserId 123) (UserId 9) (PrincipalId principal) Nothing (Just (turnRuntimeOutputContext turn)))
                    ( TurnCapabilities
                        { tcMultimodal = False,
                          tcStickers = False,
                          tcSkills = False,
                          tcOutput = qqAdvertisedCaps,
                          tcMonitorArming = False,
                          tcCatalogGrants = Map.empty,
                          tcEffectCeiling = Nothing,
                          tcBackground = False
                        }
                    )
                )
                Nothing
                Nothing
                Nothing
            admission = ExecutionAdmission (\_ -> pure Admitted) (\_ -> pure True) (\_ _ -> pure Admitted)
            journal = ExecutionJournal (\_ _ _ -> pure ()) (const pure) (\_ _ -> pure ())
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
              . runOutbound tasks jobs deliveries
              . runAgentWith admission journal (ExecutionEvents (\_ _ -> pure []) (const STM.retry) (const (pure True)) (\_ _ -> pure Nothing)) Nothing (AgentLimits 2) (const (buildToolRegistry [] []))
              $ withAsync (deliveryWorker deliveries [transport])
              $ \sender -> do
                link sender
                withAsync (agentTurn turn agentContext (defaultModelName config.llm) [MsgUser "question"] (handleAgentEvent output)) $ \agent -> do
                  liftIO $ atomically (readTQueue received) `shouldReturn` (first, False)
                  liftIO (putMVar finishProvider ())
                  result <- wait agent
                  liftIO $ result.outcome `shouldBe` Answered (AgentReply (first <> tailText) first)
                  let reply = case result.outcome of
                        Answered value -> value
                        _ -> error "streaming fixture did not complete"
                  remainingState <- liftIO (readTVarIO state)
                  publication <- sendAndPersistReply target remainingState (replyRemainder reply)
                  liftIO $ do
                    publication.failure `shouldBe` Nothing
                    atomically (readTQueue received) `shouldReturn` (T.strip tailText, True)
                    readIORef sendCount `shouldReturn` 2
        outcome `shouldBe` Just ()
        void (finishTurnRuntime tasks turn)
