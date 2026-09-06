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
import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO)
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Browser.Registry (destroyBrowsersForGroup)
import Max.DB.Browser (revokeConversationBrowsers)
import Max.Command.Help (helpText)
import Max.Command.Types
import Max.Command.Version (readHostUptime, readOsPretty, versionCard)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History (HistoryItem (..), bestName, fetchMessageInScope, fetchMessagesByIdsInScope)
import Max.DB.Stickers qualified as Stickers
import Max.Env (BotEnv (..))
import Max.Intent (IntentConfig (..))
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryMutationResult (..),
    MemoryVersion (..),
    archiveMemory,
    countMemories,
    fetchMemory,
    groupMemoryNamespace,
    listMemories,
    userMemoryNamespace,
  )
import Max.ModelCatalog (ModelCapabilities (..), ModelCatalog, lookupModelCapabilities, modelProfileNames)
import Max.Sandbox.Docker (ExecResult (..))
import Max.Sandbox.Registry (SandboxEntry (..), SandboxId (..), destroySandboxesForGroup, ensureSandbox, execInSandbox)
import Max.Platform.Types (PrincipalId (..))
import Max.Session (Session (..), SessionHandle, updateSession)
import Max.Session qualified as Session
import Max.Skills (skillsForGroup)
import Max.Tasks
  ( TaskId (..),
    TaskInfo (..),
    cancelAllTasks,
    cancelTask,
    listTasks,
  )
import Max.Toolset (toolCountFor)
import Max.Util (tshow)
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)

-- | What the caller should do after dispatching a command.
--
-- Most commands collapse to 'ReplyText' (just say something back).
-- 'SideQuestion' carries !btw: the caller should spawn an ordinary LLM
-- dispatch with the carried text as the user prompt, marked so the
-- supplement classifier can't fold it into a running turn.  Wiring it
-- as a result rather than a direct call keeps Dispatcher free of the
-- Agent/platform-write/Concurrent constraints; 'FeedbackNote' is deferred to
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
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  SessionHandle ->
  GroupId ->
  UserId -> -- the command's sender (permission scope for !memory rm)
  PrincipalId -> -- the same sender as a person, for memory scoping
  Maybe Int64 -> -- replyTarget canonical message id, if the command was a reply
  Command ->
  Eff es DispatchResult
