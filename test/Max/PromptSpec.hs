module Max.PromptSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.DB.Files (FileRecord (..))
import Max.DB.History (HistoryItem (..))
import Max.Effects.LLM (ChatMessage (..))
import Max.Prompt (PromptInputs (..), renderContext)
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

--------------------------------------------------------------------------------
-- Fixtures.

botId :: Int64
botId = 1000

memberId :: Int64
memberId = 2001

otherMemberId :: Int64
otherMemberId = 2002

groupRaw :: Int64
groupRaw = 7777

triggerMid :: Int64
triggerMid = 9000

timeAt :: Int -> UTCTime
timeAt h =
  UTCTime
    (fromGregorian 2026 6 5)
    (secondsToDiffTime (fromIntegral (h * 3600)))

historyAt ::
  Int -> -- hour
  Int64 -> -- message_id
  Int64 -> -- user_id
  Maybe Text -> -- nickname
  Text -> -- rendered_text
  HistoryItem
historyAt h mid uid nick body =
  HistoryItem
    { messageId = mid,
      userId = uid,
      selfId = botId,
      senderNickname = nick,
      renderedText = body,
      receivedAt = timeAt h
    }

triggerMsg :: [Segment] -> GroupMessage
triggerMsg segs =
  GroupMessage
    { selfId = UserId botId,
      groupId = GroupId groupRaw,
      userId = UserId memberId,
      messageId = MessageId triggerMid,
      message = segs,
      rawMessage = "",
      sender = Sender (UserId memberId) (Just "Alice") Nothing
    }

emptySession :: Session
emptySession =
  Session
    { groupId = GroupId groupRaw,
      branch = "main",
      model = "deepseek-flash",
      persona = Nothing,
      btwNotes = [],
      clearedAt = Nothing,
      pinned = [],
      thinkingOverride = Nothing
    }

baseInputs :: PromptInputs
baseInputs =
  PromptInputs
    { defaultPersona = "default-persona",
      session = emptySession,
      triggerMessage = triggerMsg [SegAt (UserId botId), SegText " hello"],
      ambient = [],
      mention = [],
      pinnedItems = [],
      replyCtx = Nothing,
      triggerImageUrls = []
    }

--------------------------------------------------------------------------------
-- Helpers.

-- | Pull out the assistant-facing system+history+user-body trio.
-- We pattern-match because the structure is fixed: system first,
-- then zero-or-more mention messages, then exactly one user message.
splitMessages :: [ChatMessage] -> (Text, [ChatMessage], Text)
splitMessages msgs = case msgs of
  (MsgSystem sys : rest) ->
    let (mid, lastUser) = unsnoc rest
     in case lastUser of
          Just (MsgUser ub) -> (sys, mid, ub)
          other ->
            error $
              "expected trailing MsgUser, got: " <> show other
  other -> error $ "expected leading MsgSystem, got: " <> show other
  where
    unsnoc [] = ([], Nothing)
    unsnoc [x] = ([], Just x)
    unsnoc (x : xs) = let (i, l) = unsnoc xs in (x : i, l)

--------------------------------------------------------------------------------
-- Tests.

