{-# LANGUAGE TypeFamilies #-}

-- | Non-content social interaction. Text/media and recorded reactions continue
-- through canonical Outbound publication, not this capability.
module Max.Effects.PlatformInteraction (PlatformInteraction, runPlatformInteraction, pokeUser) where

import Data.Functor (void)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Failure (PlatformFailure)
import Max.Platform.Rpc (PlatformRouter, callPlatform)
import OneBot.Action (Action (SendPoke))
import OneBot.Types (GroupId, UserId)

data PlatformInteraction :: Effect where
  PokeUser :: GroupId -> UserId -> PlatformInteraction m (Either PlatformFailure ())

type instance DispatchOf PlatformInteraction = Dynamic

runPlatformInteraction :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Eff (PlatformInteraction : es) a -> Eff es a
runPlatformInteraction router = interpret $ \_ -> \case
  PokeUser group user -> fmap void (callPlatform router (SendPoke group user) 10000)

pokeUser :: (PlatformInteraction :> es) => GroupId -> UserId -> Eff es (Either PlatformFailure ())
pokeUser group user = send (PokeUser group user)
