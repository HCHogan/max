module Max.DB.HistorySpec (spec) where

import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple (Only (..), execute)
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, insertRawReply, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.History
  ( HistoryItem (..),
    MessageCursor (..),
    fetchForwardChildrenInScope,
    fetchMentionHistory,
    fetchMessageInScope,
    fetchMessagesByIdsInScope,
    fetchRecentInGroup,
    fetchTranscriptAfter,
  )
import OneBot.Types (GroupId (..))
import Test.Hspec

gid :: Integer
gid = 100

groupId :: (Integral a) => a
groupId = fromIntegral gid

botId :: (Integral a) => a
botId = 1000

memberA :: (Integral a) => a
memberA = 2001

memberB :: (Integral a) => a
memberB = 2002

timeAt :: Int -> UTCTime
timeAt h =
  UTCTime
    (fromGregorian 2026 6 5)
    (secondsToDiffTime (fromIntegral (h * 3600)))

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.History" $ do
    let scope = conversationScopeFor (GroupId groupId)
    describe "fetchRecentInGroup" $ do
      it "returns rows chronological (oldest first), respecting LIMIT and excludeId" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "msg-a"
        insertRawMessage pool 1002 groupId memberB botId (timeAt 10) (Just "Bob") "msg-b"
        insertRawMessage pool 1003 groupId memberA botId (timeAt 11) (Just "Alice") "msg-c"
        insertRawMessage pool 1004 groupId memberA botId (timeAt 12) (Just "Alice") "excluded"
        rows <- withDb pool $ fetchRecentInGroup groupId 1004 Nothing 10
        map (.messageId) rows `shouldBe` [1001, 1002, 1003]

      it "applies the LIMIT to the LATEST N (not the earliest)" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "old-1"
        insertRawMessage pool 1002 groupId memberA botId (timeAt 10) Nothing "old-2"
        insertRawMessage pool 1003 groupId memberA botId (timeAt 11) Nothing "new-1"
        insertRawMessage pool 1004 groupId memberA botId (timeAt 12) Nothing "new-2"
        rows <- withDb pool $ fetchRecentInGroup groupId 9999 Nothing 2
        -- Two newest, then re-ordered oldest-first → 1003, 1004
        map (.messageId) rows `shouldBe` [1003, 1004]

      it "filters out messages older than the watermark when 'since' is Just" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "old"
        insertRawMessage pool 1002 groupId memberA botId (timeAt 10) Nothing "watermark"
        insertRawMessage pool 1003 groupId memberA botId (timeAt 11) Nothing "after"
        rows <- withDb pool $ fetchRecentInGroup groupId 9999 (Just (timeAt 10)) 10
        -- Strictly newer than the watermark — equal-to is excluded too
        map (.messageId) rows `shouldBe` [1003]

    describe "fetchTranscriptAfter" $ do
      it "reads the complete exact-cursor tail without a message-count lane" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "covered"
        insertRawMessage pool 1002 groupId memberA botId (timeAt 10) Nothing "tail-a"
        insertRawMessage pool 1003 groupId memberB botId (timeAt 11) Nothing "tail-b"
        insertRawMessage pool 1004 groupId memberA botId (timeAt 12) Nothing "current"
        cursorRows <- withDb pool $ query "SELECT ingest_seq FROM messages WHERE message_id = ?" (Only (1001 :: Int))
        coveredCursor <- case cursorRows :: [Only Int64] of
          Only cursor : _ -> pure (MessageCursor cursor)
          _ -> expectationFailure "missing covered cursor" >> pure (MessageCursor 0)
        rows <- withDb pool $ fetchTranscriptAfter scope coveredCursor 1004 Nothing
        map (.messageId) rows `shouldBe` [1002, 1003]

      it "keeps scope and clear-watermark filtering on the raw tail" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "old"
        insertRawMessage pool 1002 (groupId + 1) memberB botId (timeAt 11) Nothing "other-group"
        insertRawMessage pool 1003 groupId memberA botId (timeAt 12) Nothing "visible"
        rows <- withDb pool $ fetchTranscriptAfter scope (MessageCursor 0) 9999 (Just (timeAt 10))
        map (.messageId) rows `shouldBe` [1003]

    describe "fetchMessageInScope" $ do
      it "returns Nothing for an absent id" $ do
        m <- withDb pool $ fetchMessageInScope scope 9999
        case m of
          Nothing -> pure ()
          Just h -> expectationFailure $ "expected Nothing, got: " <> show h

      it "returns Just with the requested row" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "hello"
        m <- withDb pool $ fetchMessageInScope scope 1001
        case m of
          Just h -> do
            h.messageId `shouldBe` 1001
            h.userId `shouldBe` memberA
            h.renderedText `shouldBe` "hello"
            h.senderNickname `shouldBe` Just "Alice"
          Nothing -> expectationFailure "expected Just"

      it "does not resolve an id owned by another conversation" $ do
        insertRawMessage pool 1001 (groupId + 1) memberA botId (timeAt 9) (Just "Alice") "secret"
        m <- withDb pool $ fetchMessageInScope scope 1001
        m `shouldSatisfy` isNothing

    describe "fetchMentionHistory" $ do
      it "includes bot-sent messages (user_id = botId)" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "@1000 hi"
        insertRawMessage pool 1002 groupId botId botId (timeAt 10) Nothing "hi back"
        rows <- withDb pool $ fetchMentionHistory groupId botId 9999 Nothing 10
        map (.messageId) rows `shouldBe` [1001, 1002]

      it "includes member messages that mention @<botId> in rendered_text" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "@1000 你好"
        insertRawMessage pool 1002 groupId memberB botId (timeAt 9) (Just "Bob") "random chat"
        rows <- withDb pool $ fetchMentionHistory groupId botId 9999 Nothing 10
        map (.messageId) rows `shouldBe` [1001]

      it "excludes the triggering message id even when it would match" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "@1000 hi"
        rows <- withDb pool $ fetchMentionHistory groupId botId 1001 Nothing 10
        map (.messageId) rows `shouldBe` []

      it "respects the watermark" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "@1000 old"
        insertRawMessage pool 1002 groupId memberA botId (timeAt 11) (Just "Alice") "@1000 new"
        rows <- withDb pool $ fetchMentionHistory groupId botId 9999 (Just (timeAt 10)) 10
        map (.messageId) rows `shouldBe` [1002]

      it "includes messages the bot itself quoted (proactive replies)" $ do
        -- No @, no reply — a proactive turn's target.  The bot's reply
        -- quotes it, which must pull the user's side into the history:
        -- otherwise the bot reads its own answers with no question.
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) (Just "Alice") "max在吗"
        insertRawReply pool 1002 groupId botId botId (timeAt 10) Nothing "在。干嘛。" 1001
        insertRawMessage pool 1003 groupId memberB botId (timeAt 10) (Just "Bob") "无关闲聊"
        rows <- withDb pool $ fetchMentionHistory groupId botId 9999 Nothing 10
        map (.messageId) rows `shouldBe` [1001, 1002]

    describe "fetchMessagesByIdsInScope" $ do
      it "returns rows in the requested order (not DB order)" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "a"
        insertRawMessage pool 1002 groupId memberA botId (timeAt 10) Nothing "b"
        insertRawMessage pool 1003 groupId memberA botId (timeAt 11) Nothing "c"
        rows <- withDb pool $ fetchMessagesByIdsInScope scope [1003, 1001, 1002]
        map (.messageId) rows `shouldBe` [1003, 1001, 1002]

      it "silently drops unknown ids without failing" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "a"
        rows <- withDb pool $ fetchMessagesByIdsInScope scope [9999, 1001, 8888]
        map (.messageId) rows `shouldBe` [1001]

      it "returns [] for empty input without hitting the DB" $ do
        rows <- withDb pool $ fetchMessagesByIdsInScope scope []
        map (.messageId) rows `shouldBe` []

      it "drops ids owned by another conversation" $ do
        insertRawMessage pool 1001 groupId memberA botId (timeAt 9) Nothing "visible"
        insertRawMessage pool 1002 (groupId + 1) memberB botId (timeAt 10) Nothing "secret"
        rows <- withDb pool $ fetchMessagesByIdsInScope scope [1001, 1002]
        map (.messageId) rows `shouldBe` [1001]

    describe "fetchForwardChildrenInScope" $ do
      it "does not expand a forward container owned by another conversation" $ do
        insertRawMessage pool 2001 (groupId + 1) memberA botId (timeAt 9) Nothing "[forward]"
        insertRawMessage pool (-1) (groupId + 1) memberB botId (timeAt 10) Nothing "secret child"
        withConn pool $ \conn -> do
          _ <-
            execute
              conn
              "UPDATE messages SET forwarded_in_message_id = ?, forward_position = 0, is_synthetic = true WHERE message_id = ?"
              (2001 :: Int, -1 :: Int)
          pure ()
        rows <- withDb pool $ fetchForwardChildrenInScope scope 2001 10
        rows `shouldSatisfy` null
