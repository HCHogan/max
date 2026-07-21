-- |
-- Post-dispatch memory extraction (the mem0 pattern): after each
-- persisted agent turn, a cheap dedicated model reads the turn's
-- transcript plus the currently stored memories and emits a JSON list
-- of ADD / UPDATE / DELETE operations.  The main chat model keeps
-- zero responsibility for remembering — in practice it never calls
-- the memory tools on its own — while the explicit tools remain for
-- direct user requests ("记住X").
--
-- Runs after the reply is already sent (inside the dispatch async),
-- so extraction latency is invisible to the group.  Failures only
-- log; a lost extraction is a non-event.
module Max.MemoryExtract
  ( extractMemories,
    -- * Exposed for tests
    ExtractOp (..),
    parseOps,
  )
where

import Data.Aeson
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.ByteString.Lazy qualified as LBS
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Memory
  ( MemoryItem (..),
    MemoryScope (..),
    countMemories,
    deleteMemory,
    insertMemory,
    listMemories,
    parseScope,
    scopeText,
    updateMemory,
  )
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, chat)
import Max.Embedding (EmbedClient, embedTexts, renderVector)
import Max.Tools.Memory (checkContent, maxMemoriesPerScope)
import OneBot.Event (GroupMessage (..))
import OneBot.Types (GroupId (..), UserId (..))

-- | One operation the extractor model may emit.
data ExtractOp
  = OpAdd !Text !(Maybe Int64) !Text -- scope, user_id (scope=user), content
  | OpUpdate !Int64 !Text
  | OpDelete !Int64
  deriving stock (Show, Eq)

instance FromJSON ExtractOp where
  parseJSON = withObject "op" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> OpAdd <$> o .: "scope" <*> o .:? "user_id" <*> o .: "content"
      "update" -> OpUpdate <$> o .: "id" <*> o .: "content"
      "delete" -> OpDelete <$> o .: "id"
      other -> fail ("unknown action: " <> T.unpack other)

-- | Run one extraction pass for a finished dispatch.
extractMemories ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- extractor profile name
  Maybe EmbedClient -> -- for semantic dedup of adds
  GroupMessage -> -- the trigger (group + sender scope keys)
  [ChatMessage] -> -- the dispatch conversation (context + appended)
  Eff es ()
extractMemories profile mEmbed gm conversation = localDomain "memx" $ do
  let GroupId gid = gm.groupId
      UserId uid = gm.userId
  groupMems <- listMemories ScopeGroup gid
  userMems <- listMemories ScopeUser uid
  let transcript = renderTranscript conversation
      msgs =
        [ MsgSystem extractorSystem,
          MsgUser (renderInput gid uid groupMems userMems transcript)
        ]
  chat profile (Just False) msgs [] >>= \case
    Left err -> logAttention "memx: chat failed" $ object ["error" .= err]
    Right (ToolCallsResp _ _) ->
      logAttention "memx: unexpected tool calls" $ object []
    Right (ContentResp raw) -> case parseOps raw of
      Left err ->
        logAttention "memx: bad ops json" $
          object ["error" .= err, "raw" .= T.take 400 raw]
      Right [] -> logInfo "memx: no ops" $ object []
      Right ops -> traverse_ (applyOp mEmbed gid uid) (take 6 ops)

-- | Parse the model's output into ops: strip code fences, find the
-- first @[@ .. last @]@, decode.
parseOps :: Text -> Either String [ExtractOp]
parseOps raw =
  let t = T.strip (stripFences (T.strip raw))
      sliced = case (T.findIndex (== '[') t, T.length t - 1) of
        (Just i, _) -> T.drop i (T.dropWhileEnd (/= ']') t)
        _ -> t
   in eitherDecode (LBS.fromStrict (TE.encodeUtf8 sliced))
  where
    stripFences s
      | "```" `T.isPrefixOf` s =
          T.intercalate "\n"
            . takeWhile (not . ("```" `T.isPrefixOf`))
            . drop 1
            $ T.lines s
      | otherwise = s

applyOp ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Maybe EmbedClient ->
  Int64 -> -- group id
  Int64 -> -- trigger user id
  ExtractOp ->
  Eff es ()
