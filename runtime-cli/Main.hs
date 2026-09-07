module Main (main) where

import Control.Exception (IOException, try)
import Data.Text qualified as T
import Max.Runtime.Broker (runRuntimeBroker)
import Max.Runtime.Client (runRuntimeClient)
import Max.Runtime.Protocol (parseVolumeName)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  arguments <- getArgs
  result <- try @IOException $ case arguments of
    ["--serve", configuration] -> runRuntimeBroker configuration >> pure 0
    ["--validate-volume", volume] -> case parseVolumeName (T.pack volume) of
      Left message -> hPutStrLn stderr (T.unpack message) >> pure 64
      Right _ -> pure 0
    ["--help"] -> putStrLn "max-runtime [--serve CONFIG | INSTANCE-OPERATION ...]" >> pure 0
    _ -> runRuntimeClient arguments
  code <- case result of
    Left err -> hPutStrLn stderr ("max runtime unavailable: " <> show err) >> pure 125
    Right value -> pure value
  exitWith (if code == 0 then ExitSuccess else ExitFailure code)
