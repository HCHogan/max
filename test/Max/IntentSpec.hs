module Max.IntentSpec (spec) where

import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, secondsToDiffTime)
import Max.Intent
  ( IntentConfig (..),
    IntentKind (..),
    IntentRetry (..),
    IntentVerdict (..),
    Throttle (..),
    claimIntentBatchAt,
    enqueueIntent,
    msgSignal,
    newIntentState,
    parseSupplement,
    parseVerdict,
    retryIntentBatchAt,
    throttleAllows,
  )
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (SegText))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

cfg :: IntentConfig
cfg =
  IntentConfig
    { icProfile = "deepseek-flash",
      icCooldownSeconds = 120,
      icMaxPerHour = 10,
      icContextLines = 15
    }

at :: Integer -> UTCTime
at s = UTCTime (fromGregorian 2026 7 21) (secondsToDiffTime s)

spec :: Spec
spec = do
  describe "batch retries" $ do
    it "backs off transient failures and drops the third failed attempt" $ do
      st <- newIntentState
      enqueueIntent st (mkMessage 42 1 "max?")
      now <- getCurrentTime
      Just (gid, attempt0, batch0) <- claimIntentBatchAt st (addUTCTime 1 now)
      map (.messageId) batch0 `shouldBe` [MessageId 1]

      first <- retryIntentBatchAt st gid attempt0 batch0 now
      first `shouldBe` IntentRetryScheduled (addUTCTime 15 now)
      enqueueIntent st (mkMessage 43 2 "other group")
      Just (otherGid, _, _) <- claimIntentBatchAt st (addUTCTime 1 now)
      otherGid `shouldBe` 43
      enqueueIntent st (mkMessage 42 3 "newer")
      beforeRetry <- claimIntentBatchAt st (addUTCTime 14 now)
      beforeRetry `shouldSatisfy` isNothing

      Just (_, attempt1, batch1) <- claimIntentBatchAt st (addUTCTime 15 now)
      map (.messageId) batch1 `shouldBe` [MessageId 1, MessageId 3]
      second <- retryIntentBatchAt st gid attempt1 batch1 now
      second `shouldBe` IntentRetryScheduled (addUTCTime 60 now)

      Just (_, attempt2, batch2) <- claimIntentBatchAt st (addUTCTime 60 now)
      third <- retryIntentBatchAt st gid attempt2 batch2 now
      third `shouldBe` IntentRetryExhausted
      afterExhaustion <- claimIntentBatchAt st (addUTCTime 3600 now)
      afterExhaustion `shouldSatisfy` isNothing

  describe "parseVerdict" $ do
    it "parses a full verdict with kind" $
      parseVerdict "{\"trigger\": true, \"kind\": \"called\", \"reason\": \"有人叫Max\"}"
        `shouldBe` Just (IntentVerdict True KindCalled (Just "有人叫Max"))

    it "parses followup kind" $
      parseVerdict "{\"trigger\": true, \"kind\": \"followup\", \"reason\": \"对话延续\"}"
        `shouldBe` Just (IntentVerdict True KindFollowup (Just "对话延续"))

    it "defaults a missing or unknown kind to topic (most throttled)" $ do
      parseVerdict "{\"trigger\": true, \"reason\": \"x\"}"
        `shouldBe` Just (IntentVerdict True KindTopic (Just "x"))
      parseVerdict "{\"trigger\": true, \"kind\": \"whatever\"}"
        `shouldBe` Just (IntentVerdict True KindTopic Nothing)

    it "parses trigger=false without a reason" $
      parseVerdict "{\"trigger\": false}"
        `shouldBe` Just (IntentVerdict False KindTopic Nothing)

    it "tolerates markdown fences around the object" $
      parseVerdict "```json\n{\"trigger\": true, \"kind\": \"topic\", \"reason\": \"话题\"}\n```"
        `shouldBe` Just (IntentVerdict True KindTopic (Just "话题"))

    it "tolerates prose around the object" $
      parseVerdict "好的，我的判断是：{\"trigger\": false, \"reason\": \"闲聊\"} 以上。"
        `shouldBe` Just (IntentVerdict False KindTopic (Just "闲聊"))

    it "rejects text without any JSON object" $ do
      parseVerdict "true" `shouldBe` Nothing
      parseVerdict "" `shouldBe` Nothing

    it "rejects an object missing the trigger field" $
      parseVerdict "{\"reason\": \"x\"}" `shouldBe` Nothing

  describe "msgSignal (gate)" $ do
    it "hits on the bot's name, any case" $ do
      msgSignal "max帮我看看" `shouldBe` True
      msgSignal "问问 Max 吧" `shouldBe` True
      msgSignal "MAX?" `shouldBe` True

    it "hits even when the name is about something else (classifier decides)" $
      msgSignal "买个 Claude Max 套餐" `shouldBe` True

    it "misses plain chatter" $ do
      msgSignal "今天吃什么" `shouldBe` False
      msgSignal "[image]" `shouldBe` False

  describe "parseSupplement" $ do
    it "parses both verdicts" $ do
      parseSupplement "{\"supplement\": true, \"reason\": \"追加要求\"}"
        `shouldBe` Just True
      parseSupplement "{\"supplement\": false, \"reason\": \"新问题\"}"
        `shouldBe` Just False

    it "tolerates fences and prose around the object" $ do
      parseSupplement "```json\n{\"supplement\": true}\n```" `shouldBe` Just True
      parseSupplement "判断：{\"supplement\": false} 完毕" `shouldBe` Just False

    it "rejects garbage and missing field" $ do
      parseSupplement "true" `shouldBe` Nothing
      parseSupplement "{\"reason\": \"x\"}" `shouldBe` Nothing

  describe "throttleAllows" $ do
    it "allows a group with no history" $
      throttleAllows cfg (at 0) KindTopic Nothing `shouldBe` True

    it "blocks a topic trigger inside the cooldown window" $
      throttleAllows cfg (at 100) KindTopic (Just (Throttle (at 0) [at 0]))
        `shouldBe` False

    it "lets name-calls and follow-ups through the cooldown" $ do
      -- The bot just spoke; someone answers it — going deaf here is
      -- the failure mode the kind split exists to prevent.
      throttleAllows cfg (at 10) KindCalled (Just (Throttle (at 0) [at 0]))
        `shouldBe` True
      throttleAllows cfg (at 10) KindFollowup (Just (Throttle (at 0) [at 0]))
        `shouldBe` True

    it "allows a topic trigger once the cooldown has passed" $
      throttleAllows cfg (at 121) KindTopic (Just (Throttle (at 0) [at 0]))
        `shouldBe` True

    it "the hourly cap blocks every kind" $ do
      let recent = [at (fromIntegral (i * 130)) | i <- [0 .. 9 :: Int]]
          th = Just (Throttle (at 1170) recent)
      throttleAllows cfg (at 2000) KindTopic th `shouldBe` False
      throttleAllows cfg (at 2000) KindCalled th `shouldBe` False
      throttleAllows cfg (at 2000) KindFollowup th `shouldBe` False

    it "forgets triggers older than an hour" $ do
      let recent = [at (fromIntegral (i * 130)) | i <- [0 .. 9 :: Int]]
      throttleAllows cfg (at 5000) KindTopic (Just (Throttle (at 1170) recent))
        `shouldBe` True

mkMessage :: Int -> Int -> Text -> GroupMessage
mkMessage gid mid body =
  GroupMessage
    { selfId = UserId 99,
      groupId = GroupId (fromIntegral gid),
      userId = UserId 7,
      messageId = MessageId (fromIntegral mid),
      message = [SegText body],
      rawMessage = body,
      sender = Sender (UserId 7) (Just "alice") Nothing
    }
