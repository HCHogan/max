-- | Process-local futures with exact subscription ownership. Admission can
-- reserve an outcome before a consumer attaches; joins transfer reservations
-- and retain actual results until every selected producer settles.
module Max.Node.Futures
  ( Futures,
    Ticket,
    newFutures,
    reserve,
    claim,
    subscribe,
    publish,
    invalidate,
    await,
    release,
    retainedKeys,
    hasSubscribers,
  )
where

import Control.Concurrent.STM
import Control.Monad (filterM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

newtype Futures owner key value = Futures (TVar (Integer, Map Integer (Subscription owner key value)))

data Ticket owner key value = Ticket !(Futures owner key value) !Integer !(Set key)

data Subscription owner key value = Subscription
  { owner :: !owner,
    reserved :: !Bool,
    keys :: !(Set key),
    values :: !(Map key value),
    valid :: !(STM Bool)
  }

newFutures :: STM (Futures owner key value)
newFutures = Futures <$> newTVar (0, Map.empty)

live :: Futures owner key value -> STM (Integer, Map Integer (Subscription owner key value))
live (Futures ref) = do
  (next, entries) <- readTVar ref
  kept <- filterM (\(_, entry) -> entry.valid) (Map.toList entries)
  let current = Map.fromList kept
  writeTVar ref (next, current)
  pure (next, current)

reserve :: Futures owner key value -> owner -> key -> STM Bool -> STM ()
reserve (Futures ref) owner key valid = do
  (next, entries) <- readTVar ref
  writeTVar ref (next + 1, Map.insert next (Subscription owner True (Set.singleton key) Map.empty valid) entries)

-- | A reserved call can be attached once. A second waiter must explicitly
-- subscribe and receives its own receipt, never another call's reservation.
claim :: (Eq owner, Ord key) => Futures owner key value -> owner -> key -> STM (Maybe (Ticket owner key value))
claim futures@(Futures ref) owner key = do
  (next, entries) <- live futures
  case [(identifier, entry) | (identifier, entry) <- Map.toList entries, entry.reserved && entry.owner == owner && Set.member key entry.keys] of
    (identifier, entry) : _ -> do
      writeTVar ref (next, Map.insert identifier entry {reserved = False} entries)
      pure (Just (Ticket futures identifier entry.keys))
    [] -> pure Nothing

subscribe :: (Eq owner, Ord key) => Futures owner key value -> owner -> Set key -> Map key value -> STM Bool -> STM (Ticket owner key value)
subscribe futures@(Futures ref) owner keys seed valid = do
  (next, entries) <- live futures
  let transfers entry = entry.reserved && entry.owner == owner && entry.keys `Set.isSubsetOf` keys
      (transferred, remaining) = Map.partition transfers entries
      values = Map.restrictKeys seed keys <> Map.unions (map (.values) (Map.elems transferred))
  writeTVar ref (next + 1, Map.insert next (Subscription owner False keys values valid) remaining)
  pure (Ticket futures next keys)

publish :: (Ord key) => Futures owner key value -> key -> value -> STM Bool
publish futures@(Futures ref) key value = do
  (next, entries) <- live futures
  let owns entry = Set.member key entry.keys
      deliver entry = if owns entry then entry {values = Map.insertWith (\_ old -> old) key value entry.values} else entry
  writeTVar ref (next, fmap deliver entries)
  pure (any owns entries)

-- | Replacement keeps logical joins but removes the previous generation's
-- outcomes. Generation-bound admission reservations expire through their guard.
invalidate :: (Ord key) => Futures owner key value -> key -> STM ()
invalidate (Futures ref) key = modifyTVar' ref $ \(next, entries) ->
  (next, fmap (\entry -> entry {values = Map.delete key entry.values}) entries)

await :: (Ord key) => Ticket owner key value -> STM (Maybe [value])
await (Ticket futures identifier keys) = do
  (_, entries) <- live futures
  case Map.lookup identifier entries of
    Nothing -> pure Nothing
    Just entry -> do
      check (keys `Set.isSubsetOf` Map.keysSet entry.values)
      pure (Just (Map.elems (Map.restrictKeys entry.values keys)))

-- | Exact, idempotent release: an obsolete finalizer cannot release a newer
-- subscription even when its principal and producer selection are identical.
release :: Ticket owner key value -> STM (Set key)
release (Ticket (Futures ref) identifier keys) = do
  modifyTVar' ref (\(next, entries) -> (next, Map.delete identifier entries))
  pure keys

retainedKeys :: (Ord key) => Futures owner key value -> STM (Set key)
retainedKeys futures = Set.unions . map (.keys) . Map.elems . snd <$> live futures

hasSubscribers :: (Ord key) => Futures owner key value -> key -> STM Bool
hasSubscribers futures key = Set.member key <$> retainedKeys futures
