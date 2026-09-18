-- | Durable dispatch ownership, independent of models and agent execution.
module Max.Dispatch.Lease (DispatchOwner (..), dispatchLeaseSeconds, settleDispatchOwner) where

import Control.Monad (void)
import Data.Foldable (for_)
import Data.Text qualified as T (Text)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Store
  ( DispatchCompletion,
    completeDispatch,
  )
import Max.Platform.Types (CanonicalMessageId)

-- The claim attempt fences earlier workers with the same process identity.
data DispatchOwner = DispatchOwner
  { doWorker :: !T.Text,
    doMessage :: !CanonicalMessageId,
    doAttempt :: !Int
  }

dispatchLeaseSeconds :: NominalDiffTime
dispatchLeaseSeconds = 120

settleDispatchOwner :: (WithConnection :> es, IOE :> es) => Maybe DispatchOwner -> DispatchCompletion -> Eff es ()
settleDispatchOwner owner completion = for_ owner $ \o -> void (completeDispatch o.doWorker o.doMessage o.doAttempt completion)
