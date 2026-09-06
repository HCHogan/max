-- | Typed failures at the platform capability boundary. Display text is not
-- used for routing, retcode handling or websocket-generation fencing.
module Max.Platform.Failure (PlatformFailure (..), renderPlatformFailure) where

import Data.Text (Text)
import Data.Text qualified as T

data PlatformFailure
  = PlatformRouteMissing
  | PlatformRouteUnavailable !Text ![Text]
  | PlatformTransportFailure !Text
  | PlatformRejected !Int
  | PlatformInvalidResponse !Text
  | PlatformGenerationChanged
  deriving stock (Eq, Show)

renderPlatformFailure :: PlatformFailure -> Text
renderPlatformFailure = \case
  PlatformRouteMissing -> "platform route unresolved: target has no canonical endpoint"
  PlatformRouteUnavailable required configured -> "platform route unavailable: endpoint requires " <> required <> ", configured=" <> T.intercalate "," configured
  PlatformTransportFailure message -> message
  PlatformRejected code -> "platform retcode " <> T.pack (show code)
  PlatformInvalidResponse message -> "platform response parse failed: " <> message
  PlatformGenerationChanged -> "connection generation changed"
