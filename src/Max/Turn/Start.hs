-- | Background work and notices do not admit foreground feedback.
module Max.Turn.Start
  ( TurnStart (..),
    InputAdmission (..),
    startTurn,
    startAllowsInput,
    startHostView,
    startEffectCeiling,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Max.Turn.Types (AgentTurnRef)

data InputAdmission = AdmitFrontendInput | StartSeparateTurn deriving stock (Eq, Show)

data TurnStart
  = NewTurn !InputAdmission
  | TaskTurn !AgentTurnRef !(Maybe Text) !(Map Text Text)
  deriving stock (Eq, Show)

startTurn :: TurnStart -> Maybe AgentTurnRef
startTurn NewTurn {} = Nothing
startTurn (TaskTurn turn _ _) = Just turn

startAllowsInput :: TurnStart -> Bool
startAllowsInput (NewTurn AdmitFrontendInput) = True
startAllowsInput _ = False

startHostView :: TurnStart -> Maybe Text
startHostView (TaskTurn _ view _) = view
startHostView _ = Nothing

startEffectCeiling :: TurnStart -> Maybe (Map Text Text)
startEffectCeiling (TaskTurn _ _ grants) = Just grants
startEffectCeiling _ = Nothing
