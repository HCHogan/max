-- |
-- Builtin tools the agent loop exposes to the LLM.  Tools are
-- per-dispatch: 'builtinsFor' builds a tool list scoped to one group,
-- since the model shouldn't have to pass @group_id@ explicitly — it's
-- implicit in the conversation it's serving.
--
-- Historical recall is deliberately exposed through one unified tool:
-- @context_search@.  Keeping legacy corpus-specific search names visible made
-- tool selection ambiguous and let model-supplied placeholder filters bypass
-- unified recall entirely.
module Max.Tools
  ( builtinsFor,
    contextSearchSummary,
    episodeExpansionSummary,
    parseTimeArg,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Effectful.Log
import Max.Context.Media (tagMediaMarkers)
import Max.Effects.ConversationQuery (ConversationQuery, expandEpisode, readForward, readMessage, searchConversation)
import Max.Effects.Embedding (Embedding, embedBatch, renderEmbeddingFault)
import Max.Effects.PlatformInteraction (PlatformInteraction, pokeUser)
import Max.Effects.Tools (Tool (..))
import Max.Effects.TurnQuery (TurnQuery, expandTurnTrace)
import Max.Embedding (EmbeddingRecord)
import Max.Episode.Types (EpisodeExpansion (..), SourceRange (..), episodeHandleText, parseEpisodeHandle)
import Max.History.Types (HistoryItem (..), LedgerItem (..), MessageCursor (..), bestName)
import Max.Media.Types (MessageMedia)
import Max.Platform.Failure (renderPlatformFailure)
import Max.Recall.Types (RecallHit (..))
import Max.Time (fmtDateHM)
import Max.Time.Parse (parseTimeArg)
import Max.ToolContext (ToolContext, toolGroupId)
import Max.Tools.Schema (boundedIntegerParam, integerParam, stringParam, toolObject)
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
    <> [ getMessageByIdTool tz,
         contextSearchTool tz,
         contextExpandTool tz,
         viewForwardTool tz,
         pokeTool dc
       ]

--------------------------------------------------------------------------------
-- get_message_by_id

getMessageByIdTool :: (ConversationQuery :> es) => TimeZone -> Tool es
getMessageByIdTool tz =
  Tool
    { toolName = "get_message_by_id",
      toolDescription =
        T.unwords
          [ "按 id 取一条历史消息：传上下文行里 #<id> 或 [reply#<id>] 的那个数字。",
            "适合有人提到一条旧消息、或者你想看引用/转发的原文时用。",
            "库里没有这条就返回 null。"
          ],
      toolSchema = toolObject [("message_id", integerParam "上下文里 #<id> / [reply#<id>] 的那个数字")] ["message_id"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> do
          message <- readMessage mid
          pure $ Right (toJSON (map (historyItemSummary tz) (maybe [] pure message)))
    }
  where
    parseArgs :: Object -> Parser Int64
    parseArgs o = o .: "message_id"

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
            "episode 的细节用返回的 handle 调 context_expand。"
          ],
      toolSchema =
        toolObject
          [ ("query", stringParam "要回忆的自然语言主题或关键词"),
            ("limit", boundedIntegerParam 1 30 10)
          ]
          ["query"],
      toolRun = \args -> case parseEither (withObject "args" parseRecallArgs) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right (rawQuery, limit)
          | T.null (T.strip rawQuery) -> pure (Left "bad args: query cannot be blank")
          | otherwise -> do
              embedding <- bestEffortRecallEmbedding "context_search" rawQuery
              hits <- searchConversation rawQuery embedding limit
              pure . Right $
                contextSearchSummary
                  tz
                  rawQuery
                  (isJust embedding)
                  hits
    }
  where
    parseRecallArgs o =
      (,)
        <$> o .: "query"
        <*> (fromMaybe 10 <$> o .:? "limit")

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
      <> ["principal_id" .= principal | Just principal <- [hit.rhPrincipalId]]
      <> ["message_id" .= message | Just message <- [hit.rhMessageId]]
      <> ["memory_id" .= memory | Just memory <- [hit.rhMemoryId]]
      <> ["handle" .= episodeHandleText handle | Just handle <- [hit.rhEpisodeHandle]]

--------------------------------------------------------------------------------
-- context_expand

