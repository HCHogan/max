-- | Durable dispatch ownership, independent of models and agent execution.
module Max.Dispatch.Lease (DispatchOwner (..), dispatchLeaseSeconds, holdingDispatchLease, settleDispatchOwner) where

import Control.Monad (unless, void)
import Data.Foldable (for_)
import Data.Text qualified as T (Text, pack)
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, type (:>))
import Effectful.Concurrent.Async (Concurrent, withAsync)
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Concurrent.Lease (renewUntilLost)
import Max.Platform.Store
  ( DispatchCompletion,
    completeDispatch,
    renewDispatchLease,
  )
import Max.Platform.Types (CanonicalMessageId)
import Max.Util (catchSync)

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

-- A lost claim stops renewal, not a turn that may already have published output.
holdingDispatchLease :: (Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) => Maybe DispatchOwner -> Eff es a -> Eff es a
holdingDispatchLease owner act = case owner of
  Nothing -> act
  Just o -> withAsync (renewDispatchLeaseLoop o) (const act)

renewDispatchLeaseLoop :: (Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) => DispatchOwner -> Eff es ()
renewDispatchLeaseLoop o = renewUntilLost (max 1 (floor dispatchLeaseSeconds `div` 3) * 1_000_000) $ do
  -- A blip reaching the database is not evidence the row was taken away,
  -- so it costs a renewal and not the lease.
  held <-
    renewDispatchLease o.doWorker o.doMessage o.doAttempt dispatchLeaseSeconds
      `catchSync` \e -> do
        logAttention "dispatch lease renewal failed" $
          object ["error" .= T.pack (show (e :: SomeException))]
        pure True
  unless held $
    logAttention "dispatch lease lost while the turn was still running" $
      object
        [ "canonical_message_id" .= o.doMessage,
          "worker" .= o.doWorker
        ]
  pure held
