-- |
-- Builtin tools the agent loop exposes to the LLM.  Tools are
-- per-dispatch: 'builtinsFor' builds a tool list scoped to one group,
-- since the model shouldn't have to pass @group_id@ explicitly — it's
-- implicit in the conversation it's serving.
--
-- Phase 6b ships two read-only history tools.  Write/exec tools come
-- in Phase 6.5 once sandboxing is in place.
module Max.Tools
  ( builtinsFor,
    parseTimeArg,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Foldable (asum)
import Data.Int (Int64)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Ord (clamp)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (LocalTime, TimeZone, defaultTimeLocale, localTimeToUTC, parseTimeM)
import Database.PostgreSQL.Simple (SqlError (..))
import Database.PostgreSQL.Simple.ToField qualified as PG
import Effectful
import Effectful.Exception (try)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..), bestName, fetchForwardChildrenInScope, fetchMessageInScope)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, EmbeddingRecord (..), embedTexts, makeEmbeddingRecord)
import Max.EpisodeStore (EpisodeExpansion (..), SourceRange (..), episodeHandleText, expandEpisode, parseEpisodeHandle)
import Max.Prompt (tagMediaMarkers)
import Max.Recall (RecallCorpus (..), RecallHit (..), searchRecall, searchRecallIn)
import Max.Time (fmtDateHM)
import Max.ToolContext (ToolContext, toolGroupId)
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..), UserId (..))

builtinsFor ::
  ( WithConnection :> es,
    PlatformApi :> es,
    Log :> es,
    IOE :> es
  ) =>
  TimeZone ->
  Maybe EmbedClient ->
  ToolContext ->
  [Tool es]
builtinsFor tz mEmbed dc =
  [ getMessageByIdTool tz dc,
    searchMessagesTool tz mEmbed (toolGroupId dc),
    contextSearchTool tz mEmbed dc,
    contextExpandTool tz dc,
    viewForwardTool tz dc,
    pokeTool dc
  ]

--------------------------------------------------------------------------------
-- get_message_by_id

getMessageByIdTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
getMessageByIdTool tz dc =
  Tool
    { toolName = "get_message_by_id",
      toolDescription =
        T.unwords
          [ "Fetch one historical message by its QQ message_id.",
            "Useful when the user references an old message id or you",
            "want the full original text of something quoted/forwarded.",
            "Returns null if the message is not in the bot's database."
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("QQ message_id (positive integer)" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> do
          m <- fetchMessageInScope (conversationScopeFor (toolGroupId dc)) mid
          pure $ Right (toJSON (fmap (historyItemSummary tz . tagMediaMarkers) m))
    }
  where
    parseArgs :: Object -> Parser Int64
    parseArgs o = o .: "message_id"

--------------------------------------------------------------------------------
-- search_messages

searchMessagesTool :: (WithConnection :> es, Log :> es, IOE :> es) => TimeZone -> Maybe EmbedClient -> GroupId -> Tool es
searchMessagesTool tz mEmbed groupId@(GroupId gid) =
  Tool
    { toolName = "search_messages",
      toolDescription =
        T.unwords $
          [ "搜索聊天记录（之前讨论过X吗 / 上次谁说了Y / 张三昨天说了啥）。",
            "所有过滤条件可选、AND 组合，各参数含义见参数说明；",
            "没给任何文本条件时就按其余条件列出最近的消息。"
          ]
            <> [ "找不到原话怎么说时用 semantic 按语义搜，结果按相似度排序。"
               | Just _ <- [mEmbed]
               ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Substring match (case-insensitive)." :: Text)
                      ],
                  "regex"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("POSIX regex (case-insensitive)." :: Text)
                      ],
                  "sender_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Sender's QQ id." :: Text)
                      ],
                  "sender"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Sender name contains this (nickname or 群名片)." :: Text)
                      ],
                  "after"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("At or after 'YYYY-MM-DD [HH:MM]' (result-display clock)." :: Text)
                      ],
                  "before"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("At or before 'YYYY-MM-DD [HH:MM]'." :: Text)
                      ],
                  "semantic"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Natural-language meaning search (no exact wording needed)." :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Default 10, max 30." :: Text),
                        "default" .= (10 :: Int)
                      ]
                ]
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right sa -> case compatibilityRecallQuery sa of
          Just (queryText, wantsSemantic) -> case (wantsSemantic, mEmbed) of
            (True, Nothing) -> pure (Left "semantic 搜索未启用（没有配置 embedding）")
            _ -> do
              embedding <-
                if wantsSemantic
                  then bestEffortRecallEmbedding "search_messages" mEmbed queryText
                  else pure Nothing
              let scope = conversationScopeFor groupId
                  corpora = Set.fromList [RecallMessages, RecallPins, RecallCaptions]
              hits <- searchRecallIn (currentConversationRecall scope) corpora queryText embedding sa.saLimit
              items <-
                catMaybes
                  <$> traverse
                    (\hit -> maybe (pure Nothing) (fetchMessageInScope scope) hit.rhMessageId)
                    hits
              pure . Right . toJSON $ map (historyItemSummary tz . tagMediaMarkers) items
          Nothing ->
            let run f mVec = fmap (toJSON . map (historyItemSummary tz . tagMediaMarkers)) <$> runSearch f mVec
             in case toFilter sa of
                  Left e -> pure (Left e)
                  Right f -> case (sa.saSemantic, mEmbed) of
                    (Nothing, _) -> run f Nothing
                    (Just _, Nothing) -> pure (Left "semantic 搜索未启用（没有配置 embedding）")
                    (Just q, Just ec) -> do
                      evec <- liftIO (embedTexts ec [q])
                      case evec of
                        Left err -> pure (Left ("embedding failed: " <> err))
                        Right [v] -> case makeEmbeddingRecord ec q v of
                          Left err -> pure (Left ("embedding failed: " <> err))
                          Right record -> run f (Just record)
                        Right _ -> pure (Left "embedding failed: unexpected result shape")
    }
  where
    parseArgs :: Object -> Parser SearchArgs
    parseArgs o =
      SearchArgs
        <$> o .:? "query"
        <*> o .:? "regex"
        <*> o .:? "sender_id"
        <*> o .:? "sender"
        <*> o .:? "after"
        <*> o .:? "before"
        <*> o .:? "semantic"
        <*> (fromMaybe 10 <$> o .:? "limit")

    toFilter :: SearchArgs -> Either Text MessageFilter
    toFilter sa = do
      after <- traverse (parseTimeArg tz) sa.saAfter
      before <- traverse (parseTimeArg tz) sa.saBefore
      pure
        MessageFilter
          { mfGroupId = gid,
            mfQuery = sa.saQuery,
            mfRegex = sa.saRegex,
            mfSenderId = sa.saSenderId,
            mfSender = sa.saSender,
            mfAfter = after,
            mfBefore = before,
            mfLimit = clamp (1, 30) sa.saLimit
          }

-- | Raw tool arguments, straight out of the JSON.
data SearchArgs = SearchArgs
  { saQuery :: !(Maybe Text),
    saRegex :: !(Maybe Text),
    saSenderId :: !(Maybe Int64),
    saSender :: !(Maybe Text),
    saAfter :: !(Maybe Text),
    saBefore :: !(Maybe Text),
    saSemantic :: !(Maybe Text),
    saLimit :: !Int
  }

-- | The old tool remains model-visible, but ordinary text/semantic lookups
-- now share context_search's corpus, ranking, scope, and dedup policy.  Regex,
-- sender, time-range, and combined exact+semantic requests retain the
-- specialised SQL path because those are constraints rather than recall.
compatibilityRecallQuery :: SearchArgs -> Maybe (Text, Bool)
compatibilityRecallQuery sa
  | isJust sa.saSenderId || any isJust [sa.saRegex, sa.saSender, sa.saAfter, sa.saBefore] = Nothing
  | Just queryText <- sa.saQuery, Nothing <- sa.saSemantic = Just (queryText, False)
  | Nothing <- sa.saQuery, Just semanticText <- sa.saSemantic = Just (semanticText, True)
  | otherwise = Nothing

