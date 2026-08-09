-- | Regression cover for the argument shape a live model actually sent.
--
-- On 2026-08-10 @gpt-5.6-luna@ asked for a one-shot reminder as
-- @{"at":".","cron":".","in_minutes":1}@ — filling the two unused optional
-- parameters with a placeholder instead of omitting them.  The mutual-exclusion
-- check read three specifiers, rejected the call, and because @set_reminder@
-- writes, the rejection reached the model as outcome-unknown — which the host
-- prompt tells it not to retry.  It re-sent the identical arguments seven times.
module Max.ReminderArgsSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone (..), UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Tools.Reminder
import Test.Hspec

tz :: TimeZone
tz = TimeZone (8 * 60) False "CST"

now :: UTCTime
now = UTCTime (fromGregorian 2026 8 10) (secondsToDiffTime (1 * 3600))

args :: Maybe Int -> Maybe Text -> Maybe Text -> SetArgs
args minutes at cron =
  SetArgs
    { saText = "1分钟到了，起来一下。",
      saInMinutes = dropZero minutes,
      saAt = dropFiller at,
      saCron = dropFiller cron
    }

resolved :: SetArgs -> Either Text (Maybe Text)
resolved setArgs = fst <$> resolveWhen tz setArgs now

spec :: Spec
spec = do
  describe "placeholder arguments" $ do
    it "accepts the exact call that looped in production" $
      resolved (args (Just 1) (Just ".") (Just ".")) `shouldBe` Right Nothing

    it "reads the usual placeholder vocabulary as absence" $
      mapM_
        (\filler -> dropFiller (Just filler) `shouldBe` Nothing)
        ["", " ", ".", "-", "null", "NULL", "none", "N/A", "无"]

    it "reads a zero integer as absence but keeps a negative" $ do
      dropZero (Just 0) `shouldBe` Nothing
      dropZero (Just (-5)) `shouldBe` Just (-5)
      dropZero (Just 3) `shouldBe` Just 3

    it "does not swallow a real value that merely looks short" $ do
      dropFiller (Just "0 9 * * *") `shouldBe` Just "0 9 * * *"
      dropFiller (Just "2026-08-10 20:00") `shouldBe` Just "2026-08-10 20:00"

  describe "specifier selection" $ do
    it "still resolves each specifier on its own" $ do
      resolved (args (Just 5) Nothing Nothing) `shouldBe` Right Nothing
      resolved (args Nothing (Just "2026-08-10 20:00") Nothing) `shouldBe` Right Nothing
      resolved (args Nothing Nothing (Just "0 9 * * *")) `shouldBe` Right (Just "0 9 * * *")

    it "still refuses two genuine specifiers, and says how to fix it" $
      case resolved (args (Just 5) (Just "2026-08-10 20:00") Nothing) of
        -- The remedy has to be in the text: naming the rule alone is what let
        -- the model conclude "change the placeholders" instead of "omit them".
        Left message -> message `shouldSatisfy` T.isInfixOf "省略"
        Right _ -> expectationFailure "two real specifiers were accepted"

    it "still refuses an empty request" $
      resolved (args Nothing Nothing Nothing) `shouldSatisfy` \case
        Left _ -> True
        Right _ -> False

    it "keeps a negative in_minutes on the precise error" $
      resolved (args (Just (-5)) Nothing Nothing)
        `shouldBe` Left "in_minutes 必须是正整数"
