-- | Bounded process-local conversation ownership. Waiting turns keep their
-- original dispatch context; only explicit owner feedback enters a live turn.
module Max.Conversation
  ( Conversations,
    Ticket,
    TurnInput (..),
    newConversations,
    enqueue,
    awaitTurn,
    release,
    readFeedback,
    awaitFeedback,
  )
where

import Control.Concurrent.STM
import Control.Monad (filterM, forM_, when)
import Data.Foldable (find)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Max.Platform.Types (PrincipalId)
import Max.Task.FrontendInput (FrontendInputView, renderFrontendInputs)
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId)

newtype Conversations = Conversations (TVar (Map GroupId [Ticket]))

data TurnInput = TurnInput
  { group :: !GroupId,
    turn :: !AgentTurnId,
    principal :: !PrincipalId,
    sourceOrder :: !(Maybe Int64),
    feedback :: !(Maybe FrontendInputView),
    acceptsFeedback :: !Bool,
    notice :: !Bool
  }

data Ticket = Ticket {input :: !TurnInput, state :: !(TVar TicketState)}

data TicketState = Waiting | Running | Feeding | Observed
  deriving stock (Eq)

newConversations :: IO Conversations
newConversations = Conversations <$> newTVarIO Map.empty

-- | Each admitted turn owns a bounded waiting slot. The caller installs
-- 'release' before unmasking or waiting, including for feedback-only turns.
enqueue :: Conversations -> TurnInput -> IO (Maybe Ticket)
enqueue (Conversations registry) input = atomically $ do
  groups <- readTVar registry
  let tickets = Map.findWithDefault [] input.group groups
  if length tickets >= 256 || sum (map length (Map.elems groups)) >= 1024
    then pure Nothing
    else do
      active <- filterM (fmap (== Running) . readTVar . (.state)) tickets
      let feeds owner =
            owner.input.acceptsFeedback
              && input.principal == owner.input.principal
              && isJust input.feedback
              && case (owner.input.sourceOrder, input.sourceOrder) of
                (Just previous, Just incoming) -> incoming > previous
                _ -> False
          initial = case active of
            [] -> Running
            [owner] | feeds owner -> Feeding
            _ -> Waiting
      ticket <- Ticket input <$> newTVar initial
      writeTVar registry (Map.insert input.group (tickets <> [ticket]) groups)
      pure (Just ticket)

-- | False means the active Agent consumed this explicit feedback.
awaitTurn :: Ticket -> IO Bool
awaitTurn ticket =
  atomically $
    readTVar ticket.state >>= \case
      Running -> pure True
      Observed -> pure False
      _ -> retry

release :: Conversations -> Ticket -> IO ()
release (Conversations registry) ticket = atomically $ do
  groups <- readTVar registry
  let remaining = filter ((/= ticket.input.turn) . (.input.turn)) (Map.findWithDefault [] ticket.input.group groups)
  wasRunning <- (== Running) <$> readTVar ticket.state
  writeTVar ticket.state Observed
  when wasRunning $ do
    -- Feedback arriving after the final inbox read gets its own turn.
    forM_ remaining $ \pending -> do
      status <- readTVar pending.state
      when (status == Feeding) (writeTVar pending.state Waiting)
    waiting <- filterM (fmap (== Waiting) . readTVar . (.state)) remaining
    case find (not . (.input.notice)) waiting of
      Just next -> writeTVar next.state Running
      Nothing -> forM_ (take 1 waiting) $ \next -> writeTVar next.state Running
  writeTVar registry $
    if null remaining
      then Map.delete ticket.input.group groups
      else Map.insert ticket.input.group remaining groups

awaitFeedback :: Conversations -> AgentTurnId -> STM ()
awaitFeedback (Conversations registry) turn = do
  groups <- readTVar registry
  case find (any ((== turn) . (.input.turn))) (Map.elems groups) of
    Nothing -> retry
    Just tickets -> do
      active <- filterM (fmap (== Running) . readTVar . (.state)) tickets
      check (any ((== turn) . (.input.turn)) active)
      feeding <- filterM (fmap (== Feeding) . readTVar . (.state)) tickets
      check (not (null feeding))

readFeedback :: Conversations -> AgentTurnId -> IO Text
readFeedback (Conversations registry) turn = atomically $ do
  groups <- readTVar registry
  let owningGroup = find (any ((== turn) . (.input.turn))) (Map.elems groups)
  case owningGroup of
    Nothing -> pure ""
    Just tickets -> do
      active <- filterM (fmap (== Running) . readTVar . (.state)) tickets
      if not (any ((== turn) . (.input.turn)) active)
        then pure ""
        else do
          feeding <- filterM (fmap (== Feeding) . readTVar . (.state)) tickets
          let observed = take 32 (sortOn (.input.sourceOrder) feeding)
          forM_ observed $ \ticket -> writeTVar ticket.state Observed
          pure (renderFrontendInputs (mapMaybe (.input.feedback) observed))
