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
import Data.Foldable (asum)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (LocalTime, TimeZone, defaultTimeLocale, localTimeToUTC, parseTimeM)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..), bestName, fetchForwardChildrenInScope, fetchMessageInScope)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, EmbeddingRecord (..), embedTexts, makeEmbeddingRecord)
import Max.EpisodeStore (EpisodeExpansion (..), SourceRange (..), episodeHandleText, expandEpisode, parseEpisodeHandle)
import Max.Prompt (tagMediaMarkers)
import Max.Recall (RecallHit (..), searchRecall)
import Max.Time (fmtDateHM)
import Max.ToolContext (ToolContext, toolGroupId)
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (UserId (..))

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
                contextSearchSummary
                  tz
                  rawQuery
                  (maybe False (const True) embedding)
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
