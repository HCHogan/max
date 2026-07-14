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
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.ByteString.Lazy qualified as LBS
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Memory
  ( MemoryItem (..),
    MemoryScope (..),
    countMemories,
    deleteMemory,
    insertMemory,
    listMemories,
    parseScope,
    updateMemory,
  )
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, chat)
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
  GroupMessage -> -- the trigger (group + sender scope keys)
  [ChatMessage] -> -- the dispatch conversation (context + appended)
  Eff es ()
extractMemories profile gm conversation = localDomain "memx" $ do
  let GroupId gid = gm.groupId
      UserId uid = gm.userId
  groupMems <- listMemories ScopeGroup gid
  userMems <- listMemories ScopeUser uid
  let transcript = renderTranscript conversation
      msgs =
        [ MsgSystem extractorSystem,
          MsgUser (renderInput gid uid groupMems userMems transcript)
        ]
  eres <- chat profile (Just False) msgs []
  case eres of
    Left err -> logAttention "memx: chat failed" $ object ["error" .= err]
    Right (ToolCallsResp _ _) ->
      logAttention "memx: unexpected tool calls" $ object []
    Right (ContentResp raw) -> case parseOps raw of
      Left err ->
        logAttention "memx: bad ops json" $
          object ["error" .= err, "raw" .= T.take 400 raw]
      Right [] -> logInfo "memx: no ops" $ object []
      Right ops -> mapM_ (applyOp gid uid) (take 6 ops)

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
  Int64 -> -- group id
  Int64 -> -- trigger user id
  ExtractOp ->
  Eff es ()
applyOp gid triggerUid = \case
  OpAdd scopeRaw mUid content -> case parseScope scopeRaw of
    Nothing -> logAttention "memx: bad scope" $ object ["scope" .= scopeRaw]
    Just scope -> case checkContent content of
      Left err -> logAttention "memx: bad content" $ object ["error" .= err]
      Right c -> do
        let sid = case scope of
              ScopeGroup -> gid
              ScopeUser -> maybe triggerUid id mUid
        n <- countMemories scope sid
        if n >= maxMemoriesPerScope
          then
            logAttention "memx: scope full, add skipped" $
              object ["scope" .= scopeRaw, "scope_id" .= sid]
          else do
            mid <- insertMemory scope sid c (Just gid)
            logInfo "memx: added" $
              object ["id" .= mid, "scope" .= scopeRaw, "scope_id" .= sid, "content" .= c]
  OpUpdate mid content -> case checkContent content of
    Left err -> logAttention "memx: bad content" $ object ["error" .= err]
    Right c -> do
      ok <- updateMemory mid c
      logInfo "memx: updated" $ object ["id" .= mid, "ok" .= ok, "content" .= c]
  OpDelete mid -> do
    ok <- deleteMemory mid
    logInfo "memx: deleted" $ object ["id" .= mid, "ok" .= ok]

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
      [ ["[已有记忆 — 本群 group_id=" <> T.pack (show gid) <> "]"],
        memLines groupMems,
        ["", "[已有记忆 — 触发用户 user_id=" <> T.pack (show uid) <> "]"],
        memLines userMems,
        ["", "[本轮对话]", transcript, "", "输出操作 JSON 数组："]
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