-- | Validated filter set, times parsed.  Every field except the group
-- and the limit is optional; present ones are AND-combined.
data MessageFilter = MessageFilter
  { mfGroupId :: !Int64,
    mfQuery :: !(Maybe Text),
    mfRegex :: !(Maybe Text),
    mfSenderId :: !(Maybe Int64),
    mfSender :: !(Maybe Text),
    mfAfter :: !(Maybe UTCTime),
    mfBefore :: !(Maybe UTCTime),
    mfLimit :: !Int
  }

--------------------------------------------------------------------------------
-- context_search

contextSearchTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  TimeZone ->
  Maybe EmbedClient ->
  ToolContext ->
  Tool es
contextSearchTool tz mEmbed dc =
  Tool
    { toolName = "context_search",
      toolDescription =
        T.unwords
          [ "统一搜索当前会话的长期记忆、episode 摘要、原始消息、pin 和媒体简介。",
            "结果已经做 scope 过滤、混合排序、来源配额和同源去重；",
            "episode 的细节用返回的 handle 调 context_expand。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("要回忆的自然语言主题或关键词" :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "minimum" .= (1 :: Int),
                        "maximum" .= (30 :: Int),
                        "default" .= (10 :: Int)
                      ]
                ],
            "required" .= (["query"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseRecallArgs) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right (rawQuery, limit)
          | T.null (T.strip rawQuery) -> pure (Left "bad args: query cannot be blank")
          | otherwise -> do
              embedding <- bestEffortRecallEmbedding "context_search" mEmbed rawQuery
              let scope = conversationScopeFor (toolGroupId dc)
              hits <- searchRecall (currentConversationRecall scope) rawQuery embedding limit
              pure . Right $
                object
                  [ "query" .= T.strip rawQuery,
                    "semantic_used" .= maybe False (const True) embedding,
                    "results" .= map (recallHitSummary tz) hits
                  ]
    }
  where
    parseRecallArgs o =
      (,)
        <$> o .: "query"
        <*> (fromMaybe 10 <$> o .:? "limit")

bestEffortRecallEmbedding :: (Log :> es, IOE :> es) => Text -> Maybe EmbedClient -> Text -> Eff es (Maybe EmbeddingRecord)
bestEffortRecallEmbedding _ Nothing _ = pure Nothing
bestEffortRecallEmbedding caller (Just client) queryText = do
  result <- liftIO (embedTexts client [T.strip queryText])
  case result of
    Right [vector] -> case makeEmbeddingRecord client (T.strip queryText) vector of
      Right record -> pure (Just record)
      Left err -> do
        logAttention (caller <> ": invalid query embedding; using lexical recall") $ object ["error" .= err]
        pure Nothing
    Right _ -> do
      logAttention (caller <> ": unexpected embedding shape; using lexical recall") (object [])
      pure Nothing
    Left err -> do
      logAttention (caller <> ": embedding failed; using lexical recall") $ object ["error" .= err]
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

contextExpandTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
contextExpandTool tz dc =
  Tool
    { toolName = "context_expand",
      toolDescription =
        T.unwords
          [ "展开上下文中的 [episode#<handle>]，读取该摘要对应的原始聊天记录。",
            "handle 只用于定位；每次调用都会按当前会话重新检查权限。",
            "长 episode 会分页，按返回的 next_after_cursor 继续读取。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "handle"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "format" .= ("uuid" :: Text),
                        "description" .= ("[episode#<handle>] 标记中的 opaque handle" :: Text)
                      ],
                  "after_cursor"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("继续读取时使用上页返回的 next_after_cursor" :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "minimum" .= (1 :: Int),
                        "maximum" .= (100 :: Int),
                        "default" .= (40 :: Int)
                      ]
                ],
            "required" .= (["handle"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseExpandArgs) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right (rawHandle, after, limit) -> case parseEpisodeHandle rawHandle of
          Nothing -> pure (Left "bad args: handle must be the UUID from an [episode#...] marker")
          Just handle -> do
            let scope = conversationScopeFor (toolGroupId dc)
            expanded <-
              expandEpisode
                (currentConversationRecall scope)
                handle
                (MessageCursor <$> after)
                limit
            pure $ case expanded of
              Nothing -> Left "episode not found or not visible in this conversation"
              Just episode -> Right (episodeExpansionSummary tz episode)
    }
  where
    parseExpandArgs o =
      (,,)
        <$> o .: "handle"
        <*> o .:? "after_cursor"
        <*> (fromMaybe 40 <$> o .:? "limit")

