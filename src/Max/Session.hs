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
    -- * Convenience updates (pass to 'updateSession')
    appendHistoryTurn,
    appendBtwNote,
    drainBtwNotes,
    clearHistory,
    clearAll,
  )
where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Session qualified as DB
import Max.Effects.LLM (ChatMessage)
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

appendHistoryTurn :: ChatMessage -> ChatMessage -> Session -> Session
appendHistoryTurn user assistant s =
  s {history = s.history <> [user, assistant]}

appendBtwNote :: Text -> Session -> Session
appendBtwNote note s = s {btwNotes = s.btwNotes <> [note]}

-- | Pull all pending notes; the returned 'Session' has 'btwNotes' empty.
drainBtwNotes :: Session -> ([Text], Session)
drainBtwNotes s = (s.btwNotes, s {btwNotes = []})

clearHistory :: Session -> Session
clearHistory s = s {history = []}

-- | Wipe back to defaults: empty history, no btw, no persona override.
-- Leaves model + branch as-is (use !model to change those explicitly).
clearAll :: Session -> Session
clearAll s = s {history = [], btwNotes = [], persona = Nothing}
