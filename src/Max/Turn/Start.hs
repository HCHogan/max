-- | Explicit execution intent; background work, notices and automation fires
-- never route their trigger as foreground feedback. Once started, root tasks
-- can receive replies, including tasks started by !btw, notices and fires.
module Max.Turn.Start (TurnStart (..), InputAdmission (..), startAllowsInput, startToolCeiling, startTrigger) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Max.Node.Log qualified as NodeLog
import Max.Node.Router (MessageRelay (..), Origin (..), Relay (..), ReportRelay (..))
import Max.Platform.Types (CanonicalMessageId)
import Max.Task.Types (JobSpec (..), JobView (..))
import Max.ToolContext (toolCanonicalId, toolCatalogGrants)
import Max.Turn.Types (AgentTurnId (..))

data InputAdmission = AdmitFrontendInput | StartSeparateTurn deriving stock (Eq, Show)

data TurnStart
  = NewTurn !InputAdmission
  | JobTurn !JobView
  | MessageNotice !MessageRelay
  | CompletionNotice !Relay
  | ReportNotice !ReportRelay
  | -- | An automation fire: its creator's delayed request, handled by an
    -- ordinary foreground turn and settled into the job that admitted it.
    AutomationTurn !JobView
  deriving stock (Eq, Show)

startAllowsInput :: TurnStart -> Bool
startAllowsInput (NewTurn AdmitFrontendInput) = True
startAllowsInput _ = False

-- | Delayed work never borrows the current foreground's broader catalog.
startToolCeiling :: TurnStart -> Maybe (Map Text Text)
startToolCeiling = \case
  CompletionNotice relay -> Just (toolCatalogGrants relay.origin.context)
  ReportNotice relay -> Just relay.job.spec.grants
  MessageNotice relay -> Just relay.job.spec.grants
  AutomationTurn job -> Just job.spec.grants
  JobTurn job -> Just job.spec.grants
  NewTurn _ -> Nothing

-- | Immutable admission event; its source and result come from host-owned
-- routing receipts, never from a later live lookup of a monitor or child.
startTrigger :: TurnStart -> Maybe CanonicalMessageId -> NodeLog.Trigger
startTrigger start source = case start of
  NewTurn _ -> NodeLog.Said source
  JobTurn job -> NodeLog.Spawned job.run job.spec
  AutomationTurn job -> NodeLog.Fired job.run job.spec
  MessageNotice relay -> NodeLog.ChildSaid relay.job relay.text
  ReportNotice relay -> NodeLog.ChildDone relay.job
  CompletionNotice relay -> NodeLog.Settled (toolCanonicalId relay.origin.context) relay.origin.turn.unAgentTurnId relay.reference relay.value relay.media
