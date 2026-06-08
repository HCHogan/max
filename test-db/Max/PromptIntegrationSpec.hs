-- |
-- End-to-end test for 'Max.Prompt.buildContext' against a real
-- database: insert fixture rows, drive 'buildContext' through the
-- effect stack, then assert on the rendered ChatMessage list.  The
-- pure render path is covered separately in 'Max.PromptSpec'; this
-- module specifically verifies that the DB queries wire up to the
-- renderer correctly (dedup, watermark, pin resolution, reply lookup).
module Max.PromptIntegrationSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Helpers (insertRawMessage, truncateAll, withDb, withDbLog)
import Max.DB.Connection (DbPool)
import Max.DB.Session (fetchActiveOrInit, upsertSession)
import Max.Effects.LLM (ChatMessage (..))
import Max.Prompt (buildContext)
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

groupRaw :: (Integral a) => a
groupRaw = 7777

botRaw :: (Integral a) => a
botRaw = 1000

memberRaw :: (Integral a) => a
memberRaw = 2001

timeAt :: Int -> UTCTime
timeAt h =
  UTCTime
    (fromGregorian 2026 6 5)
    (secondsToDiffTime (fromIntegral (h * 3600)))

trigger :: GroupMessage
trigger =
  GroupMessage
    { selfId = UserId botRaw,
      groupId = GroupId groupRaw,
      userId = UserId memberRaw,
      messageId = MessageId 9000,
      message = [SegAt (UserId botRaw), SegText " 现在几点"],
      rawMessage = "",
      sender = Sender (UserId memberRaw) (Just "Alice") Nothing
    }

userBodyOf :: [ChatMessage] -> Text
userBodyOf msgs = case last msgs of
  MsgUser t -> t
  other -> error $ "expected trailing MsgUser, got: " <> show other

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.Prompt.buildContext (integration)" $ do
    it "renders ambient rows from the messages table" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "随便聊"
      insertRawMessage pool 1002 groupRaw memberRaw botRaw (timeAt 10) (Just "Alice") "另一条"
      s <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, notes) <-
        withDbLog pool $ buildContext "default-persona" 20 False s trigger
      notes `shouldBe` []
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("随便聊" `T.isInfixOf`)
      ub `shouldSatisfy` ("另一条" `T.isInfixOf`)

    it "honours cleared_at watermark — older rows are dropped" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "旧"
      insertRawMessage pool 1002 groupRaw memberRaw botRaw (timeAt 11) (Just "Alice") "新"
      s0 <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      let s = s0 {clearedAt = Just (timeAt 10)}
      withDb pool $ upsertSession s
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 False s trigger
      let ub = userBodyOf msgs
      ub `shouldNotSatisfy` ("旧" `T.isInfixOf`)
      ub `shouldSatisfy` ("新" `T.isInfixOf`)

    it "renders prior @-mention as MsgUser/MsgAssistant turns" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "@1000 你好"
      insertRawMessage pool 1002 groupRaw botRaw botRaw (timeAt 10) Nothing "你好 Alice"
      s <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 False s trigger
      -- Expect: [system, user(mention), assistant(reply), user(current trigger)]
      length msgs `shouldBe` 4
      case msgs of
        [MsgSystem _, MsgUser u, MsgAssistant a, MsgUser _curr] -> do
          u `shouldSatisfy` ("Alice" `T.isInfixOf`)
          a `shouldBe` "你好 Alice"
        other -> expectationFailure $ "unexpected message shape: " <> show other

    it "renders pinned messages in the [pin 上下文] section" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "重要信息"
      s0 <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      let s = s0 {pinned = [1001]}
      withDb pool $ upsertSession s
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 False s trigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[pin 上下文" `T.isInfixOf`)
      ub `shouldSatisfy` ("重要信息" `T.isInfixOf`)

    it "renders reply context when trigger has SegReply" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "被引用的话"
      s <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      let replyTrigger =
            trigger
              { message = [SegReply (MessageId 1001), SegAt (UserId botRaw), SegText " 看这条"]
              }
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 False s replyTrigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[引用上下文]" `T.isInfixOf`)
      ub `shouldSatisfy` ("被引用的话" `T.isInfixOf`)

    it "drains btw notes into the second tuple element" $ do
      s0 <- withDb pool $ fetchActiveOrInit (GroupId groupRaw) "deepseek-flash"
      let s = s0 {btwNotes = ["note-1", "note-2"]}
      withDb pool $ upsertSession s
      (_, notes) <- withDbLog pool $ buildContext "default-persona" 20 False s trigger
      notes `shouldBe` ["note-1", "note-2"]
