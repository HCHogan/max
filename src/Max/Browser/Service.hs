-- | Native browser service lifecycle through Max's restricted runtime broker.
module Max.Browser.Service (runRunBrowser, browserHostPort, defaultBrowserImage) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

-- Retained in the registry's internal API; the host chooses the package.
defaultBrowserImage :: Text
defaultBrowserImage = "native-camoufox"

runRunBrowser :: Text -> Text -> IO (Either Text Text)
runRunBrowser name _ = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime" ["browser-create", T.unpack name] ""
  pure $ case result of
    Left err -> Left (T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (T.strip (T.pack out))
    Right (ExitFailure code, _, err) -> Left ("browser service startup exited " <> T.pack (show code) <> ": " <> T.strip (T.pack err))

browserHostPort :: Text -> IO (Either Text Int)
browserHostPort name = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime" ["browser-port", T.unpack name] ""
  pure $ case result of
    Left err -> Left (T.pack (show err))
    Right (ExitSuccess, out, _) -> case readMaybe (T.unpack (T.strip (T.pack out))) of
      Just port | port >= 1024 && port <= 65535 -> Right port
      _ -> Left "browser service returned an invalid endpoint"
    Right (ExitFailure code, _, err) -> Left ("browser endpoint lookup exited " <> T.pack (show code) <> ": " <> T.strip (T.pack err))