contextExpandTool :: (ConversationQuery :> es, TurnQuery :> es) => TimeZone -> Tool es
contextExpandTool tz =
  Tool
    { toolName = "context_expand",
      toolDescription =
        T.unwords
          [ "展开上下文中的 [episode#<handle>]，读取该摘要对应的原始聊天记录。",
            "也可展开 [recent turns] 中的 t#<n>，读取该工作回合的规范化执行记录。",
            "handle 只用于定位；每次调用都会按当前会话重新检查权限。",
            "长 episode 或 turn trace 会分页，按返回的 next_after_cursor 继续读取。"
          ],
      toolSchema =
        toolObject
          [ ( "handle",
              stringParam "[episode#<uuid>] 或 t#<n> 标记中的 handle"
            ),
            ("after_cursor", integerParam "继续读取时使用上页返回的 next_after_cursor"),
            ("limit", boundedIntegerParam 1 100 40)
          ]
          ["handle"],
      toolRun = \args -> case parseEither (withObject "args" parseExpandArgs) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right (rawHandle, after, limit) -> case (parseEpisodeHandle rawHandle, parseTurnHandle rawHandle) of
          (Just handle, _) -> do
            expanded <- expandEpisode handle (MessageCursor <$> after) limit
            pure $ case expanded of
              Nothing -> Left "episode not found or not visible in this conversation"
              Just (episode, media) -> Right (episodeExpansionSummary tz media episode)
          (Nothing, Just (ParsedTurn ordinal)) -> do
            expanded <- expandTurnTrace ordinal after limit
            pure $ maybe (Left "turn not found or not visible in this conversation") Right expanded
          (Nothing, Just ParsedTurnResult {}) ->
            pure (Left "bad args: pass the t#<n> turn handle, not a t#<n>:r<m> result handle")
          _ -> pure (Left "bad args: handle must be an episode UUID or t#<n>")
    }
  where
    parseExpandArgs o =
      (,,)
        <$> o .: "handle"
        <*> o .:? "after_cursor"
        <*> (fromMaybe 40 <$> o .:? "limit")

episodeExpansionSummary :: TimeZone -> Map.Map Int64 MessageMedia -> EpisodeExpansion -> Value
episodeExpansionSummary tz media episode =
  object
    [ "handle" .= episodeHandleText episode.expansionHandle,
      "source_range"
        .= object
          [ "start_cursor" .= episode.expansionRange.srStart.ingestSeq,
            "end_cursor" .= episode.expansionRange.srEnd.ingestSeq,
            "message_count" .= episode.expansionRange.srMessageCount
          ],
      "projection_state" .= episode.expansionState,
      "source_hash_matches" .= episode.expansionSourceHashMatches,
      "messages" .= map (expandedHistoryItem tz media) episode.expansionMessages,
      "has_more" .= episode.expansionHasMore,
      "next_after_cursor" .= fmap (.ingestSeq) episode.expansionNextCursor
    ]

expandedHistoryItem :: TimeZone -> Map.Map Int64 MessageMedia -> LedgerItem -> Value
expandedHistoryItem tz media entry =
  object $
    [ "ingest_cursor" .= entry.cursor.ingestSeq,
      "message_id" .= h.canonicalId,
      "principal_id" .= h.authorPrincipalId,
      "sender" .= bestName h,
      "time" .= fmtDateHM tz h.receivedAt,
      "text" .= h.renderedText,
      "prompt_eligible" .= entry.transcriptEligible
    ]
      <> ["reply_to" .= reply | Just reply <- [h.replyTo]]
  where
    h = tagMediaMarkers media entry.history

-- view_forward — expand a 转发聊天记录 on demand

-- | Cap on child lines returned per call — a mega-bundle shouldn't
-- flood the context (the summary shape already truncates each line).
maxForwardChildren :: Int
maxForwardChildren = 100

viewForwardTool :: (ConversationQuery :> es) => TimeZone -> Tool es
viewForwardTool tz =
  Tool
    { toolName = "view_forward",
      toolDescription =
        T.unwords
          [ "展开一条转发聊天记录：传 [forward#<id>] 里的 <id>（容器消息的 message_id），",
            "返回里面的每条消息。嵌套的转发同样以 [forward#<id>] 出现，可以继续展开。"
          ],
      toolSchema = toolObject [("message_id", integerParam "[forward#<id>] 标记里的 id（可能是负数）")] ["message_id"],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "message_id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid :: Int64) -> do
          kids <- readForward mid maxForwardChildren
          if null kids
            then pure $ Left "这条消息没有已展开的转发内容（不是转发聊天记录，或还没抓取完）"
            else pure . Right . toJSON $ map (historyItemSummary tz) kids
    }

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
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "qq")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (qq :: Int64) -> do
          eres <- pokeUser (toolGroupId dc) (UserId qq)
          case eres of
            Left err -> pure $ Left ("poke 失败: " <> renderPlatformFailure err)
            Right () -> do
              logInfo "poke: sent" $ object ["qq" .= qq]
              pure $ Right (object ["ok" .= True])
    }

--------------------------------------------------------------------------------
-- Summary shape sent back to the model.  Keep it compact — every byte
-- here costs prompt tokens on the next turn.

historyItemSummary :: TimeZone -> HistoryItem -> Value
historyItemSummary tz h =
  object $
    [ "message_id" .= h.canonicalId,
      "principal_id" .= h.authorPrincipalId,
      -- 群名片 > 昵称 > principal id, matching the prompt's context lines.
      "sender" .= bestName h,
      "time" .= fmtDateHM tz h.receivedAt,
      "text" .= shorten 400 h.renderedText
    ]
      -- The message this one quotes, so a quote chain is walkable one
      -- get_message_by_id hop at a time (the same handle rendered as
      -- [reply#<id>] in the prompt's context lines).
      <> ["reply_to" .= r | Just r <- [h.replyTo]]

shorten :: Int -> Text -> Text
shorten n t
  | T.length t <= n = t
  | otherwise = T.take n t <> "…"
