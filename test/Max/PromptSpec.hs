module Max.PromptSpec (spec) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, minutesToTimeZone, secondsToDiffTime, utc)
import Max.Context (ContextDecision (..), ContextTrace (..))
import Max.DB.Files (FileRecord (..))
import Max.DB.History (HistoryItem (..))
import Max.Effects.Blob (blobRefFromSha256)
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.EpisodeStore (EpisodeHandle, parseEpisodeHandle)
import Max.MemoryStore (MemoryId (..), MemoryItem (..), MemoryVersion (..))
import Max.ModelCatalog (ContextLimits (..))
import Max.Prompt (CompartmentTier (..), ContextCandidates (..), ContextCompartment (..), ContextPlan (..), ContextSnapshot (..), PromptImage (..), PromptInputs (..), TriggerOrigin (..), applyBaseCompartmentTiers, applyStickerCaptions, applyVideoCaptions, cpInputs, planContext, renderContext, renderContextPlan, tagImageMarkers, tagMediaMarkers)
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
      receivedAt = timeAt h,
      replyTo = Nothing
    }

memAt :: Int64 -> Text -> MemoryItem
memAt mid content =
  MemoryItem
    { memId = MemoryId mid,
      memVersion = MemoryVersion 1,
      memScope = "group", -- rendering doesn't read scope fields
      memScopeId = 0,
      memContent = content,
      memLifecycle = "active",
      memCategory = Nothing,
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
      model = "deepseek-flash",
      persona = Nothing,
      clearedAt = Nothing,
      pinned = [],
      debugOverride = Nothing,
      stickerOverride = Nothing,
      proactiveOverride = Nothing,
      effortOverride = Nothing
    }

baseInputs :: PromptInputs
baseInputs =
  PromptInputs
    { defaultPersona = "default-persona",
      session = emptySession,
      triggerMessage = triggerMsg [SegAt (UserId botId), SegText " hello"],
      transcript = [],
      compartments = [],
      historyTurns = False,
      inFlight = Set.empty,
      pinnedItems = [],
      replyCtx = Nothing,
      triggerForward = [],
      multimodal = False,
      origin = OriginDirect,
      groupBrief = [],
      groupMemories = [],
      userMemories = [],
      images = [],
      skills = [],
      now = timeAt 12,
      tz = utc
    }

--------------------------------------------------------------------------------
-- Helpers.

-- | Pull out the system prompt and the user body.
--
-- Pattern-matching on exactly two messages is itself the assertion:
-- the whole conversation is one system message plus one user message,
-- with prior bot replies living inside the transcript as text rather
-- than as 'MsgAssistant' turns.  Nothing can produce two consecutive
-- same-role messages if there is only one of each.
splitMessages :: [ChatMessage] -> (Text, Text)
splitMessages msgs = case msgs of
  [MsgSystem sys, MsgUser ub] -> (sys, ub)
  other -> error $ "expected [MsgSystem, MsgUser], got: " <> show other

--------------------------------------------------------------------------------
-- Tests.

