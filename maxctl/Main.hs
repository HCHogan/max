module Main (main) where

import Data.Text qualified as T
import Max.Reload
  ( ReloadError (..),
    ReloadResponse (..),
    requestReload,
  )
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  path <- case args of
    ["reload", "--socket", value] -> pure value
    ["--socket", value, "reload"] -> pure value
    _ -> do
      hPutStrLn stderr "usage: maxctl reload --socket PATH"
      exitFailure
  requestReload path >>= \case
    Left err -> hPutStrLn stderr (T.unpack err) >> exitFailure
    Right response -> report response

report :: ReloadResponse -> IO ()
report response = do
  let generations =
        show response.rpOldGeneration
          <> " -> "
          <> show response.rpNewGeneration
      changed = comma response.rpChangedFields
  if response.rpOk
    then putStrLn ("Max configuration reloaded (" <> generations <> ")" <> suffix changed)
    else do
      hPutStrLn stderr $
        "Max configuration reload failed: "
          <> renderError response.rpError
          <> suffix (comma response.rpRestartFields)
      exitFailure
  where
    suffix "" = ""
    suffix fields = ": " <> fields

comma :: [T.Text] -> String
comma = T.unpack . T.intercalate ", "

renderError :: Maybe ReloadError -> String
renderError = \case
  Nothing -> "unknown failure"
  Just ReloadProtocolMismatch -> "control protocol mismatch"
  Just ReloadInvalidRequest -> "invalid control request"
  Just ReloadConfigInvalid -> "candidate configuration is invalid"
  Just ReloadRestartRequired -> "restart required"
  Just ReloadPreparationFailed -> "replacement resources could not be prepared"
  Just ReloadTimedOut -> "reload timed out; the previous configuration remains active"
  Just ReloadInternalFailure -> "internal reload failure"
