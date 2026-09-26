-- | One execution segment at a time per node. Haskell threads retain task and
-- guest continuations while waiting; this executor, not thread timing, grants
-- permission to run a segment. No tool body holds or acquires a permit.
module Max.Node.Executor
  ( Executor,
    Actor,
    Priority (..),
    newExecutor,
    registerTask,
    guestActor,
    enter,
    runSteps,
    leave,
    closeActor,
    closeTask,
    taskStarted,
    await,
    shortDeadline,
  )
where

import Control.Concurrent.STM
import Control.Exception (mask, onException)
import Control.Monad (unless, when)
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Max.Turn.Types (AgentTurnId)

-- Declaration order is scheduler priority; each class is FIFO.
data Priority = GuestStep | ResumedTask | NewRequest | Notice deriving stock (Eq, Ord, Show)

newtype Executor = Executor (TVar State)

data Actor = Actor {executor :: !Executor, identifier :: !Integer, task :: !AgentTurnId, priority :: !Priority}

data State = State
  { next :: !Integer,
    owner :: !(Maybe Integer),
    actors :: !(Map Integer AgentTurnId),
    tasks :: !(Map AgentTurnId Bool),
    ready :: !(Map Integer (Priority, Integer))
  }

newExecutor :: IO Executor
newExecutor = Executor <$> newTVarIO (State 0 Nothing Map.empty Map.empty Map.empty)

-- | Admission registers work before spawning its continuation. The first 32
-- tasks may be open concurrently; further new tasks remain in the ready queue.
registerTask :: Executor -> AgentTurnId -> Priority -> STM Actor
registerTask executor@(Executor stateRef) task priority = do
  state <- readTVar stateRef
  unless (Map.member task state.tasks) $ writeTVar stateRef state {tasks = Map.insert task False state.tasks}
  registerActor executor task priority

guestActor :: Actor -> STM Actor
guestActor parent = registerActor parent.executor parent.task GuestStep

registerActor :: Executor -> AgentTurnId -> Priority -> STM Actor
registerActor executor@(Executor stateRef) task priority = do
  state <- readTVar stateRef
  let identifier = state.next
  writeTVar stateRef state {next = identifier + 1, actors = Map.insert identifier task state.actors, ready = Map.insert identifier (priority, identifier) state.ready}
  dispatch executor
  pure (Actor executor identifier task priority)

-- | Every acquisition is cancellable; removing an abandoned queued actor does
-- not release a different actor's ownership (including another guest).
enter :: Actor -> IO Bool
enter actor = mask $ \restore -> do
  atomically (enqueue actor actor.priority >> dispatch actor.executor)
  restore (atomically (granted actor)) `onException` atomically (closeActor actor)

-- | Drive a model task's steps under this node's ownership. State is handed
-- back to the executor after each poll. Only 'await' yields ownership: a short
-- tool round that completes before its deadline keeps the permit, as do model
-- corrections. Awaiting retains the Haskell continuation and reacquires
-- ownership before returning, in the ready queue's priority/FIFO order.
-- The callback is always invoked on the caller's thread, so scoped sequential
-- effect interpreters and their output sinks remain on that same thread.
-- A normal result keeps ownership through the caller's final publication;
-- its existing closeTask boundary releases the slot. Exceptions revoke it now.
runSteps :: Actor -> state -> (state -> IO (Either result state)) -> IO (Maybe result)
runSteps actor initial step = mask $ \restore ->
  let go state = do
        active <- restore (atomically (granted actor))
        if not active
          then pure Nothing
          else do
            outcome <- restore (step state)
            case outcome of
              Left value -> do
                current <- atomically (granted actor)
                pure (if current then Just value else Nothing)
              Right next -> go next
   in ( do
          active <- restore (enter actor)
          if active then go initial else pure Nothing
      )
        `onException` atomically (closeTask actor)

continuationPriority :: Actor -> Priority
continuationPriority actor = if actor.priority == GuestStep then GuestStep else ResumedTask

granted :: Actor -> STM Bool
granted actor = do
  let Executor stateRef = actor.executor
  state <- readTVar stateRef
  if not (Map.member actor.identifier state.actors) || not (Map.member actor.task state.tasks)
    then pure False
    else check (state.owner == Just actor.identifier) >> pure True

