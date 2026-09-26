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
    readFeedback,
    awaitFeedback,
  )
where

import Control.Concurrent.STM
import Control.Monad (filterM, forM_, void)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import Max.Node.Executor qualified as Executor
import Max.Platform.Types (PrincipalId)
import Max.Task.FrontendInput (FrontendInputView, renderFrontendInputs)
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId)

newtype Conversations = Conversations (TVar (Map GroupId Root))

data Root = Root
  { executor :: !Executor.Executor,
    tasks :: !(Map AgentTurnId TaskHandle),
    inputs :: !(Map AgentTurnId [(TaskHandle, FrontendInputView)])
  }

data TurnInput = TurnInput
  { group :: !GroupId,
    turn :: !AgentTurnId,
    principal :: !PrincipalId,
    sourceOrder :: !(Maybe Int64),
    feedback :: !(Maybe FrontendInputView),
    acceptsFeedback :: !Bool,
    notice :: !Bool
  }

-- | A routed input acknowledges without running a model. An admitted task has
-- an actor on the root executor. There are no parked conversation tickets.
data TaskHandle = TaskHandle {input :: !TurnInput, decision :: !(TMVar (Maybe Executor.Actor))}

newConversations :: IO Conversations
newConversations = Conversations <$> newTVarIO Map.empty

enqueue :: Conversations -> TurnInput -> IO (Maybe TaskHandle)
enqueue (Conversations registry) input = do
  fresh <- Executor.newExecutor
  atomically $ do
    groups <- readTVar registry
    let root = Map.findWithDefault (Root fresh Map.empty Map.empty) input.group groups
    if Map.size root.tasks >= 256 || sum (map (Map.size . (.tasks)) (Map.elems groups)) >= 1024 || Map.member input.turn root.tasks
      then pure Nothing
      else do
        open <- filterM (fmap (maybe False id) . started) (Map.elems root.tasks)
        let feeds owner =
              owner.input.acceptsFeedback && input.principal == owner.input.principal && isJust input.feedback && case (owner.input.sourceOrder, input.sourceOrder) of
                (Just previous, Just incoming) -> incoming > previous
                _ -> False
            newest = filter feeds (sortOn (Down . (.input.sourceOrder)) open)
        handle <- TaskHandle input <$> newEmptyTMVar
        routed <- case (newest, input.feedback) of
          (owner : _, Just feedback) -> pure root {inputs = Map.insertWith (flip (<>)) owner.input.turn [(handle, feedback)] root.inputs}
          _ -> do
            actor <- Executor.registerTask root.executor input.turn (if input.notice then Executor.Notice else Executor.NewRequest)
            putTMVar handle.decision (Just actor)
            pure root
        writeTVar registry (Map.insert input.group routed {tasks = Map.insert input.turn handle routed.tasks} groups)
        pure (Just handle)
  where
    started handle =
      tryReadTMVar handle.decision >>= \case
        Just (Just actor) -> Just <$> Executor.taskStarted actor
        _ -> pure Nothing

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
      -- Until all frontend delivery moves into the node event log, preserve
      -- unread inputs at the finish boundary as independent requests.
      forM_ (Map.findWithDefault [] handle.input.turn root.inputs) $ \(pending, _) -> do
        actor <- Executor.registerTask root.executor pending.input.turn Executor.NewRequest
        void (tryPutTMVar pending.decision (Just actor))
      void (tryPutTMVar handle.decision Nothing)
      let remaining = Map.delete handle.input.turn root.tasks
          inputs = Map.map (filter ((/= handle.input.turn) . (.input.turn) . fst)) (Map.delete handle.input.turn root.inputs)
      writeTVar registry $ if Map.null remaining then Map.delete handle.input.group groups else Map.insert handle.input.group root {tasks = remaining, inputs} groups

awaitFeedback :: Conversations -> AgentTurnId -> STM ()
awaitFeedback (Conversations registry) turn = do
  groups <- readTVar registry
  check (any (not . null . Map.findWithDefault [] turn . (.inputs)) (Map.elems groups))

readFeedback :: Conversations -> AgentTurnId -> IO Text
readFeedback (Conversations registry) turn = atomically $ do
  groups <- readTVar registry
  let selected = [(group, root) | (group, root) <- Map.toList groups, Map.member turn root.tasks]
  case selected of
    [] -> pure ""
    (group, root) : _ -> do
      let pending = sortOn ((.input.sourceOrder) . fst) (Map.findWithDefault [] turn root.inputs)
          (observed, remaining) = splitAt 32 pending
      forM_ observed $ \(handle, _) -> void (tryPutTMVar handle.decision Nothing)
      writeTVar registry (Map.insert group root {inputs = Map.insert turn remaining root.inputs} groups)
      pure (renderFrontendInputs (map snd observed))
