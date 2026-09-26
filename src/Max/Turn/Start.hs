-- | Explicit execution intent; background work, notices and automation fires
-- never route their trigger as foreground feedback. Once started, root tasks
-- can receive replies, including tasks started by !btw, notices and fires.
module Max.Turn.Start (TurnStart (..), InputAdmission (..), startAllowsInput) where

import Data.Text (Text)
import Max.Task.Types (JobView)

data InputAdmission = AdmitFrontendInput | StartSeparateTurn deriving stock (Eq, Show)

data TurnStart
  = NewTurn !InputAdmission
  | JobTurn !JobView
  | JobNotice !JobView !Int !Text
  | -- | An automation fire: its creator's delayed request, handled by an
    -- ordinary foreground turn and settled into the job that admitted it.
    AutomationTurn !JobView
  deriving stock (Eq, Show)

startAllowsInput :: TurnStart -> Bool
startAllowsInput (NewTurn AdmitFrontendInput) = True
startAllowsInput _ = False
