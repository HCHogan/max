-- | Root nodes and frontend admission. Segment ownership is granted by the
-- shared node executor, and survives neither task closure nor cancellation.
-- Frontend provenance is retained separately from execution permits.
module Max.Conversation
  ( Conversations,
    TaskHandle,
    TurnInput (..),
    newConversations,
    enqueue,
    awaitTurn,
    actorFor,
    release,
    eventsFor,
    canAdmit,
  )
where

import Control.Concurrent.STM
import Control.Monad (forM_, void)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Executor
import Max.Node.Log qualified as NodeLog
import Max.Node.Routing qualified as Routing
import Max.Platform.Types (PrincipalId)
import Max.Task.FrontendInput (FrontendInputView (..))
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId)

newtype Conversations = Conversations (TVar (Map GroupId Root))

data Root = Root
  { executor :: !Executor.Executor,
    tasks :: !(Map AgentTurnId TaskHandle),
    events :: !Events.Node
  }

data TurnInput = TurnInput
  { group :: !GroupId,
    turn :: !AgentTurnId,
    principal :: !PrincipalId,
    sourceOrder :: !(Maybe Int64),
    sourceMessage :: !(Maybe Int64),
    replyTurn :: !(Maybe AgentTurnId),
    feedback :: !(Maybe FrontendInputView),
    notice :: !Bool,
    trigger :: !NodeLog.Trigger
  }

-- | A routed input acknowledges without running a model. An admitted task has
-- an actor on the root executor. There are no parked conversation tickets.
data TaskHandle = TaskHandle {input :: !TurnInput, decision :: !(TMVar (Maybe Executor.Actor)), taskEvents :: !(Maybe Events.Task)}

newConversations :: IO Conversations
newConversations = Conversations <$> newTVarIO Map.empty

canAdmit :: Conversations -> GroupId -> STM Bool
canAdmit (Conversations registry) group = do
  groups <- readTVar registry
  pure (maybe 0 (Map.size . (.tasks)) (Map.lookup group groups) < 256 && sum (map (Map.size . (.tasks)) (Map.elems groups)) < 1024)

enqueue :: Conversations -> TurnInput -> IO (Maybe TaskHandle)
enqueue (Conversations registry) input = do
  fresh <- Executor.newExecutor
  atomically $ do
    groups <- readTVar registry
    events <- Events.newNode
    let root = Map.findWithDefault (Root fresh Map.empty events) input.group groups
    if Map.size root.tasks >= 256 || sum (map (Map.size . (.tasks)) (Map.elems groups)) >= 1024 || Map.member input.turn root.tasks
      then pure Nothing
      else do
        owners <- traverse routingOwner (Map.elems root.tasks)
        let selected = Routing.route (Routing.Frontend (Routing.FrontendInput input.principal input.sourceOrder input.replyTurn input.feedback) owners)
        decision <- newEmptyTMVar
        routed <- case (selected >>= (`Map.lookup` root.tasks) >>= (.taskEvents), input.feedback, input.sourceOrder) of
          (Just target, Just feedback, Just order) -> Events.deliver target (Events.FrontendSteered order feedback)
          _ -> pure False
        if routed
          then do
            putTMVar decision Nothing
            let handle = TaskHandle input decision Nothing
            writeTVar registry (Map.insert input.group root {tasks = Map.insert input.turn handle root.tasks} groups)
            pure (Just handle)
          else case selected of
            Just _ -> pure Nothing -- matched recipient refused the bounded event
            Nothing -> do
              actor <- Executor.registerTask root.executor input.turn (if input.notice then Executor.Notice else Executor.NewRequest)
              target <- Events.newTaskFrom root.events input.trigger
              putTMVar decision (Just actor)
              let handle = TaskHandle input decision (Just target)
              writeTVar registry (Map.insert input.group root {tasks = Map.insert input.turn handle root.tasks} groups)
              pure (Just handle)

routingOwner :: TaskHandle -> STM (Routing.FrontendOwner AgentTurnId)
routingOwner handle = do
  open <- hasOpenEvents handle
  started <- tryReadTMVar handle.decision >>= maybe (pure False) (maybe (pure False) Executor.taskStarted)
  pure (Routing.FrontendOwner handle.input.turn handle.input.turn.unAgentTurnId handle.input.principal handle.input.sourceOrder handle.input.sourceMessage open started)

hasOpenEvents :: TaskHandle -> STM Bool
hasOpenEvents = maybe (pure False) Events.isOpen . (.taskEvents)

awaitTurn :: TaskHandle -> IO Bool
awaitTurn handle = actorFor handle >>= maybe (pure False) Executor.enter

actorFor :: TaskHandle -> IO (Maybe Executor.Actor)
actorFor handle = atomically (readTMVar handle.decision)

release :: Conversations -> TaskHandle -> IO ()
release (Conversations registry) handle = atomically $ do
  groups <- readTVar registry
  case Map.lookup handle.input.group groups of
    Nothing -> pure ()
    Just root -> do
      decision <- tryReadTMVar handle.decision
      forM_ decision (mapM_ Executor.closeTask)
      mapM_ Events.close handle.taskEvents
      void (tryPutTMVar handle.decision Nothing)
      let remaining = Map.delete handle.input.turn root.tasks
      writeTVar registry $ if Map.null remaining then Map.delete handle.input.group groups else Map.insert handle.input.group root {tasks = remaining} groups

-- | Production binds the admitted task's node events to its TurnRuntime before
-- collecting context. Routed receipts have no task of their own.
eventsFor :: Conversations -> AgentTurnId -> STM (Maybe Events.Task)
eventsFor (Conversations registry) turn = do
  groups <- readTVar registry
  pure $ case [target | root <- Map.elems groups, Just handle <- [Map.lookup turn root.tasks], Just target <- [handle.taskEvents]] of
    target : _ -> Just target
    [] -> Nothing
