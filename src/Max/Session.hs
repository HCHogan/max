-- |
-- Per-group bot session state.  Group-wide shared: anyone in a group
-- can flip the bot's model, persona, clear history, etc.  Persisted to
-- the @sessions@ table so it survives restarts.
--
-- == Branches
--
-- A group can have multiple named sessions ("branches") and one of
-- them is the active branch.  All commands operate on the active
-- branch unless they explicitly name another.  Branches are useful
-- for trying out different personas without losing the main thread.
--
-- == Mutability
--
-- The in-memory shape is @TVar (Map GroupId (TVar Session))@: the
-- outer map is locked only while we add a new group; per-group state
-- is its own TVar so concurrent groups don't contend.
--
-- Every mutation goes through 'updateSession', which writes through
-- to Postgres before returning.  Reads come from the TVar without
-- touching the DB (the cache is authoritative once loaded).
module Max.Session
  ( -- * Re-exported record
    Session (..),
    SessionRegistry,
    newSessionRegistry,
    loadSession,
    readSession,
    updateSession,
    -- * Branches
    listBranches,
    forkAndSwitch,
    switchToBranch,
    dropBranch,
    isValidBranchName,
    -- * Convenience updates (pass to 'updateSession')
    appendBtwNote,
    drainBtwNotes,
    clearHistory,
    clearAll,
    unclear,
    addPin,
    removePin,
    removeAllPins,
    setThinkingOverride,
    clearThinkingOverride,
    setDebugOverride,
    clearDebugOverride,
    setStickerOverride,
    clearStickerOverride,
    setProactiveOverride,
    clearProactiveOverride,
  )
where

import Control.Concurrent.STM
import Data.Char (isAlphaNum)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Session qualified as DB
import Max.Session.Types (Session (..))
import OneBot.Types (GroupId)

-- | Outer registry: map from group id to that group's active session.
-- We only hold the active branch hot in memory; non-active branches
-- live in DB and are loaded on demand by !switch.
newtype SessionRegistry = SessionRegistry (TVar (Map GroupId (TVar Session)))

newSessionRegistry :: IO SessionRegistry
newSessionRegistry = SessionRegistry <$> newTVarIO Map.empty

-- | Get the group's TVar, loading from DB (or creating a 'main'
-- branch with defaults) on cache miss.
loadSession ::
  (WithConnection :> es, IOE :> es) =>
  SessionRegistry ->
  Text -> -- default model (registry.defaultName) used when DB has no row
  GroupId ->
  Eff es (TVar Session)
loadSession (SessionRegistry outer) defaultModel gid = do
  cached <- liftIO . atomically $ do
    m <- readTVar outer
    pure (Map.lookup gid m)
  case cached of
    Just t -> pure t
    Nothing -> do
      s <- DB.fetchActiveOrInit gid defaultModel
      tvar <- liftIO (newTVarIO s)
      liftIO . atomically $ modifyTVar' outer (Map.insertWith (\_ old -> old) gid tvar)
      -- If someone else won the race, the insertWith above keeps the
      -- existing TVar; re-read so we return the winner.
      finalMap <- liftIO (readTVarIO outer)
      pure (Map.findWithDefault tvar gid finalMap)

-- | Read the current state.  Pure read against the in-memory TVar.
readSession :: TVar Session -> IO Session
readSession = readTVarIO

-- | Apply a pure update and persist to DB.  The update sees the
-- previous 'Session' and returns the new one; the function may also
-- yield a value for the caller.
updateSession ::
  (WithConnection :> es, IOE :> es) =>
  TVar Session ->
  (Session -> (Session, a)) ->
  Eff es a
updateSession t f = do
  (new, a) <- liftIO . atomically $ do
    old <- readTVar t
    let (new, a) = f old
    writeTVar t new
    pure (new, a)
  DB.upsertSession new
  pure a

--------------------------------------------------------------------------------
-- Pure helpers callable inside updateSession.

appendBtwNote :: Text -> Session -> Session
appendBtwNote note s = s {btwNotes = s.btwNotes <> [note]}

-- | Pull all pending notes; the returned 'Session' has 'btwNotes' empty.
drainBtwNotes :: Session -> ([Text], Session)
drainBtwNotes s = (s.btwNotes, s {btwNotes = []})

-- | Stamp a 'clearedAt' watermark so the next prompt skips ambient
-- group messages AND reconstructed mention history older than now.
-- Pinned messages and explicit reply contexts still survive.  No
-- destructive truncation any more — the data lives in the messages
-- table; @!unclear@ brings it all back.
clearHistory :: UTCTime -> Session -> Session
clearHistory now s = s {clearedAt = Just now}

-- | Stamp 'clearedAt' AND wipe per-session ephemera: btw notes,
-- persona override, and pins.  Leaves model + branch alone (use
-- !model to change those explicitly).
clearAll :: UTCTime -> Session -> Session
clearAll now s =
  s
    { btwNotes = [],
      persona = Nothing,
      clearedAt = Just now,
      pinned = []
    }

-- | Remove the 'clearedAt' watermark.  The next prompt is allowed to
-- pull in everything (ambient + mention history) from before any
-- earlier @!clear@.
unclear :: Session -> Session
unclear s = s {clearedAt = Nothing}

-- | Add a message id to the pin list.  Dedupes; preserves insertion
-- order (the pinned list reads in the order the user pinned).
addPin :: Int64 -> Session -> Session
addPin mid s
  | mid `elem` s.pinned = s -- already pinned, no-op
  | otherwise = s {pinned = s.pinned <> [mid]}

removePin :: Int64 -> Session -> Session
removePin mid s = s {pinned = filter (/= mid) s.pinned}

removeAllPins :: Session -> Session
removeAllPins s = s {pinned = []}

