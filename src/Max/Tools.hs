-- | Builtin tools scoped to the current conversation. Historical retrieval
-- uses context_search rather than separate corpus-specific entry points.
module Max.Tools
  ( builtinsFor,
    contextSearchSummary,
    parseTimeArg,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Effectful.Log
import Max.Context.Capacity (readPageTokens)
import Max.Context.Read (messageRef, parseCanonicalId, parseReadRequest)
import Max.Effects.ConversationQuery
  ( ConversationQuery,
    readContext,
    searchContext,
  )
import Max.Effects.Embedding
  ( Embedding,
    embedBatch,
    renderEmbeddingFault,
  )
import Max.Effects.PlatformInteraction
  ( PlatformInteraction,
    pokeUser,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Effects.TurnQuery
  ( TurnQuery,
    expandTurnResult,
    expandTurnTrace,
  )
import Max.Embedding (EmbeddingRecord)
import Max.Episode.Types (episodeHandleText)
import Max.Memory.Types (MemoryId (..))
import Max.Platform.Failure (renderPlatformFailure)
import Max.Recall.Types (RecallFilter (..), RecallHit (..))
import Max.Time (fmtDateHM)
import Max.Time.Parse (parseTimeArg)
import Max.ToolContext (ToolContext, toolContextLimits, toolGroupId, toolMultimodal)
import Max.Tools.Schema
  ( boundedIntegerParam,
    integerParam,
    stringArrayParam,
    stringParam,
    toolObject,
  )
import Max.Tools.SelfSource (selfSourceTools)
import Max.Turn.Types (ParsedTurnHandle (..), parseTurnHandle)
import OneBot.Types (UserId (..))

builtinsFor ::
  ( ConversationQuery :> es,
    TurnQuery :> es,
    PlatformInteraction :> es,
    Embedding :> es,
    Log :> es
  ) =>
  TimeZone ->
  ToolContext ->
  [Tool es]
builtinsFor tz dc =
  selfSourceTools
    <> [ contextSearchTool tz,
         contextReadTool tz dc,
         contextResumeTool dc,
         pokeTool dc
       ]

-- | Same request and continuation objects in native calls and code mode.
contextReadTool :: (ConversationQuery :> es) => TimeZone -> ToolContext -> Tool es
contextReadTool tz dc =
  Tool
    { toolName = "context_read",
      toolDescription = "读取当前会话原文。无参数读最近消息；ref 支持 message:<id>、episode:<uuid>、memory:<id>、forward:<id>。message 可加 before/after 看上下文。episode 只是定位，prev/next 可以跨 episode；日期 [from,until) 是硬筛选，默认配置时区，也接受 Z/offset。items 按时间线顺序；原样传 prev/next 继续翻页，item.more 续读长正文。节点观察的溢出 cursor 只在所属任务本次进程内有效，续读 items.kind=node_observation 的原始事件文本。不会删除原文，不接受其他群号。",
      toolSchema =
        toolObject
          [ ("ref", stringParam "规范引用，ID 用字符串"),
            ("from", stringParam "起始日期/时间（包含）"),
            ("until", stringParam "结束日期/时间（不包含）"),
            ("before", boundedIntegerParam 0 100 0),
            ("after", boundedIntegerParam 0 100 0),
            ("limit", boundedIntegerParam 1 100 40),
            ("cursor", stringParam "原样传入返回的续读对象，不与其他参数混用")
          ]
          [],
      toolRunner = LegacyRunner $ \args -> case parseEither (parseReadRequest tz) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right request -> readContext (readPageTokens (toolContextLimits dc) (toolMultimodal dc)) request
    }

-- context_search

contextSearchTool ::
  (ConversationQuery :> es, Embedding :> es, Log :> es) =>
  TimeZone ->
  Tool es
contextSearchTool tz =
  Tool
    { toolName = "context_search",
      toolDescription =
        T.unwords
          [ "统一搜索当前会话的长期记忆、episode 摘要、原始消息、pin 和媒体简介。",
            "结果已经做 scope 过滤、混合排序、来源配额和同源去重；",
            "结果 read 对象可以直接传给 context_read；搜索是相关候选，不保证穷举。kinds 为 message/episode/memory，pin 和媒体简介归入 message。日期筛选原文按接收时间、episode 按来源范围、memory 按更新时间；sender 只返回该人原话和个人记忆。"
          ],
      toolSchema =
        toolObject
          [ ("query", stringParam "要回忆的自然语言主题或关键词"),
            ("limit", boundedIntegerParam 1 30 10),
            ("kinds", stringArrayParam "message、episode、memory；默认全部"),
            ("from", stringParam "日期/时间（包含）"),
            ("until", stringParam "日期/时间（不包含）"),
            ("sender", stringParam "规范 principal ID 字符串")
          ]
          ["query"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseRecallArgs) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right (rawQuery, limit, filters)
          | T.null (T.strip rawQuery) -> pure (Left "bad args: query cannot be blank")
          | otherwise -> do
              embedding <- bestEffortRecallEmbedding "context_search" rawQuery
              hits <- searchContext filters rawQuery embedding limit
              pure . Right $
                contextSearchSummary
                  tz
                  rawQuery
                  (isJust embedding)
                  hits
    }
  where
    parseRecallArgs o = do
      query <- o .: "query"
      limit <- o .:? "limit" .!= 10
      kinds <- o .:? "kinds" .!= ["message", "episode", "memory"]
      from <- time o "from"
      endTime <- time o "until"
      sender <- o .:? "sender" >>= traverse (either (fail . T.unpack) pure . parseCanonicalId)
      unless (limit >= 1 && limit <= 30 && all (`elem` ["message", "episode", "memory"]) kinds) (fail "invalid limit or kinds")
      case (from, endTime) of
        (Just start, Just end) | start >= end -> fail "from must precede until"
        _ -> pure ()
      pure (query, limit, RecallFilter kinds from endTime sender)
    time o key = o .:? key >>= traverse (either (fail . T.unpack) pure . parseTimeArg tz)

-- | Stable model-facing shape of unified recall results.  Kept pure so the
-- generated prompt-flow document can exercise the same renderer as the live
-- tool after its database/embedding effects have produced candidates.
contextSearchSummary :: TimeZone -> Text -> Bool -> [RecallHit] -> Value
contextSearchSummary tz rawQuery semanticUsed hits =
  object
    [ "query" .= T.strip rawQuery,
      "semantic_used" .= semanticUsed,
      "results" .= map (recallHitSummary tz) hits
    ]

bestEffortRecallEmbedding :: (Embedding :> es, Log :> es) => Text -> Text -> Eff es (Maybe EmbeddingRecord)
bestEffortRecallEmbedding caller queryText = do
  result <- embedBatch [T.strip queryText]
  case result of
    Right [record] -> pure (Just record)
    Right _ -> do
      logAttention (caller <> ": unexpected embedding shape; using lexical recall") (object [])
      pure Nothing
    Left fault -> do
      logAttention (caller <> ": embedding failed; using lexical recall") $ object ["error" .= renderEmbeddingFault fault]
      pure Nothing

recallHitSummary :: TimeZone -> RecallHit -> Value
recallHitSummary tz hit =
  object $
    [ "source" .= hit.rhSource,
      "kind" .= kind,
      "ref" .= ref,
      "read" .= object ["ref" .= ref],
      "score" .= hit.rhScore,
      "time" .= fmtDateHM tz hit.rhOccurredAt,
      "snippet" .= hit.rhSnippet,
      "pinned" .= hit.rhPinned,
      "permanent" .= hit.rhPermanent,
      "match"
        .= object
          [ "lexical" .= hit.rhLexicalScore,
            "semantic" .= hit.rhSemanticScore
          ]
    ]
      <> ["principal_id" .= T.pack (show principal) | Just principal <- [hit.rhPrincipalId]]
      <> ["message_id" .= T.pack (show message) | Just message <- [hit.rhMessageId]]
      <> ["memory_id" .= T.pack (show memory.unMemoryId) | Just memory <- [hit.rhMemoryId]]
      <> ["handle" .= episodeHandleText handle | Just handle <- [hit.rhEpisodeHandle]]
  where
    (kind, ref) = case (hit.rhSource, hit.rhMemoryId, hit.rhEpisodeHandle, hit.rhMessageId) of
      ("memory", Just mid, _, _) -> ("memory" :: Text, "memory:" <> T.pack (show mid.unMemoryId))
      ("episode", _, Just handle, _) -> ("episode", "episode:" <> episodeHandleText handle)
      (_, _, _, Just mid) -> ("message", messageRef mid)
      _ -> (hit.rhSource, hit.rhDedupKey)

-- | Reading a previous working turn does not restart or replay its effects.
contextResumeTool :: (TurnQuery :> es) => ToolContext -> Tool es
contextResumeTool dc =
  Tool
    { toolName = "context_resume",
      toolDescription = "读旧工作回合以接续当前工作：turn=t#<n> 返回执行轨迹、结果和状态；t#<n>:r<m> 或 call_id 读取完整工具结果。原样传 next 续读。只读取，不重启任务、不重放工具；旧结果不代表当前外部状态，outcome-unknown 仍需核实。",
      toolSchema =
        toolObject
          [ ("turn", stringParam "t#<n> 或 t#<n>:r<m>"),
            ("call_id", stringParam "可选工具调用 ID；有歧义时使用结果句柄"),
            ("after_cursor", integerParam "返回的分页位置；通常直接传 next"),
            ("limit", boundedIntegerParam 1 12000 40)
          ]
          ["turn"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "context_resume" parseArgs) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (turn, callId, after, limit) -> case parseTurnHandle turn of
          Nothing -> pure (Left "bad args: turn must be t#<n> or t#<n>:r<m>")
          Just parsed -> do
            result <- case (parsed, callId) of
              (ParsedTurn ordinal, Nothing) -> expandTurnTrace ordinal after (min limit (max 1 (budget `div` 1400)))
              _ -> expandTurnResult turn callId after (min (budget * 2) (if limit == 40 then 6000 else limit))
            pure $ maybe (Left "turn/result not found, ambiguous, or not visible") (Right . withNext turn callId limit) result
    }
  where
    budget = readPageTokens (toolContextLimits dc) (toolMultimodal dc)
    parseArgs o = do
      turn <- o .: "turn"
      callId <- o .:? "call_id"
      after <- o .:? "after_cursor"
      limit <- o .:? "limit" .!= 40
      unless (limit >= 1 && limit <= 12000 && maybe True (>= 0) after) (fail "invalid limit or cursor")
      pure (turn, callId, after, limit)
    withNext turn callId limit (Object fields) =
      let next = case KeyMap.lookup "next_after_cursor" fields of
            Just at | at /= Null -> object (["turn" .= (turn :: Text), "after_cursor" .= at, "limit" .= (limit :: Int)] <> ["call_id" .= cid | Just cid <- [callId]])
            _ -> Null
       in Object (KeyMap.insert "next" next fields)
    withNext _ _ _ value = value

--------------------------------------------------------------------------------
-- poke — 戳一戳

pokeTool ::
  (PlatformInteraction :> es, Log :> es) =>
  ToolContext ->
  Tool es
pokeTool dc =
  Tool
    { toolName = "poke",
      toolDescription =
        T.unwords
          [ "戳一戳（QQ 的轻互动，无文字）。适合代替说话的轻回应：",
            "回应别人戳你、提醒某人看消息、打招呼。",
            "一次任务最多戳一下，别对同一个人连戳。"
          ],
      toolSchema = toolObject [("qq", integerParam "要戳的人的 QQ号")] ["qq"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" (\o -> o .: "qq")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (qq :: Int64) -> do
          eres <- pokeUser (toolGroupId dc) (UserId qq)
          case eres of
            Left err -> pure $ Left ("poke 失败: " <> renderPlatformFailure err)
            Right () -> do
              logInfo "poke: sent" $ object ["qq" .= qq]
              pure $ Right (object ["ok" .= True])
    }
