-- |
-- Stable browser-domain errors derived at the MCP boundary.  Recovery code
-- branches on 'BrowserErrorKind'; 'browserErrorMessage' remains diagnostic
-- prose only.
module Max.Browser.Error
  ( BrowserError (..),
    BrowserErrorKind (..),
    browserErrorFromMcp,
    browserCallFailed,
    renderBrowserError,
  )
where

import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)
import Max.MCP.Client (McpError (..), renderMcpError)

data BrowserErrorKind
  = BrowserSessionGone
  | BrowserSessionBlocked
  | BrowserCallFailed
  deriving stock (Show, Eq)

data BrowserError = BrowserError
  { browserErrorKind :: !BrowserErrorKind,
    browserErrorMessage :: !Text
  }
  deriving stock (Show, Eq)

renderBrowserError :: BrowserError -> Text
renderBrowserError = (.browserErrorMessage)

browserCallFailed :: Text -> BrowserError
browserCallFailed = BrowserError BrowserCallFailed

browserErrorFromMcp :: McpError -> BrowserError
browserErrorFromMcp err =
  BrowserError
    { browserErrorKind = metadataKind err.mcpErrorMetadata,
      browserErrorMessage = renderMcpError err
    }

metadataKind :: Maybe Value -> BrowserErrorKind
metadataKind metadata =
  case metadata >>= parseMaybe (withObject "camoufox metadata" (.: "camoufox/errorKind")) of
    Just ("session_gone" :: Text) -> BrowserSessionGone
    Just "session_blocked" -> BrowserSessionBlocked
    _ -> BrowserCallFailed