execute t gid uid senderPrincipal replyTarget cmd = do
  env :: BotEnv <- ask
  catalog :: ModelCatalog <- ask
  let conversation = conversationScopeFor gid
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
      "" -> reply "用法：!task steer task#N <内容>；!feedback/!fb 需要显式 task# 或回复任务关联消息，不再默认选最新任务"
      body -> pure (FeedbackNote body)
    Help mTopic -> reply (helpText mTopic)
    --
    ModelShow -> do
      s <- liftIO (Session.readSession t)
      reply $ "当前 model: " <> s.model
    ModelList -> do
      let profs = modelProfileNames catalog
      reply $ "可用 models:\n  " <> T.intercalate "\n  " (sort profs)
    ModelSet name -> do
      let profs = modelProfileNames catalog
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
    EffortShow -> do
      s <- liftIO (Session.readSession t)
      let profEffort = configuredEffort =<< lookupModelCapabilities s.model catalog
      reply $ case (s.effortOverride, profEffort) of
        (Just e, _) -> "effort: " <> e <> "（session 覆盖；!effort default 撤销）"
        (Nothing, Just e) -> "effort: " <> e <> "（profile 配置）"
        (Nothing, Nothing) -> "effort: 未设置（不发送该字段，服务端默认）"
    EffortSet mv -> do
      updateSession t $ \s ->
        ( case mv of
            Just v -> Session.setEffortOverride v s
            Nothing -> Session.clearEffortOverride s,
          ()
        )
      logInfo "session: effort override" $ object ["value" .= mv]
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
      revokeConversationBrowsers gid
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
          mMsg <- fetchMessageInScope conversation mid
          case mMsg of
            Nothing -> reply $ "找不到 message_id=" <> tshow mid
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
          items <- fetchMessagesByIdsInScope conversation ids
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
              execInSandbox env.beSandboxes gid e.seId pkgs cmdLine (shellTimeoutSecs pkgs)
          reply $ case res of
            Left err -> "执行失败: " <> err
            Right er -> formatExecResult er
    --
    -- Both group and person memories remain inside the current
    -- conversation. Cross-conversation self-audit can be added later as an
    -- explicit projection; it must not be an exception hidden in this path.
    MemoryList -> do
      let PrincipalId principal = senderPrincipal
          private = isPrivateChat gid
      gms <- listMemories (groupMemoryNamespace conversation)
      ums <- listMemories (userMemoryNamespace conversation principal)
      reply (formatMemories private gms ums)
    MemoryRm mid -> do
      let PrincipalId principal = senderPrincipal
          memoryId = MemoryId mid
          actor = MemoryActor ActorCommand (Just principal) (Just "!memory rm")
          archiveCurrent namespace =
            fetchMemory namespace memoryId >>= \case
              Nothing -> pure False
              Just item ->
                archiveMemory actor namespace memoryId (ExpectedVersion item.memVersion) >>= \case
                  MemoryMutationApplied _ -> pure True
                  MemoryMutationRejected -> pure False
      removedGroup <- archiveCurrent (groupMemoryNamespace conversation)
      removedUser <-
        if removedGroup
          then pure False
          else archiveCurrent (userMemoryNamespace conversation principal)
      if removedGroup || removedUser
        then do
          logInfo "memory: removed via !memory" $ object ["id" .= mid]
          ack
        else reply $ "没有 id=" <> tshow mid <> " 的本会话记忆"
    --
    StickerStats -> do
      st <- Stickers.stickerStats
      sess <- liftIO (Session.readSession t)
      reply $
        T.concat
          [ "表情包库：共 ",
            tshow st.ssTotal,
            "，已识图 ",
            tshow st.ssCaptioned,
            "，待识图 ",
            tshow st.ssPending,
            "，已屏蔽 ",
            tshow st.ssBanned,
            "\n发送开关：",
            renderStickerState env.beStickerDefault sess.stickerOverride,
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
              "\n判定模型：",
              ic.icProfile,
              "，冷却 ",
              tshow ic.icCooldownSeconds,
              "s（仅话题类；点名/对话延续不受冷却）",
              "，每小时上限 ",
              tshow ic.icMaxPerHour,
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
      -- What THIS group's dispatches see (global + group, shadowed
      -- skills; tools under this session's gates), not process-wide
      -- totals — the card answers "what can you do here", and the
      -- numbers differ across groups and profiles.
      sess <- liftIO (Session.readSession t)
      let multimodal = maybe False supportsMultimodal (lookupModelCapabilities sess.model catalog)
      skillCount <- liftIO (length <$> skillsForGroup env.beSkills gid)
      let toolCount =
            toolCountFor
              env
              gid
              multimodal
              (fromMaybe env.beStickerDefault sess.stickerOverride)
              (skillCount > 0)
      -- Public on purpose: the version card is group trivia, not a
      -- personal query.
      pure . ReplyPublicText $
        versionCard
          osName
          toolCount
          skillCount
          (realToFrac (diffUTCTime now env.beStartedAt))
          hostUp
    StickerList -> do
      rows <- Stickers.listRecentStickers 10
      reply (formatStickers rows)
    StickerBan prefix -> banSticker True prefix
    StickerUnban prefix -> banSticker False prefix
    --
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
            Just g -> "当前操作对象：群 " <> tshow g <> "（!use clear 退出）"
            Nothing -> "没有选中的群；!use <群号> 之后，你在私聊里发的命令都作用于那个群"
    UseSet g
      | not (isPrivateChat gid) -> reply "!use 只在私聊里有意义"
      | otherwise -> do
          known <- groupKnown g
          if not known
            then reply $ "我没见过群 " <> tshow g <> "（bot 不在这个群，或还没收到过它的消息）"
            else do
              let UserId uidRaw = uid
              liftIO (atomically (modifyTVar' env.beAdminTarget (Map.insert uidRaw g)))
              reply $
                "好，接下来你私聊里的命令都作用于群 "
                  <> tshow g
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
      memCount <- countMemories (groupMemoryNamespace conversation)
      tasks <- liftIO (listTasks env.beTasks (Just gid))
      reply . T.intercalate "\n" $
        [ (if isPrivateChat gid then "本私聊" else "群 " <> tshow gidRaw) <> " 状态：",
          "  model: " <> s.model,
          "  persona: " <> maybe "（默认）" (\p -> T.take 40 p <> if T.length p > 40 then "…" else "") s.persona,
          "  debug: " <> onOff env.beDebugDefault s.debugOverride,
          "  sticker: " <> onOff env.beStickerDefault s.stickerOverride,
          "  proactive: " <> onOff (isJust env.beIntent) s.proactiveOverride,
          "  pin: " <> tshow (length s.pinned) <> " 条",
          "  记忆: " <> tshow memCount <> " 条",
          "  任务: " <> tshow (length tasks) <> " 个在跑",
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
    reply :: (Applicative f) => Text -> f DispatchResult
    reply = pure . ReplyText

    -- Pure acknowledgement: an OK reaction on the command message.
    ack :: (Applicative f) => f DispatchResult
    ack = pure ReplyAck

    banSticker b prefix
      | T.length prefix < 6 =
          reply "sha 前缀至少 6 位（!sticker list 里有）"
      | otherwise = do
          n <- Stickers.setStickerBanned b prefix
          if n == 0
            then reply ("没有匹配 " <> prefix <> "* 的表情")
            else ack

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

formatMemories :: Bool -> [MemoryItem] -> [MemoryItem] -> Text
formatMemories _ [] [] = "没有长期记忆（bot 觉得值得记的东西会存在这里）"
formatMemories private gms ums =
  T.unlines . concat $
    [ if null gms
        then []
        else (if private then "本会话记忆:" else "本群记忆:") : map memLine gms,
      if null ums
        then []
        else "当前会话中关于你的记忆:" : map memLine ums,
      ["用 !memory rm <id> 删除"]
    ]
  where
    memLine m =
      "  #"
        <> tshow m.memId.unMemoryId
        <> "@v"
        <> tshow m.memVersion.unMemoryVersion
        <> "  "
        <> m.memContent

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
                 <> maybe "" ("，输出文件在 " <>) er.erSpillPath
                 <> if er.erSpillTruncated then "，文件也达到安全上限" else ""
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
        <> tshow h.canonicalId
        <> "  "
        <> bestName h
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
    [ "  " <> ti.tiId.unTaskId,
      ti.tiKind,
      ageText now ti.tiStartedAt,
      -- Who started it.  Informational only — anyone may !feedback at
      -- any running turn.
      byTag
    ]
      <> [triggerTag | Just _ <- [ti.tiTrigger]]
      <> [groupTag | Just _ <- [callerGid]]
      <> [pendingTag | ti.tiPending > 0]
      <> [idleTag | idleSeconds >= idleWorthSaying]
  where
    GroupId raw = ti.tiGroup
    UserId uidRaw = ti.tiUser
    byTag = "by=" <> tshow uidRaw
    -- The message to reply to when aiming a !feedback at this turn
    -- rather than at whatever is newest.
    triggerTag = "on=#" <> maybe "" (T.pack . show) ti.tiTrigger
    groupTag = "group=" <> tshow raw
    pendingTag = "fb=" <> tshow ti.tiPending
    -- Silence rather than age: a turn ten minutes into honest work reads the
    -- same as a wedged one under 'ageText', and only this tells them apart.
    idleTag = "idle=" <> ageText now ti.tiProgressAt
    idleSeconds = round (realToFrac (diffUTCTime now ti.tiProgressAt) :: Double) :: Int

-- | Below this a turn is simply between rounds, and a row that says so on
-- every line stops being read.
idleWorthSaying :: Int
idleWorthSaying = 30

ageText :: UTCTime -> UTCTime -> Text
ageText now started =
  let secs = round (realToFrac (diffUTCTime now started) :: Double) :: Int
   in case secs of
        n | n < 60 -> tshow n <> "s"
        n | n < 3600 -> tshow (n `div` 60) <> "m"
        n -> tshow (n `div` 3600) <> "h"
