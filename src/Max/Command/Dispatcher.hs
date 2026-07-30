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
import Control.Concurrent.STM (TVar, atomically, modifyTVar', readTVarIO)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.BuildInfo (gitRev)
import Max.Command.Help (helpText)
import Max.Skills (skillsForGroup)
import Max.Command.Permission (PermTier (..), adminGrantable, knownCapabilities)
import Max.Command.Types
import Max.DB.Permissions (deleteGrant, insertGrant, listGrantsFor)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text.IO qualified as TIO
import Data.Version (showVersion)
import Distribution.Pretty (prettyShow)
import Distribution.Simple.Utils (cabalVersion)
import Max.Util (trySyncIO)
import Paths_max (version)
import System.Info (arch, fullCompilerVersion, os)
import Text.Read (readMaybe)
import Max.DB.History (HistoryItem (..), fetchMessage, fetchMessagesByIds)
import Max.DB.Memory (MemoryItem (..), MemoryScope (..), countMemories, deleteMemory, fetchMemory, listMemories, listUserMemoriesEverywhere)
import Max.DB.Stickers qualified as Stickers
import Max.Effects.LLM (LLM, listProfiles)
import Max.Browser.Registry (destroyBrowsersForGroup)
import Max.Env (BotEnv (..))
import Max.Intent (IntentConfig (..))
import Max.Sandbox.Docker (ExecResult (..), wrapPackages)
import Max.Sandbox.Registry (SandboxEntry (..), SandboxId (..), destroySandboxesForGroup, ensureSandbox, execInSandbox)
import Max.Session (Session (..), updateSession)
import Max.Session qualified as Session
import Max.Tasks
  ( TaskId (..),
    TaskInfo (..),
    cancelAllTasks,
    cancelTask,
    listTasks,
  )
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)

-- | What the caller should do after dispatching a command.
--
-- Most commands collapse to 'ReplyText' (just say something back).
-- 'SideQuestion' carries !btw: the caller should spawn an ordinary LLM
-- dispatch with the carried text as the user prompt, marked so the
-- supplement classifier can't fold it into a running turn.  Wiring it
-- as a result rather than a direct call keeps Dispatcher free of the
-- Agent/NapCat/Concurrent constraints; 'FeedbackNote' is deferred to
-- the caller for the same reason.
data DispatchResult
  = ReplyText !Text
  | -- | Pure acknowledgement — the caller reacts an OK face onto the
    -- command message instead of posting text.
    ReplyAck
  | -- | Group-audience text: skip the private-delivery routing even
    -- when the command came from a group (e.g. !version — a public
    -- card, not a personal query).
    ReplyPublicText !Text
  | SideQuestion !Text
  | -- | !feedback: hand this note to a turn already running.  The
    -- caller does the routing because it holds the trigger message —
    -- it needs the sender's display name to render the note the way
    -- history lines are rendered, and its reply target to decide which
    -- turn the note is aimed at.
    FeedbackNote !Text
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
  PermTier -> -- the sender's effective tier (Handler resolves it)
  Maybe Int64 -> -- replyTarget message_id, if the command was a reply
  Command ->
  Eff es DispatchResult
