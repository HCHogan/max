module Max.IntentSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Intent
  ( IntentConfig (..),
    IntentKind (..),
    IntentVerdict (..),
    Throttle (..),
    parseSupplement,
    parseVerdict,
    throttleAllows,
  )
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
