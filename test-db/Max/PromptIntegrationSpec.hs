-- |
-- End-to-end test for 'Max.Prompt.buildContext' against a real
-- database: insert fixture rows, drive 'buildContext' through the
-- effect stack, then assert on the rendered ChatMessage list.  The
-- pure render path is covered separately in 'Max.PromptSpec'; this
-- module specifically verifies that the DB queries wire up to the
-- renderer correctly (dedup, watermark, pin resolution, reply lookup).
module Max.PromptIntegrationSpec (spec) where

import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, utc)
import Helpers (insertRawKind, insertRawMessage, truncateAll, updateDbSession, withDb, withDbLog)
import Max.DB.Connection (DbPool)
import Max.DB.Session (fetchOrInit)
import Max.Effects.LLM (ChatMessage (..))
import Max.Prompt (TriggerOrigin (..), buildContext)
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

groupRaw :: (Integral a) => a
groupRaw = 7777

botRaw :: (Integral a) => a
botRaw = 1000

memberRaw :: (Integral a) => a
memberRaw = 2001

otherMemberRaw :: (Integral a) => a
otherMemberRaw = 2002

timeAt :: Int -> UTCTime
timeAt h =
  UTCTime
    (fromGregorian 2026 6 5)
    (secondsToDiffTime (fromIntegral (h * 3600)))

trigger :: GroupMessage
trigger =
  GroupMessage
    { selfId = UserId botRaw,
      groupId = GroupId groupRaw,
      userId = UserId memberRaw,
      messageId = MessageId 9000,
      message = [SegAt (UserId botRaw), SegText " 现在几点"],
      rawMessage = "",
      sender = Sender (UserId memberRaw) (Just "Alice") Nothing
    }

