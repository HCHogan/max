module Max.HistorianSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, minutesToTimeZone)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (IOE, liftIO, runEff)
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertRawMessage, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.ConversationCursor (historianCursor, loadCursor)
import Max.DB.History (MessageCursor (..))
import Max.Effects.LLM
  ( ChatCtx (..),
    ChatMessage (..),
    ChatResponse (..),
    LLMInterpreter (..),
    runLLMWith,
  )
import Max.EpisodeStore
import Max.Historian
  ( CaptureProcessResult (..),
    historianPromptVersion,
    historianSchemaVersion,
    processCaptureLease,
  )
import Max.Tasks (newTaskRegistry)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Historian v2 worker core" $ do
  it "persists the raw structured response and atomically publishes its capture" $ do
    insertRawMessage pool 1001 groupId member botId testTime (Just "Alice") "Alice likes green tea"
    insertRawMessage pool 1002 groupId botId botId testTime Nothing "Max acknowledges"
    end <- latestCursor pool
    let scope = conversationScopeFor (GroupId groupId)
        request =
          CaptureRequest
            { requestReason = CaptureIdle,
              requestHistorianProfile = "historian-test",
              requestPromptVersion = historianPromptVersion,
              requestSchemaVersion = historianSchemaVersion
            }
    _ <- withDb pool $ enqueueCaptureRun scope (MessageCursor 0) end request
    lease <- withDb pool (claimCaptureRun "test-worker" 600) >>= requireJust "capture lease"
    tasks <- newTaskRegistry

    result <-
      runEff
        . runWithConnectionPool pool
        . runLLMWith (fakeHistorian rawCapture)
        $ processCaptureLease 16_000 600 (minutesToTimeZone 480) tasks lease
    result `shouldSatisfy` \case CapturePublished _ -> True; _ -> False

    rows <-
      withDb pool $
        query
          "SELECT status, raw_output, parsed_output->>'episode_kind' FROM episode_capture_runs"
          ()
    (rows :: [(Text, Maybe Text, Maybe Text)])
      `shouldBe` [("published", Just rawCapture, Just "max_interaction")]
    withDb pool (loadCursor scope historianCursor) `shouldReturn` end
    compartments <- withDb pool $ query "SELECT summary_p1, summary_p3 FROM conversation_compartments WHERE state = 'active'" ()
    (compartments :: [(Text, Text)])
      `shouldBe` [("Alice said she likes green tea; Max acknowledged it.", "Alice's green-tea preference was acknowledged.")]

fakeHistorian :: Text -> LLMInterpreter '[WithConnection, IOE]
fakeHistorian raw =
  LLMInterpreter
    { liChat = \ctx profile messages tools sink -> do
        liftIO $ do
          ctx.ccSource `shouldBe` "historian"
          ctx.ccGroup `shouldBe` Just groupId
          ctx.ccTimeoutSeconds `shouldBe` Just 600
          ctx.ccBufferedRetryDelaysSeconds `shouldBe` Just []
          profile `shouldBe` "historian-test"
          tools `shouldSatisfy` null
          case sink of
            Nothing -> pure ()
            Just _ -> expectationFailure "historian unexpectedly used streaming"
          messages `shouldSatisfy` \case
            [MsgSystem _, MsgUser input] ->
              all (`T.isInfixOf` input) ["user_id=2001", "message_id=1001", "message_id=1002"]
            _ -> False
        pure (Right (ContentResp raw))
    }

latestCursor :: DbPool -> IO MessageCursor
latestCursor pool = do
  rows <- withDb pool $ query "SELECT max(ingest_seq) FROM messages WHERE group_id = ?" (Only groupId)
  case rows :: [Only (Maybe Int64)] of
    Only (Just cursor) : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "expected a latest cursor" >> pure (MessageCursor 0)

requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)

rawCapture :: Text
rawCapture =
  "{\"summary_p1\":{\"text\":\"Alice said she likes green tea; Max acknowledged it.\",\"evidence_message_ids\":[1001,1002]},\"summary_p2\":{\"text\":\"Alice likes green tea.\",\"evidence_message_ids\":[1001]},\"summary_p3\":{\"text\":\"Alice's green-tea preference was acknowledged.\",\"evidence_message_ids\":[1001,1002]},\"importance\":0.7,\"confidence\":0.95,\"episode_kind\":\"max_interaction\",\"memory_proposals\":[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":2001,\"content\":\"Alice likes green tea.\",\"category\":\"preference\",\"evidence_message_ids\":[1001]}]}"

groupId, member, botId :: Int64
groupId = 100
member = 2001
botId = 1000

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
