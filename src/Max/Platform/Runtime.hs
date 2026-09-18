-- | Assemble the application's narrow platform capabilities.
module Max.Platform.Runtime (runPlatforms, qqBackend) where

import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.PlatformAccount (PlatformAccount, runPlatformAccount)
import Max.Effects.PlatformInteraction (PlatformInteraction, runPlatformInteraction)
import Max.Effects.PlatformQuery (PlatformQuery, runPlatformQuery)
import Max.Platform (PlatformBackend)
import Max.Platform.Rpc (platformRouter, qqBackend)

runPlatforms :: (WithConnection :> es, IOE :> es) => PlatformBackend -> [PlatformBackend] -> Eff (PlatformQuery : PlatformInteraction : PlatformAccount : es) a -> Eff es a
runPlatforms dflt foreignBackends =
  runPlatformAccount (platformRouter dflt (pure foreignBackends))
    . runPlatformInteraction (platformRouter dflt (pure foreignBackends))
    . runPlatformQuery (platformRouter dflt (pure foreignBackends))
