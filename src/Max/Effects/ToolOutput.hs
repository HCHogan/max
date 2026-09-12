{-# LANGUAGE TypeFamilies #-}

-- |
-- Scoped output collected from tools for the Agent to feed back into the next
-- model round.  The interpreter is installed once per Agent turn, so media can
-- neither leak across concurrent dispatches nor force tools to share the
-- orchestrator's mutable state.
module Max.Effects.ToolOutput
  ( ToolOutput,
    InlineMedia (..),
    ToolOutputRead,
    ToolOutputQueue,
    newToolOutputQueue,
    runToolOutput,
    runToolOutputRead,
    queueInlineMedia,
    queueInlineMediaOnce,
    canQueueInlineMediaOnce,
    drainInlineMedia,
    defaultInlineMediaLimit,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data InlineMedia = InlineMedia
  { imLabel :: !Text,
    imDataUrl :: !Text
  }
  deriving stock (Show, Eq)

data ToolOutput :: Effect where
  QueueInlineMedia :: Maybe Text -> InlineMedia -> ToolOutput m Bool
  CanQueueInlineMediaOnce :: Text -> ToolOutput m Bool

data ToolOutputRead :: Effect where
  DrainInlineMedia :: ToolOutputRead m [InlineMedia]

type instance DispatchOf ToolOutput = Dynamic

type instance DispatchOf ToolOutputRead = Dynamic

defaultInlineMediaLimit :: Int
defaultInlineMediaLimit = 8

-- | The queue belongs to one turn. Only the assembly layer shares this handle
-- between the producer and consumer interpreters; tool closures receive the
-- producer effect alone. The total counter survives drains.
data ToolOutputQueue = ToolOutputQueue !Int !(TVar (Int, Set Text, [InlineMedia]))

newToolOutputQueue :: (IOE :> es) => Int -> Eff es ToolOutputQueue
newToolOutputQueue limit = ToolOutputQueue (max 0 limit) <$> liftIO (newTVarIO (0, Set.empty, []))

runToolOutput ::
  (IOE :> es) =>
  ToolOutputQueue ->
  Eff (ToolOutput : es) a ->
  Eff es a
runToolOutput (ToolOutputQueue limit state) = interpret $ \_ -> \case
  CanQueueInlineMediaOnce key -> liftIO . atomically $ do
    (used, keys, _) <- readTVar state
    pure (used < limit && Set.notMember key keys)
  QueueInlineMedia key media -> liftIO . atomically $ do
    (used, keys, queued) <- readTVar state
    if used >= limit || maybe False (`Set.member` keys) key
      then pure False
      else True <$ writeTVar state (used + 1, maybe keys (`Set.insert` keys) key, queued <> [media])

runToolOutputRead ::
  (IOE :> es) =>
  ToolOutputQueue ->
  Eff (ToolOutputRead : es) a ->
  Eff es a
runToolOutputRead (ToolOutputQueue _ state) = interpret $ \_ -> \case
  DrainInlineMedia -> liftIO . atomically $ do
    (used, keys, queued) <- readTVar state
    writeTVar state (used, keys, [])
    pure queued

queueInlineMedia :: (ToolOutput :> es) => InlineMedia -> Eff es Bool
queueInlineMedia = send . QueueInlineMedia Nothing

-- | A producer category can attach at most once in an agent turn, including
-- across queue drains and adapter reconstruction. It still uses the global quota.
queueInlineMediaOnce :: (ToolOutput :> es) => Text -> InlineMedia -> Eff es Bool
queueInlineMediaOnce key = send . QueueInlineMedia (Just key)

canQueueInlineMediaOnce :: (ToolOutput :> es) => Text -> Eff es Bool
canQueueInlineMediaOnce = send . CanQueueInlineMediaOnce

drainInlineMedia :: (ToolOutputRead :> es) => Eff es [InlineMedia]
drainInlineMedia = send DrainInlineMedia
