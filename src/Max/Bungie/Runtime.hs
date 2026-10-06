-- | Process-lifetime Bungie integration resources, present when the operator
-- configured a Bungie application.
module Max.Bungie.Runtime
  ( BungieRuntime (..),
    newBungieRuntime,
    callbackPath,
  )
where

import Control.Concurrent.MVar (MVar, newMVar)
import Data.Text (Text)
import Max.Browser.Vault (BrowserVault)
import Max.Bungie.Types (BungieConfig)
import Max.HttpRuntime (HttpRuntime)

data BungieRuntime = BungieRuntime
  { brConfig :: !BungieConfig,
    brHttp :: !HttpRuntime,
    -- | Seals stored tokens; the same owner-only key file as browser state.
    brVault :: !BrowserVault,
    -- | Public HTTPS URL registered as the application's redirect.
    brCallbackUrl :: !Text,
    -- | Serializes refreshes: Bungie rotates refresh tokens, so two
    -- concurrent refreshes would invalidate each other.
    brRefreshGate :: !(MVar ()),
    -- | Serializes item actions; Bungie throttles them per account.
    brWriteGate :: !(MVar ())
  }

newBungieRuntime :: BungieConfig -> HttpRuntime -> BrowserVault -> Text -> IO BungieRuntime
newBungieRuntime config http vault publicBase =
  BungieRuntime config http vault (publicBase <> callbackPath) <$> newMVar () <*> newMVar ()

-- | Served by the admin listener next to @/hooks/@; the reverse proxy must
-- forward it without SSO.
callbackPath :: Text
callbackPath = "/oauth/bungie/callback"
