module Main (main) where

import Control.Monad (unless)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import PromptFlow (projectionParityFailures, promptStatistics, renderPromptFlow)
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (die)

documentPath :: FilePath
documentPath = "docs/prompt-flow.md"

main :: IO ()
main = do
  unless (null projectionParityFailures) $
    die ("uninterrupted projection changed for: " <> T.unpack (T.intercalate ", " projectionParityFailures))
  getArgs >>= \case
    [] -> do
      TIO.writeFile documentPath renderPromptFlow
      putStrLn ("generated " <> documentPath)
    ["--check"] -> do
      exists <- doesFileExist documentPath
      unless exists (die (documentPath <> " is missing; run cabal run max-prompt-flow"))
      actual <- TIO.readFile documentPath
      unless (actual == renderPromptFlow) $
        die (documentPath <> " is stale; run cabal run max-prompt-flow")
      putStrLn (documentPath <> " is up to date")
    ["--stdout"] -> TIO.putStr renderPromptFlow
    ["--stats"] -> LBS.putStrLn (encode promptStatistics)
    _ -> die "usage: max-prompt-flow [--check|--stdout|--stats]"
