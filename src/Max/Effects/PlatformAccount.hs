{-# LANGUAGE TypeFamilies #-}

-- | Account administration is installed at the event edge, never in tools or
-- roster/permission queries. An approval flag comes from the platform event.
module Max.Effects.PlatformAccount
  ( PlatformAccount,
    FriendRequestDecision (..),
    runPlatformAccount,
    respondToFriendRequest,
  )
where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Failure (PlatformFailure)
import Max.Platform.Rpc (PlatformRouter, sendPlatform)
import OneBot.Action (Action (SetFriendAddRequest))

data FriendRequestDecision = AcceptFriend | RejectFriend deriving stock (Eq, Show)

data PlatformAccount :: Effect where
  RespondToFriendRequest :: Text -> FriendRequestDecision -> PlatformAccount m (Either PlatformFailure ())

type instance DispatchOf PlatformAccount = Dynamic

runPlatformAccount :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Eff (PlatformAccount : es) a -> Eff es a
runPlatformAccount router = interpret $ \_ -> \case
  RespondToFriendRequest flag decision -> sendPlatform router (SetFriendAddRequest flag (decision == AcceptFriend))

respondToFriendRequest :: (PlatformAccount :> es) => Text -> FriendRequestDecision -> Eff es (Either PlatformFailure ())
respondToFriendRequest flag decision = send (RespondToFriendRequest flag decision)
