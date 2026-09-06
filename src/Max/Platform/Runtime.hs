-- | Application assembly for narrow platform capabilities. Each operation
-- resolves foreign resources from the current caller's immutable generation.
module Max.Platform.Runtime (runRuntimePlatforms, qqBackend) where

import Effectful
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Effects.PlatformAccount (PlatformAccount, runPlatformAccount)
import Max.Effects.PlatformInteraction (PlatformInteraction, runPlatformInteraction)
import Max.Effects.PlatformQuery (PlatformQuery, runPlatformQuery)
import Max.Env (BotEnv (..))
import Max.Platform (PlatformBackend)
import Max.Platform.Rpc (platformRouter, qqBackend)
import Max.RuntimeConfig (RuntimeResources (..), RuntimeSnapshot (..))

runRuntimePlatforms :: (WithConnection :> es, IOE :> es, Reader BotEnv :> es) => PlatformBackend -> Eff (PlatformQuery : PlatformInteraction : PlatformAccount : es) a -> Eff es a
runRuntimePlatforms dflt =
  runPlatformAccount (platformRouter dflt foreignBackends)
    . runPlatformInteraction (platformRouter dflt foreignBackends)
    . runPlatformQuery (platformRouter dflt foreignBackends)
  where
    foreignBackends :: (Reader BotEnv :> xs) => Eff xs [PlatformBackend]
    foreignBackends = (\env -> env.beRuntimeSnapshot.rsResources.rrForeignEdges) <$> ask @BotEnv