episodeExpansionSummary :: TimeZone -> EpisodeExpansion -> Value
episodeExpansionSummary tz episode =
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
      "messages" .= map (expandedHistoryItem tz) episode.expansionMessages,
      "has_more" .= episode.expansionHasMore,
      "next_after_cursor" .= fmap (.ingestSeq) episode.expansionNextCursor
    ]

expandedHistoryItem :: TimeZone -> LedgerItem -> Value
expandedHistoryItem tz entry =
  object $
    [ "ingest_cursor" .= entry.cursor.ingestSeq,
      "message_id" .= h.messageId,
      "sender_user_id" .= h.userId,
      "sender" .= fromMaybe (T.pack (show h.userId)) (bestName h),
      "time" .= fmtDateHM tz h.receivedAt,
      "text" .= h.renderedText,
      "prompt_eligible" .= entry.transcriptEligible
    ]
      <> ["reply_to" .= reply | Just reply <- [h.replyTo]]
  where
    h = tagMediaMarkers entry.history

-- | Accept the timestamp shapes a model plausibly emits.  Naive times
-- are read in the display timezone — the same clock the tool's results
-- and the prompt show — then converted to the UTC the DB stores, so a
-- time the model saw in an earlier result round-trips to the right row.
parseTimeArg :: TimeZone -> Text -> Either Text UTCTime
parseTimeArg tz t =
  case asum [parseTimeM True defaultTimeLocale f s :: Maybe LocalTime | f <- fmts] of
    Just lt -> Right (localTimeToUTC tz lt)
    Nothing -> Left ("bad time '" <> t <> "': use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM'")
  where
    s = T.unpack (T.strip t)
    fmts =
      [ "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
        "%Y-%m-%dT%H:%M:%S%QZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M"
      ]

-- | Filtered history search.  Text matching (@ILIKE@ substring and
-- @~*@ regex alike) is backed by the @pg_trgm@ GIN index (migration
-- 005), which accelerates both operator classes — unlike the previous
-- @tsvector @@ plainto_tsquery('simple', ...)@ approach, which broke
-- on mixed CJK+ASCII text because the 'simple' tokeniser doesn't
-- split CJK runs.
--
-- The WHERE clause is assembled from code-controlled fragments only;
-- user input travels exclusively through @?@ parameters.  A bad regex
-- makes Postgres throw 'SqlError', which we surface as a normal tool
-- error so the model can correct the pattern instead of killing the
-- dispatch.
runSearch ::
  (WithConnection :> es, IOE :> es) =>
  MessageFilter ->
  -- | Validated query vector — 'Just' switches ordering from
  -- newest-first to most-similar-first and excludes incompatible rows.
  Maybe EmbeddingRecord ->
  Eff es (Either Text [HistoryItem])
