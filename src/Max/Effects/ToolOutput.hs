{-# LANGUAGE TypeFamilies #-}

-- |
-- Scoped output collected from tools for the Agent to feed back into the next
-- model round.  The interpreter is installed once per Agent turn, so media can
-- neither leak across concurrent dispatches nor force tools to share the
-- orchestrator's mutable state.
module Max.Effects.ToolOutput
  ( ToolOutput,
    InlineMedia (..),
    runToolOutput,
    queueInlineMedia,
    drainInlineMedia,
    defaultInlineMediaLimit,
  )
where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data InlineMedia = InlineMedia
  { imLabel :: !Text,
    imDataUrl :: !Text
  }
  deriving stock (Show, Eq)

data ToolOutput :: Effect where
  QueueInlineMedia :: InlineMedia -> ToolOutput m Bool
  DrainInlineMedia :: ToolOutput m [InlineMedia]

type instance DispatchOf ToolOutput = Dynamic

defaultInlineMediaLimit :: Int
defaultInlineMediaLimit = 8

-- | Install a fresh queue.  The total counter survives drains so a long tool
-- loop cannot reset its attachment budget every round.
runToolOutput ::
  (IOE :> es) =>
  Int ->
  Eff (ToolOutput : es) a ->
  Eff es a
runToolOutput limit action = do
  state <- liftIO (newTVarIO (0 :: Int, [] :: [InlineMedia]))
  interpret
    ( \_ -> \case
        QueueInlineMedia media -> liftIO . atomically $ do
          (used, queued) <- readTVar state
          if used >= max 0 limit
            then pure False
            else True <$ writeTVar state (used + 1, queued <> [media])
        DrainInlineMedia -> liftIO . atomically $ do
          (used, queued) <- readTVar state
          writeTVar state (used, [])
          pure queued
    )
    action

queueInlineMedia :: (ToolOutput :> es) => InlineMedia -> Eff es Bool
queueInlineMedia = send . QueueInlineMedia

drainInlineMedia :: (ToolOutput :> es) => Eff es [InlineMedia]
drainInlineMedia = send DrainInlineMedia
