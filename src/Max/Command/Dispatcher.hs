-- |
-- Execute parsed 'Command's against the session registry + task
-- registry, producing the text the bot should reply with.  All
-- side-effects (DB writes, session mutations, task pokes) happen here;
-- the parser is pure.
module Max.Command.Dispatcher
  ( execute,
    DispatchResult (..),
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (TVar)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Types
import Data.Int (Int64)
import Max.DB.History (HistoryItem (..), fetchMessage, fetchMessagesByIds)
import Max.DB.Memory (MemoryItem (..), MemoryScope (..), deleteMemory, fetchMemory, listMemories)
import Max.DB.Stickers qualified as Stickers
import Max.Effects.LLM (LLM, listProfiles)
import Max.Browser.Registry (destroyBrowsersForGroup)
import Max.Env (BotEnv (..))
import Max.Sandbox.Registry (destroySandboxesForGroup)
import Max.Session (Session (..), updateSession)
import Max.Session qualified as Session
import Max.Tasks
  ( TaskId (..),
    TaskInfo (..),
    cancelAllTasks,
    cancelTask,
    listTasks,
    pushBtwToLatest,
  )
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)

-- | What the caller should do after dispatching a command.
--
-- Most commands collapse to 'ReplyText' (just say something back).
-- 'EphemeralAsk' is reserved for the new !btw semantics: the caller
-- should spawn a regular LLM dispatch with the carried text as the
-- user prompt, but under 'Max.Persistence.withEphemeral' so the
-- reply doesn't get persisted to mention history.  Wiring it as a
-- result rather than a direct call keeps Dispatcher free of the
-- Agent/NapCat/Concurrent constraints.
data DispatchResult
  = ReplyText !Text
  | EphemeralAsk !Text
  deriving stock (Show, Eq)