-- | Set the thinking-mode override for this session.
setThinkingOverride :: Bool -> Session -> Session
setThinkingOverride b s = s {thinkingOverride = Just b}

-- | Drop the override; subsequent dispatches fall back to the
-- profile's (or server's) default.
clearThinkingOverride :: Session -> Session
clearThinkingOverride s = s {thinkingOverride = Nothing}

-- | Set the debug override for this session (@!debug on@/@off@).
setDebugOverride :: Bool -> Session -> Session
setDebugOverride b s = s {debugOverride = Just b}

-- | Drop the override; fall back to @AppConfig.debug@.
clearDebugOverride :: Session -> Session
clearDebugOverride s = s {debugOverride = Nothing}

-- | Set the sticker override for this session (@!sticker on@/@off@).
setStickerOverride :: Bool -> Session -> Session
setStickerOverride b s = s {stickerOverride = Just b}

-- | Drop the override; fall back to @AppConfig.stickersEnabled@.
clearStickerOverride :: Session -> Session
clearStickerOverride s = s {stickerOverride = Nothing}

-- | Set the proactive override for this session (@!proactive on@/@off@).
setProactiveOverride :: Bool -> Session -> Session
setProactiveOverride b s = s {proactiveOverride = Just b}

-- | Drop the override; fall back to the config default (on whenever
-- @intent.profile@ is configured).
clearProactiveOverride :: Session -> Session
clearProactiveOverride s = s {proactiveOverride = Nothing}

--------------------------------------------------------------------------------
-- Branches.

-- | Branch names must be a non-empty run of letters/digits/@. _ -@,
-- ≤64 chars, not starting with a dot.  Conservative on purpose:
-- branches show up in user-facing output and we don't want surprises
-- from whitespace or shell-like characters.
isValidBranchName :: Text -> Bool
isValidBranchName name =
  not (T.null name)
    && T.length name <= 64
    && T.all ok name
    && T.head name /= '.'
  where
    ok c = isAlphaNum c || c == '.' || c == '_' || c == '-'

-- | List branch names known for a group.  Read-through to DB; we
-- don't keep a per-group branch index in memory.
listBranches ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Eff es [Text]
listBranches = DB.listBranches

-- | Result of a branch operation.  @Right ()@ on success; @Left msg@
-- with a user-facing reason on failure.
type BranchResult = Either Text ()

-- | @git checkout -b@: create @newName@ by copying the currently
-- active branch's state (model, persona, pinned, thinking_override),
-- stamp 'clearedAt' to @now@ so the new branch starts with a fresh
-- view of the messages table, drain @btw_notes@, then flip the
-- active-branch pointer.  Errors out if @newName@ already exists or
-- is invalid.
forkAndSwitch ::
  (WithConnection :> es, IOE :> es) =>
  SessionRegistry ->
  GroupId ->
  Text -> -- new branch name
  UTCTime -> -- wall clock used for the watermark on the new branch
  Eff es BranchResult
forkAndSwitch (SessionRegistry outer) gid newName now
  | not (isValidBranchName newName) =
      pure (Left ("分支名不合法（允许字母数字 . _ -，最多 64 字符，不能以 . 开头）：" <> newName))
  | otherwise = do
      exists <- DB.branchExists gid newName
      if exists
        then pure (Left ("分支已存在：" <> newName))
        else do
          mTvar <- liftIO . atomically $ do
            m <- readTVar outer
            pure (Map.lookup gid m)
          case mTvar of
            Nothing ->
              pure (Left "当前 group 还没有 session（先发一条消息让 bot 初始化）")
            Just t -> do
              cur <- liftIO (readTVarIO t)
              let forked =
                    cur
                      { branch = newName,
                        btwNotes = [],
                        clearedAt = Just now
                      }
              DB.upsertSession forked
              DB.switchActiveBranch gid newName
              liftIO . atomically $ writeTVar t forked
              pure (Right ())

-- | Switch the active branch to one that already exists.  Loads the
-- target branch row, flips the active pointer, then atomically
-- replaces the in-memory 'Session' inside the existing TVar so
-- callers that already hold the TVar handle see the new branch on
-- their next read.
switchToBranch ::
  (WithConnection :> es, IOE :> es) =>
  SessionRegistry ->
  GroupId ->
  Text -> -- target branch name
  Text -> -- default model (for resolving NULL row.model on load)
  Eff es BranchResult
switchToBranch (SessionRegistry outer) gid name defaultModel =
  DB.fetchBranch gid name defaultModel >>= \case
    Nothing -> pure (Left ("分支不存在：" <> name <> "（用 !branch " <> name <> " 创建）"))
    Just target -> do
      mTvar <- liftIO . atomically $ do
        m <- readTVar outer
        pure (Map.lookup gid m)
      DB.switchActiveBranch gid name
      case mTvar of
        Just t -> liftIO . atomically $ writeTVar t target
        Nothing -> do
          tvar <- liftIO (newTVarIO target)
          liftIO . atomically $ modifyTVar' outer (Map.insert gid tvar)
      pure (Right ())

-- | Delete a branch.  Refuses to drop the active branch or the only
-- remaining branch (so a group always has somewhere to land).
dropBranch ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- branch to delete
  Eff es BranchResult
dropBranch gid name =
  DB.getActiveBranch gid >>= \case
    Just a | a == name ->
      pure (Left ("不能删除当前 active 分支 " <> name <> "（先 !switch 到别的分支）"))
    _ -> do
      branches <- DB.listBranches gid
      if name `notElem` branches
        then pure (Left ("分支不存在：" <> name))
        else
          if length branches <= 1
            then pure (Left "不能删除最后一个分支")
            else do
              DB.deleteBranch gid name
              pure (Right ())