userBodyOf :: [ChatMessage] -> Text
userBodyOf msgs = case last msgs of
  MsgUser t -> t
  other -> error $ "expected trailing MsgUser, got: " <> show other

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.Prompt.buildContext (integration)" $ do
    it "renders ambient rows from the messages table" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "随便聊"
      insertRawMessage pool 1002 groupRaw memberRaw botRaw (timeAt 10) (Just "Alice") "另一条"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, _) <-
        withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("随便聊" `T.isInfixOf`)
      ub `shouldSatisfy` ("另一条" `T.isInfixOf`)

    it "honours cleared_at watermark — older rows are dropped" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "旧"
      insertRawMessage pool 1002 groupRaw memberRaw botRaw (timeAt 11) (Just "Alice") "新"
      s <-
        updateDbSession pool (GroupId groupRaw) "deepseek-flash" $ \current ->
          current {clearedAt = Just (timeAt 10)}
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      let ub = userBodyOf msgs
      ub `shouldNotSatisfy` ("旧" `T.isInfixOf`)
      ub `shouldSatisfy` ("新" `T.isInfixOf`)

    it "renders prior @-mention and the bot's reply as transcript lines" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "@1000 你好"
      insertRawMessage pool 1002 groupRaw botRaw botRaw (timeAt 10) Nothing "你好 Alice"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      -- The whole conversation is [system, user]: the bot's own past
      -- replies are lines in the transcript, not assistant turns.
      length msgs `shouldBe` 2
      case msgs of
        [MsgSystem _, MsgUser ub] -> do
          ub `shouldSatisfy` ("[09:00 Alice #1001]:" `T.isInfixOf`)
          ub `shouldSatisfy` ("[10:00 Max #1002]: 你好 Alice" `T.isInfixOf`)
        other -> expectationFailure $ "unexpected message shape: " <> show other

    -- The two queries reach back different distances: fetchRecentInGroup
    -- takes the last n messages, fetchMentionHistory the last n that
    -- involve the bot.  With a small window and chatty filler, the bot
    -- exchange falls out of the first and must survive via the second —
    -- that is the whole reason both are still issued.
    it "keeps bot conversation that chatter has pushed out of the recent window" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 1) (Just "Alice") "@1000 昨天那事呢"
      insertRawMessage pool 1002 groupRaw botRaw botRaw (timeAt 2) Nothing "已经办好了"
      mapM_
        ( \i ->
            insertRawMessage pool (2000 + i) groupRaw otherMemberRaw botRaw (timeAt (3 + fromIntegral i)) (Just "Bob") ("闲聊" <> T.pack (show i))
        )
        [1 .. 5 :: Int64]
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      -- Window of 3: the bot exchange is well outside the last 3 raw
      -- messages, but is still among the last 3 bot-related ones.
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 3 80 False False OriginDirect utc [] [] Set.empty s trigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("昨天那事呢" `T.isInfixOf`)
      ub `shouldSatisfy` ("已经办好了" `T.isInfixOf`)
      ub `shouldSatisfy` ("闲聊5" `T.isInfixOf`)

    -- Everything the chat saw is in the table; only `kind = 'chat'`
    -- reaches the model.  Load-bearing for !btw in particular: its
    -- command message used to sit in the transcript as a question, and
    -- a later turn would answer it again.
    it "shows only kind='chat' rows in the transcript" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "普通聊天"
      insertRawKind pool "command" 1002 groupRaw memberRaw botRaw (timeAt 10) (Just "Alice") "!btw 顺便问一下"
      insertRawKind pool "command" 1003 groupRaw botRaw botRaw (timeAt 11) (Just "max") "在跑的任务: t3"
      insertRawKind pool "debug" 1004 groupRaw botRaw botRaw (timeAt 12) (Just "max") "⚙ web_search {\"q\":\"foo\"}"
      insertRawKind pool "debug" 1005 groupRaw botRaw botRaw (timeAt 13) (Just "max") "↳ web_search {\"results\":[]}"
      -- The bot's narration is conversation, so it stays.
      insertRawMessage pool 1006 groupRaw botRaw botRaw (timeAt 14) (Just "max") "我查一下日志"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("普通聊天" `T.isInfixOf`)
      ub `shouldSatisfy` ("我查一下日志" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("顺便问一下" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("在跑的任务" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("⚙" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("↳" `T.isInfixOf`))

    -- The anchor is the whole point of the cache work: the transcript
    -- has to grow rather than slide, or its first line changes on every
    -- dispatch and no prefix cache can cover it.
    it "reports no anchor move while under the high-water mark" $ do
      mapM_
        (\i -> insertRawMessage pool (3000 + i) groupRaw memberRaw botRaw (timeAt (fromIntegral i)) (Just "Alice") ("行" <> T.pack (show i)))
        [1 .. 5 :: Int64]
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      (_, moved) <- withDbLog pool $ buildContext "default-persona" 2 10 False False OriginDirect utc [] [] Set.empty s trigger
      moved `shouldBe` Nothing

    it "moves the anchor once past it, and the anchor then narrows the window" $ do
      mapM_
        (\i -> insertRawMessage pool (3000 + i) groupRaw memberRaw botRaw (timeAt (fromIntegral i)) (Just "Alice") ("行" <> T.pack (show i)))
        [1 .. 6 :: Int64]
      s0 <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      -- Low 2 / high 4: six rows overflow, so the anchor moves and the
      -- rendered transcript keeps the newest two.
      (msgs, moved) <- withDbLog pool $ buildContext "default-persona" 2 4 False False OriginDirect utc [] [] Set.empty s0 trigger
      moved `shouldSatisfy` (/= Nothing)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("行6" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("行1" `T.isInfixOf`))
      -- Commit it the way the dispatcher does, then rebuild: the same
      -- floor now applies at the query, so the window is already short
      -- and nothing moves again.
      s1 <-
        updateDbSession pool (GroupId groupRaw) "deepseek-flash" $ \current ->
          current {contextAnchor = moved}
      (msgs', moved') <- withDbLog pool $ buildContext "default-persona" 2 4 False False OriginDirect utc [] [] Set.empty s1 trigger
      moved' `shouldBe` Nothing
      userBodyOf msgs' `shouldSatisfy` (not . ("行1" `T.isInfixOf`))
      userBodyOf msgs' `shouldSatisfy` ("行6" `T.isInfixOf`)

    -- A message can come back from both queries; it must appear once.
    it "shows a message that both queries return exactly once" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "@1000 只此一次"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      T.count "只此一次" (userBodyOf msgs) `shouldBe` 1

    it "renders pinned messages in the [pinned] section" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "重要信息"
      s <-
        updateDbSession pool (GroupId groupRaw) "deepseek-flash" $ \current ->
          current {pinned = [1001]}
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s trigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[pinned" `T.isInfixOf`)
      ub `shouldSatisfy` ("重要信息" `T.isInfixOf`)

    it "renders reply context when trigger has SegReply" $ do
      insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "被引用的话"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      let replyTrigger =
            trigger
              { message = [SegReply (MessageId 1001), SegAt (UserId botRaw), SegText " 看这条"]
              }
      (msgs, _) <- withDbLog pool $ buildContext "default-persona" 20 80 False False OriginDirect utc [] [] Set.empty s replyTrigger
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[quoted context]" `T.isInfixOf`)
      ub `shouldSatisfy` ("被引用的话" `T.isInfixOf`)
