-- | Explicit execution intent; background work never admits foreground feedback.
module Max.Turn.Start (TurnStart (..), InputAdmission (..), startAllowsInput) where

import Data.Text (Text)
import Max.Task.Types (JobView)

data InputAdmission = AdmitFrontendInput | StartSeparateTurn deriving stock (Eq, Show)

data TurnStart
  = NewTurn !InputAdmission
  | JobTurn !JobView
  | JobNotice !JobView !Int !Text
  deriving stock (Eq, Show)

startAllowsInput :: TurnStart -> Bool
startAllowsInput (NewTurn AdmitFrontendInput) = True
startAllowsInput _ = False
