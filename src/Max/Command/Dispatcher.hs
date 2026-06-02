-- |
-- Execute parsed 'Command's against the session registry and produce
-- the text the bot should reply with.  All side-effects (DB writes,
-- session mutations) happen here; the parser is pure.
--
-- 'execute' returns the reply 'Text'; the handler posts it via the
-- NapCat effect.  Returning 'Nothing' means "command produced no
-- reply" (currently only !btw without inject context falls here is
-- still a reply — kept for future commands).
--
-- Commands that don't exist yet (!ps !kill !branch !switch in Phase
-- 6a) return a friendly "coming in Phase 6b/6c" stub.
module Max.Command.Dispatcher
  ( execute,
  )
where

import Control.Concurrent.STM (TVar)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Command.Types
import Max.Effects.LLM (LLM, listProfiles)
import Max.Session (Session (..), updateSession)
import Max.Session qualified as Session

-- | Run one command and produce the reply text.
execute ::
  ( Log :> es,
    WithConnection :> es,
    LLM :> es,
    IOE :> es
  ) =>
  TVar Session ->
  Command ->
  Eff es Text
execute t cmd = case cmd of
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
    pure "✓ history / btw / persona override 全清"
  --
  Btw note -> do
    -- Phase 6a: queue-only fallback (no running tasks yet).
    -- Phase 6b will check the task registry first and inject if any
    -- task is in flight, falling back to this queue otherwise.
    updateSession t (\s -> (Session.appendBtwNote note s, ()))
    n <- (length . (.btwNotes)) <$> liftIO (Session.readSession t)
    pure $ "✓ 侧记已收 (" <> T.pack (show n) <> " 条待消化)"
  --
  PsLocal -> pure "(后台任务表 Phase 6b 接入)"
  PsAll -> pure "(后台任务表 Phase 6b 接入)"
  Kill _ -> pure "(任务取消 Phase 6b 接入)"
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
      "  !btw <text>              排一条侧记，下次回复消化",
      "  !ps                      看本群后台任务  (6b)",
      "  !kill <id>               砍后台任务      (6b)",
      "  !branch <name>           新建分支        (6c)",
      "  !branch list             列分支          (6c)",
      "  !switch <name>           切分支          (6c)"
    ]
helpText (Just topic) =
  -- Phase 6a: no per-topic help yet; punt back to the index.
  "(目前没有 '" <> topic <> "' 的详细帮助，看 !help)"
