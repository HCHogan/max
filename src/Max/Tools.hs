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
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.History (HistoryItem (..), fetchMessage)
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.NapCat (NapCat, sendAction)
import Max.Effects.Tools (Tool (..))
import OneBot.Action (Action (SendGroupMsg))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..))

builtinsFor ::
  ( WithConnection :> es,
    NapCat :> es,
    Log :> es,
    IOE :> es
  ) =>
  DispatchContext ->
  [Tool es]
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
          [ "Case-insensitive substring search across messages in this group.",
            "The 'query' is matched as a literal substring (single word, phrase,",
            "or partial token) against each message's rendered text.  Mixed",
            "CJK + ASCII works (e.g. 'haskell' will match '我在学haskell').",
            "Returns up to 'limit' most-recent matches, each summarised as",
            "message_id, sender, time, and a short snippet.  Use this when the",
            "user asks something like 我们之前讨论过 X 吗 or 上次谁说了 Y.",
            "For multi-keyword AND, call the tool multiple times and intersect."
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Substring to match (case-insensitive)." :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Max results (default 10, max 30)." :: Text),
                        "default" .= (10 :: Int)
                      ]
                ],
            "required" .= (["query"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q, lim) -> do
          rows <- runSearch gid q (min 30 (max 1 lim))
          pure $ Right (toJSON (map historyItemSummary rows))
    }
  where
    parseArgs :: Object -> Parser (Text, Int)
    parseArgs o = do
      q <- o .: "query"
      l <- o .:? "limit"
      pure (q, maybe 10 id l)

-- | Substring search via @ILIKE@.  Backed by a @pg_trgm@ GIN index
-- (migration 005), which actually accelerates @%foo%@ patterns —
-- unlike the previous @tsvector @@ plainto_tsquery('simple', ...)@
-- approach, which broke on mixed CJK+ASCII text because the 'simple'
-- tokeniser doesn't split CJK runs.
runSearch ::
  (WithConnection :> es, IOE :> es) =>
  Int64 ->
  Text ->
  Int ->
  Eff es [HistoryItem]
runSearch gid q lim =
  query
    "SELECT message_id, user_id, self_id, sender_nickname, rendered_text, received_at \
    \  FROM messages \
    \  WHERE group_id = ? \
    \    AND NOT is_synthetic \
    \    AND forwarded_in_message_id IS NULL \
    \    AND rendered_text ILIKE ? \
    \  ORDER BY received_at DESC \
    \  LIMIT ?"
    (gid, "%" <> q <> "%", lim)

--------------------------------------------------------------------------------
-- say — mid-task progress updates

-- | Send a status update to the user *during* an agent dispatch,
-- before the final answer.  The agent loop's content response is
-- still what we treat as the final reply; @say@ is for interstitial
-- updates so the user isn't staring at silence while the bot is busy
-- (especially when running sandbox commands that take real time).
sayTool ::
  (NapCat :> es, Log :> es) =>
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
          sendAction
            ( SendGroupMsg
                dc.dcGroupId
                [ SegReply dc.dcMessageId,
                  SegAt dc.dcUserId,
                  SegText (" " <> T.strip msg)
                ]
            )
          logInfo "say: sent" $ object ["len" .= T.length msg]
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
      "sender" .= h.senderNickname,
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
