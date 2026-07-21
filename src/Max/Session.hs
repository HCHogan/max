-- |
-- Per-group bot session state.  Group-wide shared: anyone in a group
-- can flip the bot's model, persona, clear history, etc.  Persisted to
-- the @sessions@ table so it survives restarts.
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
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Session qualified as DB
import Max.Session.Types (Session (..))
import OneBot.Types (GroupId)

-- | Outer registry: map from group id to that group's session.
newtype SessionRegistry = SessionRegistry (TVar (Map GroupId (TVar Session)))

newSessionRegistry :: IO SessionRegistry
newSessionRegistry = SessionRegistry <$> newTVarIO Map.empty

-- | Get the group's TVar, loading from DB (or creating a fresh row
-- with defaults) on cache miss.
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
      s <- DB.fetchOrInit gid defaultModel
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
-- persona override, and pins.  Leaves the model alone (use !model to
-- change it explicitly).
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
