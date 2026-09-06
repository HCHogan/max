{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

-- | Pure agent output protocol. The final stream event returns acceptance so
-- the loop only advances its sent-prefix watermark after publication.
module Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..)) where

import Data.Aeson (Value)
import Data.Text (Text)

-- | Debug facts emitted by the loop without deciding whether debug output is
-- enabled or how the values should be formatted for chat.
data ToolDebugEvent
  = ToolCallsStarted ![(Text, Value)]
  | ToolCallFinished !Text !(Either Text Value)
  deriving stock (Show, Eq)

-- | Events crossing from the agent orchestrator to its output boundary.
data AgentEvent a where
  AgentProgressText :: !Text -> AgentEvent ()
  AgentToolDebug :: !ToolDebugEvent -> AgentEvent ()
  AgentFinalStreamText :: !Text -> AgentEvent Bool

-- | A natural transformation from typed agent events into some carrier.
type AgentEventSink m = forall a. AgentEvent a -> m a
