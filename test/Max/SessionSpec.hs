module Max.SessionSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Session
  ( Session (..),
    clearAll,
    clearHistory,
    unclear,
  )
import OneBot.Types (GroupId (..))
import Test.Hspec

-- | A canonical fresh Session for tests.  Holds the defaults you'd
-- get from 'fetchOrInit' on a never-seen group.
emptySession :: Session
emptySession =
  Session
    { groupId = GroupId 1001,
      model = "deepseek-flash",
      persona = Nothing,
      clearedAt = Nothing,
      debugOverride = Nothing,
      stickerOverride = Nothing,
      proactiveOverride = Nothing,
      effortOverride = Nothing
    }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 5) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "clear / unclear watermark" $ do
    it "clearHistory sets the watermark, leaves model/persona alone" $ do
      let s = clearHistory t0 (emptySession {persona = Just "x", model = "m2"})
      clearedAt s `shouldBe` Just t0
      persona s `shouldBe` Just "x"
      model s `shouldBe` "m2"
    it "clearAll wipes ephemera AND sets watermark" $ do
      let dirty =
            emptySession
              { persona = Just "x",
                model = "m2"
              }
          s = clearAll t0 dirty
      persona s `shouldBe` Nothing
      clearedAt s `shouldBe` Just t0
      model s `shouldBe` "m2" -- model survives
    it "unclear removes the watermark" $ do
      let s = unclear (emptySession {clearedAt = Just t0})
      clearedAt s `shouldBe` Nothing
