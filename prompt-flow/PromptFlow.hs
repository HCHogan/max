-- |
-- Deterministic source for @docs/prompt-flow.md@.
--
-- The fixture stops at the system boundaries the runtime already exposes:
-- 'Max.Prompt.planContext' and 'Max.Prompt.renderContextPlan' own prompt planning/rendering,
-- 'Max.Effects.Agent.assembleToolRound' owns the agent-loop transition, and
-- 'Max.Effects.LLM.requestBodyFor' owns protocol encoding.  No documentation
-- copy of any of those rules exists here; this module only supplies stable
-- input data and Markdown framing around their output.
module PromptFlow
  ( renderPromptFlow,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
import Max.Context.Types (ContextCandidates (..))
import Max.DB.Calls (redactDataUrls)
import Max.DB.Files (FileRecord (..))
import Max.DB.History (HistoryItem (..), LedgerItem (LedgerItem), MessageCursor (..))
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.Agent (assembleToolRound, toolResultMessage)
import Max.Effects.Blob (blobRefFromSha256)
import Max.Effects.LLM
  ( ChatMessage (..),
    ContentBlock (..),
    ToolCall (..),
    ToolSpec,
    requestBodyFor,
  )
import Max.Effects.ToolOutput (InlineMedia (..))
import Max.EpisodeStore (EpisodeExpansion (..), EpisodeHandle, SourceRange (..), parseEpisodeHandle)
import Max.MemoryStore (MemoryId (..), MemoryItem (..), MemoryVersion (..))
import Max.ModelCatalog (ContextLimits (..), LLMProfile (..), Protocol (..), defaultContextLimits)
import Max.IR (Body (..), MediaKind (..), MediaMeta (..), MentionTarget (..), Node (..))
import Max.Platform.Types (CanonicalMessageId (..), Platform (PlatformQQ), PrincipalId (..), PrincipalIdentityId (..), qqAdvertisedCaps)
import Max.Prompt (CompartmentTier (..), ContextCompartment (..), ContextSnapshot (..), PromptImage (..), PromptInputs (..), TriggerOrigin (..), planContext, renderContextPlan)
import Max.Recall (RecallHit (..))
import Max.Session (Session (..))
import Max.Tools (contextSearchSummary, episodeExpansionSummary)
import Max.Tools.Images (viewImageSpec)
import Max.Tools.Video (viewVideoSpec)
import OneBot.Types (GroupId (..), UserId (..))

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
      "DB / PlatformApi / EpisodeStore effects",
      "        │",
      "        ▼",
      "ContextCollector ──▶ ContextMaterialization CAS (tiered history)",
      "        │                        │ revision + exact raw cursor",
      "        └────────────────────────▼",
      "                         ContextSnapshot",
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
      "P1/P2/P3/P4 episode、技能索引、当前图片/视频都存在。工具表刻意只保留 `view_image` 和",
      "`view_video`，让 JSON 仍可阅读；这两个 schema 直接取自工具实现，不是文档副本。",
      "第一轮模型调用 `view_image(message_id=7405)`，第二轮展示 agent 追加",
      "assistant 原文、tool result 和真实图片块后的完整请求。",
      ""
    ]
      <> renderEpisodeLifecycle
      <> concatMap renderProtocol ([minBound .. maxBound] :: [Protocol])
      <> [ "## 不随协议改变的 loop 语义",
           "",
           "- `ChatMessage` 是 Prompt、Agent、LLM 三层之间唯一的协议中立表示。",
           "- 工具调用返回后，assistant 原文逐字保留；tool result 先配对，附件再作为一条 user blocks 消息追加。",
           "- 后续请求重发完整消息前缀。OpenAI/Anthropic/Responses 只在最外层 wire 编码不同。",
           "- 文档中的请求使用 `stream: false`，便于展示缓冲形状；流式路径复用同一批字段 builder，只额外切换 stream 字段。"
         ]

