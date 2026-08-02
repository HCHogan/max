-- |
-- Deterministic source for @docs/prompt-flow.md@.
--
-- The fixture stops at the system boundaries the runtime already exposes:
-- 'Max.Prompt.planContext' and 'Max.Prompt.renderContextPlan' own prompt planning/rendering,
-- 'Max.Effects.Agent.assembleToolRound' owns the agent-loop transition, and
-- 'Max.Effects.LLM.requestBodyFor' owns protocol encoding.  No documentation
-- copy of any of those rules exists here; this module only supplies stable
-- input data and Markdown framing around their output.
module Max.PromptFlow
  ( renderPromptFlow,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( Day,
    LocalTime (..),
    TimeOfDay (..),
    TimeZone,
    UTCTime,
    fromGregorian,
    localTimeToUTC,
    minutesToTimeZone,
  )
import Data.Vector qualified as V
import Max.Config qualified as Config
import Max.DB.Calls (redactDataUrls)
import Max.DB.Files (FileRecord (..))
import Max.DB.History (HistoryItem (..))
import Max.Effects.Agent (assembleToolRound, toolResultMessage)
import Max.Effects.Blob (blobRefFromSha256)
import Max.Effects.LLM
  ( ChatMessage,
    ToolCall (..),
    ToolSpec,
    requestBodyFor,
  )
import Max.Effects.ToolOutput (InlineMedia (..))
import Max.MemoryStore (MemoryId (..), MemoryItem (..), MemoryVersion (..))
import Max.ModelCatalog (ContextLimits (..))
import Max.ModelCatalog.Internal (LLMProfile (..), Protocol (..))
import Max.Prompt (ContextSnapshot (..), PromptImage (..), PromptInputs (..), TriggerOrigin (..), planContext, renderContextPlan)
import Max.Session (Session (..))
import Max.Tools.Images (viewImageSpec)
import Max.Tools.Video (viewVideoSpec)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..), VideoSegInfo (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

renderPromptFlow :: Text
renderPromptFlow =
  T.unlines $
    [ "<!-- GENERATED FILE: cabal run max-prompt-flow. DO NOT EDIT BY HAND. -->",
      "",
      "# Prompt 全流程：从 effect 边界生成的真实 wire JSON",
      "",
      "> 本文由 `max-prompt-flow` 确定性生成。它直接复用生产代码中的",
      "> `Max.Prompt.planContext` / `renderContextPlan`、`Max.Effects.Agent.assembleToolRound` 和",
      "> `Max.Effects.LLM.requestBodyFor`；因此 prompt、工具轮或协议编码变化后，",
      "> 重新生成会把变化原样带进本文。base64 已由运行时同一个 redactor 截断。",
      "",
      "更新文档：",
      "",
      "```sh",
      "cabal run max-prompt-flow",
      "```",
      "",
      "只检查而不写文件（测试和 CI 也会做同一项检查）：",
      "",
      "```sh",
      "cabal run max-prompt-flow -- --check",
      "```",
      "",
      "## 生成路径",
      "",
      "```text",
      "DB / PlatformApi effects",
      "        │",
      "        ▼",
      "ContextCollector ──▶ ContextSnapshot",
      "                           │",
      "                           ▼",
      "                 ContextPolicy + ContextBudget",
      "                           │",
      "                           ▼",
      "                    ContextPlan + trace",
      "                           │ PromptRenderer",
      "                           ▼",
      "                     [ChatMessage]",
      "                                      │",
      "                        Agent tool loop│ assembleToolRound",
      "                                      ▼",
      "                              [ChatMessage] + tool turns",
      "                                      │",
      "                                      ▼",
      "                         LLM.requestBodyFor(profile)",
      "                                      │",
      "                    ┌─────────────────┼──────────────────┐",
      "                    ▼                 ▼                  ▼",
      "             Chat Completions   Anthropic Messages   Responses API",
      "```",
      "",
      "这里用固定的多模态群聊 fixture：群历史、pin、引用文件、两类 memory、",
      "技能索引、当前图片/视频都存在。工具表刻意只保留 `view_image` 和",
      "`view_video`，让 JSON 仍可阅读；这两个 schema 直接取自工具实现，不是文档副本。",
      "第一轮模型调用 `view_image(message_id=7405)`，第二轮展示 agent 追加",
      "assistant 原文、tool result 和真实图片块后的完整请求。",
      ""
    ]
      <> concatMap renderProtocol ([minBound .. maxBound] :: [Protocol])
      <> [ "## 不随协议改变的 loop 语义",
           "",
           "- `ChatMessage` 是 Prompt、Agent、LLM 三层之间唯一的协议中立表示。",
           "- 工具调用返回后，assistant 原文逐字保留；tool result 先配对，附件再作为一条 user blocks 消息追加。",
           "- 后续请求重发完整消息前缀。OpenAI/Anthropic/Responses 只在最外层 wire 编码不同。",
           "- 文档中的请求使用 `stream: false`，便于展示缓冲形状；流式路径复用同一批字段 builder，只额外切换 stream 字段。"
         ]

renderProtocol :: Protocol -> [Text]
renderProtocol protocol =
  [ "## " <> protocolTitle protocol,
    "",
    "请求地址：`POST " <> endpoint protocol <> "`",
    "",
    "### 请求 #1",
    "",
    jsonFence (wireRequest protocol initialMessages),
    "",
    "### 工具调用返回后",
    "",
    "下面是 provider assistant payload；Agent 会原样保存它，再执行工具：",
    "",
    jsonFence (redactDataUrls raw),
    "",
    "### 请求 #2",
    "",
    jsonFence (wireRequest protocol nextMessages),
    ""
  ]
  where
    (raw, tc) = toolCallFixture protocol
    nextMessages =
      initialMessages
        <> assembleToolRound
          raw
          [tc]
          [toolResultMessage tc (Right toolResult)]
          [toolImage]

wireRequest :: Protocol -> [ChatMessage] -> Value
wireRequest protocol messages =
  redactDataUrls (requestBodyFor (profileFor protocol) messages representativeTools False)

representativeTools :: [ToolSpec]
representativeTools = [viewImageSpec, viewVideoSpec]

profileFor :: Protocol -> LLMProfile
profileFor protocol =
  LLMProfile
    { baseUrl = base,
      apiKey = "<redacted>",
      model = modelName,
      maxInputTokens = 32768,
      maxTokens = 4096,
      attachmentReserve = 4096,
      toolRoundReserve = 4096,
      temperature = Nothing,
      effort = effortLevel,
      timeoutSeconds = 120,
      protocol = protocol,
      multimodal = True,
      historyAsTurns = False,
      stream = False
    }
  where
    (base, modelName, effortLevel) = case protocol of
      ProtocolOpenAI -> ("https://llm.example/v1", "kimi-k2.7-code", Nothing)
      ProtocolAnthropic -> ("https://api.anthropic.example", "claude-opus", Just "high")
      ProtocolResponses -> ("https://api.openai.example/v1", "gpt-5", Just "high")

protocolTitle :: Protocol -> Text
protocolTitle = \case
  ProtocolOpenAI -> "OpenAI Chat Completions"
  ProtocolAnthropic -> "Anthropic Messages"
  ProtocolResponses -> "OpenAI Responses"

endpoint :: Protocol -> Text
endpoint = \case
  ProtocolOpenAI -> "https://llm.example/v1/chat/completions"
  ProtocolAnthropic -> "https://api.anthropic.example/v1/messages"
  ProtocolResponses -> "https://api.openai.example/v1/responses"

toolCallFixture :: Protocol -> (Value, ToolCall)
toolCallFixture = \case
  ProtocolOpenAI ->
    ( object
        [ "role" .= ("assistant" :: Text),
          "content" .= Null,
          "reasoning_content" .= ("先看历史里的波形图是否是同一类问题。" :: Text),
          "tool_calls"
            .= [ object
                   [ "id" .= callId,
                     "type" .= ("function" :: Text),
                     "function"
                       .= object
                         [ "name" .= toolName,
                           "arguments" .= ("{\"message_id\":7405}" :: Text)
                         ]
                   ]
               ]
        ],
      toolCall callId
    )
    where
      callId = "call_abc123"
  ProtocolAnthropic ->
    ( object
        [ "role" .= ("assistant" :: Text),
          "content"
            .= [ object
                   [ "type" .= ("thinking" :: Text),
                     "thinking" .= ("先核对相关波形。" :: Text),
                     "signature" .= ("fixture-signature" :: Text)
                   ],
                 object
                   [ "type" .= ("text" :: Text),
                     "text" .= ("我先把前面的波形原图翻出来。" :: Text)
                   ],
                 object
                   [ "type" .= ("tool_use" :: Text),
                     "id" .= callId,
                     "name" .= toolName,
                     "input" .= toolArgs
                   ]
               ]
        ],
      toolCall callId
    )
    where
      callId = "toolu_01fixture"
  ProtocolResponses ->
    ( toJSON
        [ object
            [ "type" .= ("reasoning" :: Text),
              "id" .= ("rs_fixture" :: Text),
              "encrypted_content" .= ("encrypted-fixture" :: Text),
              "summary" .= ([] :: [Value])
            ],
          object
            [ "type" .= ("function_call" :: Text),
              "id" .= ("fc_fixture" :: Text),
              "call_id" .= callId,
              "name" .= toolName,
              "arguments" .= ("{\"message_id\":7405}" :: Text),
              "status" .= ("completed" :: Text)
            ]
        ],
      toolCall callId
    )
    where
      callId = "call_fixture"
  where
    toolName = "view_image"
    toolArgs = object ["message_id" .= (7405 :: Int)]
    toolCall cid = ToolCall cid toolName toolArgs

toolResult :: Value
toolResult =
  object
    [ "attached" .= (1 :: Int),
      "total" .= (1 :: Int),
      "note" .= ("图片已附在下一条消息里" :: Text)
    ]

toolImage :: InlineMedia
toolImage =
  InlineMedia
    { imLabel = "[22:52 老张] 消息里的图片:",
      imDataUrl = "data:image/jpeg;base64,dG9vbC1pbWFnZQ=="
    }

initialMessages :: [ChatMessage]
initialMessages =
  renderContextPlan $
    planContext
      (ContextLimits 32768 4096 4096 4096)
      (ContextSnapshot promptFixture 1000 2000)

promptFixture :: PromptInputs
promptFixture =
  PromptInputs
    { defaultPersona = Config.defaultPersona,
      session = fixtureSession,
      triggerMessage = fixtureTrigger,
      transcript = fixtureTranscript,
      historyTurns = False,
      inFlight = Set.empty,
      pinnedItems = [history 7301 777888999 "老张" 19 2 "本群入门资料汇总 [file:STM32入门.pdf] 新人先看这个"],
      replyCtx = Just (quotedMessage, [quotedFile], []),
      triggerForward = [],
      multimodal = True,
      origin = OriginDirect,
      groupBrief =
        [ "群名：单片机与嵌入式交流（47人）",
          "群主：老张（777888999）；管理员：阿飞（223344556）"
        ],
      groupMemories = [memory 12 "group" 114514191 "群里主要玩 STM32 和 ESP32，老张是硬件老师傅"],
      userMemories = [memory 31 "user" 223344556 "阿飞在做一个 LoRa 气象站毕设"],
      images =
        [ PromptImage "[↩ quoted message（22:45 阿飞）] 里的图片:" "data:image/jpeg;base64,cXVvdGVkLWltYWdl",
          PromptImage "[current message] 里的图片:" "data:image/png;base64,Y3VycmVudC1pbWFnZQ==",
          PromptImage "[current message] 里的视频（时长 29 秒）:" "data:video/mp4;base64,Y3VycmVudC12aWRlbw=="
        ],
      skills =
        [ ("self-knowledge", "Max 自身实现、部署和命令的现行说明"),
          ("sandbox", "在隔离容器中处理代码、数据和文件的流程")
        ],
      now = hkAt 23 10,
      tz = hkTimeZone
    }

fixtureSession :: Session
fixtureSession =
  Session
    { groupId = GroupId 114514191,
      model = "kimi-k2.7-code",
      persona = Nothing,
      clearedAt = Nothing,
      contextAnchor = Nothing,
      pinned = [7301],
      debugOverride = Nothing,
      stickerOverride = Nothing,
      proactiveOverride = Nothing,
      memxAnchor = Nothing,
      effortOverride = Nothing
    }

fixtureTrigger :: GroupMessage
fixtureTrigger =
  GroupMessage
    { selfId = UserId 10086,
      groupId = GroupId 114514191,
      userId = UserId 223344556,
      messageId = MessageId 7413,
      message =
        [ SegReply (MessageId 7398),
          SegAt (UserId 10086),
          SegText "看看这个报错是啥问题，视频里是复位后的现象 ",
          SegImage (ImageSegInfo Nothing (Just 0) Nothing),
          SegText " ",
          SegVideo (VideoSegInfo "fixture.mp4" Nothing Nothing)
        ],
      rawMessage = "",
      sender = Sender (UserId 223344556) (Just "阿飞") Nothing
    }

fixtureTranscript :: [HistoryItem]
fixtureTranscript =
  [ history 7402 445566778 "小美" 22 48 "今晚有人打游戏吗",
    history 7404 777888999 "老张" 22 50 "[↩#7402] 不打，在调板子",
    history 7405 777888999 "老张" 22 52 "我这个波形好怪 [image#7405: 示波器截图，黄色方波上升沿明显圆角]",
    history 7406 445566778 "小美" 22 53 "[sticker#212: 猫猫瞪大眼睛凑近屏幕]",
    history 7407 777888999 "老张" 22 54 "拍了段视频你们看 [video#7407: 首帧是一块面包板电路](42秒)",
    history 7408 10086 "Max" 22 55 "[↩#7405] 上升沿圆角一般是探头电容补偿没调，或者还挂在 1X 档",
    history 7409 223344556 "阿飞" 22 56 "[card: 哔哩哔哩 | 示波器探头 10X 档到底干嘛用的 | https://b23.tv/fixture]",
    history 7410 223344556 "阿飞" 22 57 "[face#187: 幽灵] 我的板子也出鬼畜问题了",
    history 7411 445566778 "小美" 22 58 "楼上俩难兄难弟 ⏎ 建议直接烧了重买"
  ]

quotedMessage :: HistoryItem
quotedMessage = history 7398 223344556 "阿飞" 22 45 "烧录完就这样了，串口一直打这个 [image]"

quotedFile :: FileRecord
quotedFile =
  FileRecord
    { frFileId = "c8a3f2d1e0",
      frGroupId = 114514191,
      frMessageId = Just 7398,
      frSenderUserId = 223344556,
      frFileName = "firmware.bin",
      frMimeType = Just "application/octet-stream",
      frBytesSize = Just 2188038,
      frBlobRef = blobRefFromSha256 (T.replicate 64 "a"),
      frReceivedAt = hkAt 22 45,
      frFetchedAt = Just (hkAt 22 46)
    }

history :: Int64 -> Int64 -> Text -> Int -> Int -> Text -> HistoryItem
history mid uid name hour minute body =
  HistoryItem
    { messageId = mid,
      userId = uid,
      selfId = 10086,
      senderNickname = Just name,
      senderCard = Nothing,
      renderedText = body,
      receivedAt = hkAt hour minute,
      replyTo = Nothing
    }

memory :: Int64 -> Text -> Int64 -> Text -> MemoryItem
memory mid scope sid body =
  MemoryItem
    { memId = MemoryId mid,
      memVersion = MemoryVersion 1,
      memScope = scope,
      memScopeId = sid,
      memContent = body,
      memLifecycle = "active",
      memCategory = Nothing,
      memUpdatedAt = hkAt 12 0
    }

fixtureDay :: Day
fixtureDay = fromGregorian 2026 7 22

hkTimeZone :: TimeZone
hkTimeZone = minutesToTimeZone 480

hkAt :: Int -> Int -> UTCTime
hkAt hour minute =
  localTimeToUTC hkTimeZone (LocalTime fixtureDay (TimeOfDay hour minute 0))

jsonFence :: Value -> Text
jsonFence value = "```json\n" <> prettyJson value <> "\n```"

-- | Small canonical pretty-printer: object keys are sorted so generated
-- docs do not churn with KeyMap implementation details.  Scalar encoding
-- still goes through Aeson, including all string escaping and number rules.
prettyJson :: Value -> Text
prettyJson = go 0
  where
    go depth = \case
      Object o
        | KM.null o -> "{}"
        | otherwise ->
            "{\n"
              <> T.intercalate
                ",\n"
                [ indent (depth + 1) <> scalar (String (Key.toText k)) <> ": " <> go (depth + 1) v
                | (k, v) <- sortOn (Key.toText . fst) (KM.toList o)
                ]
              <> "\n"
              <> indent depth
              <> "}"
      Array a
        | V.null a -> "[]"
        | otherwise ->
            "[\n"
              <> T.intercalate
                ",\n"
                [indent (depth + 1) <> go (depth + 1) v | v <- V.toList a]
              <> "\n"
              <> indent depth
              <> "]"
      v -> scalar v
    indent n = T.replicate n "  "
    scalar = TE.decodeUtf8 . LBS.toStrict . encode
