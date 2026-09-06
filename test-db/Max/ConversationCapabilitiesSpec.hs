module Max.ConversationCapabilitiesSpec (spec) where

import Control.Monad (forM_, void)
import Data.Aeson (Value (Object, String))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful.PostgreSQL (execute)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.TaskSpec (seed)
import Max.Effects.ConversationQuery qualified as Query
import Max.Effects.TurnQuery qualified as Turn
import Max.History.Types (HistoryItem (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "scoped conversation capabilities" $ do
  let scope = conversationScopeFor (GroupId 900)
  it "enriches only scoped message rows with canonical media handles" $ do
    identifier <- insertRawMessage pool 1 900 1 99 testTime Nothing "[video]"
    void $ withDb pool (execute "INSERT INTO videos(sha256,mime_type,bytes_size,local_path,description) VALUES('query-video','video/mp4',3,'unused','scoped description')" ())
    void $ withDb pool (execute "INSERT INTO message_videos(canonical_message_id,sha256,seg_index) VALUES(?,'query-video',0)" [identifier])
    Just message <- withDb pool (Query.runConversationQuery scope (Query.readMessage identifier))
    message.renderedText `shouldSatisfy` T.isInfixOf ("[video#" <> T.pack (show identifier) <> ".0: scoped description]")
    elsewhere <- withDb pool (Query.runConversationQuery (conversationScopeFor (GroupId 901)) (Query.readMessage identifier))
    elsewhere `shouldSatisfy` isNothing

  it "bounds forward expansion and retains canonical ordering and ownership" $ do
    parent <- insertRawMessage pool 1 900 1 99 testTime Nothing "[forward]"
    forM_ [1 .. 105 :: Int64] $ \index -> do
      child <- insertRawMessage pool (index + 1) 900 1 99 testTime Nothing (T.pack (show index))
      void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position) VALUES(?,'contained_in',?,?)" (child, parent, index))
    page <- withDb pool (Query.runConversationQuery scope (Query.readForward parent 1000))
    map (.renderedText) page `shouldBe` map (T.pack . show) [1 .. 100 :: Int]
    elsewhere <- withDb pool (Query.runConversationQuery (conversationScopeFor (GroupId 901)) (Query.readForward parent 1000))
    elsewhere `shouldSatisfy` null

  it "keeps turn trace reads behind the bound conversation and clear watermark" $ do
    (turn, _, _) <- seed pool 900 1
    let readTrace = Turn.expandTurnTrace turn.atrTurnOrdinal Nothing 10
    visible <- withDbLog pool (Turn.runTurnQuery scope Nothing readTrace)
    visible `shouldSatisfy` isJust
    visible `shouldSatisfy` (\case Just (Object fields) -> KeyMap.lookup "handle" fields == Just (String "t#1"); _ -> False)
    outside <- withDbLog pool (Turn.runTurnQuery (conversationScopeFor (GroupId 901)) Nothing readTrace)
    outside `shouldBe` Nothing
    cleared <- getCurrentTime
    withDbLog pool (Turn.runTurnQuery scope (Just cleared) readTrace) `shouldReturn` Nothing