-- | Protocol-neutral context lifecycle around the same production prompt
-- renderer.  Search/expand database effects are represented by fixed typed
-- results, then passed through the live model-facing result renderers.
renderEpisodeLifecycle :: [Text]
renderEpisodeLifecycle =
  [ "## Episode 分代、搜索与展开",
    "",
    "这一段展示同一个 episode 如何从稳定 prompt 中的摘要，变成一次性的原文工具结果。",
    "fixture 中最老的低功耗调试 episode 已衰减到 P4，因此首轮 prompt 不显示它；",
    "`context_search` 仍能返回其 opaque handle，`context_expand` 再按当前会话权限恢复原始 ledger。",
    "搜索和展开的固定 typed fixture 都经过生产 `Max.Tools` 的结果 renderer。",
    "",
    "### 首轮 prompt：P1/P2/P3 + raw tail",
    "",
    "```text",
    episodePromptExcerpt,
    "```",
    "",
    "P4 的 `aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa` 没有出现在上面；它只是不渲染，",
    "不是被删除，也没有失去检索和展开能力。",
    "",
    "### 模型调用 `context_search`",
    "",
    jsonFence (object ["query" .= contextQuery, "limit" .= (5 :: Int)]),
    "",
    "工具返回：",
    "",
    jsonFence contextSearchFixture,
    "",
    "### 模型调用 `context_expand`",
    "",
    jsonFence (object ["handle" .= contextHandleText, "limit" .= (40 :: Int)]),
    "",
    "工具返回原始消息及身份、reply、cursor 和 hash 状态：",
    "",
    jsonFence contextExpandFixture,
    "",
    "这个 JSON 只作为当前 agent turn 的 tool result 进入下一轮请求。turn 结束后它不会写回",
    "稳定 prompt；下一个独立 dispatch 仍从上面的 P1/P2/P3 + raw tail 开始，P4 继续按需搜索。",
    ""
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
      maxInputTokens = defaultContextLimits.maxInputTokens,
      maxTokens = defaultContextLimits.reservedOutputTokens,
      attachmentReserve = defaultContextLimits.attachmentReserve,
      toolRoundReserve = defaultContextLimits.toolRoundReserve,
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
      defaultContextLimits
      (ContextSnapshot (ContextCandidates promptFixture) Nothing Nothing)

promptFixture :: PromptInputs
promptFixture =
  PromptInputs
    { defaultPersona = Config.defaultPersona,
      session = fixtureSession,
      triggerMessage = fixtureTrigger,
      recentTurns = ["t#42 14:32 ✓「画了销量周环比图」 · 5 tools · sandbox s1 ↦ #1234"],
      continuationView = Nothing,
      transcript = fixtureTranscript,
      compartments = fixtureCompartments,
      historyTurns = False,
      inFlight = Set.empty,
      pinnedItems = [history 7301 5 "老张" 19 2 "本群入门资料汇总 [file:STM32入门.pdf] 新人先看这个"],
      replyCtx = Just (quotedMessage, [quotedFile], []),
      triggerForward = [],
      multimodal = True,
      outputCapabilities = qqAdvertisedCaps,
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
        [ ("self-knowledge", "自知总入口：inspect_source 源码快照的导航图与实时命令帮助"),
          ("sandbox", "在隔离容器中处理代码、数据和文件的流程")
        ],
      now = hkAt 23 10,
      tz = hkTimeZone
    }

fixtureCompartments :: [ContextCompartment]
fixtureCompartments =
  [ compartment
      101
      contextEpisodeHandle
      (dayAt 2025 1 11 20 4)
      (dayAt 2025 1 11 20 18)
      0.35
      hiddenP4SummaryP1
      hiddenP4SummaryP2
      "LoRa 气象站曾解决 STOP2 唤醒后复位问题。"
      TierP4,
    compartment
      102
      (fixtureHandle "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
      (dayAt 2026 3 2 19 20)
      (dayAt 2026 3 2 20 6)
      0.48
      "群里比较 STM32L4 和 ESP32-S3 后，决定气象站主控继续使用 STM32L4；老张负责原理图复核，阿飞先验证低功耗和 LoRa 唤醒链路。"
      "气象站主控确定为 STM32L4，先验证低功耗与 LoRa 唤醒。"
      "群里确定 LoRa 气象站的主控和验证顺序。"
      TierP3,
    compartment
      103
      (fixtureHandle "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
      (dayAt 2026 6 5 21 10)
      (dayAt 2026 6 5 22 3)
      0.66
      "阿飞完成 LoRa 气象站首版通信协议；节点每五分钟上报温湿度和电池电压，网关按 sequence 去重。老张要求掉线重连不得重放旧采样，Max 给出状态机测试清单。"
      "LoRa 气象站确定五分钟上报、sequence 去重和重连不重放旧采样。"
      "群里敲定气象站 LoRa 上报协议。"
      TierP2,
    compartment
      104
      (fixtureHandle "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
      (dayAt 2026 7 20 22 14)
      (dayAt 2026 7 20 22 42)
      0.82
      "阿飞的新固件在复位后持续进入 HardFault，串口 PC 指向 DMA 完成回调。老张怀疑 buffer 生命周期，Max 建议先保留 fault frame、反汇编 PC 并检查链接脚本；阿飞承诺补 map 文件和最小复现。"
      "气象站新固件复位后进入 HardFault，当前在核对 DMA buffer、fault frame、map 文件和链接脚本。"
      "气象站固件出现 HardFault，等待 map 文件定位。"
      TierP1
  ]
  where
    compartment cid handle started ended importance p1 p2 p3 tier =
      ContextCompartment
        { contextCompartmentId = cid,
          contextExpandHandle = handle,
          contextStartedAt = started,
          contextEndedAt = ended,
          contextImportance = importance,
          contextConfidence = 0.92,
          contextMaterializationVersion = cid - 100,
          contextSummaryP1 = p1,
          contextSummaryP2 = p2,
          contextSummaryP3 = p3,
          contextTier = tier
        }

hiddenP4SummaryP1 :: Text
hiddenP4SummaryP1 =
  "阿飞测试 STOP2 时发现节点唤醒后立即复位。老张指出 NRST 上的 100nF 电容与长 ST-Link 排线让复位沿过慢，建议先换成 10nF 并缩短排线；修改后连续唤醒 200 次稳定。"

hiddenP4SummaryP2 :: Text
hiddenP4SummaryP2 =
  "气象站 STOP2 唤醒复位由 NRST 100nF 电容和长 ST-Link 排线导致；改为 10nF 后恢复稳定。"

contextQuery :: Text
contextQuery = "气象站 STOP2 唤醒后复位 NRST 电容 当时怎么解决"

contextHandleText :: Text
contextHandleText = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

contextEpisodeHandle :: EpisodeHandle
contextEpisodeHandle = fixtureHandle contextHandleText

fixtureHandle :: Text -> EpisodeHandle
fixtureHandle raw =
  fromMaybe (error "invalid prompt-flow episode handle fixture") (parseEpisodeHandle raw)

contextSearchFixture :: Value
contextSearchFixture =
  contextSearchSummary
    hkTimeZone
    contextQuery
    True
    [ RecallHit
        { rhSource = "episode",
          rhDedupKey = "episode:101",
          rhSnippet = hiddenP4SummaryP2,
          rhOccurredAt = dayAt 2025 1 11 20 18,
          rhPrincipalId = Nothing,
          rhMessageId = Nothing,
          rhEpisodeHandle = Just contextEpisodeHandle,
          rhMemoryId = Nothing,
          rhScore = 0.94,
          rhLexicalScore = Just 0.71,
          rhSemanticScore = Just 0.91,
          rhPinned = False,
          rhPermanent = False
        },
      RecallHit
        { rhSource = "message",
          rhDedupKey = "message:7213",
          rhSnippet = "换 10nF 再把 ST-Link 排线拔掉试试，100nF 这个沿太慢了。",
          rhOccurredAt = dayAt 2025 1 11 20 12,
          rhPrincipalId = Just 777888999,
          rhMessageId = Just 7213,
          rhEpisodeHandle = Nothing,
          rhMemoryId = Nothing,
          rhScore = 0.86,
          rhLexicalScore = Just 0.62,
          rhSemanticScore = Just 0.84,
          rhPinned = False,
          rhPermanent = False
        }
    ]

contextExpandFixture :: Value
contextExpandFixture =
  episodeExpansionSummary
    hkTimeZone
    Map.empty
    EpisodeExpansion
      { expansionHandle = contextEpisodeHandle,
        expansionRange =
          SourceRange
            (MessageCursor 4100)
            (MessageCursor 4104)
            (T.replicate 64 "b")
            5,
        expansionState = "active",
        expansionSourceHashMatches = True,
        expansionMessages =
          [ episodeLedger 4100 7210 223344556 "阿飞" 20 4 "一进 STOP2，RTC 唤醒后板子就像重新上电，boot count 也清了。" Nothing,
            episodeLedger 4101 7211 777888999 "老张" 20 7 "先看 NRST 波形。你板上是不是还挂着 100nF 和那根很长的 ST-Link 排线？" (Just 7210),
            episodeLedger 4102 7212 223344556 "阿飞" 20 9 "对，NRST 是 100nF，调试器也一直插着。" (Just 7211),
            episodeLedger 4103 7213 777888999 "老张" 20 12 "换 10nF 再把 ST-Link 排线拔掉试试，100nF 这个沿太慢了。" (Just 7212),
            episodeLedger 4104 7214 223344556 "阿飞" 20 18 "好了，连续唤醒 200 次都没再复位。" (Just 7213)
          ],
        expansionHasMore = False,
        expansionNextCursor = Nothing
      }

episodeLedger :: Int64 -> Int64 -> Int64 -> Text -> Int -> Int -> Text -> Maybe Int64 -> LedgerItem
episodeLedger cursor' mid uid name hour minute body reply =
  LedgerItem
    (MessageCursor cursor')
    ((historyOn (fromGregorian 2025 1 11) mid uid name hour minute body) {replyTo = reply})
    True

episodePromptExcerpt :: Text
episodePromptExcerpt =
  let body = initialUserText
      stableHistory = takeBefore "\n[environment]" (dropBefore "[earlier conversation" body)
      current = takeBefore "\n\n请回复当前消息。" (dropBefore "[current message]" body)
   in stableHistory
        <> "\n\n… environment / memories / quoted context …\n\n"
        <> current
        <> "\n\n请回复当前消息。"

initialUserText :: Text
initialUserText =
  fromMaybe "(missing fixture user message)" $ foldr pick Nothing initialMessages
  where
    pick (MsgUser body) _ = Just body
    pick (MsgUserBlocks (TextBlock body : _)) _ = Just body
    pick _ found = found

dropBefore :: Text -> Text -> Text
dropBefore marker body = case T.breakOn marker body of
  (_, suffix) | not (T.null suffix) -> suffix
  _ -> body

takeBefore :: Text -> Text -> Text
takeBefore marker body = case T.breakOn marker body of
  (prefix, suffix) | not (T.null suffix) -> prefix
  _ -> body

fixtureSession :: Session
fixtureSession =
  Session
    { groupId = GroupId 114514191,
      model = "kimi-k2.7-code",
      persona = Nothing,
      clearedAt = Nothing,
      pinned = [7301],
      debugOverride = Nothing,
      stickerOverride = Nothing,
      proactiveOverride = Nothing,
      effortOverride = Nothing
    }

fixtureTrigger :: DispatchMessage
fixtureTrigger =
  DispatchMessage
    { selfId = UserId 10086,
      groupId = GroupId 114514191,
      userId = UserId 223344556,
      selfPrincipalId = PrincipalId 1,
      authorPrincipalId = PrincipalId 7,
      canonicalId = CanonicalMessageId 7413,
      body =
        Body
          [ NMention (MentionIdentity (PrincipalIdentityId 1)) "Max",
            NText "看看这个报错是啥问题，视频里是复位后的现象 ",
            NMedia Nothing (fixtureMedia MImage),
            NText " ",
            NMedia Nothing (fixtureMedia MVideo)
          ],
      replyTo = Just (CanonicalMessageId 7398),
      senderDisplayName = Just "阿飞",
      sourcePlatform = PlatformQQ,
      mentionPrincipals = Map.singleton (PrincipalIdentityId 1) (PrincipalId 1)
    }

fixtureMedia :: MediaKind -> MediaMeta
fixtureMedia kind =
  MediaMeta
    { kind,
      mime = Nothing,
      sizeBytes = Nothing,
      name = Nothing,
      description = Nothing,
      raw = Nothing
    }

fixtureTranscript :: [HistoryItem]
fixtureTranscript =
  [ history 7402 9 "小美" 22 48 "今晚有人打游戏吗",
    history 7404 5 "老张" 22 50 "[reply#7402] 不打，在调板子",
    history 7405 5 "老张" 22 52 "我这个波形好怪 [image#7405.1: 示波器截图，黄色方波上升沿明显圆角]",
    history 7406 9 "小美" 22 53 "[sticker#212: 猫猫瞪大眼睛凑近屏幕]",
    history 7407 5 "老张" 22 54 "拍了段视频你们看 [video#7407.1: 首帧是一块面包板电路](42秒)",
    history 7408 1 "Max" 22 55 "[reply#7405] 上升沿圆角一般是探头电容补偿没调，或者还挂在 1X 档",
    history 7409 7 "阿飞" 22 56 "[card: 哔哩哔哩 | 示波器探头 10X 档到底干嘛用的 | https://b23.tv/fixture]",
    history 7410 7 "阿飞" 22 57 "[face#187: 幽灵] 我的板子也出鬼畜问题了",
    history 7411 9 "小美" 22 58 "楼上俩难兄难弟 ⏎ 建议直接烧了重买"
  ]

quotedMessage :: HistoryItem
quotedMessage = history 7398 7 "阿飞" 22 45 "烧录完就这样了，串口一直打这个 [image]"

quotedFile :: FileRecord
quotedFile =
  FileRecord
    { frFileId = "c8a3f2d1e0",
      frGroupId = 114514191,
      frCanonicalMessageId = Just 7398,
      frSenderUserId = 223344556,
      frFileName = "firmware.bin",
      frMimeType = Just "application/octet-stream",
      frBytesSize = Just 2188038,
      frBlobRef = blobRefFromSha256 (T.replicate 64 "a"),
      frReceivedAt = hkAt 22 45,
      frFetchedAt = Just (hkAt 22 46)
    }

history :: Int64 -> Int64 -> Text -> Int -> Int -> Text -> HistoryItem
history = historyOn fixtureDay

historyOn :: Day -> Int64 -> Int64 -> Text -> Int -> Int -> Text -> HistoryItem
historyOn day mid principal name hour minute body =
  HistoryItem
    { canonicalId = mid,
      authorPrincipalId = principal,
      fromBot = principal == 1,
      senderNickname = Just name,
      senderCard = Nothing,
      renderedText = body,
      receivedAt = localTimeToUTC hkTimeZone (LocalTime day (TimeOfDay hour minute 0)),
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
hkAt = dayAt 2026 7 22

dayAt :: Integer -> Int -> Int -> Int -> Int -> UTCTime
dayAt year month day hour minute =
  localTimeToUTC hkTimeZone (LocalTime (fromGregorian year month day) (TimeOfDay hour minute 0))

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
