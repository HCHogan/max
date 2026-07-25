-- |
-- Long-term memory tools (Letta-style self-editing, ChatGPT-style
-- full injection).  The agent decides what to remember via explicit
-- CRUD; everything remembered is injected wholesale into the system
-- prompt (see "Max.Prompt"), so there is no retrieval step and no
-- vector store.
--
-- == Keeping memory in its place
--
-- The failure mode to guard against is not "forgets to save" — it's
-- the opposite: models pattern-match on having a memory tool and
-- start hoarding trivia, or worse, keep steering conversation back
-- to whatever the memory block says.  Three lines of defence:
--
--   * tool descriptions frame saving as the exception, not the rule
--     ("大多数对话不需要保存任何记忆");
--   * a hard per-scope cap ('maxMemoriesPerScope') with a
--     consolidate-first error, so hoarding stops paying off
--     (ChatGPT's "Memory Full" mechanism);
--   * the injection block in "Max.Prompt" is framed as 背景参考
--     with explicit 不要复述 guidance.
--
module Max.Tools.Memory
  ( memoryToolsFor,
    maxMemoriesPerScope,
    maxMemoryChars,
    checkContent,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
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
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, embedTexts, renderVector)
import OneBot.Types (GroupId (..), UserId (..))

-- | Per (scope, scope_id) ceiling.  Hitting it turns 'memory_save'
-- into an error that demands consolidation first — the pressure that
-- keeps the block small enough to inject wholesale.
maxMemoriesPerScope :: Int
maxMemoriesPerScope = 30

-- | One memory is a compact fact, not an essay.
maxMemoryChars :: Int
maxMemoryChars = 300

memoryToolsFor ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Maybe EmbedClient ->
  DispatchContext ->
  [Tool es]
memoryToolsFor mEmbed dc =
  [ saveTool dc,
    updateTool,
    forgetTool,
    listTool dc
  ]
    <> [searchTool dc ec | Just ec <- [mEmbed]]

--------------------------------------------------------------------------------
-- memory_save

saveTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  DispatchContext ->
  Tool es
saveTool dc =
  Tool
    { toolName = "memory_save",
      toolDescription =
        T.unwords
          [ "保存一条长期记忆。只存将来还会用到的稳定信息（身份、偏好、约定、",
            "长期项目）；闲聊和一次性细节不存，大多数对话不需要动记忆。",
            "已有相近记忆就 memory_update，别重复存。存了不必在回复里宣布",
            "（用户可用 !memory 查看）。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "scope"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "enum" .= (["group", "user"] :: [Text]),
                        "description" .= ("group=关于本群；user=关于某个人（跨群）。" :: Text)
                      ],
                  "content"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description"
                          .= ( "一条紧凑的事实（≤"
                                 <> T.pack (show maxMemoryChars)
                                 <> " 字），第三人称陈述句，不带上下文引用。"
                             )
                      ],
                  "user_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("scope=user 时记忆归属的 QQ 号；缺省为当前发言者。" :: Text)
                      ]
                ],
            "required" .= (["scope", "content"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (scopeRaw, content, mUid) -> do
          let GroupId gid = dc.dcGroupId
              UserId triggerUid = dc.dcUserId
          case parseScope scopeRaw of
            Nothing -> pure $ Left "scope 必须是 group 或 user"
            Just scope -> case checkContent content of
              Left err -> pure (Left err)
              Right c -> do
                let sid = case scope of
                      ScopeGroup -> gid
                      ScopeUser -> maybe triggerUid id mUid
                n <- countMemories scope sid gid
                if n >= maxMemoriesPerScope
                  then
                    pure $
                      Left $
                        "该 scope 的记忆已满（"
                          <> T.pack (show maxMemoriesPerScope)
                          <> " 条）。先用 memory_forget 删掉过时的，或用 memory_update 合并相近条目，再保存。"
                  else do
                    mid <- insertMemory scope sid c (Just gid)
                    logInfo "memory: saved" $
                      object ["id" .= mid, "scope" .= scopeRaw, "scope_id" .= sid]
                    pure $ Right (object ["id" .= mid])
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Int64)
    parseArgs o = (,,) <$> o .: "scope" <*> o .: "content" <*> o .:? "user_id"

--------------------------------------------------------------------------------
-- memory_update

updateTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Tool es
updateTool =
  Tool
    { toolName = "memory_update",
      toolDescription =
        T.unwords
          [ "改写一条已有的长期记忆（id 来自系统提示的 [memories] 段或",
            "memory_list）。当事实变化、或要把几条相近记忆合并成一条时用它。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "id" .= object ["type" .= ("integer" :: Text), "description" .= ("记忆 id。" :: Text)],
                  "content"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("替换后的完整内容（≤" <> T.pack (show maxMemoryChars) <> " 字）。" :: Text)
                      ]
                ],
            "required" .= (["id", "content"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, content) ->
          case checkContent content of
            Left err -> pure (Left err)
            Right c -> do
              ok <- updateMemory mid c
              if ok
                then do
                  logInfo "memory: updated" $ object ["id" .= mid]
                  pure $ Right (object ["id" .= mid])
                else pure $ Left ("没有 id=" <> T.pack (show mid) <> " 的记忆")
    }
  where
    parseArgs :: Object -> Parser (Int64, Text)
    parseArgs o = (,) <$> o .: "id" <*> o .: "content"

--------------------------------------------------------------------------------
-- memory_forget

forgetTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Tool es
forgetTool =
  Tool
    { toolName = "memory_forget",
      toolDescription =
        T.unwords
          [ "删除一条长期记忆（id 来自系统提示的 [memories] 段或 memory_list）。",
            "记忆过时且无修订价值、或用户要求忘记时用它。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                ["id" .= object ["type" .= ("integer" :: Text), "description" .= ("记忆 id。" :: Text)]],
            "required" .= (["id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (.: "id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid :: Int64) -> do
          ok <- deleteMemory mid
          if ok
            then do
              logInfo "memory: forgotten" $ object ["id" .= mid]
              pure $ Right (object ["ok" .= True])
            else pure $ Left ("没有 id=" <> T.pack (show mid) <> " 的记忆")
    }

--------------------------------------------------------------------------------
-- memory_list

listTool ::
  (WithConnection :> es, IOE :> es) =>
  DispatchContext ->
  Tool es
listTool dc =
  Tool
    { toolName = "memory_list",
      toolDescription =
        T.unwords
          [ "查看某个 scope 的全部长期记忆。本群和当前发言者的记忆已在系统",
            "提示里，别重复查；只在涉及别的人或别的群时用。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "scope"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "enum" .= (["group", "user"] :: [Text]),
                        "description" .= ("group 或 user。" :: Text)
                      ],
                  "scope_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("群号或 QQ 号；缺省为本群 / 当前发言者。" :: Text)
                      ]
                ],
            "required" .= (["scope"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (scopeRaw, mSid) -> do
          let GroupId gid = dc.dcGroupId
              UserId triggerUid = dc.dcUserId
          case parseScope scopeRaw of
            Nothing -> pure $ Left "scope 必须是 group 或 user"
            Just scope -> do
              let sid = case (scope, mSid) of
                    (_, Just s) -> s
                    (ScopeGroup, Nothing) -> gid
                    (ScopeUser, Nothing) -> triggerUid
              items <- listMemories scope sid gid
              pure $ Right (toJSON (map memorySummary items))
    }
  where
    parseArgs :: Object -> Parser (Text, Maybe Int64)
    parseArgs o = (,) <$> o .: "scope" <*> o .:? "scope_id"

memorySummary :: MemoryItem -> Value
memorySummary m = object ["id" .= m.memId, "content" .= m.memContent]

--------------------------------------------------------------------------------
-- memory_search (semantic; only registered when embedding is configured)

searchTool ::
  (WithConnection :> es, IOE :> es) =>
  DispatchContext ->
  EmbedClient ->
  Tool es
searchTool dc ec =
  let GroupId gid = dc.dcGroupId
   in Tool
    { toolName = "memory_search",
      toolDescription =
        T.unwords
          [ "在本群的长期记忆里做语义搜索（谁擅长X、之前定过什么）。",
            "只覆盖本群——本群的群记忆，以及成员在本群留下的个人记忆。",
            "当前发言者的记忆已在系统提示里，别重复查。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("自然语言描述要找的内容。" :: Text)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("最多返回条数（默认 8，上限 20）。" :: Text),
                        "default" .= (8 :: Int)
                      ]
                ],
            "required" .= (["query"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q, lim) -> do
          evec <- liftIO (embedTexts ec [q])
          case evec of
            Left err -> pure $ Left ("embedding failed: " <> err)
            Right [vec] -> do
              -- Confined to this conversation.  Unscoped, this ranked
              -- every memory in the database — every other group's
              -- facts, every other person's — and handed the model
              -- whatever scored highest, which is how a fact learned in
              -- one group surfaced in another.  Group rows partition on
              -- scope_id; user rows on where they were learned.
              rows <-
                query
                  "SELECT id, scope, scope_id, content, updated_at \
                  \  FROM memories \
                  \  WHERE embedding IS NOT NULL \
                  \    AND ( (scope = 'group' AND scope_id = ?) \
                  \       OR (scope = 'user' AND source_group_id = ?) ) \
                  \  ORDER BY embedding <=> ?::vector LIMIT ?"
                  (gid, gid, renderVector vec, min 20 (max 1 lim))
              pure $ Right (toJSON (map fullSummary (rows :: [MemoryItem])))
            Right _ -> pure $ Left "embedding failed: unexpected result shape"
    }
  where
    parseArgs :: Object -> Parser (Text, Int)
    parseArgs o = (,) <$> o .: "query" <*> (maybe 8 id <$> o .:? "limit")

    fullSummary m =
      object
        [ "id" .= m.memId,
          "scope" .= m.memScope,
          "scope_id" .= m.memScopeId,
          "content" .= m.memContent
        ]

--------------------------------------------------------------------------------
-- Shared guards.

checkContent :: Text -> Either Text Text
checkContent raw
  | T.null c = Left "content 不能为空"
  | T.length c > maxMemoryChars =
      Left ("content 太长（" <> T.pack (show (T.length c)) <> " 字），压缩到 " <> T.pack (show maxMemoryChars) <> " 字以内")
  | otherwise = Right c
  where
    c = T.strip raw
