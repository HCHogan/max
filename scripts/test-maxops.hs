{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Foldable (toList)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (IOE, runEff)
import Max.Effects.Tools (Tool (..))
import Max.HttpRuntime (newHttpRuntime)
import Max.MaxOps.Protocol (CatalogAccess (..))
import Max.MaxOps.Types
import Max.Tools.MaxOps (maxOpsToolsFor)
import OneBot.Types (GroupId (..))
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  (endpoint, tokenFile, host, unit, management) <- case arguments of
    [endpoint, tokenFile, host, unit] -> pure (T.pack endpoint, tokenFile, T.pack host, T.pack unit, False)
    [endpoint, tokenFile, host, unit, "--management"] -> pure (T.pack endpoint, tokenFile, T.pack host, T.pack unit, True)
    _ -> die "usage: test-maxops.hs HUB_URL TOKEN_FILE HOST UNIT [--management (isolated fixtures only)]"
  runtime <- newHttpRuntime
  let config = MaxOpsConfig True endpoint tokenFile [611798505]
  current <- newIORef config
  let tools :: [Tool '[IOE]]
      tools = maxOpsToolsFor runtime config (readIORef current) (GroupId 611798505) (if management then ManagementCatalog else ReadOnlyCatalog)
      call name params = case find ((== name) . (.toolName)) tools of
        Nothing -> die "expected maxops tool is missing"
        Just tool -> runEff (tool.toolRun params)
      query operation params = call "maxops_query" (object ["op" .= (operation :: Text), "params" .= params])
      execute :: Text -> Value -> Maybe Text -> IO (Either Text Value)
      execute operation params key = call "maxops_execute" (object (["op" .= operation, "params" .= params] <> ["idempotency_key" .= value | Just value <- [key]]))
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
  putStrLn "PASS mutation denied by the read-only query path"
  when management $ do
    let params = object ["host" .= host]
        key = Just "max-adapter-diagnostic"
    submitted <- success "durable diagnostic submission" (execute "diagnostics.collect" params key)
    identifier <- maybe (die "submission has no job ID") pure (field "job_id" submitted)
    repeated <- success "same idempotency key resumes the original job" (execute "diagnostics.collect" params key)
    unless (field "job_id" repeated == Just identifier) (die "idempotent submission duplicated the job")
    conflict <- execute "diagnostics.collect" (object ["host" .= host, "lines" .= (51 :: Int)]) key
    unless (conflict == Left "maxops HTTP 409") (die "changed specification did not conflict with the original key")
    putStrLn "PASS changed specification cannot reuse a submitted key"
    let waitForJob job remaining = do
          status <- query "jobs.status" (object ["job_id" .= job]) >>= either (die . T.unpack) pure
          case field "handle" status >>= field "state" of
            Just (String "succeeded") -> pure status
            Just (String state) | state `elem` ["queued", "dispatching", "running", "reconciling"], remaining > (0 :: Int) -> threadDelay 100000 >> waitForJob job (remaining - 1)
            _ -> die "diagnostic did not reach a verified successful terminal state"
    completed <- waitForJob identifier 100
    unless (hasField "result" completed) (die "terminal job lost its evidence")
    putStrLn "PASS queued job is polled to a terminal result"
    _ <- success "job list" (query "jobs.list" (object []))
    events <- success "durable event replay" (query "events.list" (object ["host" .= host]))
    _ <- success "hub status" (query "self.status" (object []))
    event <- case field "events" events of
      Just (Array values) | first : _ <- toList values -> maybe (die "event has no ID") pure (field "event_id" first)
      _ -> die "diagnostic did not emit an event"
    claim <- success "durable remediation claim" (execute "remediations.begin" (object ["host" .= host, "event_id" .= event]) (Just "fixture-remediation"))
    claimId <- maybe (die "remediation claim has no job ID") pure (field "job_id" claim)
    claimed <- waitForJob claimId 100
    remediation <- maybe (die "claim has no remediation record") pure (field "result" claimed >>= field "remediation")
    remediationId <- maybe (die "remediation has no ID") pure (field "remediation_id" remediation)
    revision <- maybe (die "remediation has no revision") pure (field "revision" remediation)
    _ <- success "revisioned control without idempotency header" (execute "remediations.finish" (object ["remediation_id" .= remediationId, "expected_revision" .= revision, "outcome" .= ("no_action" :: Text), "summary" .= ("isolated adapter test" :: Text)]) Nothing)
    denied "management host scope" (execute "diagnostics.collect" (object ["host" .= ("maxops-denied-fixture" :: Text)]) (Just "denied-fixture"))
  let deniedTools :: [Tool '[IOE]]
      deniedTools = maxOpsToolsFor runtime config (readIORef current) (GroupId 611798506) ManagementCatalog
  unless (null deniedTools) (die "unlisted group received tools")
  writeIORef current (config {mocAllowedGroups = []})
  revoked <- query "fleet.overview" (object [])
  unless (revoked == Left "maxops access was revoked or configuration changed; start a new turn") (die "old turn retained revoked authority")
  when management $ do
    revokedWrite <- execute "diagnostics.collect" (object ["host" .= host]) (Just "revoked-fixture")
    unless (revokedWrite == Left "maxops access was revoked or configuration changed; start a new turn") (die "old turn retained management authority")
  putStrLn "PASS unlisted group and revoked in-flight turn denied"

field :: Key -> Value -> Maybe Value
field name (Object fields) = KeyMap.lookup name fields
field _ _ = Nothing

hasField :: Key -> Value -> Bool
hasField name value = isJust (field name value)
