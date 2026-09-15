module Max.Concurrent.Lock (withLock, LockMap, newLockMap, withKeyLock, tryWithKeyLock, SharedLock, newSharedLock, withSharedLock, withExclusiveLock) where

import Control.Concurrent.STM
import Control.Exception (bracket, bracket_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

newtype LockMap key = LockMap (TVar (Map key (TMVar (), Int)))

newLockMap :: IO (LockMap key)
newLockMap = LockMap <$> newTVarIO Map.empty

-- | One cancellation-safe mutex scope, shared by keyed and entry-owned locks.
withLock :: TMVar () -> IO value -> IO value
withLock lock = bracket_ (atomically (takeTMVar lock)) (atomically (putTMVar lock ()))

-- Commands share access; lifecycle changes close admission and drain users.
-- Holding the gate while draining also prevents new readers starving a writer.
data SharedLock = SharedLock (TMVar ()) (TVar Int)

newSharedLock :: IO SharedLock
newSharedLock = SharedLock <$> newTMVarIO () <*> newTVarIO 0

withSharedLock :: SharedLock -> IO value -> IO value
withSharedLock (SharedLock gate users) =
  bracket_
    (atomically (readTMVar gate >> modifyTVar' users (+ 1)))
    (atomically (modifyTVar' users (subtract 1)))

withExclusiveLock :: SharedLock -> IO value -> IO value
withExclusiveLock (SharedLock gate users) action =
  withLock gate $ do
    atomically (readTVar users >>= check . (== 0))
    action

withKeyLock :: (Ord key) => LockMap key -> key -> IO value -> IO value
withKeyLock registry key action =
  withLockReference registry key $ \lock ->
    withLock lock action

tryWithKeyLock :: (Ord key) => LockMap key -> key -> IO value -> IO (Maybe value)
tryWithKeyLock registry key action = withLockReference registry key $ \lock ->
  bracket (atomically (tryTakeTMVar lock)) (maybe (pure ()) (const (atomically (putTMVar lock ())))) $ \case
    Nothing -> pure Nothing
    Just () -> Just <$> action

withLockReference :: (Ord key) => LockMap key -> key -> (TMVar () -> IO value) -> IO value
withLockReference (LockMap registry) key = bracket acquire release
  where
    acquire = atomically $ do
      locks <- readTVar registry
      case Map.lookup key locks of
        Just (lock, references) -> do
          writeTVar registry (Map.insert key (lock, references + 1) locks)
          pure lock
        Nothing -> do
          lock <- newTMVar ()
          writeTVar registry (Map.insert key (lock, 1) locks)
          pure lock
    release _ =
      atomically $
        modifyTVar' registry $
          Map.update (\(lock, references) -> if references == 1 then Nothing else Just (lock, references - 1)) key
