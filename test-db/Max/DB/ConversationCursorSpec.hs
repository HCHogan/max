module Max.DB.ConversationCursorSpec (spec) where

import Control.Monad (forM_)
import Data.Int (Int64)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple (Only (..), execute)
import Helpers (insertRawKind, insertRawMessage, truncateAll, withDb)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.ConversationCursor
  ( advanceCursor,
    historianCursor,
    loadCursor,
  )
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    fetchOldestPageAfter,
    hasMessagesAfter,
    pageEndCursor,
  )
import OneBot.Types (GroupId (..))
import Test.Hspec

groupA, groupB, member, botId :: Int64
groupA = 100
groupB = 200
member = 2001
botId = 1000

timeAt :: Int64 -> UTCTime
timeAt second =
  UTCTime
    (fromGregorian 2026 8 2)
    (secondsToDiffTime (fromIntegral second))

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ do
  describe "oldest-first message ledger pagination" $ do
    it "drains a 250-message backlog without gaps, duplicates, or a newest-N jump" $ do
      -- Reverse event timestamps prove pagination follows DB ingestion, not a
      -- non-unique/provider-controlled timestamp.
      forM_ [1 .. 250] $ \i ->
        insertRawMessage
          pool
          (10_000 + i)
          groupA
          member
          botId
          (timeAt (251 - i))
          Nothing
          "message"

      pages <- drainPages pool (scopeFor groupA) (MessageCursor 0) 120
      map length pages `shouldBe` [120, 120, 10]
      map (.messageId) (concatMap (map (.history)) pages)
        `shouldBe` [10_001 .. 10_250]

    it "pages the raw ledger before applying transcript eligibility" $ do
      insertRawMessage pool 1001 groupA member botId (timeAt 1) Nothing "chat"
      insertRawKind pool "command" 1002 groupA member botId (timeAt 2) Nothing "!admin"
      insertRawMessage pool 1003 groupA botId botId (timeAt 3) Nothing "[silence]"
      withConn pool $ \conn -> do
        _ <- execute conn "UPDATE messages SET is_synthetic = true WHERE message_id = ?" (Only (1003 :: Int64))
        pure ()

      page <- withDb pool $ fetchOldestPageAfter (scopeFor groupA) (MessageCursor 0) 10
      map ((.messageId) . (.history)) page.items `shouldBe` [1001, 1002, 1003]
      map (.transcriptEligible) page.items `shouldBe` [True, False, True]

    it "never returns another conversation even when global sequences interleave" $ do
      insertRawMessage pool 1001 groupA member botId (timeAt 1) Nothing "a1"
      insertRawMessage pool 2001 groupB member botId (timeAt 2) Nothing "b1"
      insertRawMessage pool 1002 groupA member botId (timeAt 3) Nothing "a2"

      page <- withDb pool $ fetchOldestPageAfter (scopeFor groupA) (MessageCursor 0) 10
      map ((.messageId) . (.history)) page.items `shouldBe` [1001, 1002]

  describe "durable conversation cursor" $ do
    it "replays the identical page until successful publication advances it" $ do
      insertRawMessage pool 1001 groupA member botId (timeAt 1) Nothing "a"
      insertRawMessage pool 1002 groupA member botId (timeAt 2) Nothing "b"
      let scope = scopeFor groupA

      first <- withDb pool $ fetchOldestPageAfter scope (MessageCursor 0) 10
      replay <- withDb pool $ fetchOldestPageAfter scope (MessageCursor 0) 10
      map (.cursor) first.items `shouldBe` map (.cursor) replay.items
      map ((.messageId) . (.history)) first.items
        `shouldBe` map ((.messageId) . (.history)) replay.items

      withDb pool (loadCursor scope historianCursor)
        `shouldReturn` MessageCursor 0

    it "uses CAS so stale or backward writers cannot overwrite progress" $ do
      insertRawMessage pool 1001 groupA member botId (timeAt 1) Nothing "a"
      insertRawMessage pool 1002 groupA member botId (timeAt 2) Nothing "b"
      let scope = scopeFor groupA
      initial <- withDb pool $ loadCursor scope historianCursor
      page <- withDb pool $ fetchOldestPageAfter scope initial 10
      end <- requireEnd page

      withDb pool (advanceCursor scope historianCursor initial end)
        `shouldReturn` True
      withDb pool (advanceCursor scope historianCursor initial end)
        `shouldReturn` False
      withDb pool (advanceCursor scope historianCursor end initial)
        `shouldReturn` False
      withDb pool (loadCursor scope historianCursor)
        `shouldReturn` end

    it "persists independently per conversation and reports pending rows" $ do
      insertRawMessage pool 1001 groupA member botId (timeAt 1) Nothing "a"
      let scopeA = scopeFor groupA
          scopeB = scopeFor groupB
      startA <- withDb pool $ loadCursor scopeA historianCursor
      endA <- withDb pool (fetchOldestPageAfter scopeA startA 10) >>= requireEnd
      withDb pool (advanceCursor scopeA historianCursor startA endA)
        `shouldReturn` True

      withDb pool (hasMessagesAfter scopeA endA) `shouldReturn` False
      withDb pool (loadCursor scopeB historianCursor)
        `shouldReturn` MessageCursor 0

scopeFor :: Int64 -> ConversationScope
scopeFor = conversationScopeFor . GroupId

drainPages :: DbPool -> ConversationScope -> MessageCursor -> Int -> IO [[LedgerItem]]
drainPages pool scope cursor pageSize = do
  page <- withDb pool $ fetchOldestPageAfter scope cursor pageSize
  case (page.hasMore, pageEndCursor page) of
    (True, Just end) -> (page.items :) <$> drainPages pool scope end pageSize
    _ -> pure [page.items]

requireEnd :: HistoryPage -> IO MessageCursor
requireEnd page = case pageEndCursor page of
  Just cursor -> pure cursor
  Nothing -> expectationFailure "expected a non-empty history page" >> pure (MessageCursor 0)
