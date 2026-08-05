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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (currentConversationRecall)
import Max.Effects.Tools (Tool (..))
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryDraft (..),
    MemoryEvidence (..),
    MemoryId,
    MemoryItem (..),
    MemoryLifecycle (..),
    MemoryMutationResult (..),
    MemoryScope (..),
    MemoryUpdate (..),
    MemoryVersion,
    archiveVisibleMemory,
    countMemories,
    createMemory,
    groupMemoryNamespace,
    listMemories,
    parseScope,
    updateVisibleMemory,
    userMemoryNamespace,
  )
import Max.ToolContext (ToolContext, toolConversationScope, toolGroupId, toolMessageId, toolUserId)
import Max.Tools.Schema (enumParam, integerParam, stringParam, toolObject)
import Max.Util (tshow)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

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
  ToolContext ->
  [Tool es]
memoryToolsFor dc =
  [ saveTool dc,
    updateTool dc,
    forgetTool dc,
    listTool dc
  ]

--------------------------------------------------------------------------------
-- memory_save

saveTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  ToolContext ->
  Tool es
saveTool dc =
  Tool
    { toolName = "memory_save",
      toolDescription =
        T.unwords
          [ "保存一条长期记忆。一般不用主动存——对话结束后有后台抽取器负责记；",
            "只在用户明确让你记住某事时用。已有相近记忆就 memory_update，",
            "别重复存。存了不必在回复里宣布。"
          ],
      toolSchema =
        toolObject
          [ ("scope", enumParam ["group", "user"] "group=关于本会话；user=关于某个人（仅限本会话）。"),
            ( "content",
              stringParam
                ("一条紧凑的事实（≤" <> tshow maxMemoryChars <> " 字），第三人称陈述句，不带上下文引用。")
            ),
            ("user_id", integerParam "scope=user 时记忆归属的 QQ 号；缺省为当前发言者。")
          ]
          ["scope", "content"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (scopeRaw, content, mUid) -> do
          let GroupId gid = toolGroupId dc
              UserId triggerUid = toolUserId dc
              conversation = toolConversationScope dc
          case parseScope scopeRaw of
            Nothing -> pure $ Left "scope 必须是 group 或 user"
            Just scope -> case checkContent content of
              Left err -> pure (Left err)
              Right c -> do
                let sid = case scope of
                      ScopeGroup -> gid
                      ScopeUser -> fromMaybe triggerUid mUid
                    namespace = case scope of
                      ScopeGroup -> groupMemoryNamespace conversation
                      ScopeUser -> userMemoryNamespace conversation sid
                n <- countMemories namespace
                if n >= maxMemoriesPerScope
                  then
                    pure $
                      Left $
                        "该 scope 的记忆已满（"
                          <> tshow maxMemoriesPerScope
                          <> " 条）。先用 memory_forget 删掉过时的，或用 memory_update 合并相近条目，再保存。"
                  else do
                    let MessageId sourceMessage = toolMessageId dc
                        actor = MemoryActor ActorAgentTool (Just triggerUid) (Just "memory_save tool")
                        draft =
                          MemoryDraft
                            { draftContent = c,
                              draftLifecycle = MemoryPermanent,
                              draftCategory = Nothing,
                              draftEvidence = MessageEvidence conversation (Just triggerUid) sourceMessage
                            }
                    saved <- createMemory actor namespace draft
                    logInfo "memory: saved" $
                      object ["id" .= saved.memId, "version" .= saved.memVersion, "scope" .= scopeRaw, "scope_id" .= sid]
                    pure $ Right (object ["id" .= saved.memId, "version" .= saved.memVersion])
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Int64)
    parseArgs o = (,,) <$> o .: "scope" <*> o .: "content" <*> o .:? "user_id"

--------------------------------------------------------------------------------
-- memory_update

updateTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  ToolContext ->
  Tool es
updateTool dc =
  Tool
    { toolName = "memory_update",
      toolDescription =
        T.unwords
          [ "改写一条已有的长期记忆（id 来自系统提示的 [memories] 段或",
            "memory_list）。当事实变化、或要把几条相近记忆合并成一条时用它。"
          ],
      toolSchema =
        toolObject
          [ ("id", integerParam "记忆 id。"),
            ("version", integerParam "当前版本号（和 id 一起显示）。"),
            ("content", stringParam ("替换后的完整内容（≤" <> tshow maxMemoryChars <> " 字）。"))
          ]
          ["id", "version", "content"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, version, content) ->
          case checkContent content of
            Left err -> pure (Left err)
            Right c -> do
              let UserId triggerUid = toolUserId dc
                  MessageId sourceMessage = toolMessageId dc
                  conversation = toolConversationScope dc
                  actor = MemoryActor ActorAgentTool (Just triggerUid) (Just "memory_update tool")
              result <-
                updateVisibleMemory
                  actor
                  (currentConversationRecall conversation)
                  mid
                  (ExpectedVersion version)
                  (MemoryUpdate c (MessageEvidence conversation (Just triggerUid) sourceMessage))
              case result of
                MemoryMutationApplied updated -> do
                  logInfo "memory: updated" $ object ["id" .= updated.memId, "version" .= updated.memVersion]
                  pure $ Right (object ["id" .= updated.memId, "version" .= updated.memVersion])
                MemoryMutationRejected -> pure $ Left "记忆不存在、不可见，或版本已变化；请重新 memory_list 后再试"
    }
  where
    parseArgs :: Object -> Parser (MemoryId, MemoryVersion, Text)
    parseArgs o = (,,) <$> o .: "id" <*> o .: "version" <*> o .: "content"

--------------------------------------------------------------------------------
-- memory_forget

forgetTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  ToolContext ->
  Tool es
forgetTool dc =
  Tool
    { toolName = "memory_forget",
      toolDescription =
        T.unwords
          [ "删除一条长期记忆（id 来自系统提示的 [memories] 段或 memory_list）。",
            "记忆过时且无修订价值、或用户要求忘记时用它。"
          ],
      toolSchema =
        toolObject
          [ ("id", integerParam "记忆 id。"),
            ("version", integerParam "当前版本号。")
          ]
          ["id", "version"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, version) -> do
          let UserId triggerUid = toolUserId dc
              conversation = toolConversationScope dc
              actor = MemoryActor ActorAgentTool (Just triggerUid) (Just "memory_forget tool")
          result <-
            archiveVisibleMemory
              actor
              (currentConversationRecall conversation)
              mid
              (ExpectedVersion version)
          case result of
            MemoryMutationApplied archived -> do
              logInfo "memory: forgotten" $ object ["id" .= archived.memId, "version" .= archived.memVersion]
              pure $ Right (object ["ok" .= True, "version" .= archived.memVersion])
            MemoryMutationRejected -> pure $ Left "记忆不存在、不可见，或版本已变化；请重新 memory_list 后再试"
    }
  where
    parseArgs :: Object -> Parser (MemoryId, MemoryVersion)
    parseArgs o = (,) <$> o .: "id" <*> o .: "version"

--------------------------------------------------------------------------------
-- memory_list

listTool ::
  (WithConnection :> es, IOE :> es) =>
  ToolContext ->
  Tool es
listTool dc =
  Tool
    { toolName = "memory_list",
      toolDescription =
        T.unwords
          [ "查看某个 scope 的全部长期记忆。系统提示的 [memories] 只有最近",
            "更新的一部分——要看全量、或涉及别的人时用这个。"
          ],
      toolSchema =
        toolObject
          [ ("scope", enumParam ["group", "user"] "group 或 user。"),
            ("user_id", integerParam "scope=user 时的 QQ 号；缺省为当前发言者。group 始终是本会话。")
          ]
          ["scope"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (scopeRaw, mSid) -> do
          let UserId triggerUid = toolUserId dc
              conversation = toolConversationScope dc
          case parseScope scopeRaw of
            Nothing -> pure $ Left "scope 必须是 group 或 user"
            Just scope -> do
              let namespace = case scope of
                    ScopeGroup -> groupMemoryNamespace conversation
                    ScopeUser -> userMemoryNamespace conversation (fromMaybe triggerUid mSid)
              items <- listMemories namespace
              pure $ Right (toJSON (map memorySummary items))
    }
  where
    parseArgs :: Object -> Parser (Text, Maybe Int64)
    parseArgs o = (,) <$> o .: "scope" <*> o .:? "user_id"

memorySummary :: MemoryItem -> Value
memorySummary m =
  object
    [ "id" .= m.memId,
      "version" .= m.memVersion,
      "lifecycle" .= m.memLifecycle,
      "content" .= m.memContent
    ]

-- Shared guards.

checkContent :: Text -> Either Text Text
checkContent raw
  | T.null c = Left "content 不能为空"
  | T.length c > maxMemoryChars =
      Left ("content 太长（" <> tshow (T.length c) <> " 字），压缩到 " <> tshow maxMemoryChars <> " 字以内")
  | otherwise = Right c
  where
    c = T.strip raw
