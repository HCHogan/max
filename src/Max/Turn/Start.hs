-- | Explicit execution intent; background work, notices and automation fires
-- never route their trigger as foreground feedback. Once started, root tasks
-- can receive replies, including tasks started by !btw, notices and fires.
module Max.Turn.Start (TurnStart (..), InputAdmission (..), startAllowsInput, startToolCeiling) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Max.Node.Router (MessageRelay (..), Origin (..), Relay (..), ReportRelay (..))
import Max.Task.Types (JobSpec (..), JobView (..))
import Max.ToolContext (toolCatalogGrants)

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
