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
-- Writes are gated on 'isEphemeral': a @!btw@ one-shot must not leave
-- permanent traces.
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
import Effectful.Reader.Dynamic (Reader)
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
import Max.Persistence (PersistMode, isEphemeral)
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
  (WithConnection :> es, Reader PersistMode :> es, Log :> es, IOE :> es) =>
  Maybe EmbedClient ->
  DispatchContext ->
  [Tool es]
memoryToolsFor mEmbed dc =
  [ saveTool dc,
    updateTool,
    forgetTool,
    listTool dc
  ]
    <> [searchTool ec | Just ec <- [mEmbed]]

--------------------------------------------------------------------------------
-- memory_save

saveTool ::
  (WithConnection :> es, Reader PersistMode :> es, Log :> es, IOE :> es) =>
  DispatchContext ->
  Tool es
saveTool dc =
  Tool
    { toolName = "memory_save",
      toolDescription =
        T.unwords
          [ "保存一条长期记忆。仅当出现将来的对话还会用到的【稳定信息】时",
            "才调用：身份/背景、长期偏好、明确的约定或承诺、进行中的长期",
            "项目。大多数对话不需要保存任何记忆——闲聊、单次任务的细节、",
            "search_messages 能查到的内容都不要存。一次对话最多存一两条。",
            "scope=group 存本群的事；scope=user 存关于某个人的事（跨群",
            "生效，user_id 默认为当前发言者）。已有相近记忆时用",
            "memory_update 修订，不要重复保存。"
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
        Right (scopeRaw, content, mUid) -> guardWrites $ do
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
                n <- countMemories scope sid
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
  (WithConnection :> es, Reader PersistMode :> es, Log :> es, IOE :> es) =>
  Tool es
updateTool =
  Tool
    { toolName = "memory_update",
      toolDescription =
        T.unwords
          [ "改写一条已有的长期记忆（id 来自系统提示的 [长期记忆] 段或",
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
        Right (mid, content) -> guardWrites $
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
  (WithConnection :> es, Reader PersistMode :> es, Log :> es, IOE :> es) =>
  Tool es
forgetTool =
  Tool
    { toolName = "memory_forget",
      toolDescription =
        T.unwords
          [ "删除一条长期记忆（id 来自系统提示的 [长期记忆] 段或 memory_list）。",
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
        Right (mid :: Int64) -> guardWrites $ do
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
  (WithConnection :> es, Log :> es, IOE :> es) =>
  DispatchContext ->
  Tool es
listTool dc =
  Tool
    { toolName = "memory_list",
      toolDescription =
        T.unwords
          [ "查看某个 scope 的全部长期记忆。本群和当前发言者的记忆已经在",
            "系统提示里了，不需要用这个工具重复查；只有当对话涉及【别的",
            "人】（给出其 user_id）或【别的群】时才用。"
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
              items <- listMemories scope sid
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
  (WithConnection :> es, Log :> es, IOE :> es) =>
  EmbedClient ->
  Tool es
searchTool ec =
  Tool
    { toolName = "memory_search",
      toolDescription =
        T.unwords
          [ "跨【所有群、所有人】的长期记忆做语义搜索。当你想知道",
            "\"谁擅长X\"、\"哪个群在做Y\" 这类跨 scope 的问题时用它；",
            "本群和当前发言者的记忆已在系统提示里，别用它重复查。"
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
              rows <-
                query
                  "SELECT id, scope, scope_id, content, updated_at \
                  \  FROM memories WHERE embedding IS NOT NULL \
                  \  ORDER BY embedding <=> ?::vector LIMIT ?"
                  (renderVector vec, min 20 (max 1 lim))
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

-- | Reject writes inside an ephemeral (@!btw@) dispatch.
guardWrites ::
  Reader PersistMode :> es =>
  Eff es (Either Text Value) ->
  Eff es (Either Text Value)
guardWrites act = do
  ephemeral <- isEphemeral
  if ephemeral
    then pure (Left "临时对话（!btw）里不能改动长期记忆")
    else act

checkContent :: Text -> Either Text Text
checkContent raw
  | T.null c = Left "content 不能为空"
  | T.length c > maxMemoryChars =
      Left ("content 太长（" <> T.pack (show (T.length c)) <> " 字），压缩到 " <> T.pack (show maxMemoryChars) <> " 字以内")
  | otherwise = Right c
  where
    c = T.strip raw