spec :: Spec
spec = do
  describe "renderContext system prompt" $ do
    it "uses default persona when session has no override" $ do
      let (sys, _) = splitMessages (renderContext baseInputs)
      sys `shouldSatisfy` ("default-persona" `T.isPrefixOf`)

    it "uses session persona override when set" $ do
      let inp = baseInputs {session = emptySession {persona = Just "猫娘 mode"}}
          (sys, _) = splitMessages (renderContext inp)
      sys `shouldSatisfy` ("猫娘 mode" `T.isPrefixOf`)

    -- The environment block lives in the user message now, after the
    -- transcript: it carries the clock, so leaving it in the system
    -- prompt capped every provider cache at "persona + format guide".
    it "includes an environment block with date, group, and model" $ do
      let (_, ub) = splitMessages (renderContext baseInputs)
      ub `shouldSatisfy` ("[environment]" `T.isInfixOf`)
      ub `shouldSatisfy` ("2026-06-05" `T.isInfixOf`)
      ub `shouldSatisfy` ("7777" `T.isInfixOf`)
      ub `shouldSatisfy` ("deepseek-flash" `T.isInfixOf`)

    it "renders timestamps in the configured display timezone" $ do
      -- 01:00 UTC on 2026-06-05 is 09:00 the same day at UTC+8; a
      -- context line at 20:00 UTC rolls over to 04:00 next day.
      let inp =
            baseInputs
              { now = timeAt 1,
                tz = minutesToTimeZone 480,
                transcript = [historyAt 20 8001 otherMemberId (Just "Bob") "晚上好"]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("2026-06-05（周五） 09:00" `T.isInfixOf`)
      ub `shouldSatisfy` ("[04:00 Bob #8001]" `T.isInfixOf`)

    it "splices groupBrief lines into the environment block" $ do
      let inp =
            baseInputs
              { groupBrief =
                  [ "群名：测试群（3人）",
                    "群主：Alice(6001)；管理员：Bob(6002)"
                  ]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("  群名：测试群（3人）" `T.isInfixOf`)
      ub `shouldSatisfy` ("  群主：Alice(6001)；管理员：Bob(6002)" `T.isInfixOf`)

    -- Progressive disclosure, index half: one line per skill in the
    -- system prompt, bodies nowhere in sight (they arrive as
    -- use_skill tool results).
    it "renders the skill index when the group has skills" $ do
      let inp =
            baseInputs
              { skills =
                  [ ("bilibili-dl", "下载 B 站视频转 gif 的流程"),
                    ("server-status", "查询服务器状态的命令和判读")
                  ]
              }
          (sys, _) = splitMessages (renderContext inp)
      sys `shouldSatisfy` ("技能对照表" `T.isInfixOf`)
      sys `shouldSatisfy` ("  bilibili-dl：下载 B 站视频转 gif 的流程" `T.isInfixOf`)
      sys `shouldSatisfy` ("  server-status：查询服务器状态的命令和判读" `T.isInfixOf`)

    -- The 台下设定 line still names use_skill (self-knowledge ships
    -- builtin, so in production the tool always exists); only the
    -- index section itself must vanish.
    it "omits the skill section entirely when there are none" $ do
      let (sys, _) = splitMessages (renderContext baseInputs)
      sys `shouldNotSatisfy` ("技能对照表" `T.isInfixOf`)

  describe "renderContext identity" $ do
    it "includes a roster mapping QQ ids to display names, bot first" $ do
      let inp = baseInputs {transcript = [historyAt 9 8001 otherMemberId (Just "Bob") "早"]}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("成员对照" `T.isInfixOf`)
      ub `shouldSatisfy` (("[@#" <> T.pack (show botId) <> "]=Max（你自己）") `T.isInfixOf`)
      ub `shouldSatisfy` (("[@#" <> T.pack (show memberId) <> "]=Alice") `T.isInfixOf`)
      ub `shouldSatisfy` (("[@#" <> T.pack (show otherMemberId) <> "]=Bob") `T.isInfixOf`)

    it "prefers 群名片 over nickname in context lines and the roster" $ do
      let item = (historyAt 9 8001 otherMemberId (Just "SkyRain") "早") {senderCard = Just "sleepy"}
          inp = baseInputs {transcript = [item]}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[09:00 sleepy #8001]" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("SkyRain" `T.isInfixOf`))
      ub `shouldSatisfy` (("[@#" <> T.pack (show otherMemberId) <> "]=sleepy") `T.isInfixOf`)

    it "treats a blank card as absent" $ do
      let item = (historyAt 9 8001 otherMemberId (Just "SkyRain") "早") {senderCard = Just ""}
          inp = baseInputs {transcript = [item]}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[09:00 SkyRain #8001]" `T.isInfixOf`)

  describe "renderContext private chat" $ do
    it "labels the environment as 私聊 instead of 群号" $ do
      let inp = baseInputs {triggerMessage = privateTriggerMsg [SegText "hi"]}
          (sys, _) = splitMessages (renderContext inp)
      sys `shouldSatisfy` ("私聊" `T.isInfixOf`)
      sys `shouldSatisfy` (not . ("群号" `T.isInfixOf`))

    it "injects the matching 对话场景 block per chat kind" $ do
      let (sysG, _) = splitMessages (renderContext baseInputs)
          inpP = baseInputs {triggerMessage = privateTriggerMsg [SegText "hi"]}
          (sysP, _) = splitMessages (renderContext inpP)
      sysG `shouldSatisfy` ("对话场景：QQ 群聊" `T.isInfixOf`)
      sysP `shouldSatisfy` ("对话场景：QQ 一对一私聊" `T.isInfixOf`)
      sysP `shouldSatisfy` (not . ("群成员" `T.isInfixOf`))

  describe "renderContext quoted forward" $ do
    it "expands stored forward children under the reply block" $ do
      let container = historyAt 9 8001 otherMemberId (Just "Bob") "[forward]"
          kids =
            [ historyAt 8 (-1) 3001 (Just "甲") "第一条转发",
              historyAt 8 (-2) 3002 (Just "乙") "第二条转发"
            ]
          inp = baseInputs {replyCtx = Just (container, [], kids)}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("转发记录内容" `T.isInfixOf`)
      ub `shouldSatisfy` ("第一条转发" `T.isInfixOf`)
      ub `shouldSatisfy` ("乙" `T.isInfixOf`)

    it "omits the forward section for ordinary quoted messages" $ do
      let replied = historyAt 9 8001 otherMemberId (Just "Bob") "普通消息"
          inp = baseInputs {replyCtx = Just (replied, [], [])}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` (not . ("转发记录内容" `T.isInfixOf`))

  describe "renderContext long-term memory" $ do
    it "omits the memory block entirely when nothing is remembered" $ do
      let (sys, _) = splitMessages (renderContext baseInputs)
      sys `shouldSatisfy` (not . ("[memories" `T.isInfixOf`))

    -- Memories change per group and per speaker, so like the
    -- environment block they sit in the user message below the
    -- transcript — everything a prefix cache could cover has to come
    -- before the first byte that varies.
    it "renders group + user memories with ids, below the transcript" $ do
      let inp =
            baseInputs
              { groupMemories = [memAt 5 "群里在开发 max bot"],
                userMemories = [memAt 9 "偏好 Haskell"],
                transcript = [historyAt 9 8001 memberId (Just "Alice") "早"]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[memories — 背景备忘]" `T.isInfixOf`)
      ub `shouldSatisfy` ("(#5@v1 2026-06-05) 群里在开发 max bot" `T.isInfixOf`)
      ub `shouldSatisfy` ("(#9@v1 2026-06-05) 偏好 Haskell" `T.isInfixOf`)
      ub `shouldSatisfy` ("关于当前发言者 <Alice>" `T.isInfixOf`)
      -- Order within the user body: transcript, then the volatile
      -- blocks, then the message being answered.
      let (upToBlock, _) = T.breakOn "[memories" ub
      upToBlock `shouldSatisfy` ("[recent messages]" `T.isInfixOf`)
      upToBlock `shouldSatisfy` (not . ("[current message]" `T.isInfixOf`))

  describe "renderContext transcript" $ do
    -- The whole conversation is one system message plus one user
    -- message.  splitMessages asserts that shape; this pins down that
    -- the bot's own history really did move inside the user body
    -- rather than getting dropped.
    it "renders the bot's own rows as transcript lines, not assistant turns" $ do
      let inp =
            baseInputs
              { transcript =
                  [ historyAt 9 8001 memberId (Just "Alice") "@1000 你好",
                    historyAt 9 8002 botId Nothing "你好 Alice",
                    historyAt 10 8003 memberId (Just "Alice") "@1000 你叫什么"
                  ]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[09:00 Alice #8001]:" `T.isInfixOf`)
      ub `shouldSatisfy` ("[09:00 Max #8002]: 你好 Alice" `T.isInfixOf`)
      ub `shouldSatisfy` ("[10:00 Alice #8003]:" `T.isInfixOf`)

    -- Multi-chunk replies persist as several consecutive bot rows.
    -- They used to be merged back into one assistant turn; as
    -- transcript lines each keeps its own id, which is strictly better
    -- — the model can quote the specific chunk.
    it "keeps consecutive bot rows as separate quotable lines" $ do
      let inp =
            baseInputs
              { transcript =
                  [ historyAt 9 8001 memberId (Just "Alice") "@1000 讲讲",
                    historyAt 9 8002 botId Nothing "第一段",
                    historyAt 9 8003 botId Nothing "第二段"
                  ]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[09:00 Max #8002]: 第一段" `T.isInfixOf`)
      ub `shouldSatisfy` ("[09:00 Max #8003]: 第二段" `T.isInfixOf`)

    -- The A-then-B collision: A's turn is still running, so its reply
    -- isn't in the messages table and A's question would otherwise be
    -- a question the bot visibly owes an answer to.  The model then
    -- answers both, and A gets answered twice.
    it "keeps an unanswered question when nothing is in flight" $ do
      let inp =
            baseInputs
              { transcript = [historyAt 10 8003 otherMemberId (Just "Bob") "@1000 Qb"]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("Qb" `T.isInfixOf`)

    -- Hidden, not annotated.  An annotation is one more string the
    -- model has to read as not-speech, and the one that used to live
    -- here came back as the bot's reply; a line that isn't there can't
    -- be answered and can't be quoted.
    it "hides a question another turn is already answering" $ do
      let inp =
            baseInputs
              { transcript =
                  [ historyAt 9 8001 memberId (Just "Alice") "@1000 Qa",
                    historyAt 10 8003 otherMemberId (Just "Bob") "@1000 Qb"
                  ],
                inFlight = Set.fromList [8001]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` (not . ("Qa" `T.isInfixOf`))
      ub `shouldSatisfy` ("Qb" `T.isInfixOf`)

    it "never hides the bot's own rows, whatever ids are in flight" $ do
      let inp =
            baseInputs
              { transcript =
                  [ historyAt 9 8001 memberId (Just "Alice") "@1000 Qa",
                    historyAt 9 8002 botId Nothing "答 Qa"
                  ],
                inFlight = Set.fromList [8001, 8002]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("答 Qa" `T.isInfixOf`)

    it "uses numeric user id when nickname is missing" $ do
      let inp =
            baseInputs
              { transcript = [historyAt 9 8001 otherMemberId Nothing "@1000 hi"]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("2002" `T.isInfixOf`)

  -- The alternative shape, per-profile.  Kept because the two trade
  -- one hazard for the other and only the live bot can settle it: turns
  -- can't teach the model to imitate the line prefix, flat can't offer
  -- an assistant slot to continue.
  describe "renderContext historyTurns" $ do
    let convo =
          [ historyAt 9 8001 memberId (Just "Alice") "@1000 你好",
            historyAt 9 8002 botId Nothing "你好 Alice",
            historyAt 9 8003 botId Nothing "还有什么要问的",
            historyAt 10 8004 memberId (Just "Alice") "@1000 讲讲 STM",
            historyAt 10 8005 otherMemberId (Just "Bob") "@1000 我也想听"
          ]

    -- Strict alternation, ending on the current message.  Rows trailing
    -- the bot's last message rejoin the user body rather than becoming
    -- a user turn of their own, which would put two user messages
    -- back-to-back at the handover — the thing this shape exists to
    -- avoid, and in a group it would happen almost every turn.
    it "emits strictly alternating turns, current message last" $ do
      let inp = baseInputs {transcript = convo, historyTurns = True}
      case renderContext inp of
        [MsgSystem _, MsgUser h1, MsgAssistant a, MsgUser curr] -> do
          h1 `shouldSatisfy` ("[09:00 Alice #8001]:" `T.isInfixOf`)
          -- Multi-chunk replies persist as several bot rows; they merge
          -- back into one assistant turn.
          a `shouldBe` "你好 Alice\n\n还有什么要问的"
          -- The trailing run rode along into the current-message turn.
          curr `shouldSatisfy` ("[10:00 Alice #8004]:" `T.isInfixOf`)
          curr `shouldSatisfy` ("[10:00 Bob #8005]:" `T.isInfixOf`)
          curr `shouldSatisfy` ("[current message]" `T.isInfixOf`)
        other -> expectationFailure $ "unexpected shape: " <> show other

    it "never produces two consecutive same-role messages" $ do
      let roleOf = \case
            MsgSystem _ -> "s" :: Text
            MsgAssistant _ -> "a"
            _ -> "u"
          shapes =
            [ renderContext baseInputs {transcript = rows, historyTurns = True}
            | rows <-
                [ convo,
                  -- ends on a bot row
                  take 3 convo,
                  -- starts with the bot
                  drop 1 convo,
                  [],
                  [historyAt 9 8002 botId Nothing "只有我说过话"]
                ]
            ]
          adjacentDupes ms = or (zipWith (==) (map roleOf ms) (drop 1 (map roleOf ms)))
      map adjacentDupes shapes `shouldBe` map (const False) shapes

    -- Deliberate: a [HH:MM Max #id] prefix in the assistant slot is the
    -- likeliest way to teach the model to open its own replies that way.
    -- The cost is that the bot's messages have no quotable id here.
    it "leaves the bot's own turns unlabelled" $ do
      let inp = baseInputs {transcript = convo, historyTurns = True}
      case renderContext inp of
        (_ : _ : MsgAssistant a : _) ->
          a `shouldSatisfy` (not . ("#8002" `T.isInfixOf`))
        other -> expectationFailure $ "unexpected shape: " <> show other

    -- Rows that became turns must not also appear in the body, or the
    -- model reads the same message twice.
    it "does not repeat rows that became turns in the user body" $ do
      let inp = baseInputs {transcript = convo, historyTurns = True}
      case last (renderContext inp) of
        MsgUser ub -> do
          ub `shouldSatisfy` (not . ("你好 Alice" `T.isInfixOf`))
          ub `shouldSatisfy` (not . ("#8001" `T.isInfixOf`))
        other -> expectationFailure $ "unexpected trailing: " <> show other

    it "omits the [recent messages] block when nothing trails the bot" $ do
      let inp = baseInputs {transcript = take 3 convo, historyTurns = True}
      case last (renderContext inp) of
        MsgUser ub -> ub `shouldSatisfy` (not . ("[recent messages]" `T.isInfixOf`))
        other -> expectationFailure $ "unexpected trailing: " <> show other

    it "hides in-flight questions in this shape too" $ do
      let inp =
            baseInputs
              { transcript = convo,
                historyTurns = True,
                inFlight = Set.fromList [8005]
              }
      case renderContext inp of
        [MsgSystem _, MsgUser _, MsgAssistant _, MsgUser curr] ->
          curr `shouldSatisfy` (not . ("我也想听" `T.isInfixOf`))
        other -> expectationFailure $ "unexpected shape: " <> show other

  describe "renderContext user body" $ do
    it "shows '(无历史消息)' when the transcript is empty" $ do
      let (_, ub) = splitMessages (renderContext baseInputs)
      ub `shouldSatisfy` ("(无历史消息)" `T.isInfixOf`)

    it "renders the transcript with [HH:MM <nick> #<id>] markers" $ do
      let inp =
            baseInputs
              { transcript =
                  [ historyAt 9 7001 memberId (Just "Alice") "今天吃啥",
                    historyAt 9 7002 otherMemberId (Just "Bob") "随便"
                  ]
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[09:00 Alice #7001]" `T.isInfixOf`)
      ub `shouldSatisfy` ("[09:00 Bob #7002]" `T.isInfixOf`)
      ub `shouldSatisfy` ("今天吃啥" `T.isInfixOf`)

    it "places pinned messages in their own section, before the transcript" $ do
      let pin = historyAt 8 6001 otherMemberId (Just "Bob") "重要的话"
          inp = baseInputs {pinnedItems = [pin]}
          (_, ub) = splitMessages (renderContext inp)
          pinIdx = T.breakOnAll "[pinned" ub
          ambIdx = T.breakOnAll "[recent messages]" ub
      ub `shouldSatisfy` ("重要的话" `T.isInfixOf`)
      length pinIdx `shouldBe` 1
      length ambIdx `shouldBe` 1
      -- ordering check: pin section starts before the transcript section
      case (pinIdx, ambIdx) of
        ([(p, _)], [(a, _)]) -> T.length p `shouldSatisfy` (< T.length a)
        _ -> expectationFailure "expected one of each marker"

    it "omits pin section entirely when no pins" $ do
      let (_, ub) = splitMessages (renderContext baseInputs)
      ub `shouldNotSatisfy` ("[pinned" `T.isInfixOf`)

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
                frBlobRef = blobRefFromSha256 (T.replicate 64 "a"),
                frReceivedAt = timeAt 8,
                frFetchedAt = Just (timeAt 8)
              }
          inp = baseInputs {replyCtx = Just (replied, [file], [])}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[quoted context]" `T.isInfixOf`)
      ub `shouldSatisfy` ("report.pdf" `T.isInfixOf`)
      ub `shouldSatisfy` ("file_id=\"abc-123\"" `T.isInfixOf`)
      ub `shouldSatisfy` ("ready=true" `T.isInfixOf`)

    it "marks ready=false when reply file has no blob reference" $ do
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
                frBlobRef = Nothing,
                frReceivedAt = timeAt 8,
                frFetchedAt = Nothing
              }
          inp = baseInputs {replyCtx = Just (replied, [file], [])}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("ready=false" `T.isInfixOf`)

    -- The current message wears the same [HH:MM <name> #<id>]: shape as
    -- every transcript line.  One documented format for "a message in
    -- this conversation"; the old [#id] <name>: was a second shape the
    -- format guide never mentioned.  A GroupMessage carries no
    -- timestamp, so the trigger's time is `now`.
    it "renders the current line like a transcript line, mention stripped" $ do
      let inp =
            baseInputs
              { triggerMessage = triggerMsg [SegAt (UserId botId), SegText " 你好啊"],
                now = timeAt 12
              }
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` (("[12:00 Alice #" <> T.pack (show triggerMid) <> "]: 你好啊") `T.isInfixOf`)

  describe "renderContext images" $ do
    it "attaches images with labels, never two adjacent text blocks" $ do
      let img1 = PromptImage "[09:15 Alice] 消息里的图片:" "data:image/png;base64,AAAA"
          img2 = PromptImage "[当前消息] 里的图片:" "data:image/jpeg;base64,BBBB"
          inp = baseInputs {multimodal = True, images = [img1, img2]}
          msgs = renderContext inp
      case last msgs of
        MsgUserBlocks (TextBlock body : blocks) -> do
          body `shouldSatisfy` ("[current message]" `T.isInfixOf`)
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
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[current message]" `T.isInfixOf`)

    it "documents attached images in the format guide only when multimodal" $ do
      let (sysOff, _) = splitMessages (renderContext baseInputs)
          (sysOn, _) = splitMessages (renderContext baseInputs {multimodal = True})
      sysOff `shouldSatisfy` ("你看不到原图" `T.isInfixOf`)
      sysOn `shouldSatisfy` ("直接附在消息末尾" `T.isInfixOf`)

  describe "renderContext reply handles" $ do
    it "prefixes a transcript reply line with a [↩#<id>] handle" $ do
      let quoter = (historyAt 9 7001 memberId (Just "Alice") "同意") {replyTo = Just 6001}
          inp = baseInputs {transcript = [quoter]}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[↩#6001] 同意" `T.isInfixOf`)

    it "leaves non-reply transcript lines without a handle" $ do
      let inp = baseInputs {transcript = [historyAt 9 7001 memberId (Just "Alice") "随便说说"]}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` (not . ("[↩#" `T.isInfixOf`))

  describe "applyStickerCaptions" $ do
    let caps = Map.fromList [(50 :: Int64, [(700 :: Int64, "柴犬歪头，配字\"啊?\"，表达疑惑")])]
        item marker = historyAt 1 50 memberId (Just "甲") ("看这个 " <> marker)

    it "swaps a [sticker] marker for its captioned handle" $ do
      (applyStickerCaptions caps (item "[sticker]")).renderedText
        `shouldBe` "看这个 [sticker#700: 柴犬歪头，配字\"啊?\"，表达疑惑]"

    it "swaps the pre-rename [动画表情] marker too (old rows)" $ do
      (applyStickerCaptions caps (item "[动画表情]")).renderedText
        `shouldBe` "看这个 [sticker#700: 柴犬歪头，配字\"啊?\"，表达疑惑]"

    it "handles legacy [image] markers too" $ do
      (applyStickerCaptions caps (item "[image]")).renderedText
        `shouldBe` "看这个 [sticker#700: 柴犬歪头，配字\"啊?\"，表达疑惑]"

    it "consumes markers in order, leaves extras alone" $ do
      let caps2 = Map.fromList [(50 :: Int64, [(11 :: Int64, "第一张"), (12, "第二张")])]
      (applyStickerCaptions caps2 (item "[mface] 和 [动画表情] 和 [image]")).renderedText
        `shouldBe` "看这个 [sticker#11: 第一张] 和 [sticker#12: 第二张] 和 [image]"

    it "leaves messages without captions untouched" $ do
      (applyStickerCaptions Map.empty (item "[动画表情]")).renderedText
        `shouldBe` "看这个 [动画表情]"

    it "does not let a photo's [image] swallow the sticker's caption in a mixed message" $ do
      (applyStickerCaptions caps (item "[image] 配 [动画表情]")).renderedText
        `shouldBe` "看这个 [image] 配 [sticker#700: 柴犬歪头，配字\"啊?\"，表达疑惑]"

  describe "renderContext proactive turns" $ do
    it "labels the trigger block honestly and offers [silence]" $ do
      let (_, ub) = splitMessages (renderContext baseInputs {origin = OriginProactive})
      ub `shouldSatisfy` ("没人 @ 你" `T.isInfixOf`)
      ub `shouldSatisfy` ("[silence]" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("[current message]" `T.isInfixOf`))

    it "keeps the normal header for addressed turns" $ do
      let (_, ub) = splitMessages (renderContext baseInputs)
      ub `shouldSatisfy` ("[current message]" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("没人 @ 你" `T.isInfixOf`))

  describe "renderContext trigger forward" $ do
    it "expands the trigger's own forward children under the current message" $ do
      let kids =
            [ historyAt 8 (-51) otherMemberId (Just "Bob") "转发里第一句",
              historyAt 9 (-52) memberId (Just "Alice") "转发里第二句"
            ]
          inp = baseInputs {triggerForward = kids}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("转发记录内容" `T.isInfixOf`)
      ub `shouldSatisfy` ("转发里第一句" `T.isInfixOf`)
      ub `shouldSatisfy` ("转发里第二句" `T.isInfixOf`)

  describe "tagMediaMarkers" $ do
    it "upgrades a bare [forward] with the message's own id" $
      (tagMediaMarkers (historyAt 9 8001 memberId (Just "Alice") "看这个 [forward]")).renderedText
        `shouldBe` "看这个 [forward#8001]"

    it "upgrades a bare [video] the same way" $
      (tagMediaMarkers (historyAt 9 8002 memberId (Just "Alice") "[video] 好活")).renderedText
        `shouldBe` "[video#8002] 好活"

    it "leaves text without the marker untouched" $
      (tagMediaMarkers (historyAt 9 8001 memberId (Just "Alice") "普通消息")).renderedText
        `shouldBe` "普通消息"

  describe "tagImageMarkers" $ do
    it "appends the caption when one exists" $ do
      let caps = Map.fromList [(8001 :: Int64, ["一张报错截图" :: Text])]
      (tagImageMarkers caps (Set.fromList [8001]) (historyAt 9 8001 memberId (Just "Alice") "看 [image]")).renderedText
        `shouldBe` "看 [image#8001: 一张报错截图]"

    it "falls back to the bare handle without a caption" $
      (tagImageMarkers Map.empty (Set.fromList [8001]) (historyAt 9 8001 memberId (Just "Alice") "看 [image]")).renderedText
        `shouldBe` "看 [image#8001]"

    it "consumes captions left-to-right across several markers" $ do
      let caps = Map.fromList [(8001 :: Int64, ["图一" :: Text])]
      (tagImageMarkers caps (Set.fromList [8001]) (historyAt 9 8001 memberId (Just "Alice") "[image] 和 [image]")).renderedText
        `shouldBe` "[image#8001: 图一] 和 [image#8001]"

    it "does not touch untagged messages" $ do
      let caps = Map.fromList [(8001 :: Int64, ["图一" :: Text])]
      (tagImageMarkers caps Set.empty (historyAt 9 8001 memberId (Just "Alice") "看 [image]")).renderedText
        `shouldBe` "看 [image]"

  describe "applyVideoCaptions" $ do
    it "renders description in the colon slot and duration as a paren attribute" $ do
      let caps = Map.fromList [(8002 :: Int64, [(Just "猫打键盘" :: Maybe Text, Just "29 秒" :: Maybe Text)])]
      (applyVideoCaptions caps (historyAt 9 8002 memberId (Just "Alice") "[video#8002] 好活")).renderedText
        `shouldBe` "[video#8002: 猫打键盘](29 秒) 好活"

    it "renders duration alone when no caption yet" $ do
      let caps = Map.fromList [(8002 :: Int64, [(Nothing :: Maybe Text, Just "29 秒" :: Maybe Text)])]
      (applyVideoCaptions caps (historyAt 9 8002 memberId (Just "Alice") "[video#8002] 好活")).renderedText
        `shouldBe` "[video#8002](29 秒) 好活"

    it "leaves the handle alone without a caption" $
      (applyVideoCaptions Map.empty (historyAt 9 8002 memberId (Just "Alice") "[video#8002] 好活")).renderedText
        `shouldBe` "[video#8002] 好活"

  describe "renderContext poke turns" $ do
    it "names the poker and shows no message line" $ do
      let pokeGm =
            (triggerMsg [])
              { messageId = MessageId 0,
                sender = Sender (UserId memberId) (Just "Alice") Nothing
              }
          inp = baseInputs {origin = OriginPoke, triggerMessage = pokeGm}
          (_, ub) = splitMessages (renderContext inp)
      ub `shouldSatisfy` ("[current message — 戳一戳]" `T.isInfixOf`)
      ub `shouldSatisfy` ("Alice 戳了戳你" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("[#0]" `T.isInfixOf`))

  describe "ContextSnapshot → ContextPlan → renderer" $ do
    it "preserves the existing byte output under a generous budget" $ do
      let plan = planContext generousLimits (snapshot baseInputs)
      map show (renderContextPlan plan) `shouldBe` map show (renderContext baseInputs)
      plan.cpWithinBudget `shouldBe` True

    it "is deterministic for the same snapshot and policy version" $ do
      let inputs =
            baseInputs
              { transcript =
                  [ historyAt 9 100 memberId (Just "Alice") "first",
                    historyAt 10 101 otherMemberId (Just "Bob") "second"
                  ],
                groupMemories = [memAt 10 "remember this"]
              }
          first = planContext generousLimits (snapshot inputs)
          second = planContext generousLimits (snapshot inputs)
      map show (renderContextPlan first) `shouldBe` map show (renderContextPlan second)
      first.cpEstimatedPromptTokens `shouldBe` second.cpEstimatedPromptTokens
      first.cpTrace `shouldBe` second.cpTrace
      first.cpPolicyVersion `shouldBe` second.cpPolicyVersion

    it "sizes the raw tail by estimated tokens rather than a message count" $ do
      let short = historyAt 10 102 otherMemberId (Just "Bob") "short"
          veryLong = historyAt 9 101 memberId (Just "Alice") (T.replicate 6000 "汉")
          shortOnly = baseInputs {transcript = [short]}
          shortPlan = planContext generousLimits (snapshot shortOnly)
          tightLimits = ContextLimits shortPlan.cpEstimatedPromptTokens 512 0 0
          pressured = planContext tightLimits (snapshot baseInputs {transcript = [veryLong, short]})
      map (.messageId) (cpInputs pressured).transcript `shouldBe` [short.messageId]
      pressured.cpWithinBudget `shouldBe` True
      pressured.cpTrace
        `shouldSatisfy` any (\trace -> trace.ctSource == "history.raw" && trace.ctDecision == ContextDropped)

    it "drops active semantic memory before protected recent raw context" $ do
      let recent = historyAt 10 102 otherMemberId (Just "Bob") "keep the live line"
          rawOnly = baseInputs {transcript = [recent]}
          rawPlan = planContext generousLimits (snapshot rawOnly)
          tightLimits = ContextLimits rawPlan.cpEstimatedPromptTokens 512 0 0
          pressured =
            planContext
              tightLimits
              (snapshot rawOnly {groupMemories = [memAt 20 (T.replicate 1000 "old memory ")]})
      map (.messageId) (cpInputs pressured).transcript `shouldBe` [recent.messageId]
      (cpInputs pressured).groupMemories `shouldSatisfy` null
      pressured.cpWithinBudget `shouldBe` True

    it "reports an over-budget plan when only protected sources remain" $ do
      let plan = planContext (ContextLimits 1 512 0 0) (snapshot baseInputs)
      plan.cpWithinBudget `shouldBe` False
      plan.cpTrace
        `shouldSatisfy` any (\trace -> trace.ctSource == "prompt.total" && trace.ctDecision == ContextOverBudget)

    it "renders a tiered compartment prefix before the token-sized raw tail" $ do
      let raw = historyAt 11 101 otherMemberId (Just "Bob") "live tail"
          old = compartmentAt 1 (UTCTime (fromGregorian 2025 1 1) 0) 0.1 "old P1" "old P2" "old P3"
          recent = compartmentAt 2 (timeAt 10) 0.5 "recent P1" "recent P2" "recent P3"
          plan = planContext generousLimits (tieredSnapshot baseInputs {compartments = [old, recent], transcript = [raw]})
          (_, body) = splitMessages (renderContextPlan plan)
      map (.contextTier) (cpInputs plan).compartments `shouldBe` [TierP4, TierP1]
      body `shouldSatisfy` ("[episode#00000000-0000-0000-0000-000000000002" `T.isInfixOf`)
      body `shouldSatisfy` ("recent P1" `T.isInfixOf`)
      body `shouldSatisfy` (not . ("old P3" `T.isInfixOf`))
      body `shouldSatisfy` ("live tail" `T.isInfixOf`)

    it "degrades all compartment fidelity before dropping the raw tail" $ do
      let raw = historyAt 11 101 otherMemberId (Just "Bob") "protected live tail"
          rawPlan = planContext generousLimits (tieredSnapshot baseInputs {transcript = [raw]})
          tightLimits = ContextLimits rawPlan.cpEstimatedPromptTokens 512 0 0
          large = compartmentAt 1 (timeAt 10) 0.5 (T.replicate 4000 "P1 ") (T.replicate 2000 "P2 ") (T.replicate 500 "P3 ")
          pressured = planContext tightLimits (tieredSnapshot baseInputs {compartments = [large], transcript = [raw]})
      map (.messageId) (cpInputs pressured).transcript `shouldBe` [raw.messageId]
      map (.contextTier) (cpInputs pressured).compartments `shouldBe` [TierP4]
      pressured.cpTrace
        `shouldSatisfy` any (\trace -> trace.ctSource == "history.compartment.p3->p4" && trace.ctDecision == ContextDropped)

compartmentAt :: Int64 -> UTCTime -> Double -> Text -> Text -> Text -> ContextCompartment
compartmentAt cid ended importance p1 p2 p3 =
  ContextCompartment
    { contextCompartmentId = cid,
      contextExpandHandle = episodeHandleAt cid,
      contextStartedAt = ended,
      contextEndedAt = ended,
      contextImportance = importance,
      contextConfidence = 1,
      contextMaterializationVersion = cid,
      contextSummaryP1 = p1,
      contextSummaryP2 = p2,
      contextSummaryP3 = p3,
      contextTier = TierP1
    }

episodeHandleAt :: Int64 -> EpisodeHandle
episodeHandleAt cid =
  fromMaybe
    (error "invalid episode handle fixture")
    (parseEpisodeHandle ("00000000-0000-0000-0000-" <> T.justifyRight 12 '0' (T.pack (show cid))))

snapshot :: PromptInputs -> ContextSnapshot
snapshot inputs = ContextSnapshot (ContextCandidates inputs) Nothing Nothing

tieredSnapshot :: PromptInputs -> ContextSnapshot
tieredSnapshot inputs =
  ContextSnapshot
    (ContextCandidates (inputs {compartments = applyBaseCompartmentTiers inputs.now inputs.compartments}))
    (Just 1)
    (Just "initial_materialization")

generousLimits :: ContextLimits
generousLimits = ContextLimits 200000 4096 0 0
