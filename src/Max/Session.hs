-- |
-- Per-group bot session state.  Group-wide shared: anyone in a group
-- can flip the bot's model, persona, clear history, etc.  Persisted to
-- the @sessions@ table so it survives restarts.
--
-- == Mutability
--
-- The in-memory shape is @TVar (Map GroupId SessionHandle)@: the outer map is
-- locked only while we add a new group.  Each handle owns a TVar plus a
-- mutation lock, so concurrent groups never contend and one group's DB writes
-- cannot finish out of order.
--
-- Every mutation goes through 'updateSession'.  It persists with revision CAS
-- before publishing the committed value to the TVar; a DB failure therefore
-- leaves the visible cache unchanged.  Reads remain cache-only once loaded.
module Max.Session
  ( -- * Re-exported record
    Session (..),
    SessionHandle,
    SessionPersistenceError (..),
    SessionRegistry,
    newSessionRegistry,
    loadSession,
    readSession,
    updateSession,
    updateSessionGuarded,

    -- * Convenience updates (pass to 'updateSession')
    clearHistory,
    clearAll,
    unclear,
    addPin,
    removePin,
    removeAllPins,
    setDebugOverride,
    clearDebugOverride,
    setStickerOverride,
    clearStickerOverride,
    setProactiveOverride,
    clearProactiveOverride,
    setEffortOverride,
    clearEffortOverride,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Exception (Exception)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Void (absurd)
import Effectful
import Effectful.Exception (bracket, mask, throwIO)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Session qualified as DB
import Max.DB.Transaction (withCommittedTransaction)
import Max.Session.Types (Session (..))
import OneBot.Types (GroupId)

-- | An opaque per-conversation cache and mutation domain.
data SessionHandle = SessionHandle
  { state :: !(TVar DB.SessionRecord),
    mutationLock :: !(MVar ()),
    defaultModel :: !Text
  }

-- | Outer registry: map from group id to that group's session handle.
newtype SessionRegistry = SessionRegistry (TVar (Map GroupId SessionHandle))

data SessionPersistenceError
  = SessionMissing !GroupId
  | SessionConflictExhausted !GroupId
  deriving stock (Show)

instance Exception SessionPersistenceError

newSessionRegistry :: IO SessionRegistry
newSessionRegistry = SessionRegistry <$> newTVarIO Map.empty

-- | Get the group's TVar, loading from DB (or creating a fresh row
-- with defaults) on cache miss.
loadSession ::
  (WithConnection :> es, IOE :> es) =>
  SessionRegistry ->
  Text -> -- default model (registry.defaultName) used when DB has no row
  GroupId ->
  Eff es SessionHandle
loadSession (SessionRegistry outer) defaultModel gid = do
  cached <- liftIO . atomically $ do
    m <- readTVar outer
    pure (Map.lookup gid m)
  case cached of
    Just t -> pure t
    Nothing -> do
      record <- DB.fetchRecordOrInit gid defaultModel
      handle <-
        liftIO $
          SessionHandle
            <$> newTVarIO record
            <*> newMVar ()
            <*> pure defaultModel
      liftIO . atomically $ modifyTVar' outer (Map.insertWith (\_ old -> old) gid handle)
      -- If someone else won the race, the insertWith above keeps the
      -- existing handle; re-read so we return the winner.
      finalMap <- liftIO (readTVarIO outer)
      pure (Map.findWithDefault handle gid finalMap)

-- | Read the current state.  Pure read against the in-memory TVar.
readSession :: SessionHandle -> IO Session
readSession handle = (.session) <$> readTVarIO handle.state

-- | Apply a pure update and persist to DB.  The update sees the
-- previous 'Session' and returns the new one; the function may also
-- yield a value for the caller.
updateSession ::
  (WithConnection :> es, IOE :> es) =>
  SessionHandle ->
  (Session -> (Session, a)) ->
  Eff es a
updateSession handle f = either absurd id <$> updateSessionGuarded handle (pure (Right ())) (Right . f)

-- | Recheck a domain's authority after acquiring both the local mutation lock
-- and the persisted session row. Guard, decision and CAS share one transaction;
-- publish the cache only after COMMIT, masked against asynchronous interruption.
-- A CAS refresh reruns the guard. Nested transactions are rejected, since their
-- later rollback cannot be reflected in an already-published TVar.
updateSessionGuarded ::
  forall es rejection a.
  (WithConnection :> es, IOE :> es) =>
  SessionHandle ->
  Eff es (Either rejection ()) ->
  (Session -> Either rejection (Session, a)) ->
  Eff es (Either rejection a)
updateSessionGuarded handle guard f =
  bracket
    (liftIO (takeMVar handle.mutationLock))
    (const (liftIO (putMVar handle.mutationLock ())))
    ( const $
        mask $
          \restore -> retryCAS restore maxSessionCASRetries
    )
  where
    retryCAS :: (forall x. Eff es x -> Eff es x) -> Int -> Eff es (Either rejection a)
    retryCAS restore retriesLeft = do
      oldRecord <- liftIO (readTVarIO handle.state)
      committed <- withCommittedTransaction $ restore $ do
        current <- DB.lockRecordRevision oldRecord
        if not current
          then pure (Right Nothing)
          else
            guard >>= \case
              Left failure -> pure (Left failure)
              Right () -> case f oldRecord.session of
                Left failure -> pure (Left failure)
                Right (newSession, result) -> Right . fmap (,result) <$> DB.saveSessionCAS oldRecord newSession
      case committed of
        Left failure -> pure (Left failure)
        Right (Just (newRecord, result)) -> do
          liftIO . atomically $ writeTVar handle.state newRecord
          pure (Right result)
        Right Nothing -> do
          latest <- restore (DB.fetchRecord oldRecord.session.groupId handle.defaultModel)
          case latest of
            Nothing -> throwIO (SessionMissing oldRecord.session.groupId)
            Just latestRecord -> do
              liftIO . atomically $ writeTVar handle.state latestRecord
              if retriesLeft <= 0
                then throwIO (SessionConflictExhausted oldRecord.session.groupId)
                else retryCAS restore (retriesLeft - 1)

maxSessionCASRetries :: Int
maxSessionCASRetries = 8

--------------------------------------------------------------------------------
-- Pure helpers callable inside updateSession.

-- | Stamp a 'clearedAt' watermark so the next prompt skips chronological
-- context older than now.  Pinned messages and explicit reply contexts survive.  No
-- destructive truncation any more — the data lives in the messages
-- table; @!unclear@ brings it all back.
clearHistory :: UTCTime -> Session -> Session
clearHistory now s = s {clearedAt = Just now}

-- | Stamp 'clearedAt' AND wipe per-session ephemera: persona override
-- and pins.  Leaves the model alone (use !model to change it
-- explicitly).
clearAll :: UTCTime -> Session -> Session
clearAll now s =
  s
    { persona = Nothing,
      clearedAt = Just now,
      pinned = []
    }

-- | Remove the 'clearedAt' watermark.  The next prompt is allowed to
-- pull in the tiered history from before any
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

-- | Set the reasoning-effort override (@!effort <level>@).
setEffortOverride :: Text -> Session -> Session
setEffortOverride e s = s {effortOverride = Just e}

-- | Drop the override; fall back to the profile's configured effort.
clearEffortOverride :: Session -> Session
clearEffortOverride s = s {effortOverride = Nothing}
