module Max.DB.SessionSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.Session
  ( branchExists,
    deleteBranch,
    fetchActiveOrInit,
    fetchBranch,
    getActiveBranch,
    listBranches,
    switchActiveBranch,
    upsertSession,
  )
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
    describe "fetchActiveOrInit" $ do
      it "creates a main branch + active pointer when nothing exists" $ do
        s <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        s.branch `shouldBe` "main"
        s.model `shouldBe` "deepseek-flash"
        s.persona `shouldBe` Nothing
        s.pinned `shouldBe` []
        s.btwNotes `shouldBe` []
        s.thinkingOverride `shouldBe` Nothing
        -- The pointer row should now exist
        ma <- withDb pool $ getActiveBranch testGroup
        ma `shouldBe` Just "main"

      it "is idempotent — second call returns the same row" $ do
        s1 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        s2 <- withDb pool $ fetchActiveOrInit testGroup "ignored-on-second-call"
        s2.branch `shouldBe` s1.branch
        s2.model `shouldBe` s1.model

    describe "upsertSession round-trip" $ do
      it "writes and reads back every persisted field" $ do
        s0 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
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
        mSession <- withDb pool $ fetchBranch testGroup "main" "deepseek-flash"
        case mSession of
          Nothing -> expectationFailure "expected branch to round-trip"
          Just s -> do
            s.persona `shouldBe` Just "猫娘"
            s.pinned `shouldBe` [101, 102, 103]
            s.btwNotes `shouldBe` ["a", "b"]
            s.clearedAt `shouldBe` Just t0
            s.thinkingOverride `shouldBe` Just True
            s.model `shouldBe` "deepseek-pro"

      it "ON CONFLICT updates existing row instead of inserting" $ do
        _ <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        let mk persona' =
              Session
                { groupId = testGroup,
                  branch = "main",
                  model = "deepseek-flash",
                  persona = Just persona',
                  btwNotes = [],
                  clearedAt = Nothing,
                  pinned = [],
                  thinkingOverride = Nothing
                }
        withDb pool $ upsertSession (mk "first")
        withDb pool $ upsertSession (mk "second")
        branches <- withDb pool $ listBranches testGroup
        branches `shouldBe` ["main"]
        s <- withDb pool $ fetchBranch testGroup "main" "deepseek-flash"
        (s >>= persona) `shouldBe` Just "second"

    describe "branchExists / fetchBranch" $ do
      it "returns False / Nothing for an unknown branch" $ do
        _ <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        e <- withDb pool $ branchExists testGroup "ghost"
        e `shouldBe` False
        m <- withDb pool $ fetchBranch testGroup "ghost" "deepseek-flash"
        case m of
          Nothing -> pure ()
          Just _ -> expectationFailure "expected Nothing for unknown branch"

      it "returns True after a branch row is inserted" $ do
        s0 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ upsertSession (s0 {branch = "feat-x"})
        e <- withDb pool $ branchExists testGroup "feat-x"
        e `shouldBe` True

    describe "listBranches" $ do
      it "is empty for an unknown group" $ do
        bs <- withDb pool $ listBranches (GroupId 999)
        bs `shouldBe` []

      it "returns all branches in alphabetical order" $ do
        s0 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ upsertSession (s0 {branch = "zebra"})
        withDb pool $ upsertSession (s0 {branch = "alpha"})
        withDb pool $ upsertSession (s0 {branch = "mango"})
        bs <- withDb pool $ listBranches testGroup
        bs `shouldBe` ["alpha", "main", "mango", "zebra"]

    describe "switchActiveBranch" $ do
      it "flips the pointer to a different branch" $ do
        s0 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ upsertSession (s0 {branch = "feat-x"})
        withDb pool $ switchActiveBranch testGroup "feat-x"
        ma <- withDb pool $ getActiveBranch testGroup
        ma `shouldBe` Just "feat-x"

      it "can switch to a branch that doesn't have a row yet (caller's responsibility to also upsert)" $ do
        -- Documenting current behaviour: switchActiveBranch is a thin
        -- DB write, it doesn't validate the branch exists.  The
        -- higher-level Max.Session.switchToBranch is what enforces
        -- "must exist".
        _ <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ switchActiveBranch testGroup "phantom"
        ma <- withDb pool $ getActiveBranch testGroup
        ma `shouldBe` Just "phantom"

    describe "deleteBranch" $ do
      it "removes a branch row" $ do
        s0 <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ upsertSession (s0 {branch = "scratch"})
        withDb pool $ deleteBranch testGroup "scratch"
        e <- withDb pool $ branchExists testGroup "scratch"
        e `shouldBe` False
        -- main still around
        eMain <- withDb pool $ branchExists testGroup "main"
        eMain `shouldBe` True

      it "is a no-op for an unknown branch" $ do
        _ <- withDb pool $ fetchActiveOrInit testGroup "deepseek-flash"
        withDb pool $ deleteBranch testGroup "never-existed"
        bs <- withDb pool $ listBranches testGroup
        bs `shouldBe` ["main"]
