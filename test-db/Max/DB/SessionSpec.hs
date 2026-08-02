module Max.DB.SessionSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, bracket_, try)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple (execute_)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Session
  ( SessionRecord (..),
    fetchOrInit,
    fetchRecordOrInit,
    saveSessionCAS,
  )
import Max.Session
  ( Session (..),
    loadSession,
    newSessionRegistry,
    readSession,
    updateSession,
  )
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
        s.debugOverride `shouldBe` Nothing

      it "is idempotent — second call returns the same row" $ do
        s1 <- withDb pool $ fetchOrInit testGroup "deepseek-flash"
        s2 <- withDb pool $ fetchOrInit testGroup "ignored-on-second-call"
        s2.model `shouldBe` s1.model

    describe "saveSessionCAS" $ do
      it "writes every field and increments the revision" $ do
        record0 <- withDb pool $ fetchRecordOrInit testGroup "deepseek-flash"
        let modified =
              record0.session
                { persona = Just "猫娘",
                  pinned = [101, 102, 103],
                  clearedAt = Just t0,
                  debugOverride = Just True,
                  model = "deepseek-pro"
                }
        committed <- withDb pool $ saveSessionCAS record0 modified
        case committed of
          Nothing -> expectationFailure "expected the initial CAS to commit"
          Just record1 -> record1.revision `shouldBe` record0.revision + 1
        reloaded <- withDb pool $ fetchRecordOrInit testGroup "deepseek-flash"
        reloaded.session.persona `shouldBe` Just "猫娘"
        reloaded.session.pinned `shouldBe` [101, 102, 103]
        reloaded.session.clearedAt `shouldBe` Just t0
        reloaded.session.debugOverride `shouldBe` Just True
        reloaded.session.model `shouldBe` "deepseek-pro"

      it "rejects a stale full-row writer without overwriting the winner" $ do
        stale <- withDb pool $ fetchRecordOrInit testGroup "deepseek-flash"
        first <- withDb pool $ saveSessionCAS stale (stale.session {persona = Just "first"})
        first `shouldSatisfy` isJust
        second <- withDb pool $ saveSessionCAS stale (stale.session {pinned = [99]})
        second `shouldSatisfy` isNothing
        reloaded <- withDb pool $ fetchRecordOrInit testGroup "deepseek-flash"
        reloaded.session.persona `shouldBe` Just "first"
        reloaded.session.pinned `shouldBe` []

    describe "Max.Session write-through registry" $ do
      it "serializes concurrent mutations and reloads every committed field" $ do
        registry <- newSessionRegistry
        handle <- withDb pool $ loadSession registry "deepseek-flash" testGroup
        _ <-
          concurrently
            (withDb pool $ updateSession handle (\s -> (s {persona = Just "cat"}, ())))
            (withDb pool $ updateSession handle (\s -> (s {pinned = [41, 42]}, ())))

        cached <- readSession handle
        cached.persona `shouldBe` Just "cat"
        cached.pinned `shouldBe` [41, 42]

        restarted <- newSessionRegistry
        reloadedHandle <- withDb pool $ loadSession restarted "deepseek-flash" testGroup
        reloaded <- readSession reloadedHandle
        reloaded.persona `shouldBe` Just "cat"
        reloaded.pinned `shouldBe` [41, 42]

      it "refreshes and reapplies after another registry wins the CAS" $ do
        registryA <- newSessionRegistry
        registryB <- newSessionRegistry
        handleA <- withDb pool $ loadSession registryA "deepseek-flash" testGroup
        handleB <- withDb pool $ loadSession registryB "deepseek-flash" testGroup

        withDb pool $ updateSession handleA (\s -> (s {persona = Just "winner"}, ()))
        withDb pool $ updateSession handleB (\s -> (s {pinned = [7]}, ()))

        restarted <- newSessionRegistry
        handle <- withDb pool $ loadSession restarted "deepseek-flash" testGroup
        reloaded <- readSession handle
        reloaded.persona `shouldBe` Just "winner"
        reloaded.pinned `shouldBe` [7]

      it "does not publish an in-memory mutation when persistence fails" $ do
        registry <- newSessionRegistry
        handle <- withDb pool $ loadSession registry "deepseek-flash" testGroup
        cachedBefore <- readSession handle
        bracket_
          ( withConn pool $ \conn -> do
              _ <- execute_ conn "ALTER TABLE sessions ADD CONSTRAINT session_test_reject_persona CHECK (persona <> '__reject__')"
              pure ()
          )
          ( withConn pool $ \conn -> do
              _ <- execute_ conn "ALTER TABLE sessions DROP CONSTRAINT session_test_reject_persona"
              pure ()
          )
          ( do
              result <-
                try @SomeException $
                  withDb pool $
                    updateSession handle (\s -> (s {persona = Just "__reject__"}, ()))
              result `shouldSatisfy` isLeft
              cachedAfter <- readSession handle
              cachedAfter.persona `shouldBe` cachedBefore.persona
              cachedAfter.pinned `shouldBe` cachedBefore.pinned

              -- The failing writer released the handle lock; a valid write can
              -- immediately commit and publish.
              withDb pool $
                updateSession handle (\s -> (s {persona = Just "recovered"}, ()))
              recovered <- readSession handle
              recovered.persona `shouldBe` Just "recovered"
          )

isJust :: Maybe a -> Bool
isJust = \case
  Just _ -> True
  Nothing -> False

isNothing :: Maybe a -> Bool
isNothing = not . isJust

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
