-- | Browser workspace state and recovery decisions, independent of SQL/MCP.
module Max.Browser.State
  ( WorkspaceState (..),
    workspaceStateText,
    parseWorkspaceState,
    WorkspaceError (..),
    renderWorkspaceError,
    Acquisition (..),
    decideAcquisition,
  )
where

import Data.Text (Text)

data WorkspaceState = Cold | Hot | Busy | Uncertain | Revoked deriving stock (Eq, Show)

workspaceStateText :: WorkspaceState -> Text
workspaceStateText = \case
  Cold -> "cold"
  Hot -> "hot"
  Busy -> "busy"
  Uncertain -> "uncertain"
  Revoked -> "revoked"

parseWorkspaceState :: Text -> Maybe WorkspaceState
parseWorkspaceState = \case
  "cold" -> Just Cold
  "hot" -> Just Hot
  "busy" -> Just Busy
  "uncertain" -> Just Uncertain
  "revoked" -> Just Revoked
  _ -> Nothing

data WorkspaceError = WorkspaceFenced | WorkspaceUnavailable | WorkspaceRevoked | WorkspaceUnknown | ProfileRevoked | WorkspaceClosureUnconfirmed
  deriving stock (Eq, Show)

renderWorkspaceError :: WorkspaceError -> Text
renderWorkspaceError = \case
  WorkspaceFenced -> "browser execution was fenced"
  WorkspaceUnavailable -> "browser lease unavailable"
  WorkspaceRevoked -> "browser workspace revoked; owner must reset it"
  WorkspaceUnknown -> "browser outcome unknown; inspect external effects and use !browser reset task#N; never replay the previous action"
  ProfileRevoked -> "browser authentication profile revoked"
  WorkspaceClosureUnconfirmed -> "previous browser did not confirm closure; cold recovery refused"

data Acquisition = ReuseWorkspace | ResetRevision | RestoreRuntime deriving stock (Eq, Show)

-- | Revocation and uncertainty outrank cold restoration. A new process is
-- not evidence that a previous external operation never happened.
decideAcquisition :: WorkspaceState -> Bool -> Bool -> Bool -> Either WorkspaceError Acquisition
decideAcquisition state profileValid revisionChanged runtimeChanged
  | state == Revoked = Left WorkspaceRevoked
  | state == Busy || state == Uncertain = Left WorkspaceUnknown
  | not profileValid = Left ProfileRevoked
  | revisionChanged = Right ResetRevision
  | runtimeChanged && state == Hot = Right RestoreRuntime
  | otherwise = Right ReuseWorkspace