applyOp mEmbed gid triggerUid = \case
  OpAdd scopeRaw mUid content -> case parseScope scopeRaw of
    Nothing -> logAttention "memx: bad scope" $ object ["scope" .= scopeRaw]
    Just scope -> case checkContent content of
      Left err -> logAttention "memx: bad content" $ object ["error" .= err]
      Right c -> do
        let sid = case scope of
              ScopeGroup -> gid
              ScopeUser -> maybe triggerUid id mUid
        -- The prompt says "don't re-add near-duplicates", but small
        -- extractor models re-add anyway (observed on day one).
        -- Enforce in code: embed the candidate and skip when an
        -- existing memory in the same scope sits within the distance
        -- threshold.  pg_trgm can't do this — the DB is C-locale, so
        -- CJK text yields no trigrams at all (similarity() = 0).
        (mVec, mDup) <- findNearDup scope sid c
        case mDup of
          Just (did, dist) ->
            logInfo "memx: near-duplicate skipped" $
              object ["existing_id" .= did, "distance" .= dist, "content" .= c]
          Nothing -> do
            n <- countMemories scope sid
            if n >= maxMemoriesPerScope
              then
                logAttention "memx: scope full, add skipped" $
                  object ["scope" .= scopeRaw, "scope_id" .= sid]
              else do
                mid <- insertMemory scope sid c (Just gid)
                -- Reuse the dedup vector so the new row is instantly
                -- searchable / dedupable (no worker lag window).
                case mVec of
                  Just v -> do
                    _ <-
                      execute
                        "UPDATE memories SET embedding = ?::vector WHERE id = ?"
                        (v, mid)
                    pure ()
                  Nothing -> pure ()
                logInfo "memx: added" $
                  object ["id" .= mid, "scope" .= scopeRaw, "scope_id" .= sid, "content" .= c]
  OpUpdate mid content -> case checkContent content of
    Left err -> logAttention "memx: bad content" $ object ["error" .= err]
    Right c -> do
      ok <- updateMemory mid c
      -- Content changed → stale vector; NULL it so the embed worker
      -- refreshes on its next pass.
      _ <- execute "UPDATE memories SET embedding = NULL WHERE id = ?" (Only mid)
      logInfo "memx: updated" $ object ["id" .= mid, "ok" .= ok, "content" .= c]
  OpDelete mid -> do
    ok <- deleteMemory mid
    logInfo "memx: deleted" $ object ["id" .= mid, "ok" .= ok]
  where
    -- | Returns (embedding of the candidate — reusable for the insert,
    -- nearest same-scope duplicate within 'dupDistance' if any).
    -- Fail-open: an embedding hiccup must not block memory writes; the
    -- fallback is exact-content match.
    findNearDup scope sid c = case mEmbed of
      Nothing -> do
        rows <-
          query
            "SELECT id FROM memories WHERE scope = ? AND scope_id = ? AND content = ? LIMIT 1"
            (scopeText scope, sid, c)
        let hit = case rows :: [Only Int64] of
              (Only did : _) -> Just (did, 0 :: Double)
              [] -> Nothing
        pure (Nothing, hit)
      Just ec -> do
        evec <- liftIO (embedTexts ec [c])
        case evec of
          Left err -> do
            logAttention "memx: dedup embed failed (fail-open)" $ object ["error" .= err]
            pure (Nothing, Nothing)
          Right [v] -> do
            let vt = renderVector v
            rows <-
              query
                "SELECT id, embedding <=> ?::vector AS dist FROM memories \
                \ WHERE scope = ? AND scope_id = ? AND embedding IS NOT NULL \
                \ ORDER BY dist LIMIT 1"
                (vt, scopeText scope, sid)
            let hit = case rows :: [(Int64, Double)] of
                  ((did, dist) : _) | dist < dupDistance -> Just (did, dist)
                  _ -> Nothing
            pure (Just vt, hit)
          Right _ -> pure (Nothing, Nothing)

-- | Cosine distance below which a candidate counts as "already
-- remembered".  Same-fact rewordings land well under this; genuinely
-- distinct facts about the same entity sit clearly above.
dupDistance :: Double
dupDistance = 0.15

--------------------------------------------------------------------------------
-- Prompt.

extractorSystem :: Text
extractorSystem =
  T.unlines
    [ "你是一个记忆提取器。输入是一段 QQ 群对话（bot 视角）和已存的长期记忆，",
      "输出是对记忆库的操作列表（JSON 数组），除 JSON 外不要输出任何东西。",
      "",
      "只提取【将来的对话还会用到的稳定信息】：",
      "  - 关于某个人的：身份/背景、长期偏好、专长、明确的约定或承诺 → scope=\"user\"（必须带 user_id，QQ号看成员对照或消息里的 @数字）",
      "  - 关于这个群的：进行中的项目、群规矩/惯例、反复出现的梗 → scope=\"group\"",
      "不要提取：闲聊、情绪、一次性任务的细节、时效性内容、翻聊天记录就能查到的东西。",
      "",
      "规则：",
      "  - 大多数对话没有值得记的东西——那就输出 []。宁缺毋滥。",
      "  - 和已有记忆重复/相近 → 不要 add；内容有演进 → 用 update 改写那条。",
      "  - 已有记忆被对话明确证伪且无修订价值 → delete。",
      "  - content 用第三人称陈述句，≤300 字，自包含（不引用\"上文\"）。",
      "  - 单次最多 3 个操作。",
      "",
      "操作格式：",
      "  {\"action\":\"add\",\"scope\":\"group\"|\"user\",\"user_id\":123,\"content\":\"...\"}",
      "  {\"action\":\"update\",\"id\":5,\"content\":\"...\"}",
      "  {\"action\":\"delete\",\"id\":5}"
    ]

renderInput :: Int64 -> Int64 -> [MemoryItem] -> [MemoryItem] -> Text -> Text
renderInput gid uid groupMems userMems transcript =
  T.unlines $
    concat
      [ ["[existing memories — group_id=" <> T.pack (show gid) <> "]"],
        memLines groupMems,
        ["", "[existing memories — user_id=" <> T.pack (show uid) <> "]"],
        memLines userMems,
        ["", "[conversation]", transcript, "", "输出操作 JSON 数组："]
      ]
  where
    memLines [] = ["(无)"]
    memLines ms = [T.pack (show m.memId) <> ": " <> m.memContent | m <- ms]

-- | Flatten the dispatch conversation to plain text, newest-biased:
-- keep the tail that fits the budget.  System prompt and tool-call
-- plumbing are skipped; tool results are noise for this purpose.
renderTranscript :: [ChatMessage] -> Text
renderTranscript msgs =
  let lines' = concatMap lineOf msgs
      full = T.intercalate "\n" lines'
   in if T.length full <= budget then full else T.takeEnd budget full
  where
    budget = 6000
    lineOf = \case
      MsgSystem _ -> []
      MsgTool _ _ -> []
      MsgAssistantToolCalls _ _ -> []
      MsgAssistant t -> ["bot: " <> t]
      MsgUser t -> [t]
      MsgUserBlocks blocks -> [T.unwords [t | TextBlock t <- blocks]]