execute t gid uid granterTier replyTarget cmd = do
 env :: BotEnv <- ask
 case cmd of
  -- Claude Code's btw: a quick side question that deliberately leaves
  -- the current work alone.  Always its own turn, never an injection —
  -- !feedback is the command for feeding a running turn.  The caller
  -- (Handler.dispatchCommand) spawns a dispatch marked NeverAbsorb, so
  -- the supplement classifier can't overrule the user and fold it into
  -- the running turn after all.  Otherwise it is an ordinary turn:
  -- reply persisted, memory live.  It used to be non-persisting, which
  -- belonged to the old meaning of !btw ("ask without polluting
  -- history") and left the question in the transcript with its answer
  -- deleted — a permanently unanswered-looking line.
  Btw note -> case T.strip note of
    "" -> reply "用法：!btw <要另外问的内容>（另起一轮，不打扰在跑的任务）"
    q -> pure (SideQuestion q)
  -- The other half of the split: hand a note to a turn already running.
  -- Routing happens in the Handler, which has the trigger message and
  -- can render the note the way history lines are rendered.
  Feedback note -> case T.strip note of
    "" -> reply "用法：!feedback <要补充的内容>（回复某轮的触发消息可指定给哪轮，不回复就给最新那轮）"
    body -> pure (FeedbackNote body)
  Help mTopic -> reply (helpText mTopic)
  --
  ModelShow -> do
    s <- liftIO (Session.readSession t)
    reply $ "当前 model: " <> s.model
  ModelList -> do
    profs <- listProfiles
    reply $ "可用 models:\n  " <> T.intercalate "\n  " (sort profs)
  ModelSet name -> do
    profs <- listProfiles
    if name `elem` profs
      then do
        updateSession t (\s -> (s {model = name}, ()))
        logInfo "session: model set" $ object ["model" .= name]
        ack
      else
        reply $
          "找不到 model: "
            <> name
            <> "\n用 !model list 看可用列表"
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
    ack
  --
  PersonaShow -> do
    s <- liftIO (Session.readSession t)
    reply $ case s.persona of
      Nothing -> "(使用默认 persona — 用 !persona <text> 覆盖)"
      Just p -> "当前 persona override:\n" <> p
  PersonaClear -> do
    updateSession t (\s -> (s {persona = Nothing}, ()))
    ack
  PersonaSet p -> do
    updateSession t (\s -> (s {persona = Just p}, ()))
    ack
  --
  Clear -> do
    now <- liftIO getCurrentTime
    updateSession t (\s -> (Session.clearHistory now s, ()))
    ack
  ClearAll -> do
    now <- liftIO getCurrentTime
    updateSession t (\s -> (Session.clearAll now s, ()))
    n <- liftIO (destroySandboxesForGroup env.beSandboxes gid)
    nb <- liftIO (destroyBrowsersForGroup env.beBrowsers gid)
    logInfo "session: clear --all" $
      object ["sandboxes_destroyed" .= n, "browsers_destroyed" .= nb]
    ack
  Unclear -> do
    s <- liftIO (Session.readSession t)
    case s.clearedAt of
      Nothing -> reply "本来就没设水位线"
      Just _ -> do
        updateSession t (\sess -> (Session.unclear sess, ()))
        ack
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
            logInfo "session: pinned" $ object ["message_id" .= mid]
            ack
  Unpin UnpinAll -> do
    updateSession t (\s -> (Session.removeAllPins s, ()))
    ack
  Unpin (UnpinOne mid) -> do
    updateSession t (\s -> (Session.removePin mid s, ()))
    ack
  Unpin UnpinReply -> case replyTarget of
    Nothing -> reply "用法：引用要 unpin 的那条消息发 !unpin，或者 !unpin <id> / !unpin all"
    Just mid -> do
      updateSession t (\s -> (Session.removePin mid s, ()))
      ack
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
    if ok
      then ack
      else reply ("找不到任务 " <> tid <> " (用 !ps 看在跑的)")
  KillAll -> do
    n <- liftIO (cancelAllTasks env.beTasks)
    if n == 0
      then reply "没有在跑的任务"
      else ack
  Shell pkgs cmdLine -> do
    -- Direct passthrough to the group's default sandbox — same
    -- container the model's sandbox_exec uses, so `! ls` and the
    -- model's file ops share state.  Leading +pkg tokens go on PATH
    -- for this command via the same nix-shell wrapper the tool uses.
    esb <- liftIO (ensureSandbox env.beSandboxes gid)
    case esb of
      Left err -> reply ("sandbox 启动失败: " <> err)
      Right e -> do
        logInfo "shell" $
          object ["sandbox" .= e.seId.unSandboxId, "pkgs" .= pkgs, "cmd" .= cmdLine]
        res <-
          liftIO $
            execInSandbox env.beSandboxes gid e.seId (wrapPackages pkgs cmdLine) (shellTimeoutSecs pkgs)
        reply $ case res of
          Left err -> "执行失败: " <> err
          Right er -> formatExecResult er
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
    gms <- listMemories ScopeGroup gidRaw gidRaw
    -- Deliberately unscoped: this is the self-audit channel, and with
    -- memories partitioned per group it is the only place someone can
    -- see the whole record the bot keeps on them.  Private chats only,
    -- and the subject is the audience.
    ums <- if private then listUserMemoriesEverywhere uidRaw else pure []
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
            ack
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
    ack
  ProactiveStatus -> do
    sess <- liftIO (Session.readSession t)
    reply $ case env.beIntent of
      Nothing ->
        "主动插话：未配置（config 里设 intent.profile 启用意图识别）"
      Just ic ->
        T.concat
          [ "主动插话：",
            renderStickerState True sess.proactiveOverride,
            "\n判定模型：", ic.icProfile,
            "，冷却 ", tshow ic.icCooldownSeconds, "s（仅话题类；点名/对话延续不受冷却）",
            "，每小时上限 ", tshow ic.icMaxPerHour,
            "\n用 !proactive on/off/default 开关（被 @/引用的触发不受影响）"
          ]
  ProactiveSet mb -> do
    updateSession t $ \s ->
      ( case mb of
          Just b -> Session.setProactiveOverride b s
          Nothing -> Session.clearProactiveOverride s,
        ()
      )
    logInfo "session: proactive override" $ object ["value" .= mb]
    ack
  Version -> do
    now <- liftIO getCurrentTime
    osName <- liftIO readOsPretty
    hostUp <- liftIO readHostUptime
    -- What THIS group's dispatches see (global + group, shadowed),
    -- not the whole registry — the card answers "what can you do
    -- here", and the counts differ once a group grows local skills.
    skillCount <- liftIO (length <$> skillsForGroup env.beSkills gid)
    -- Single newlines only: a blank line would split the card into
    -- separate messages ('planReply').  Public on purpose: the
    -- version card is group trivia, not a personal query.
    pure . ReplyPublicText . T.intercalate "\n" $
      [ "🦈 max v" <> T.pack (showVersion version) <> maybe "" (\r -> " (" <> T.pack r <> ")") gitRev,
        "🌊 " <> osName <> " · " <> T.pack arch,
        "🫧 ghc " <> T.pack (showVersion fullCompilerVersion) <> " · cabal " <> T.pack (prettyShow cabalVersion),
        "🐚 " <> tshow skillCount <> " skills available",
        "⏱️ up " <> fmtDur (realToFrac (diffUTCTime now env.beStartedAt))
          <> maybe "" (\u -> " · host " <> fmtDur u) hostUp
      ]
  StickerList -> do
    rows <- Stickers.listRecentStickers 10
    reply (formatStickers rows)
  StickerBan prefix -> banSticker True prefix
  StickerUnban prefix -> banSticker False prefix
  --
  Grant target cap deny global
    | cap `notElem` knownCapabilities ->
        reply $ "未知权限名: " <> cap <> "\n可用: " <> T.intercalate "、" knownCapabilities
    | granterTier < TierOwner && (global || deny) ->
        reply "--global / --deny 需要 owner 权限"
    | granterTier < TierOwner && cap `notElem` adminGrantable ->
        reply $ "群管理员只能授予: " <> T.intercalate "、" adminGrantable
    | otherwise -> do
        let GroupId gidRaw = gid
            UserId granterRaw = uid
            scope = if global then Nothing else Just gidRaw
        insertGrant target cap scope deny granterRaw
        logInfo "perm: granted" $
          object
            [ "target" .= target,
              "capability" .= cap,
              "scope" .= scope,
              "deny" .= deny,
              "by" .= granterRaw
            ]
        ack
  Revoke target cap global
    | granterTier < TierOwner && global ->
        reply "--global 需要 owner 权限"
    | granterTier < TierOwner && cap `notElem` adminGrantable ->
        reply $ "群管理员只能撤销: " <> T.intercalate "、" adminGrantable
    | otherwise -> do
        let GroupId gidRaw = gid
            scope = if global then Nothing else Just gidRaw
        ok <- deleteGrant target cap scope
        if ok
          then do
            logInfo "perm: revoked" $
              object ["target" .= target, "capability" .= cap, "scope" .= scope]
            ack
          else reply "没有这条授权（注意 scope：群内授权和 --global 是两条）"
  Perms mTarget -> do
    let UserId uidRaw = uid
        target = maybe uidRaw id mTarget
    rows <- listGrantsFor target
    reply $
      "用户 "
        <> T.pack (show target)
        <> " 的显式授权：\n"
        <> if null rows
          then "（无；生效的是身份层级：owner / 群管理员 / 成员）"
          else
            T.intercalate
              "\n"
              [ "  "
                  <> (if deny then "✗ 禁用 " else "✓ ")
                  <> cap
                  <> maybe "（全局）" (\g -> "（群 " <> T.pack (show g) <> "）") mScope
              | (cap, mScope, deny) <- rows
              ]
  -- Admin-console target selection.  Only meaningful in DMs: in a
  -- group the command already acts on that group.  NB: 'gid' here is
  -- the ORIGINAL chat id — Handler skips target redirection for the
  -- !use family itself.
  UseShow
    | not (isPrivateChat gid) -> reply "!use 只在私聊里有意义（群里发的命令就作用于本群）"
    | otherwise -> do
        let UserId uidRaw = uid
        targets <- liftIO (readTVarIO env.beAdminTarget)
        reply $ case Map.lookup uidRaw targets of
          Just g -> "当前操作对象：群 " <> T.pack (show g) <> "（!use clear 退出）"
          Nothing -> "没有选中的群；!use <群号> 之后，你在私聊里发的命令都作用于那个群"
  UseSet g
    | not (isPrivateChat gid) -> reply "!use 只在私聊里有意义"
    | otherwise -> do
        known <- groupKnown g
        if not known
          then reply $ "我没见过群 " <> T.pack (show g) <> "（bot 不在这个群，或还没收到过它的消息）"
          else do
            let UserId uidRaw = uid
            liftIO (atomically (modifyTVar' env.beAdminTarget (Map.insert uidRaw g)))
            reply $
              "好，接下来你私聊里的命令都作用于群 "
                <> T.pack (show g)
                <> "。\n权限按你在那个群的身份算；!use clear 退出，!status 看概览。"
  UseClear
    | not (isPrivateChat gid) -> reply "!use 只在私聊里有意义"
    | otherwise -> do
        let UserId uidRaw = uid
        liftIO (atomically (modifyTVar' env.beAdminTarget (Map.delete uidRaw)))
        ack
  Status -> do
    s <- liftIO (Session.readSession t)
    let GroupId gidRaw = gid
    memCount <- countMemories ScopeGroup gidRaw gidRaw
    tasks <- liftIO (listTasks env.beTasks (Just gid))
    reply . T.intercalate "\n" $
      [ (if isPrivateChat gid then "本私聊" else "群 " <> T.pack (show gidRaw)) <> " 状态：",
        "  model: " <> s.model,
        "  persona: " <> maybe "（默认）" (\p -> T.take 40 p <> if T.length p > 40 then "…" else "") s.persona,
        "  debug: " <> onOff env.beDebugDefault s.debugOverride,
        "  sticker: " <> onOff env.beStickerDefault s.stickerOverride,
        "  proactive: " <> onOff (maybe False (const True) env.beIntent) s.proactiveOverride,
        "  pin: " <> T.pack (show (length s.pinned)) <> " 条",
        "  记忆: " <> T.pack (show memCount) <> " 条",
        "  任务: " <> T.pack (show (length tasks)) <> " 个在跑",
        "  !clear 水位: " <> maybe "无" (T.pack . show) s.clearedAt
      ]
  Unknown v _ ->
    reply $
      "不认识的命令: !"
        <> v
        <> "\n用 !help 看可用命令"
  where
    -- Has the bot ever seen this group?  Cheap sanity check for !use.
    groupKnown g = do
      rows <-
        query
          "SELECT 1 FROM messages WHERE group_id = ? LIMIT 1"
          (Only g)
      pure (not (null (rows :: [Only Int])))

    onOff dflt override = case override of
      Just True -> "on（session 覆盖）"
      Just False -> "off（session 覆盖）"
      Nothing -> (if dflt then "on" else "off") <> "（配置默认）"
    reply :: Applicative f => Text -> f DispatchResult
    reply = pure . ReplyText

    -- Pure acknowledgement: an OK reaction on the command message.
    ack :: Applicative f => f DispatchResult
    ack = pure ReplyAck

    banSticker b prefix
      | T.length prefix < 6 =
          reply "sha 前缀至少 6 位（!sticker list 里有）"
      | otherwise = do
          n <- Stickers.setStickerBanned b prefix
          if n == 0
            then reply ("没有匹配 " <> prefix <> "* 的表情")
            else ack

--------------------------------------------------------------------------------
-- !version system info (best-effort, Linux; fall back quietly).

-- | Distro name from /etc/os-release's PRETTY_NAME; falls back to the
-- compiler's notion of the OS.
readOsPretty :: IO Text
readOsPretty = do
  r <- trySyncIO (TIO.readFile "/etc/os-release")
  pure $ case r of
    Right c
      | (l : _) <- [l | l <- T.lines c, "PRETTY_NAME=" `T.isPrefixOf` l] ->
          T.dropAround (== '"') (T.drop (T.length "PRETTY_NAME=") l)
    _ -> T.pack os

-- | Host uptime in seconds (/proc/uptime's first field).
readHostUptime :: IO (Maybe Double)
readHostUptime = do
  r <- trySyncIO (TIO.readFile "/proc/uptime")
  pure $ case r of
    Right c | (w : _) <- T.words c, Just d <- readMaybe (T.unpack w) -> Just d
    _ -> Nothing

-- | Compact duration: the two most significant units ("3d 4h",
-- "2h 13m", "5m 12s").
fmtDur :: Double -> Text
fmtDur secs =
  let s = max 0 (round secs) :: Int
      (d, s1) = s `divMod` 86400
      (h, s2) = s1 `divMod` 3600
      (m, sec) = s2 `divMod` 60
   in case () of
        _
          | d > 0 -> tshow d <> "d " <> tshow h <> "h"
          | h > 0 -> tshow h <> "h " <> tshow m <> "m"
          | m > 0 -> tshow m <> "m " <> tshow sec <> "s"
          | otherwise -> tshow sec <> "s"

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
-- !memory formatting.

formatMemories :: Bool -> [MemoryItem] -> [(MemoryItem, Maybe Int64)] -> Text
formatMemories _ [] [] = "没有长期记忆（bot 觉得值得记的东西会存在这里）"
formatMemories private gms ums =
  T.unlines . concat $
    [ if null gms
        then []
        else (if private then "本会话记忆:" else "本群记忆:") : map memLine gms,
      if null ums
        then []
        else "你的记忆（全部会话，只在私聊显示）:" : map userLine ums,
      ["用 !memory rm <id> 删除"]
    ]
  where
    memLine m = "  #" <> T.pack (show m.memId) <> "  " <> m.memContent
    -- Each carries where it was learned: they only apply in that
    -- conversation now, so a bare list would say nothing about where
    -- the bot will actually use them.
    userLine (m, mSrc) =
      "  #" <> T.pack (show m.memId) <> "  " <> srcTag mSrc <> " " <> m.memContent
    srcTag Nothing = "[来源未知]"
    srcTag (Just g)
      | isPrivateChat (GroupId g) = "[私聊]"
      | otherwise = "[群" <> T.pack (show g) <> "]"

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

-- | Wallclock cap for a user @! \<cmd\>@ shell command.  A plain
-- command gets an interactive-snappy 30s; one that pulls @+pkg@ gets
-- 180s, because the first fetch of a package into the shared store
-- can take a while (later uses are instant — same store the model's
-- sandbox_exec fills).
shellTimeoutSecs :: [Text] -> Int
shellTimeoutSecs pkgs = if null pkgs then 30 else 180

-- | Render a sandbox exec result as a chat reply: stdout, then stderr
-- (labelled) if any, then a trailing status line for non-zero exits
-- or truncation.  A clean, silent, zero-exit command replies "(无输出)"
-- so the user still gets an acknowledgement.
formatExecResult :: ExecResult -> Text
formatExecResult er =
  let out = T.stripEnd er.erStdout
      err = T.stripEnd er.erStderr
      stderrPart
        | T.null err = []
        | otherwise = ["[stderr]\n" <> err]
      statusPart =
        [ "[退出码 " <> tshow er.erExitCode <> "]"
        | er.erExitCode /= 0
        ]
          <> [ "[输出已截断"
                 <> maybe "" ("，完整输出在 " <>) er.erSpillPath
                 <> "]"
             | er.erTruncated
             ]
      body = filter (not . T.null) [out] <> stderrPart <> statusPart
   in case body of
        [] -> "(无输出)"
        parts -> T.intercalate "\n" parts

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
      ageText now ti.tiStartedAt,
      -- Who started it.  Informational only — anyone may !feedback at
      -- any running turn.
      byTag
    ]
      <> [triggerTag | Just _ <- [ti.tiTrigger]]
      <> [groupTag | Just _ <- [callerGid]]
      <> [pendingTag | ti.tiPending > 0]
  where
    GroupId raw = ti.tiGroup
    UserId uidRaw = ti.tiUser
    byTag = "by=" <> T.pack (show uidRaw)
    -- The message to reply to when aiming a !feedback at this turn
    -- rather than at whatever is newest.
    triggerTag = "on=#" <> maybe "" (T.pack . show) ti.tiTrigger
    groupTag = "group=" <> T.pack (show raw)
    pendingTag = "fb=" <> T.pack (show ti.tiPending)

ageText :: UTCTime -> UTCTime -> Text
ageText now started =
  let secs = round (realToFrac (diffUTCTime now started) :: Double) :: Int
   in case secs of
        n | n < 60 -> T.pack (show n) <> "s"
        n | n < 3600 -> T.pack (show (n `div` 60)) <> "m"
        n -> T.pack (show (n `div` 3600)) <> "h"
