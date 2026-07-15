module Max.DB.MessageSpec (spec) where

import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.History (HistoryItem (..), fetchMessage)
import Max.DB.Message (insertGroupMessage, insertOutbound)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

botId :: UserId
botId = UserId 1000

memberA :: UserId
memberA = UserId 2001

testGroup :: GroupId
testGroup = GroupId 42

-- | Minimal viable GroupMessage for insert tests.
mkInbound ::
  MessageId ->
  UserId ->
  [Segment] ->
  GroupMessage
mkInbound mid uid segs =
  GroupMessage
    { selfId = botId,
      groupId = testGroup,
      userId = uid,
      messageId = mid,
      message = segs,
      rawMessage = "",
      sender = Sender uid (Just "Alice") Nothing
    }

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.Message" $ do
    describe "insertGroupMessage" $ do
      it "round-trips a basic message (looked up via fetchMessage)" $ do
        let gm = mkInbound (MessageId 5001) memberA [SegText "hello"]
        withDb pool $ insertGroupMessage gm
        m <- withDb pool $ fetchMessage 5001
        case m of
          Nothing -> expectationFailure "expected message to be readable"
          Just h -> do
            h.messageId `shouldBe` 5001
            h.userId `shouldBe` 2001
            h.renderedText `shouldBe` "hello"
            h.senderNickname `shouldBe` Just "Alice"

      it "is idempotent on message_id (ON CONFLICT DO NOTHING)" $ do
        let gm1 = mkInbound (MessageId 5001) memberA [SegText "first"]
            gm2 = mkInbound (MessageId 5001) memberA [SegText "second-call-different-body"]
        withDb pool $ insertGroupMessage gm1
        withDb pool $ insertGroupMessage gm2
        m <- withDb pool $ fetchMessage 5001
        case m of
          Just h -> h.renderedText `shouldBe` "first" -- first write wins
          Nothing -> expectationFailure "expected message"

    describe "insertOutbound" $ do
      it "records a bot reply with user_id = bot's self_id" $ do
        withDb pool $
          insertOutbound
            testGroup
            botId
            "max"
            (MessageId 5050)
            Nothing
            [SegText "你好"]
        m <- withDb pool $ fetchMessage 5050
        case m of
          Just h -> do
            h.userId `shouldBe` 1000
            h.selfId `shouldBe` 1000
            h.renderedText `shouldBe` "你好"
            h.senderNickname `shouldBe` Just "max"
          Nothing -> expectationFailure "expected outbound message"

      it "is idempotent on message_id too" $ do
        withDb pool $
          insertOutbound testGroup botId "max" (MessageId 5050) Nothing [SegText "one"]
        withDb pool $
          insertOutbound testGroup botId "max" (MessageId 5050) Nothing [SegText "two"]
        m <- withDb pool $ fetchMessage 5050
        (m >>= Just . (.renderedText)) `shouldBe` Just "one"
