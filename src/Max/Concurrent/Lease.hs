-- | Shared renewal lifecycle. Callers retain their domain's fenced claim,
-- terminal writes and policy for transient renewal failures.
module Max.Concurrent.Lease (LeaseRun (..), withOwnedLease, renewUntilLost) where

import Control.Monad (when)
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (race)

data LeaseRun a = LeaseCompleted !a | LeaseLost deriving stock (Show, Eq)

renewUntilLost :: (Concurrent :> es) => Int -> Eff es Bool -> Eff es ()
renewUntilLost interval renew = go
  where
    go = do
      threadDelay (max 1 interval)
      held <- renew
      when held go

-- | Scoped child lifetime: losing authority cancels work, and completion or
-- cancellation always joins the renewer. Store CAS is still the final fence.
withOwnedLease :: (Concurrent :> es) => Int -> Eff es Bool -> Eff es a -> Eff es (LeaseRun a)
withOwnedLease interval renew action =
  race action (renewUntilLost interval renew) >>= \case
    Left value -> pure (LeaseCompleted value)
    Right () -> pure LeaseLost
