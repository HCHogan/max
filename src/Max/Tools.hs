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
import Max.DB.History (HistoryItem (..), bestName, fetchForwardChildren, fetchMessage)
import Max.Effects.NapCat (NapCat, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, embedTexts, renderVector)
import Max.Prompt (tagMediaMarkers)
import Max.Time (fmtDateHM)
import Max.ToolContext (ToolContext, toolGroupId)
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..), UserId (..))

builtinsFor ::
  ( WithConnection :> es,
    NapCat :> es,
    Log :> es,
    IOE :> es
  ) =>
  TimeZone ->
  Maybe EmbedClient ->
  ToolContext ->
  [Tool es]
builtinsFor tz mEmbed dc =
  [ getMessageByIdTool tz,
    searchMessagesTool tz mEmbed (toolGroupId dc),
    viewForwardTool tz,
    pokeTool dc
  ]

--------------------------------------------------------------------------------
-- get_message_by_id

getMessageByIdTool :: (WithConnection :> es, IOE :> es) => TimeZone -> Tool es
getMessageByIdTool tz =
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
          m <- fetchMessage mid
          pure $ Right (toJSON (fmap (historyItemSummary tz . tagMediaMarkers) m))
    }
  where
    parseArgs :: Object -> Parser Int64
    parseArgs o = o .: "message_id"

--------------------------------------------------------------------------------
-- search_messages

searchMessagesTool :: (WithConnection :> es, IOE :> es) => TimeZone -> Maybe EmbedClient -> GroupId -> Tool es
searchMessagesTool tz mEmbed (GroupId gid) =
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
                  "group_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Defaults to the current group." :: Text)
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
        Right sa ->
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
                      Right [v] -> run f (Just (renderVector v))
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
        <*> o .:? "group_id"
        <*> (maybe 10 id <$> o .:? "limit")

    toFilter :: SearchArgs -> Either Text MessageFilter
    toFilter sa = do
      after <- traverse (parseTimeArg tz) sa.saAfter
      before <- traverse (parseTimeArg tz) sa.saBefore
      pure
        MessageFilter
          { mfGroupId = maybe gid id sa.saGroupId,
            mfQuery = sa.saQuery,
            mfRegex = sa.saRegex,
            mfSenderId = sa.saSenderId,
            mfSender = sa.saSender,
            mfAfter = after,
            mfBefore = before,
            mfLimit = min 30 (max 1 sa.saLimit)
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
    saGroupId :: !(Maybe Int64),
    saLimit :: !Int
  }

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
  -- | Rendered query vector — 'Just' switches ordering from
  -- newest-first to most-similar-first.
  Maybe Text ->
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
      (orderSql, orderParams) = case mVec of
        Just v ->
          ( " AND embedding IS NOT NULL ORDER BY embedding <=> ?::vector LIMIT ?",
            [PG.toField v, PG.toField f.mfLimit]
          )
        Nothing -> (" ORDER BY received_at DESC LIMIT ?", [PG.toField f.mfLimit])
      sql =
        "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at, reply_to_message_id \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND NOT is_synthetic \
        \    AND kind = 'chat' \
        \    AND forwarded_in_message_id IS NULL"
          <> concatMap ((" AND " <>) . fst) conds
          <> orderSql
      params = PG.toField f.mfGroupId : concatMap snd conds <> orderParams
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

viewForwardTool :: (WithConnection :> es, IOE :> es) => TimeZone -> Tool es
viewForwardTool tz =
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
          kids <- fetchForwardChildren mid maxForwardChildren
          if null kids
            then pure $ Left "这条消息没有已展开的转发内容（不是转发聊天记录，或还没抓取完）"
            else
              pure . Right . toJSON $
                map (historyItemSummary tz . tagMediaMarkers) kids
    }

--------------------------------------------------------------------------------
-- poke — 戳一戳

pokeTool ::
  (NapCat :> es, Log :> es) =>
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
      "sender" .= maybe (T.pack (show h.userId)) id (bestName h),
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
