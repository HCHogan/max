{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (IOE, runEff)
import Max.Effects.Tools (Tool (..))
import Max.HttpRuntime (newHttpRuntime)
import Max.MaxOps.Types
import Max.Tools.MaxOps (maxOpsToolsFor)
import OneBot.Types (GroupId (..))
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  (endpoint, tokenFile, host, unit) <- case arguments of
    [endpoint, tokenFile, host, unit] -> pure (T.pack endpoint, tokenFile, T.pack host, T.pack unit)
    _ -> die "usage: test-maxops.hs HUB_URL TOKEN_FILE HOST UNIT"
  runtime <- newHttpRuntime
  let config = MaxOpsConfig True endpoint tokenFile [611798505]
  current <- newIORef config
  let tools :: [Tool '[IOE]]
      tools = maxOpsToolsFor runtime config (readIORef current) (GroupId 611798505)
      call name params = case find ((== name) . (.toolName)) tools of
        Nothing -> die "expected maxops tool is missing"
        Just tool -> runEff (tool.toolRun params)
      query operation params = call "maxops_query" (object ["op" .= (operation :: Text), "params" .= params])
      success label action = do
        result <- action
        case result of
          Left failure -> die (label <> ": " <> T.unpack failure)
          Right value -> putStrLn ("PASS " <> label) >> pure value
      denied label action = do
        result <- action
        case result of
          Left "maxops HTTP 403" -> putStrLn ("PASS " <> label)
          _ -> die (label <> ": expected scoped HTTP 403 denial")
  catalog <- success "authenticated operation catalog" (call "maxops_operations" (object []))
  unless (hasField "operations" catalog) (die "catalog has no operations")
  overview <- success "fleet overview with partial-state semantics" (query "fleet.overview" (object []))
  unless (hasField "hosts" overview) (die "overview has no hosts")
  facts <- success "host facts" (query "host.facts" (object ["host" .= host]))
  unless (field "host" facts == Just (String host)) (die "host identity mismatch")
  _ <- success "failed units" (query "units.failed" (object []))
  _ <- success "allowlisted unit list" (query "units.list" (object ["host" .= host]))
  _ <- success "deployment status" (query "deploy.status" (object []))
  _ <- success "host metrics with explicit unavailable-source semantics" (query "host.metrics" (object ["host" .= host]))
  _ <- success "allowlisted unit status" (query "units.status" (object ["host" .= host, "unit" .= unit]))
  denied "hub host scope" (query "host.facts" (object ["host" .= ("maxops-denied-fixture" :: Text)]))
  denied "hub metrics scope" (query "host.metrics" (object ["host" .= ("maxops-denied-fixture" :: Text)]))
  denied "hub unit scope" (query "units.status" (object ["host" .= host, "unit" .= ("maxops-denied-fixture.service" :: Text)]))
  mutation <- query "units.restart" (object ["host" .= host, "unit" .= unit])
  unless (mutation == Left "maxops operation is unavailable or not read-only; call maxops_operations") (die "mutation was not rejected")
  putStrLn "PASS mutation denied by read-only catalog"
  let deniedTools :: [Tool '[IOE]]
      deniedTools = maxOpsToolsFor runtime config (readIORef current) (GroupId 611798506)
  unless (null deniedTools) (die "unlisted group received tools")
  writeIORef current (config {mocAllowedGroups = []})
  revoked <- query "fleet.overview" (object [])
  unless (revoked == Left "maxops access was revoked or configuration changed; start a new turn") (die "old turn retained revoked authority")
  putStrLn "PASS unlisted group and revoked in-flight turn denied"

field :: Key -> Value -> Maybe Value
field name (Object fields) = KeyMap.lookup name fields
field _ _ = Nothing

hasField :: Key -> Value -> Bool
hasField name value = isJust (field name value)
