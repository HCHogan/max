-- |
-- Execute parsed 'Command's against the session registry + task
-- registry, producing the text the bot should reply with.  All
-- side-effects (DB writes, session mutations, task pokes) happen here;
-- the parser is pure.
module Max.Command.Dispatcher
  ( execute,
  )
where

import Control.Concurrent.STM (TVar)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Command.Types
import Max.Effects.LLM (LLM, listProfiles)
import Max.Sandbox.Registry (SandboxRegistry, destroySandboxesForGroup)
import Max.Session (Session (..), updateSession)
import Max.Session qualified as Session
import Max.Tasks
  ( TaskId (..),
    TaskInfo (..),
    TaskRegistry,
    cancelTask,
    listTasks,
    pushBtwToLatest,
  )
import OneBot.Types (GroupId (..))

-- | Run one command and produce the reply text.
execute ::
  ( Log :> es,
    WithConnection :> es,
    LLM :> es,
    IOE :> es
  ) =>
  TVar Session ->
  TaskRegistry ->
  SandboxRegistry ->
  GroupId ->
  Command ->
  Eff es Text
execute t taskReg sandboxReg gid cmd = case cmd of
  Help mTopic -> pure (helpText mTopic)
  --
  ModelShow -> do
    s <- liftIO (Session.readSession t)
    pure $ "当前 model: " <> s.model
  ModelList -> do
    profs <- listProfiles
    pure $ "可用 models:\n  " <> T.intercalate "\n  " (sort profs)
  ModelSet name -> do
    profs <- listProfiles
    if name `elem` profs
      then do
        updateSession t (\s -> (s {model = name}, ()))
        logInfo "session: model set" $ object ["model" .= name]
        pure $ "✓ model 切到 " <> name
      else
        pure $
          "找不到 model: "
            <> name
            <> "\n用 !model list 看可用列表"
  --
  PersonaShow -> do
    s <- liftIO (Session.readSession t)
    pure $ case s.persona of
      Nothing -> "(使用默认 persona — 用 !persona <text> 覆盖)"
      Just p -> "当前 persona override:\n" <> p
  PersonaClear -> do
    updateSession t (\s -> (s {persona = Nothing}, ()))
    pure "✓ persona override 已清，回到默认"
  PersonaSet p -> do
    updateSession t (\s -> (s {persona = Just p}, ()))
    pure $ "✓ persona 已设 (" <> T.pack (show (T.length p)) <> " 字)"
  --
  Clear -> do
    updateSession t (\s -> (Session.clearHistory s, ()))
    pure "✓ history 已清"
  ClearAll -> do
    updateSession t (\s -> (Session.clearAll s, ()))
    n <- liftIO (destroySandboxesForGroup sandboxReg gid)
    logInfo "session: clear --all" $ object ["sandboxes_destroyed" .= n]
    let sboxSuffix
          | n == 0 = ""
          | otherwise = "，并销毁了 " <> T.pack (show n) <> " 个 sandbox"
    pure $ "✓ history / btw / persona override 全清" <> sboxSuffix
  --
  Btw note -> do
    -- Prefer injecting into a running task in this group; fall back
    -- to the session queue if nothing's in flight.  Caller doesn't
    -- have to think about which case applies.
    injected <- liftIO (pushBtwToLatest taskReg gid note)
    if injected
      then pure "✓ 侧记已注入运行中的任务"
      else do
        updateSession t (\s -> (Session.appendBtwNote note s, ()))
        n <- (length . (.btwNotes)) <$> liftIO (Session.readSession t)
        pure $ "✓ 没在跑的任务，先排队了 (" <> T.pack (show n) <> " 条待消化)"
  --
  PsLocal -> do
    now <- liftIO getCurrentTime
    tasks <- liftIO (listTasks taskReg (Just gid))
    pure (formatTasks now Nothing tasks)
  PsAll -> do
    now <- liftIO getCurrentTime
    tasks <- liftIO (listTasks taskReg Nothing)
    pure (formatTasks now (Just gid) tasks)
  Kill tid -> do
    ok <- liftIO (cancelTask taskReg (TaskId tid))
    pure $
      if ok
        then "✓ 已发取消信号给 " <> tid
        else "找不到任务 " <> tid <> " (用 !ps 看在跑的)"
  --
  BranchList -> pure "(分支列表 Phase 6c 接入)"
  BranchNew _ -> pure "(分支创建 Phase 6c 接入)"
  Switch _ -> pure "(分支切换 Phase 6c 接入)"
  --
  Unknown v _ ->
    pure $
      "不认识的命令: !"
        <> v
        <> "\n用 !help 看可用命令"

--------------------------------------------------------------------------------
-- !ps formatting.

-- | Render a task list.  If 'callerGid' is given (i.e. --all mode), each
-- row includes the group id so the caller can tell which task is theirs;
-- otherwise the group is implicit and omitted.
formatTasks :: UTCTime -> Maybe GroupId -> [TaskInfo] -> Text
formatTasks _ _ [] = "(没有在跑的任务)"
formatTasks now callerGid tasks =
  T.unlines (header : map (formatOne now callerGid) tasks)
  where
    header = "在跑的任务:"

formatOne :: UTCTime -> Maybe GroupId -> TaskInfo -> Text
formatOne now callerGid ti =
  T.intercalate "  " $
    [ "  " <> (ti.tiId.unTaskId),
      ti.tiKind,
      ageText now ti.tiStartedAt
    ]
      <> [groupTag | Just _ <- [callerGid]]
      <> [pendingTag | ti.tiPendingBtw > 0]
  where
    GroupId raw = ti.tiGroup
    groupTag = "group=" <> T.pack (show raw)
    pendingTag = "btw=" <> T.pack (show ti.tiPendingBtw)

ageText :: UTCTime -> UTCTime -> Text
ageText now started =
  let secs = round (realToFrac (diffUTCTime now started) :: Double) :: Int
   in case secs of
        n | n < 60 -> T.pack (show n) <> "s"
        n | n < 3600 -> T.pack (show (n `div` 60)) <> "m"
        n -> T.pack (show (n `div` 3600)) <> "h"

--------------------------------------------------------------------------------
-- Help.

helpText :: Maybe Text -> Text
helpText Nothing =
  T.unlines
    [ "可用命令：",
      "  !help [topic]            这条帮助",
      "  !model                   看当前 model",
      "  !model list              列所有 model",
      "  !model <name>            切 model",
      "  !persona                 看当前 persona override",
      "  !persona <text>          设 persona override",
      "  !persona clear           回到默认 persona",
      "  !clear                   清 @-mention 历史",
      "  !clear --all             清历史/侧记/persona override",
      "  !btw <text>              注入运行中的任务 (没有就排队)",
      "  !ps                      看本群在跑的后台任务",
      "  !ps --all                看所有群的任务",
      "  !kill <id>               砍一个任务 (任务 id 来自 !ps)",
      "  !branch <name>           新建分支        (6c)",
      "  !branch list             列分支          (6c)",
      "  !switch <name>           切分支          (6c)"
    ]
helpText (Just topic) =
  "(目前没有 '" <> topic <> "' 的详细帮助，看 !help)"
