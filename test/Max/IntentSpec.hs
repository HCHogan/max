module Max.IntentSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Intent
  ( IntentConfig (..),
    IntentVerdict (..),
    Throttle (..),
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
    it "parses a plain JSON verdict" $
      parseVerdict "{\"trigger\": true, \"reason\": \"有人叫Max\"}"
        `shouldBe` Just (IntentVerdict True (Just "有人叫Max"))

    it "parses trigger=false without a reason" $
      parseVerdict "{\"trigger\": false}"
        `shouldBe` Just (IntentVerdict False Nothing)

    it "tolerates markdown fences around the object" $
      parseVerdict "```json\n{\"trigger\": true, \"reason\": \"话题延续\"}\n```"
        `shouldBe` Just (IntentVerdict True (Just "话题延续"))

    it "tolerates prose around the object" $
      parseVerdict "好的，我的判断是：{\"trigger\": false, \"reason\": \"闲聊\"} 以上。"
        `shouldBe` Just (IntentVerdict False (Just "闲聊"))

    it "rejects text without any JSON object" $ do
      parseVerdict "true" `shouldBe` Nothing
      parseVerdict "" `shouldBe` Nothing

    it "rejects an object missing the trigger field" $
      parseVerdict "{\"reason\": \"x\"}" `shouldBe` Nothing

  describe "throttleAllows" $ do
    it "allows a group with no history" $
      throttleAllows cfg (at 0) Nothing `shouldBe` True

    it "blocks inside the cooldown window" $
      throttleAllows cfg (at 100) (Just (Throttle (at 0) [at 0]))
        `shouldBe` False

    it "allows once the cooldown has passed" $
      throttleAllows cfg (at 121) (Just (Throttle (at 0) [at 0]))
        `shouldBe` True

    it "blocks when the hourly cap is reached" $ do
      let recent = [at (fromIntegral (i * 130)) | i <- [0 .. 9 :: Int]]
      throttleAllows cfg (at 2000) (Just (Throttle (at 1170) recent))
        `shouldBe` False

    it "forgets triggers older than an hour" $ do
      let recent = [at (fromIntegral (i * 130)) | i <- [0 .. 9 :: Int]]
      -- 3800s later every recorded trigger is out of the window.
      throttleAllows cfg (at 5000) (Just (Throttle (at 1170) recent))
        `shouldBe` True