inactive :: Actor -> STM ()
inactive actor = do
  let Executor stateRef = actor.executor
  state <- readTVar stateRef
  check (not (Map.member actor.identifier state.actors) || not (Map.member actor.task state.tasks))

enqueue :: Actor -> Priority -> STM ()
enqueue actor priority = do
  let Executor stateRef = actor.executor
  state <- readTVar stateRef
  when (Map.member actor.identifier state.actors && Map.member actor.task state.tasks && state.owner /= Just actor.identifier && not (Map.member actor.identifier state.ready)) $
    writeTVar stateRef state {next = state.next + 1, ready = Map.insert actor.identifier (priority, state.next) state.ready}

leave :: Actor -> STM ()
leave actor = suspend actor >> dispatch actor.executor

suspend :: Actor -> STM ()
suspend actor = do
  let Executor stateRef = actor.executor
  modifyTVar' stateRef $ \state -> state {owner = if state.owner == Just actor.identifier then Nothing else state.owner, ready = Map.delete actor.identifier state.ready}

closeActor :: Actor -> STM ()
closeActor actor = do
  suspend actor
  let Executor stateRef = actor.executor
  modifyTVar' stateRef $ \state -> state {actors = Map.delete actor.identifier state.actors}
  dispatch actor.executor

closeTask :: Actor -> STM ()
closeTask actor = do
  let Executor stateRef = actor.executor
  state <- readTVar stateRef
  let actors = Map.filter (/= actor.task) state.actors
  writeTVar stateRef state {actors, tasks = Map.delete actor.task state.tasks, ready = Map.restrictKeys state.ready (Map.keysSet actors), owner = state.owner >>= \ident -> if Map.member ident actors then Just ident else Nothing}
  dispatch actor.executor

taskStarted :: Actor -> STM Bool
taskStarted actor = do
  let Executor stateRef = actor.executor
  Map.findWithDefault False actor.task . (.tasks) <$> readTVar stateRef

dispatch :: Executor -> STM ()
dispatch (Executor stateRef) = do
  state <- readTVar stateRef
  unless (isJust state.owner) $ do
    let open = length (filter id (Map.elems state.tasks))
        eligible (ident, _) = case Map.lookup ident state.actors >>= (`Map.lookup` state.tasks) of
          Just started -> started || open < 32
          Nothing -> False
    case find eligible (sortOn snd (Map.toList state.ready)) of
      Nothing -> pure ()
      Just (ident, _) -> case Map.lookup ident state.actors of
        Nothing -> pure ()
        Just task -> writeTVar stateRef state {owner = Just ident, ready = Map.delete ident state.ready, tasks = Map.insert task True state.tasks}

shortDeadline :: IO (STM ())
shortDeadline = do
  expired <- registerDelay 5000000
  pure (readTVar expired >>= check)

-- | Await a future, releasing immediately for async tools or at the shared
-- five-second deadline for a native short-tool round. Readiness and enqueue
-- share a transaction. Exceptions abandon the actor's permit, never a future.
await :: Actor -> Bool -> STM () -> STM a -> IO (Maybe a)
await actor immediate deadline ready = mask $ \restore -> do
  early <- if immediate then pure Nothing else restore (atomically ((Just <$> ready) `orElse` (deadline >> pure Nothing) `orElse` (inactive actor >> pure Nothing))) `onException` atomically (leave actor)
  case early of
    Just value -> do
      active <- atomically (granted actor)
      pure (if active then Just value else Nothing)
    Nothing -> do
      available <- atomically $ do
        suspend actor
        value <- (Just <$> ready) `orElse` pure Nothing
        case value of
          Just _ -> enqueue actor (continuationPriority actor)
          Nothing -> pure ()
        dispatch actor.executor
        pure value
      let waitReady = case available of
            Just value -> pure (Just value)
            Nothing ->
              atomically $
                ( do
                    inactive actor
                    pure Nothing
                )
                  `orElse` ( do
                               value <- ready
                               enqueue actor (continuationPriority actor)
                               dispatch actor.executor
                               pure (Just value)
                           )
      ( do
          value <- restore waitReady
          active <- restore (atomically (granted actor))
          pure (if active then value else Nothing)
        )
        `onException` atomically (closeActor actor)
