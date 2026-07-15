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
import Data.Time (defaultTimeLocale, formatTime, parseTimeM)
import Database.PostgreSQL.Simple (SqlError (..))
import Database.PostgreSQL.Simple.ToField qualified as PG
import Effectful
import Effectful.Exception (try)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.Reader.Dynamic (Reader)
import Max.DB.History (HistoryItem (..), bestName, fetchMessage)
import Max.DB.Message (insertOutbound)
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.NapCat (NapCat, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, embedTexts, renderVector)
import Max.Persistence (PersistMode, isEphemeral)
import OneBot.Action (Response (..), sendChatMsg)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), isPrivateChat)

builtinsFor ::
  ( WithConnection :> es,
    NapCat :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  Maybe EmbedClient ->
  DispatchContext ->
  [Tool es]
-- WithConnection + IOE constraints already in scope above; sayTool
-- needs them for the insertOutbound persistence path.
builtinsFor mEmbed dc =
  [ getMessageByIdTool,
    searchMessagesTool mEmbed dc.dcGroupId,
    sayTool dc
  ]

--------------------------------------------------------------------------------
-- get_message_by_id

getMessageByIdTool :: (WithConnection :> es, IOE :> es) => Tool es
getMessageByIdTool =
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
          pure $ Right (toJSON (fmap historyItemSummary m))
    }
  where
    parseArgs :: Object -> Parser Int64
    parseArgs o = o .: "message_id"

--------------------------------------------------------------------------------
-- search_messages

searchMessagesTool :: (WithConnection :> es, IOE :> es) => Maybe EmbedClient -> GroupId -> Tool es
searchMessagesTool mEmbed (GroupId gid) =
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
                        "description" .= ("Literal substring to match in message text (case-insensitive)." :: Text)
                      ],
                  "regex"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("POSIX regex to match against message text (case-insensitive, Postgres ~* semantics)." :: Text)
                      ],
                  "sender_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Only messages sent by this QQ user id." :: Text)
                      ],
                  "sender"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Only messages whose sender nickname or group card contains this substring (case-insensitive)." :: Text)
                      ],
                  "after"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Only messages at or after this time: 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM' (UTC)." :: Text)
                      ],
                  "before"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Only messages at or before this time: 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM' (UTC)." :: Text)
                      ],
                  "semantic"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Natural-language meaning search; needs no exact wording. Requires embedding to be configured." :: Text)
                      ],
                  "group_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Group to search (defaults to the current group)." :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Max results (default 10, max 30)." :: Text),
                        "default" .= (10 :: Int)
                      ]
                ]
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right sa ->
          let run f mVec = fmap (toJSON . map historyItemSummary) <$> runSearch f mVec
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
      after <- traverse parseTimeArg sa.saAfter
      before <- traverse parseTimeArg sa.saBefore
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
-- are UTC — the same clock 'formatTimestamp' renders, so the model can
-- round-trip times it saw in earlier results.
parseTimeArg :: Text -> Either Text UTCTime
parseTimeArg t =
  case asum [parseTimeM True defaultTimeLocale f s :: Maybe UTCTime | f <- fmts] of
    Just u -> Right u
    Nothing -> Left ("bad time '" <> t <> "': use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM' (UTC)")
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
        "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND NOT is_synthetic \
        \    AND forwarded_in_message_id IS NULL"
          <> concatMap ((" AND " <>) . fst) conds
          <> orderSql
      params = PG.toField f.mfGroupId : concatMap snd conds <> orderParams
  eres <- try @SqlError (query (fromString sql) params)
  pure $ case eres of
    Left e -> Left ("search failed: " <> TE.decodeUtf8Lenient (sqlErrorMsg e))
    Right rows -> Right rows

--------------------------------------------------------------------------------
-- say — mid-task progress updates

-- | Send a status update to the user *during* an agent dispatch,
-- before the final answer.  The agent loop's content response is
-- still what we treat as the final reply; @say@ is for interstitial
-- updates so the user isn't staring at silence while the bot is busy
-- (especially when running sandbox commands that take real time).
sayTool ::
  ( NapCat :> es,
    WithConnection :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  DispatchContext ->
  Tool es
sayTool dc =
  Tool
    { toolName = "say",
      toolDescription =
        T.unwords
          [ "任务中途向用户播报一行进展（用户看不到你的工具调用，只能看到沉默）。",
            "开工、关键步骤成败、改变计划时各说一句；连续 ~5 轮工具没吭声也该报一下。",
            "每次一行短话；最终答案不要用 say，直接作为正文回复。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Text to send to the group (kept short, like a status line)." :: Text)
                      ]
                ],
            "required" .= (["message"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "message")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (msg :: Text) -> do
          let segs =
                [SegReply dc.dcMessageId]
                  <> [SegAt dc.dcUserId | not (isPrivateChat dc.dcGroupId)]
                  <> [SegText (" " <> T.strip msg)]
          eres <- callAction (sendChatMsg dc.dcGroupId segs) 30000
          case eres of
            Left err -> do
              logAttention "say: send failed" $ object ["error" .= err]
              pure $ Left ("say failed: " <> err)
            Right (Response _ rc payload _)
              | rc /= 0 -> do
                  logAttention "say: bad retcode" $ object ["retcode" .= rc]
                  pure $ Left ("say retcode " <> T.pack (show rc))
              | otherwise -> do
                  ephemeral <- isEphemeral
                  case parseEither (withObject "send_resp" (\o -> o .: "message_id")) payload of
                    Right (outMid :: Int64)
                      | not ephemeral ->
                          insertOutbound dc.dcGroupId dc.dcSelfId "max" (MessageId outMid) segs
                      | otherwise -> pure ()
                    Left _ ->
                      logAttention "say: no message_id in response" $
                        object ["payload" .= payload]
                  logInfo "say: sent" $ object ["len" .= T.length msg, "ephemeral" .= ephemeral]
                  pure $ Right (object ["ok" .= True])
    }

--------------------------------------------------------------------------------
-- Summary shape sent back to the model.  Keep it compact — every byte
-- here costs prompt tokens on the next turn.

historyItemSummary :: HistoryItem -> Value
historyItemSummary h =
  object
    [ "message_id" .= h.messageId,
      "sender_user_id" .= h.userId,
      -- 群名片 > 昵称 > QQ号, matching the prompt's context lines.
      "sender" .= maybe (T.pack (show h.userId)) id (bestName h),
      "time" .= formatTimestamp h.receivedAt,
      "text" .= shorten 400 h.renderedText
    ]

-- | ISO-ish minute-precision so the model has a sense of when without
-- a wall of microseconds.
formatTimestamp :: UTCTime -> Text
formatTimestamp = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M"

shorten :: Int -> Text -> Text
shorten n t
  | T.length t <= n = t
  | otherwise = T.take n t <> "…"
