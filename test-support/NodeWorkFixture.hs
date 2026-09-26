-- | Tests may race the two independent intakes when they expect either kind
-- of progress. Production consumes launches and router deliveries separately.
module NodeWorkFixture (takeWork, takeDelivery) where

import Control.Concurrent.STM (atomically, check, orElse)
import Max.Jobs qualified as Jobs
import Max.Node.Router qualified as Router
import Max.Task.Types (JobView)

takeWork :: Jobs.Jobs -> IO (Either JobView Router.DeliveryWork)
takeWork jobs = atomically $ do
  Jobs.jobsAreOpen jobs >>= check
  Jobs.flushJobEvents jobs
  (Left <$> Jobs.claimReadyJob jobs) `orElse` (Right <$> Router.takeDelivery jobs.resultRouter)

takeDelivery :: Jobs.Jobs -> IO Router.DeliveryWork
takeDelivery jobs = atomically $ do
  Jobs.jobsAreOpen jobs >>= check
  Jobs.flushJobEvents jobs
  Router.takeDelivery jobs.resultRouter
