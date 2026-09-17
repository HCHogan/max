-- | Legal dispatch entry states. Recovery cannot omit a durable owner, and
-- task/monitor work cannot accidentally acquire frontend inbox admission.
module Max.Turn.Start
  ( TurnStart (..),
    InputAdmission (..),
    startTurn,
    startAllowsInput,
    startRecoveryView,
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
  | ResumeTurn !AgentTurnRef !Text
  | TaskTurn !AgentTurnRef !(Maybe Text) !(Map Text Text)
  | MonitorTurn !AgentTurnRef !(Maybe Text) !Text !(Map Text Text)
  deriving stock (Eq, Show)

startTurn :: TurnStart -> Maybe AgentTurnRef
startTurn NewTurn {} = Nothing
startTurn (ResumeTurn turn _) = Just turn
startTurn (TaskTurn turn _ _) = Just turn
startTurn (MonitorTurn turn _ _ _) = Just turn

startAllowsInput :: TurnStart -> Bool
startAllowsInput (NewTurn AdmitFrontendInput) = True
startAllowsInput _ = False

startRecoveryView :: TurnStart -> Maybe Text
startRecoveryView (ResumeTurn _ view) = Just view
startRecoveryView (MonitorTurn _ view _ _) = view
startRecoveryView _ = Nothing

startHostView :: TurnStart -> Maybe Text
startHostView (TaskTurn _ view _) = view
startHostView (MonitorTurn _ _ view _) = Just view
startHostView _ = Nothing

startEffectCeiling :: TurnStart -> Maybe (Map Text Text)
startEffectCeiling (TaskTurn _ _ grants) = Just grants
startEffectCeiling (MonitorTurn _ _ _ grants) = Just grants
startEffectCeiling _ = Nothing
