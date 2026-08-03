module Max.ConversationScopeSpec (spec) where

import Max.ConversationScope
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec = describe "conversation recall authority" $ do
  it "keeps ordinary recall inside the current conversation" $ do
    let scope = conversationScopeFor (GroupId 123)
        policy = currentConversationRecall scope
    recallTurnScope policy `shouldBe` scope
    recallConversationScope policy `shouldBe` scope

  it "represents only the explicit group-to-DM projection direction" $ do
    let group = conversationScopeFor (GroupId 123)
        direct = conversationScopeFor (GroupId (-456))
    case authorizeGroupToDirectRecall group direct of
      Nothing -> expectationFailure "valid group-to-DM projection was rejected"
      Just grant -> do
        let policy = groupToDirectRecall grant
        recallTurnScope policy `shouldBe` direct
        recallConversationScope policy `shouldBe` group
    authorizeGroupToDirectRecall direct group `shouldBe` Nothing
    authorizeGroupToDirectRecall group group `shouldBe` Nothing
