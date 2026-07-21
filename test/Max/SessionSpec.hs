module Max.SessionSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Session
  ( Session (..),
    addPin,
    clearAll,
    clearHistory,
    clearThinkingOverride,
    removeAllPins,
    removePin,
    setThinkingOverride,
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
      pinned = [],
      thinkingOverride = Nothing,
      debugOverride = Nothing,
      stickerOverride = Nothing,
      proactiveOverride = Nothing
    }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 5) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "pin helpers" $ do
    it "addPin appends, preserving order" $ do
      let s = addPin 3 (addPin 2 (addPin 1 emptySession))
      pinned s `shouldBe` [1, 2, 3]
    it "addPin dedupes" $ do
      let s = addPin 1 (addPin 2 (addPin 1 emptySession))
      pinned s `shouldBe` [1, 2]
    it "removePin removes the named id, leaves others" $ do
      let s = removePin 2 (emptySession {pinned = [1, 2, 3]})
      pinned s `shouldBe` [1, 3]
    it "removePin on absent id is a no-op" $ do
      let s = removePin 99 (emptySession {pinned = [1, 2, 3]})
      pinned s `shouldBe` [1, 2, 3]
    it "removeAllPins wipes the list" $ do
      let s = removeAllPins (emptySession {pinned = [1, 2, 3]})
      pinned s `shouldBe` []

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
                pinned = [1, 2],
                model = "m2"
              }
          s = clearAll t0 dirty
      persona s `shouldBe` Nothing
      pinned s `shouldBe` []
      clearedAt s `shouldBe` Just t0
      model s `shouldBe` "m2" -- model survives
    it "unclear removes the watermark" $ do
      let s = unclear (emptySession {clearedAt = Just t0})
      clearedAt s `shouldBe` Nothing

  describe "thinking override" $ do
    it "set then read" $ do
      let s = setThinkingOverride True emptySession
      thinkingOverride s `shouldBe` Just True
    it "set overrides existing value" $ do
      let s = setThinkingOverride False (emptySession {thinkingOverride = Just True})
      thinkingOverride s `shouldBe` Just False
    it "clear nulls it out" $ do
      let s = clearThinkingOverride (emptySession {thinkingOverride = Just True})
      thinkingOverride s `shouldBe` Nothing
