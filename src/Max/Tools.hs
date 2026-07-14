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
import Max.Persistence (PersistMode, isEphemeral)
import OneBot.Action (Action (SendGroupMsg), Response (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..))

builtinsFor ::
  ( WithConnection :> es,
    NapCat :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  DispatchContext ->
  [Tool es]
-- WithConnection + IOE constraints already in scope above; sayTool
-- needs them for the insertOutbound persistence path.
builtinsFor dc =
  [ getMessageByIdTool,
    searchMessagesTool dc.dcGroupId,
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

searchMessagesTool :: (WithConnection :> es, IOE :> es) => GroupId -> Tool es
searchMessagesTool (GroupId gid) =
  Tool
    { toolName = "search_messages",
      toolDescription =
        T.unwords
          [ "Search the bot's message history.  All filters are optional and",
            "AND-combined: 'query' is a case-insensitive literal substring",
            "(mixed CJK + ASCII works, e.g. 'haskell' matches '我在学haskell');",
            "'regex' is a case-insensitive POSIX regex (Postgres ~*: \\d \\w,",
            "alternation, anchors all work; no lookaround; prefer 'query' for",
            "plain substrings); 'sender_id' / 'sender' filter by who sent it;",
            "'after' / 'before' bound the time range (UTC — same timezone as",
            "the 'time' values in results and chat history).  'group_id'",
            "defaults to the current group; pass a different id only when the",
            "user explicitly asks about another group.  With no text filter it",
            "just lists that slice of history (e.g. 张三昨天说了什么 →",
            "sender + after/before, no query).  Returns up to 'limit'",
            "most-recent matches as message_id, sender, time, and a snippet.",
            "Use for questions like 我们之前讨论过X吗 or 上次谁说了Y."
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
        Right sa -> case toFilter sa of
          Left e -> pure (Left e)
          Right f -> fmap (toJSON . map historyItemSummary) <$> runSearch f
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
  Eff es (Either Text [HistoryItem])
runSearch f = do
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
      sql =
        "SELECT message_id, user_id, self_id, sender_nickname, sender_card, rendered_text, received_at \
        \  FROM messages \
        \  WHERE group_id = ? \
        \    AND NOT is_synthetic \
        \    AND forwarded_in_message_id IS NULL"
          <> concatMap ((" AND " <>) . fst) conds
          <> " ORDER BY received_at DESC LIMIT ?"
      params = PG.toField f.mfGroupId : concatMap snd conds <> [PG.toField f.mfLimit]
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
          [ "Send a status update to the user *during* a long-running task,",
            "before producing your final answer.  Use this to:",
            "(a) acknowledge a request before starting (e.g. \"好的，我去装一下\");",
            "(b) mark significant milestones (e.g. \"装好了，现在跑\");",
            "(c) split a long answer into digestible chunks.",
            "Do NOT use this for the final answer — just produce that as",
            "your normal text response.  Each say() is one extra LLM turn,",
            "so don't overdo it (2-3 per task is a good ceiling)."
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
                [ SegReply dc.dcMessageId,
                  SegAt dc.dcUserId,
                  SegText (" " <> T.strip msg)
                ]
          eres <- callAction (SendGroupMsg dc.dcGroupId segs) 30000
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
