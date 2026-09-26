-- | Process-local authority for one admitted invocation. Model arguments and
-- persisted results cannot create or revive it.
module Max.Execution.Authority
  ( CallAuthority,
    newCallAuthority,
    revokeCallAuthority,
    callMatchesTool,
    callIsCurrent,
    callIsUsable,
    callIsActive,
  )
where

import Control.Concurrent.STM
import Data.Text (Text)
import Max.Turn.Types (AgentTurnId)

data CallAuthority = CallAuthority !AgentTurnId !Text !(TVar Bool) !(IO Bool)

newCallAuthority :: AgentTurnId -> Text -> IO Bool -> IO CallAuthority
newCallAuthority turn tool current = CallAuthority turn tool <$> newTVarIO True <*> pure current

revokeCallAuthority :: CallAuthority -> IO ()
revokeCallAuthority (CallAuthority _ _ active _) = atomically (writeTVar active False)

callMatchesTool :: CallAuthority -> Text -> Bool
callMatchesTool (CallAuthority _ tool _ _) = (== tool)

callIsUsable :: CallAuthority -> IO Bool
callIsUsable call@(CallAuthority owner _ _ _) = callIsCurrent call owner

callIsCurrent :: CallAuthority -> AgentTurnId -> IO Bool
callIsCurrent call@(CallAuthority _ _ active current) turn = do
  alive <- atomically (callIsActive call turn)
  if not alive
    then pure False
    else do
      allowed <- current
      stillActive <- readTVarIO active
      pure (allowed && stillActive)

-- | Participate in the admission transaction so revocation and admission have
-- one ordering, even when the runtime check happened before entering STM.
callIsActive :: CallAuthority -> AgentTurnId -> STM Bool
callIsActive (CallAuthority owner _ active _) turn =
  if owner == turn then readTVar active else pure False