spec :: Spec
spec = do
  describe "renderContext system prompt" $ do
    it "uses default persona when session has no override" $ do
      let (sys, _, _) = splitMessages (fst (renderContext baseInputs))
      sys `shouldSatisfy` ("default-persona" `T.isPrefixOf`)

    it "uses session persona override when set" $ do
      let inp = baseInputs {session = emptySession {persona = Just "猫娘 mode"}}
          (sys, _, _) = splitMessages (fst (renderContext inp))
      sys `shouldSatisfy` ("猫娘 mode" `T.isPrefixOf`)

  describe "renderContext mention history" $ do
    it "renders bot rows as MsgAssistant, member rows as MsgUser" $ do
      let mention =
            [ historyAt 9 8001 memberId (Just "Alice") "@1000 你好",
              historyAt 9 8002 botId Nothing "你好 Alice",
              historyAt 10 8003 memberId (Just "Alice") "@1000 你叫什么"
            ]
          inp = baseInputs {mention = mention}
          (_, mid, _) = splitMessages (fst (renderContext inp))
      length mid `shouldBe` 3
      case mid of
        [MsgUser u1, MsgAssistant a1, MsgUser u2] -> do
          u1 `shouldSatisfy` ("Alice" `T.isInfixOf`)
          a1 `shouldBe` "你好 Alice"
          u2 `shouldSatisfy` ("Alice" `T.isInfixOf`)
        other -> expectationFailure $ "unexpected shape: " <> show other

    it "uses numeric user id when nickname is missing" $ do
      let mention = [historyAt 9 8001 otherMemberId Nothing "@1000 hi"]
          inp = baseInputs {mention = mention}
          (_, mid, _) = splitMessages (fst (renderContext inp))
      case mid of
        [MsgUser u] -> u `shouldSatisfy` ("<2002>" `T.isInfixOf`)
        other -> expectationFailure $ "unexpected shape: " <> show other

  describe "renderContext user body" $ do
    it "shows '(无历史消息)' when ambient is empty" $ do
      let (_, _, ub) = splitMessages (fst (renderContext baseInputs))
      ub `shouldSatisfy` ("(无历史消息)" `T.isInfixOf`)

    it "renders ambient with [HH:MM <nick>] markers" $ do
      let ambient =
            [ historyAt 9 7001 memberId (Just "Alice") "今天吃啥",
              historyAt 9 7002 otherMemberId (Just "Bob") "随便"
            ]
          inp = baseInputs {ambient = ambient}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[09:00 Alice]" `T.isInfixOf`)
      ub `shouldSatisfy` ("[09:00 Bob]" `T.isInfixOf`)
      ub `shouldSatisfy` ("今天吃啥" `T.isInfixOf`)

    it "dedupes ambient against mention by message_id" $ do
      let shared = historyAt 9 7001 memberId (Just "Alice") "@1000 hi"
          inp =
            baseInputs
              { ambient = [shared, historyAt 9 7002 memberId (Just "Alice") "另一条"],
                mention = [shared]
              }
          (_, _, ub) = splitMessages (fst (renderContext inp))
      -- shared message text appears in the MENTION segment, not in ambient
      -- → it should occur exactly once across the whole user body
      T.count "@1000 hi" ub `shouldBe` 0 -- ambient version stripped; mention is separate ChatMessage

    it "places pinned messages in their own section, before ambient" $ do
      let pin = historyAt 8 6001 otherMemberId (Just "Bob") "重要的话"
          inp = baseInputs {pinnedItems = [pin]}
          (_, _, ub) = splitMessages (fst (renderContext inp))
          pinIdx = T.breakOnAll "[pin 上下文" ub
          ambIdx = T.breakOnAll "[群最近上下文]" ub
      ub `shouldSatisfy` ("重要的话" `T.isInfixOf`)
      length pinIdx `shouldBe` 1
      length ambIdx `shouldBe` 1
      -- ordering check: pin section starts before ambient section
      case (pinIdx, ambIdx) of
        ([(p, _)], [(a, _)]) -> T.length p `shouldSatisfy` (< T.length a)
        _ -> expectationFailure "expected one of each marker"

    it "omits pin section entirely when no pins" $ do
      let (_, _, ub) = splitMessages (fst (renderContext baseInputs))
      ub `shouldNotSatisfy` ("[pin 上下文" `T.isInfixOf`)

    it "renders reply context with file table when reply message has files" $ do
      let replied = historyAt 8 5001 otherMemberId (Just "Bob") "看看这个文件"
          file =
            FileRecord
              { frFileId = "abc-123",
                frGroupId = groupRaw,
                frMessageId = Just 5001,
                frSenderUserId = otherMemberId,
                frFileName = "report.pdf",
                frMimeType = Just "application/pdf",
                frBytesSize = Just 2048,
                frSha256 = Nothing,
                frLocalPath = Just "/data/x",
                frReceivedAt = timeAt 8,
                frFetchedAt = Just (timeAt 8)
              }
          inp = baseInputs {replyCtx = Just (replied, [file])}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[引用上下文]" `T.isInfixOf`)
      ub `shouldSatisfy` ("report.pdf" `T.isInfixOf`)
      ub `shouldSatisfy` ("file_id=\"abc-123\"" `T.isInfixOf`)
      ub `shouldSatisfy` ("ready=true" `T.isInfixOf`)

    it "marks ready=false when reply file has no local path" $ do
      let replied = historyAt 8 5001 otherMemberId Nothing "see file"
          file =
            FileRecord
              { frFileId = "x",
                frGroupId = groupRaw,
                frMessageId = Just 5001,
                frSenderUserId = otherMemberId,
                frFileName = "a.txt",
                frMimeType = Nothing,
                frBytesSize = Nothing,
                frSha256 = Nothing,
                frLocalPath = Nothing,
                frReceivedAt = timeAt 8,
                frFetchedAt = Nothing
              }
          inp = baseInputs {replyCtx = Just (replied, [file])}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("ready=false" `T.isInfixOf`)

    it "renders btw notes when session has any" $ do
      let inp = baseInputs {session = emptySession {btwNotes = ["记得加引用", "今天别 typo"]}}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[侧记" `T.isInfixOf`)
      ub `shouldSatisfy` ("记得加引用" `T.isInfixOf`)
      ub `shouldSatisfy` ("今天别 typo" `T.isInfixOf`)

    it "strips @-mention of the bot from current line" $ do
      let inp =
            baseInputs
              { triggerMessage = triggerMsg [SegAt (UserId botId), SegText " 你好啊"]
              }
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("<Alice>: 你好啊" `T.isInfixOf`)

  describe "renderContext drained notes" $ do
    it "returns the session btw notes verbatim as 'drained'" $ do
      let notes = ["a", "b", "c"]
          inp = baseInputs {session = emptySession {btwNotes = notes}}
          (_, drained) = renderContext inp
      drained `shouldBe` notes

    it "returns empty list when no notes" $ do
      let (_, drained) = renderContext baseInputs
      drained `shouldBe` []
