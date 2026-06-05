module Max.SessionSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.Session
  ( Session (..),
    addPin,
    appendBtwNote,
    clearAll,
    clearHistory,
    clearThinkingOverride,
    drainBtwNotes,
    isValidBranchName,
    removeAllPins,
    removePin,
    setThinkingOverride,
    unclear,
  )
import OneBot.Types (GroupId (..))
import Test.Hspec

-- | A canonical "fresh main branch" Session for tests.  Holds the
-- defaults you'd get from 'fetchActiveOrInit' on a never-seen group.
emptySession :: Session
emptySession =
  Session
    { groupId = GroupId 1001,
      branch = "main",
      model = "deepseek-flash",
      persona = Nothing,
      btwNotes = [],
      clearedAt = Nothing,
      pinned = [],
      thinkingOverride = Nothing
    }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 5) (secondsToDiffTime 0)

spec :: Spec
spec = do
  describe "isValidBranchName" $ do
    it "accepts simple names" $ do
      isValidBranchName "main" `shouldBe` True
      isValidBranchName "feat-x" `shouldBe` True
      isValidBranchName "v1.0_alpha" `shouldBe` True
    it "rejects empty" $ isValidBranchName "" `shouldBe` False
    it "rejects whitespace" $ do
      isValidBranchName "has space" `shouldBe` False
      isValidBranchName "tab\there" `shouldBe` False
    it "rejects shell-flavoured chars" $ do
      isValidBranchName "foo/bar" `shouldBe` False
      isValidBranchName "foo;bar" `shouldBe` False
      isValidBranchName "foo*bar" `shouldBe` False
    it "rejects leading dot" $ isValidBranchName ".hidden" `shouldBe` False
    it "rejects > 64 chars" $
      isValidBranchName (mconcat (replicate 13 "abcde")) `shouldBe` False
    it "accepts exactly 64 chars" $
      isValidBranchName (mconcat (replicate 16 "abcd")) `shouldBe` True

  describe "btw note helpers" $ do
    it "append accumulates in order" $ do
      let s = appendBtwNote "b" (appendBtwNote "a" emptySession)
      btwNotes s `shouldBe` ["a", "b"]
    it "drain returns notes and empties" $ do
      let withNotes = emptySession {btwNotes = ["x", "y"]}
          (drained, afterDrain) = drainBtwNotes withNotes
      drained `shouldBe` ["x", "y"]
      btwNotes afterDrain `shouldBe` []

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
              { btwNotes = ["a"],
                persona = Just "x",
                pinned = [1, 2],
                model = "m2"
              }
          s = clearAll t0 dirty
      btwNotes s `shouldBe` []
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
