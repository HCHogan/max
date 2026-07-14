module Max.PromptSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Max.DB.Files (FileRecord (..))
import Max.DB.History (HistoryItem (..))
import Max.DB.Memory (MemoryItem (..))
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.Prompt (PromptImage (..), PromptInputs (..), renderContext)
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
      senderCard = Nothing,
      renderedText = body,
      receivedAt = timeAt h
    }

memAt :: Int64 -> Text -> MemoryItem
memAt mid content =
  MemoryItem
    { memId = mid,
      memScope = "group", -- rendering doesn't read scope fields
      memScopeId = 0,
      memContent = content,
      memUpdatedAt = timeAt 12
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

-- | Same trigger but arriving via private chat (pseudo group id).
privateTriggerMsg :: [Segment] -> GroupMessage
privateTriggerMsg segs =
  GroupMessage
    { selfId = UserId botId,
      groupId = GroupId (negate memberId),
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
      thinkingOverride = Nothing,
      debugOverride = Nothing
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
      multimodal = False,
      groupMemories = [],
      userMemories = [],
      images = [],
      now = timeAt 12
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

    it "includes an environment block with date, group, and model" $ do
      let (sys, _, _) = splitMessages (fst (renderContext baseInputs))
      sys `shouldSatisfy` ("[当前环境]" `T.isInfixOf`)
      sys `shouldSatisfy` ("2026-06-05" `T.isInfixOf`)
      sys `shouldSatisfy` ("7777" `T.isInfixOf`)
      sys `shouldSatisfy` ("deepseek-flash" `T.isInfixOf`)

  describe "renderContext identity" $ do
    it "includes a roster mapping QQ ids to display names, bot first" $ do
      let inp = baseInputs {ambient = [historyAt 9 8001 otherMemberId (Just "Bob") "早"]}
          (sys, _, _) = splitMessages (fst (renderContext inp))
      sys `shouldSatisfy` ("成员对照" `T.isInfixOf`)
      sys `shouldSatisfy` ((T.pack (show botId) <> "=Max（你自己）") `T.isInfixOf`)
      sys `shouldSatisfy` ((T.pack (show memberId) <> "=Alice") `T.isInfixOf`)
      sys `shouldSatisfy` ((T.pack (show otherMemberId) <> "=Bob") `T.isInfixOf`)

    it "prefers 群名片 over nickname in context lines and the roster" $ do
      let item = (historyAt 9 8001 otherMemberId (Just "SkyRain") "早") {senderCard = Just "sleepy"}
          inp = baseInputs {ambient = [item]}
          (sys, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[09:00 sleepy]" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("SkyRain" `T.isInfixOf`))
      sys `shouldSatisfy` ((T.pack (show otherMemberId) <> "=sleepy") `T.isInfixOf`)

    it "treats a blank card as absent" $ do
      let item = (historyAt 9 8001 otherMemberId (Just "SkyRain") "早") {senderCard = Just ""}
          inp = baseInputs {ambient = [item]}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[09:00 SkyRain]" `T.isInfixOf`)

  describe "renderContext private chat" $ do
    it "labels the environment as 私聊 instead of 群号" $ do
      let inp = baseInputs {triggerMessage = privateTriggerMsg [SegText "hi"]}
          (sys, _, _) = splitMessages (fst (renderContext inp))
      sys `shouldSatisfy` ("私聊" `T.isInfixOf`)
      sys `shouldSatisfy` (not . ("群号" `T.isInfixOf`))

    it "injects the matching 对话场景 block per chat kind" $ do
      let (sysG, _, _) = splitMessages (fst (renderContext baseInputs))
          inpP = baseInputs {triggerMessage = privateTriggerMsg [SegText "hi"]}
          (sysP, _, _) = splitMessages (fst (renderContext inpP))
      sysG `shouldSatisfy` ("对话场景：QQ 群聊" `T.isInfixOf`)
      sysP `shouldSatisfy` ("对话场景：QQ 一对一私聊" `T.isInfixOf`)
      sysP `shouldSatisfy` (not . ("群成员" `T.isInfixOf`))

  describe "renderContext long-term memory" $ do
    it "omits the memory block entirely when nothing is remembered" $ do
      let (sys, _, _) = splitMessages (fst (renderContext baseInputs))
      sys `shouldSatisfy` (not . ("[长期记忆" `T.isInfixOf`))

    it "renders group + user memories with ids, at the end of the system prompt" $ do
      let inp =
            baseInputs
              { groupMemories = [memAt 5 "群里在开发 max bot"],
                userMemories = [memAt 9 "偏好 Haskell"]
              }
          (sys, _, _) = splitMessages (fst (renderContext inp))
      sys `shouldSatisfy` ("[长期记忆 — 背景备忘]" `T.isInfixOf`)
      sys `shouldSatisfy` ("(#5 2026-06-05) 群里在开发 max bot" `T.isInfixOf`)
      sys `shouldSatisfy` ("(#9 2026-06-05) 偏好 Haskell" `T.isInfixOf`)
      sys `shouldSatisfy` ("关于当前发言者 <Alice>" `T.isInfixOf`)
      -- Low-salience placement: the block sits after the persona and
      -- format guide, i.e. the memory header appears only near the end.
      let (upToBlock, _) = T.breakOn "[长期记忆" sys
      upToBlock `shouldSatisfy` ("回复风格" `T.isInfixOf`)

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

    it "merges consecutive bot rows (multi-chunk replies) into one assistant turn" $ do
      let mention =
            [ historyAt 9 8001 memberId (Just "Alice") "@1000 讲讲",
              historyAt 9 8002 botId Nothing "第一段",
              historyAt 9 8003 botId Nothing "第二段",
              historyAt 10 8004 memberId (Just "Alice") "@1000 继续"
            ]
          inp = baseInputs {mention = mention}
          (_, mid, _) = splitMessages (fst (renderContext inp))
      case mid of
        [MsgUser _, MsgAssistant a, MsgUser _] ->
          a `shouldBe` "第一段\n\n第二段"
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

  describe "renderContext images" $ do
    it "attaches images with labels, never two adjacent text blocks" $ do
      let img1 = PromptImage "[09:15 Alice] 消息里的图片:" "data:image/png;base64,AAAA"
          img2 = PromptImage "[当前消息] 里的图片:" "data:image/jpeg;base64,BBBB"
          inp = baseInputs {multimodal = True, images = [img1, img2]}
          msgs = fst (renderContext inp)
      case last msgs of
        MsgUserBlocks (TextBlock body : blocks) -> do
          body `shouldSatisfy` ("[当前 @ 你的消息]" `T.isInfixOf`)
          -- First label folds into the body (some providers 400 on
          -- adjacent text blocks); the rest interleave with images.
          body `shouldSatisfy` (img1.piLabel `T.isSuffixOf`)
          blocks
            `shouldBe` [ ImageDataUrl img1.piDataUrl,
                         TextBlock img2.piLabel,
                         ImageDataUrl img2.piDataUrl
                       ]
        other -> expectationFailure $ "unexpected shape: " <> show other

    it "stays a plain MsgUser when no images were loaded" $ do
      let inp = baseInputs {multimodal = True, images = []}
          (_, _, ub) = splitMessages (fst (renderContext inp))
      ub `shouldSatisfy` ("[当前 @ 你的消息]" `T.isInfixOf`)

    it "documents attached images in the format guide only when multimodal" $ do
      let (sysOff, _, _) = splitMessages (fst (renderContext baseInputs))
          (sysOn, _, _) = splitMessages (fst (renderContext baseInputs {multimodal = True}))
      sysOff `shouldSatisfy` ("你看不到内容" `T.isInfixOf`)
      sysOn `shouldSatisfy` ("内容会附在消息末尾" `T.isInfixOf`)

  describe "renderContext drained notes" $ do
    it "returns the session btw notes verbatim as 'drained'" $ do
      let notes = ["a", "b", "c"]
          inp = baseInputs {session = emptySession {btwNotes = notes}}
          (_, drained) = renderContext inp
      drained `shouldBe` notes

    it "returns empty list when no notes" $ do
      let (_, drained) = renderContext baseInputs
      drained `shouldBe` []
