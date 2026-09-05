{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import Control.Monad (unless)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Max.Browser.Registry
import Max.HttpRuntime (newHttpRuntime)
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))
import System.Environment (getArgs)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [endpoint, target] -> runAcceptance endpoint target
    _ -> fail "usage: cabal exec -- runghc -package=max scripts/test-browser-runtime.hs MCP_ENDPOINT PUBLIC_URL"

runAcceptance :: String -> String -> IO ()
runAcceptance endpoint target = do
  runtime <- newHttpRuntime
  let group = GroupId 1
      scope = browserScopeForTurn group (AgentTurnId 1)
  registry <- newBrowserRegistryWithHost runtime group endpoint "localhost:8931"
  let call name arguments = callBrowserTool registry scope name arguments >>= either (fail . show) pure
      close = releaseBrowserScope registry scope >> retryBrowserReleases registry
  ( do
      started <- call "browse_session_start" (object ["humanize" .= True, "geoip" .= False])
      session <- either fail pure (parseEither (withObject "result" (\result -> result .: "structuredContent" >>= withObject "session" (.: "sessionId"))) started)
      setCamoSession registry scope (Just session)
      result <- call "browse_session_navigate" (object ["sessionId" .= session, "url" .= target])
      payload <- either fail pure (parseEither (withObject "result" (.: "structuredContent")) result)
      printNavigation payload
      threadDelay 8_000_000
      _ <- call "browse_session_snapshot" (object ["sessionId" .= session])
      putStrLn "PASS real Max MCP client retains the browser session across gateway idle expiry"
      threadDelay 8_000_000
      close
      remaining <- getCamoSession registry scope
      unless (isNothing remaining) (fail "foreground browser closure was not confirmed")
      putStrLn "PASS real Max foreground finalizer confirms closure after idle expiry"
    )
    `finally` close

printNavigation :: Value -> IO ()
printNavigation payload = do
  (status, complete, title) <-
    either fail pure $
      parseEither
        ( withObject "navigation" $ \result -> do
            status <- result .: "status"
            complete <- result .: "navigation" >>= withObject "readiness" (.: "complete")
            title <- result .: "title"
            pure (status :: Int, complete :: Bool, title :: Text.Text)
        )
        payload
  putStrLn ("PASS navigation status=" <> show status <> " complete=" <> show complete <> " title=" <> Text.unpack title)
