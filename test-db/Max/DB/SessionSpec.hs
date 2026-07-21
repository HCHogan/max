module Max.DB.SessionSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.Session (fetchOrInit, upsertSession)
import Max.Session (Session (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

testGroup :: GroupId
testGroup = GroupId 42

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 5) (secondsToDiffTime 0)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.Session" $ do
    describe "fetchOrInit" $ do
      it "creates a fresh row when nothing exists" $ do
        s <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        s.model `shouldBe` "deepseek-flash"
        s.persona `shouldBe` Nothing
        s.pinned `shouldBe` []
        s.btwNotes `shouldBe` []
        s.thinkingOverride `shouldBe` Nothing

      it "is idempotent — second call returns the same row" $ do
        s1 <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        s2 <- withDb pool $ fetchOrInit testGroup "ignored-on-second-call"
        s2.model `shouldBe` s1.model

    describe "upsertSession round-trip" $ do
      it "writes and reads back every persisted field" $ do
        s0 <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        let modified =
              s0
                { persona = Just "猫娘",
                  pinned = [101, 102, 103],
                  btwNotes = ["a", "b"],
                  clearedAt = Just t0,
                  thinkingOverride = Just True,
                  model = "deepseek-pro"
                }
        withDb pool $ upsertSession modified
        s <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        s.persona `shouldBe` Just "猫娘"
        s.pinned `shouldBe` [101, 102, 103]
        s.btwNotes `shouldBe` ["a", "b"]
        s.clearedAt `shouldBe` Just t0
        s.thinkingOverride `shouldBe` Just True
        s.model `shouldBe` "deepseek-pro"

      it "ON CONFLICT updates the existing row instead of inserting" $ do
        s0 <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        withDb pool $ upsertSession (s0 {persona = Just "first"})
        withDb pool $ upsertSession (s0 {persona = Just "second"})
        s <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        s.persona `shouldBe` Just "second"