runSearch f mVec = do
  let conds :: [(String, [PG.Action])]
      conds =
        concat
          [ [("rendered_text ILIKE ?", [PG.toField ("%" <> q <> "%")]) | Just q <- [f.mfQuery]],
            [("rendered_text ~* ?", [PG.toField r]) | Just r <- [f.mfRegex]],
            [("user_id = ?", [PG.toField u]) | Just u <- [f.mfSenderId]],
            [ ("(sender_nickname ILIKE ? OR sender_card ILIKE ?)", [PG.toField p, PG.toField p])
            | Just s <- [f.mfSender],
              let p = "%" <> s <> "%"
            ],
            [("received_at >= ?", [PG.toField t]) | Just t <- [f.mfAfter]],
            [("received_at <= ?", [PG.toField t]) | Just t <- [f.mfBefore]]
          ]
      columns = "message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id"
      baseSql =
        " FROM messages \
        \  WHERE group_id = ? \
        \    AND NOT is_synthetic \
        \    AND kind = 'chat' \
        \    AND forwarded_in_message_id IS NULL"
          <> concatMap ((" AND " <>) . fst) conds
      baseParams = PG.toField f.mfGroupId : concatMap snd conds
      (sql, params) = case mVec of
        Nothing ->
          ( "SELECT " <> columns <> baseSql <> " ORDER BY received_at DESC LIMIT ?",
            baseParams <> [PG.toField f.mfLimit]
          )
        Just record ->
          ( "WITH compatible AS MATERIALIZED (SELECT "
              <> columns
              <> ", embedding"
              <> baseSql
              <> " AND embedding_model = ? AND embedding_dimensions = ?) "
              <> "SELECT "
              <> columns
              <> " FROM compatible ORDER BY embedding <=> ?::vector LIMIT ?",
            baseParams
              <> [ PG.toField record.erModelId,
                   PG.toField record.erDimensions,
                   PG.toField record.erVector,
                   PG.toField f.mfLimit
                 ]
          )
  eres <- try @SqlError (query (fromString sql) params)
  pure $ case eres of
    Left e -> Left ("search failed: " <> TE.decodeUtf8Lenient (sqlErrorMsg e))
    Right rows -> Right rows

--------------------------------------------------------------------------------
-- view_forward — expand a 转发聊天记录 on demand

-- | Cap on child lines returned per call — a mega-bundle shouldn't
-- flood the context (the summary shape already truncates each line).
maxForwardChildren :: Int
maxForwardChildren = 100

viewForwardTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
viewForwardTool tz dc =
  Tool
    { toolName = "view_forward",
      toolDescription =
        T.unwords
          [ "展开一条转发聊天记录：传 [forward#<id>] 里的 <id>（容器消息的 message_id），",
            "返回里面的每条消息。嵌套的转发同样以 [forward#<id>] 出现，可以继续展开。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("[forward#<id>] 标记里的 id（可能是负数）" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "message_id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid :: Int64) -> do
          kids <-
            fetchForwardChildrenInScope
              (conversationScopeFor (toolGroupId dc))
              mid
              maxForwardChildren
          if null kids
            then pure $ Left "这条消息没有已展开的转发内容（不是转发聊天记录，或还没抓取完）"
            else
              pure . Right . toJSON $
                map (historyItemSummary tz . tagMediaMarkers) kids
    }

--------------------------------------------------------------------------------
-- poke — 戳一戳

pokeTool ::
  (PlatformApi :> es, Log :> es) =>
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
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "qq"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("要戳的人的 QQ号" :: Text)
                      ]
                ],
            "required" .= (["qq"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "qq")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (qq :: Int64) -> do
          eres <- callAction (SendPoke (toolGroupId dc) (UserId qq)) 10000
          case eres of
            Left err -> pure $ Left ("poke 失败: " <> err)
            Right (Response _ rc _ _)
              | rc /= 0 -> pure $ Left ("poke retcode " <> T.pack (show rc))
              | otherwise -> do
                  logInfo "poke: sent" $ object ["qq" .= qq]
                  pure $ Right (object ["ok" .= True])
    }

--------------------------------------------------------------------------------
-- Summary shape sent back to the model.  Keep it compact — every byte
-- here costs prompt tokens on the next turn.

historyItemSummary :: TimeZone -> HistoryItem -> Value
historyItemSummary tz h =
  object $
    [ "message_id" .= h.messageId,
      "sender_user_id" .= h.userId,
      -- 群名片 > 昵称 > QQ号, matching the prompt's context lines.
      "sender" .= fromMaybe (T.pack (show h.userId)) (bestName h),
      "time" .= fmtDateHM tz h.receivedAt,
      "text" .= shorten 400 h.renderedText
    ]
      -- The message this one quotes, so a quote chain is walkable one
      -- get_message_by_id hop at a time (the same handle rendered as
      -- [↩#<id>] in the prompt's context lines).
      <> ["reply_to" .= r | Just r <- [h.replyTo]]

shorten :: Int -> Text -> Text
shorten n t
  | T.length t <= n = t
  | otherwise = T.take n t <> "…"