-- | Run one command and produce a 'DispatchResult'.
--
-- @replyTarget@ is the @message_id@ extracted from the trigger
-- message's @SegReply@ (if any) — lets bare @!pin@ / @!unpin@ refer
-- to the message the user replied to without typing an id.
execute ::
  ( Log :> es,
    WithConnection :> es,
    LLM :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TVar Session ->
  GroupId ->
  UserId -> -- the command's sender (permission scope for !memory rm)
  Maybe Int64 -> -- replyTarget message_id, if the command was a reply
  Command ->
  Eff es DispatchResult
execute t gid uid replyTarget cmd = do
 env :: BotEnv <- ask
 case cmd of
  Btw note -> do
    -- Prefer injecting into a running task in this group.  Otherwise
    -- become the new !btw: an ephemeral one-shot LLM ask using
    -- current context.  The caller (Handler.dispatchCommand) sees
    -- 'EphemeralAsk' and spawns a 'withEphemeral'-wrapped dispatch.
    injected <- liftIO (pushBtwToLatest env.beTasks gid note)
    if injected
      then reply "✓ 侧记已注入运行中的任务"
      else case T.strip note of
        "" -> reply "用法：!btw <要临时问的内容>（不污染对话历史）"
        q -> pure (EphemeralAsk q)
  Help mTopic -> reply (helpText mTopic)
  --
  ModelShow -> do
    s <- liftIO (Session.readSession t)
    reply $
      "当前 model: "
        <> s.model
        <> "  思考: "
        <> renderThinkingState s.thinkingOverride
  ModelList -> do
    profs <- listProfiles
    reply $ "可用 models:\n  " <> T.intercalate "\n  " (sort profs)
  ModelSet name -> do
    profs <- listProfiles
    if name `elem` profs
      then do
        updateSession t (\s -> (s {model = name}, ()))
        logInfo "session: model set" $ object ["model" .= name]
        reply $ "✓ model 切到 " <> name
      else
        reply $
          "找不到 model: "
            <> name
            <> "\n用 !model list 看可用列表"
  ModelThinkShow -> do
    s <- liftIO (Session.readSession t)
    reply $ "思考: " <> renderThinkingState s.thinkingOverride
  ModelThinkSet b -> do
    updateSession t (\s -> (Session.setThinkingOverride b s, ()))
    logInfo "session: thinking override" $ object ["value" .= b]
    reply $ "✓ 思考模式 " <> (if b then "开" else "关") <> "（覆盖 profile 默认）"
  --
  DebugShow -> do
    s <- liftIO (Session.readSession t)
    reply $ "debug: " <> renderDebugState env.beDebugDefault s.debugOverride
  DebugSet mb -> do
    updateSession t $ \s ->
      ( case mb of
          Just b -> Session.setDebugOverride b s
          Nothing -> Session.clearDebugOverride s,
        ()
      )
    logInfo "session: debug override" $ object ["value" .= mb]
    reply $ case mb of
      Just True -> "✓ debug 开 — 工具调用会打印到群里"
      Just False -> "✓ debug 关 — 工具调用不再打印"
      Nothing ->
        "✓ debug 回到配置默认（当前默认"
          <> (if env.beDebugDefault then "开" else "关")
          <> "）"
  --
  PersonaShow -> do
    s <- liftIO (Session.readSession t)
    reply $ case s.persona of
      Nothing -> "(使用默认 persona — 用 !persona <text> 覆盖)"
      Just p -> "当前 persona override:\n" <> p
  PersonaClear -> do
    updateSession t (\s -> (s {persona = Nothing}, ()))
    reply "✓ persona override 已清，回到默认"
  PersonaSet p -> do
    updateSession t (\s -> (s {persona = Just p}, ()))
    reply $ "✓ persona 已设 (" <> T.pack (show (T.length p)) <> " 字)"
  --
  Clear -> do
    now <- liftIO getCurrentTime
    updateSession t (\s -> (Session.clearHistory now s, ()))
    reply "✓ history 已清，之后的 prompt 不再带这之前的群上下文"
  ClearAll -> do
    now <- liftIO getCurrentTime
    updateSession t (\s -> (Session.clearAll now s, ()))
    n <- liftIO (destroySandboxesForGroup env.beSandboxes gid)
    nb <- liftIO (destroyBrowsersForGroup env.beBrowsers gid)
    logInfo "session: clear --all" $
      object ["sandboxes_destroyed" .= n, "browsers_destroyed" .= nb]
    let sboxSuffix
          | n == 0 = ""
          | otherwise = "，并销毁了 " <> T.pack (show n) <> " 个 sandbox"
    reply $ "✓ history / btw / persona override 全清，群上下文水位线已置" <> sboxSuffix
  Unclear -> do
    s <- liftIO (Session.readSession t)
    case s.clearedAt of
      Nothing -> reply "本来就没设水位线"
      Just _ -> do
        updateSession t (\sess -> (Session.unclear sess, ()))
        reply "✓ 水位线已撤销，下次 prompt 又能看到 !clear 之前的群上下文了"
  --
  Pin mExplicitId -> do
    let mTarget = mExplicitId <|> replyTarget
    case mTarget of
      Nothing ->
        reply "用法：引用要 pin 的那条消息发 !pin，或者 !pin <message_id>"
      Just mid -> do
        mMsg <- fetchMessage mid
        case mMsg of
          Nothing -> reply $ "找不到 message_id=" <> T.pack (show mid)
          Just _ -> do
            updateSession t (\s -> (Session.addPin mid s, ()))
            pinCount <- (length . (.pinned)) <$> liftIO (Session.readSession t)
            logInfo "session: pinned" $ object ["message_id" .= mid]
            reply $
              "✓ pinned message_id="
                <> T.pack (show mid)
                <> "（当前共 "
                <> T.pack (show pinCount)
                <> " 条 pin）"
  Unpin UnpinAll -> do
    n <- (length . (.pinned)) <$> liftIO (Session.readSession t)
    updateSession t (\s -> (Session.removeAllPins s, ()))
    reply $ "✓ 清空所有 pin（共 " <> T.pack (show n) <> " 条）"
  Unpin (UnpinOne mid) -> do
    updateSession t (\s -> (Session.removePin mid s, ()))
    reply $ "✓ unpinned message_id=" <> T.pack (show mid)
  Unpin UnpinReply -> case replyTarget of
    Nothing -> reply "用法：引用要 unpin 的那条消息发 !unpin，或者 !unpin <id> / !unpin all"
    Just mid -> do
      updateSession t (\s -> (Session.removePin mid s, ()))
      reply $ "✓ unpinned message_id=" <> T.pack (show mid)
  Pins -> do
    s <- liftIO (Session.readSession t)
    case s.pinned of
      [] -> reply "没有 pin 任何消息"
      ids -> do
        items <- fetchMessagesByIds ids
        reply (formatPins items)
  --
  PsLocal -> do
    now <- liftIO getCurrentTime
    tasks <- liftIO (listTasks env.beTasks (Just gid))
    reply (formatTasks now Nothing tasks)
  PsAll -> do
    now <- liftIO getCurrentTime
    tasks <- liftIO (listTasks env.beTasks Nothing)
    reply (formatTasks now (Just gid) tasks)
  Kill tid -> do
    ok <- liftIO (cancelTask env.beTasks (TaskId tid))
    reply $
      if ok
        then "✓ 已发取消信号给 " <> tid
        else "找不到任务 " <> tid <> " (用 !ps 看在跑的)"
  KillAll -> do
    n <- liftIO (cancelAllTasks env.beTasks)
    reply $
      if n == 0
        then "没有在跑的任务"
        else "✓ 已发取消信号给全部 " <> T.pack (show n) <> " 个任务"
  --
  -- In a group, group scope only: the reply is public, and a member's
  -- user-scope memories may have been learned in *other* groups —
  -- printing them would leak across groups.  In a private chat the
  -- audience IS the subject, so their own cross-group memories are
  -- safe to show — that's the self-audit channel.
  MemoryList -> do
    let GroupId gidRaw = gid
        UserId uidRaw = uid
        private = isPrivateChat gid
    gms <- listMemories ScopeGroup gidRaw
    ums <- if private then listMemories ScopeUser uidRaw else pure []
    reply (formatMemories private gms ums)
  MemoryRm mid -> do
    let GroupId gidRaw = gid
        UserId uidRaw = uid
    mMem <- fetchMemory mid
    case mMem of
      Nothing -> reply $ "没有 id=" <> T.pack (show mid) <> " 的记忆"
      Just m
        -- A member may delete this group's memories and their own
        -- user memories — not other people's, and not other groups'.
        | (m.memScope == "group" && m.memScopeId == gidRaw)
            || (m.memScope == "user" && m.memScopeId == uidRaw) -> do
            _ <- deleteMemory mid
            logInfo "memory: removed via !memory" $ object ["id" .= mid]
            reply $ "✓ 已删除记忆 #" <> T.pack (show mid)
        | otherwise -> reply "只能删本群的记忆或你自己的记忆"
  --
  StickerStats -> do
    st <- Stickers.stickerStats
    sess <- liftIO (Session.readSession t)
    reply $
      T.concat
        [ "表情包库：共 ", tshow st.ssTotal,
          "，已识图 ", tshow st.ssCaptioned,
          "，待识图 ", tshow st.ssPending,
          "，已屏蔽 ", tshow st.ssBanned,
          "\n发送开关：", renderStickerState env.beStickerDefault sess.stickerOverride,
          "\n用 !sticker on/off/default 开关；!sticker list 看最近的；!sticker ban <sha前缀> 屏蔽"
        ]
  StickerSet mb -> do
    updateSession t $ \s ->
      ( case mb of
          Just b -> Session.setStickerOverride b s
          Nothing -> Session.clearStickerOverride s,
        ()
      )
    logInfo "session: sticker override" $ object ["value" .= mb]
    reply $ case mb of
      Just True -> "✓ 表情包发送 开 — bot 可以主动发表情了"
      Just False -> "✓ 表情包发送 关 — bot 不再发表情（仍会学习入库）"
      Nothing ->
        "✓ 表情包发送回到配置默认（当前默认"
          <> (if env.beStickerDefault then "开" else "关")
          <> "）"
  StickerList -> do
    rows <- Stickers.listRecentStickers 10
    reply (formatStickers rows)
  StickerBan prefix -> banSticker True prefix
  StickerUnban prefix -> banSticker False prefix
  --
  BranchList -> do
    s <- liftIO (Session.readSession t)
    bs <- Session.listBranches gid
    reply (formatBranches s.branch bs)
  BranchNew name -> do
    now <- liftIO getCurrentTime
    res <- Session.forkAndSwitch env.beSessions gid name now
    case res of
      Left err -> reply err
      Right () -> do
        logInfo "session: branch forked + switched" $
          object ["branch" .= name]
        reply $
          "✓ 已创建并切到分支 " <> name
            <> "\n（继承了 model/persona/pinned/thinking；btw 清空；上下文水位线设到现在——用 !unclear 看老群消息）"
  BranchDelete name -> do
    res <- Session.dropBranch gid name
    case res of
      Left err -> reply err
      Right () -> do
        logInfo "session: branch deleted" $ object ["branch" .= name]
        reply $ "✓ 已删除分支 " <> name
  Switch name -> do
    res <- Session.switchToBranch env.beSessions gid name env.beDefaultModel
    case res of
      Left err -> reply err
      Right () -> do
        logInfo "session: branch switched" $ object ["branch" .= name]
        reply $ "✓ 已切到分支 " <> name
  --
  Unknown v _ ->
    reply $
      "不认识的命令: !"
        <> v
        <> "\n用 !help 看可用命令"
  where
    reply :: Applicative f => Text -> f DispatchResult
    reply = pure . ReplyText

    banSticker b prefix
      | T.length prefix < 6 =
          reply "sha 前缀至少 6 位（!sticker list 里有）"
      | otherwise = do
          n <- Stickers.setStickerBanned b prefix
          reply $ case n of
            0 -> "没有匹配 " <> prefix <> "* 的表情"
            _ ->
              "✓ 已"
                <> (if b then "屏蔽 " else "解除屏蔽 ")
                <> tshow n
                <> " 个表情"

renderThinkingState :: Maybe Bool -> Text
renderThinkingState = \case
  Nothing -> "(跟随 profile/服务端默认)"
  Just True -> "开 (session 覆盖)"
  Just False -> "关 (session 覆盖)"

renderDebugState :: Bool -> Maybe Bool -> Text
renderDebugState defB = \case
  Nothing -> (if defB then "开" else "关") <> " (配置默认)"
  Just True -> "开 (session 覆盖)"
  Just False -> "关 (session 覆盖)"

renderStickerState :: Bool -> Maybe Bool -> Text
renderStickerState defB = \case
  Nothing -> (if defB then "开" else "关") <> " (配置默认)"
  Just True -> "开 (session 覆盖)"
  Just False -> "关 (session 覆盖)"

--------------------------------------------------------------------------------
-- !branch formatting.

formatBranches :: Text -> [Text] -> Text
formatBranches _ [] = "(没有分支 — 异常状态，重启 bot 重建 main)"
formatBranches active bs =
  T.unlines $ "分支：" : map line (sort bs)
  where
    line b
      | b == active = "  * " <> b <> "  (active)"
      | otherwise = "    " <> b

--------------------------------------------------------------------------------
-- !memory formatting.

formatMemories :: Bool -> [MemoryItem] -> [MemoryItem] -> Text
formatMemories _ [] [] = "没有长期记忆（bot 觉得值得记的东西会存在这里）"
formatMemories private gms ums =
  T.unlines . concat $
    [ if null gms
        then []
        else (if private then "本会话记忆:" else "本群记忆:") : map memLine gms,
      if null ums
        then []
        else "你的记忆（跨群，只在私聊显示）:" : map memLine ums,
      ["用 !memory rm <id> 删除"]
    ]
  where
    memLine m = "  #" <> T.pack (show m.memId) <> "  " <> m.memContent

--------------------------------------------------------------------------------
-- !sticker formatting.

formatStickers :: [Stickers.StickerRow] -> Text
formatStickers [] = "还没有识图完成的表情包（bot 会从群里学）"
formatStickers rows =
  T.unlines $
    "最近见过的表情包（sha前缀 见/发 简介）："
      : [ "  "
            <> T.take 8 r.srSha
            <> "  "
            <> tshow r.srTimesSeen
            <> "/"
            <> tshow r.srTimesSent
            <> "  "
            <> T.take 40 r.srDescription
        | r <- rows
        ]

tshow :: Show a => a -> Text
tshow = T.pack . show

--------------------------------------------------------------------------------
-- !pins formatting.

formatPins :: [HistoryItem] -> Text
formatPins [] = "没有 pin 任何消息"
formatPins items =
  T.unlines $
    "pinned:" : map oneLine items
  where
    oneLine h =
      "  "
        <> T.pack (show h.messageId)
        <> "  "
        <> (case h.senderNickname of Just n -> n; Nothing -> T.pack (show h.userId))
        <> "  "
        <> trunc 60 h.renderedText
    trunc n t
      | T.length t <= n = t
      | otherwise = T.take n t <> "…"

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
      "  !model                   看当前 model + 思考状态",
      "  !model list              列所有 model",
      "  !model <name>            切 model",
      "  !model think             看当前思考开关",
      "  !model think on/off      开/关思考模式 (session 覆盖)",
      "  !debug                   看 debug 状态（开时工具调用打印到群里）",
      "  !debug on/off/default    开/关/回到配置默认 (session 覆盖)",
      "  !persona                 看当前 persona override",
      "  !persona <text>          设 persona override",
      "  !persona clear           回到默认 persona",
      "  !clear                   清 @-mention 历史 + 置群上下文水位线",
      "  !clear --all             清历史/侧记/persona override + 置水位线 + 销毁 sandbox",
      "  !unclear                 撤销水位线（恢复看 !clear 之前的群消息）",
      "  !pin [id]                pin 一条消息（不带 id 时用引用的那条）",
      "  !unpin [id|all]          移除 pin（同上语法 + all 清空）",
      "  !pins                    列出当前 pin 的消息",
      "  !btw <text>              在跑的任务里就注入侧记；否则当前上下文临时问一句（不入对话历史）",
      "  !memory                  看本群的长期记忆",
      "  !memory rm <id>          删除一条记忆（本群的或你自己的）",
      "  !sticker                 表情包库统计 + 发送开关状态（bot 从群里学表情包）",
      "  !sticker on/off/default  开/关/回到配置默认 bot 主动发表情 (session 覆盖)",
      "  !sticker list            看最近识图完成的表情包",
      "  !sticker ban <sha前缀>   屏蔽某个表情（unban 恢复）",
      "  !ps                      看本群在跑的后台任务",
      "  !ps --all                看所有群的任务",
      "  !kill <id>               砍一个任务 (任务 id 来自 !ps)",
      "  !kill --all              砍掉所有群的全部任务",
      "  !branch                  列分支（标出 active）",
      "  !branch <name>           创建并切到新分支（fork 当前；上下文水位线设到现在）",
      "  !branch delete <name>    删除分支（不能删 active / 最后一个）",
      "  !switch <name>           切到已存在的分支"
    ]
helpText (Just topic) =
  "(目前没有 '" <> topic <> "' 的详细帮助，看 !help)"
