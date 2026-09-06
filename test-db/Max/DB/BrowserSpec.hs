module Max.DB.BrowserSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as BS8
import Data.Either (fromRight, isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import Max.Browser.Profile (browserCommand, browserCommandOnce)
import Max.Browser.Registry (browserRuntimeId, browserVault, configureBrowserRegistry, newBrowserRegistry, newBrowserRegistryWithHost)
import Max.Browser.Runtime (browserMaintenance, releaseBrowserTurn, workspaceIdentity)
import Max.Browser.State (WorkspaceState (..))
import Max.Browser.ToolRuntime (browserToolsFor)
import Max.Browser.Vault (sealBrowserState)
import Max.DB.AgentTurn (AgentTurnTerminal (TurnSucceeded), finishAgentTurn)
import Max.DB.Browser
import Max.DB.Connection (DbPool)
import Max.DB.Monitor (armLedgerMatchMonitor)
import Max.DB.Task
import Max.DB.TaskSpec (admit, claimOne, insertOccurrence, report, seed)
import Max.Effects.Tools (Tool (..))
import Max.HttpRuntime (newHttpRuntime)
import Max.Monitor.Types
import Max.Platform.Types (PrincipalId (..), noAdvertisedCaps)
import Max.ToolContext
import Max.Turn.Types
import Network.HTTP.Types (status200, status202)
import Network.Wai (Application, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "task browser workspaces" $ do
  it "deduplicates browser commands and never replays an interrupted command" $ do
    (_, message, actor) <- seed pool 900 1
    registry <- newHttpRuntime >>= newBrowserRegistry
    first <- withDb pool (browserCommandOnce registry (GroupId 900) actor message ["profiles"])
    second <- withDb pool (browserCommandOnce registry (GroupId 900) actor message ["profiles"])
    second `shouldBe` first
    rows <- withDb pool $ query "SELECT count(*) FROM browser_command_events" ()
    rows `shouldBe` [Only (1 :: Int64)]
    void $ withDb pool $ execute "UPDATE browser_command_receipts SET result=NULL" ()
    interrupted <- withDb pool (browserCommandOnce registry (GroupId 900) actor message ["profiles"])
    show interrupted `shouldContain` "not replayed"
    later <- withDb pool $ query "SELECT count(*) FROM browser_command_events" ()
    later `shouldBe` rows

  it "hot-resumes and cold-restores through the MCP protocol without exposing authentication storage" $ do
    calls <- newIORef []
    failure <- newIORef ""
    serial <- newIORef (0 :: Int)
    testWithApplication (pure (browserFixture calls failure serial)) $ \port -> do
      source@(_, message, actor) <- seed pool 900 1
      identifier <- admit pool source "protocol"
      first <- claimOne pool
      http <- newHttpRuntime
      let endpoint = "http://127.0.0.1:" <> show port <> "/mcp"
          makeRegistry = newBrowserRegistryWithHost http (GroupId 900) endpoint "localhost"
          run registry turn name = do
            output <- newTurnOutputContext turn
            let browserContext = mkToolContext (TurnIdentity (GroupId 900) message (UserId 1) (UserId 99) actor Nothing (Just output)) (TurnCapabilities True False False noAdvertisedCaps False Map.empty Nothing True)
                arguments = object ["url" .= ("https://example.com" :: Text), "selector" .= ("#button" :: Text)]
            withDb pool $ case [tool | tool <- browserToolsFor browserContext registry Nothing, tool.toolName == name] of
              [tool] -> tool.toolRun arguments
              _ -> error "missing browser tool"
      registry <- makeRegistry
      navigated <- run registry first "browser_navigate"
      navigated `shouldSatisfy` not . isLeft
      show navigated `shouldNotContain` "fixture-auth-cookie"
      void $ withDb pool (taskReport first.atrTurnId (report "waiting"))
      withDb pool (finishAgentTurn first TurnSucceeded 1 Nothing Nothing)
      withDb pool (releaseBrowserTurn registry (GroupId 900) first.atrTurnId)
      void $ withDb pool (taskControl (GroupId 900) actor False identifier "steer" Nothing Nothing "continue")
      second <- claimOne pool
      run registry second "browser_snapshot" >>= (`shouldSatisfy` not . isLeft)
      observed <- readIORef calls
      length (filter ((== "browse_session_start") . fst) observed) `shouldBe` 1
      run registry first "browser_click" >>= (`shouldSatisfy` isLeft)
      readIORef calls `shouldReturn` observed
      restarted <- configureBrowserRegistry (browserVault registry) 1800 300 <$> makeRegistry
      run restarted second "browser_click" >>= (`shouldSatisfy` isLeft)
      run restarted second "browser_navigate" >>= (`shouldSatisfy` not . isLeft)
      restored <- readIORef calls
      let starts = [arguments | (name, arguments) <- reverse restored, name == "browse_session_start"]
      length starts `shouldBe` 2
      show (last starts) `shouldContain` "fixture-auth-cookie"
      writeIORef failure "browse_session_action"
      run restarted second "browser_click" >>= (`shouldSatisfy` isLeft)
      afterFailure <- readIORef calls
      run restarted second "browser_click" >>= (`shouldSatisfy` isLeft)
      readIORef calls `shouldReturn` afterFailure
      writeIORef failure "max_workspace_revoke"
      withDb pool (browserCommand restarted (GroupId 900) actor ["reset", "task#1"]) >>= (`shouldSatisfy` isLeft)
      writeIORef failure ""
      withDb pool (browserCommand restarted (GroupId 900) actor ["reset", "task#1"]) >>= (`shouldSatisfy` not . isLeft)

  it "uses one workspace across attempts, but fences the previous owner" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "browser"
    first <- claimOne pool
    Right original <- withDb pool (acquireBrowserWorkspace first.atrTurnId "runtime")
    withDb pool (beginBrowserOperation first.atrTurnId original.bwEpoch) `shouldReturn` True
    withDb pool (finishBrowserOperation first.atrTurnId original.bwEpoch (Just "sealed-fixture") True) `shouldReturn` True
    withDb pool (taskReport first.atrTurnId (report "waiting")) `shouldReturn` True
    withDb pool (finishAgentTurn first TurnSucceeded 1 Nothing Nothing)
    void $ withDb pool (taskControl (GroupId 900) actor False identifier "steer" Nothing Nothing "continue")
    second <- claimOne pool
    Right resumed <- withDb pool (acquireBrowserWorkspace second.atrTurnId "runtime")
    resumed.bwGeneration `shouldBe` original.bwGeneration
    resumed.bwCheckpoint `shouldBe` Just "sealed-fixture"
    resumed.bwEpoch `shouldSatisfy` (> original.bwEpoch)
    withDb pool (beginBrowserOperation first.atrTurnId original.bwEpoch) `shouldReturn` False
    withDb pool (finishBrowserOperation first.atrTurnId original.bwEpoch (Just "late-write") True) `shouldReturn` False

  it "reserves at most one operation for an epoch" $ do
    source <- seed pool 900 1
    _ <- admit pool source "browser"
    turn <- claimOne pool
    Right workspace <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime")
    results <- concurrently (withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch)) (withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch))
    results `shouldSatisfy` uncurry (/=)

  it "cold-recovers a clean restart without replaying an operation" $ do
    source <- seed pool 900 1
    _ <- admit pool source "browser"
    turn <- claimOne pool
    Right original <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "old-runtime")
    withDb pool (beginBrowserOperation turn.atrTurnId original.bwEpoch) `shouldReturn` True
    withDb pool (finishBrowserOperation turn.atrTurnId original.bwEpoch (Just "encrypted") True) `shouldReturn` True
    Right cold <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "new-runtime")
    cold.bwGeneration `shouldSatisfy` (> original.bwGeneration)
    cold.bwState `shouldBe` Cold
    cold.bwCheckpoint `shouldBe` Just "encrypted"

  it "does not automatically resume an interrupted operation, including after restart" $ do
    source <- seed pool 900 1
    _ <- admit pool source "browser"
    turn <- claimOne pool
    Right workspace <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "old-runtime")
    withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch) `shouldReturn` True
    resumed <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "new-runtime")
    resumed `shouldSatisfy` isLeft
    withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch) `shouldReturn` False

  it "reclaims cancellation and replacement, and never reuses the replaced generation" $ do
    source@(_, _, actor) <- seed pool 900 1
    identifier <- admit pool source "browser"
    turn <- claimOne pool
    Right original <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime")
    void $ withDb pool (taskControl (GroupId 900) actor False identifier "replace" (Just 1) Nothing "new goal")
    withDb pool (beginBrowserOperation turn.atrTurnId original.bwEpoch) `shouldReturn` False
    registry <- newHttpRuntime >>= newBrowserRegistry
    withDb pool (browserMaintenance registry)
    next <- claimOne pool
    Right replaced <- withDb pool (acquireBrowserWorkspace next.atrTurnId (browserRuntimeId registry))
    replaced.bwGeneration `shouldSatisfy` (> original.bwGeneration)
    replaced.bwCheckpoint `shouldBe` Nothing
    void $ withDb pool (taskControl (GroupId 900) actor False identifier "cancel" Nothing Nothing "stop")
    withDb pool (beginBrowserOperation next.atrTurnId replaced.bwEpoch) `shouldReturn` False
    withDb pool (browserMaintenance registry)
    rows <- withDb pool (browserWorkspace identifier)
    rows `shouldSatisfy` (\values -> all (\(_, _, state, runtime) -> state == "revoked" && isNothing runtime) values)

  it "clear-all revokes even tasks that have not opened a browser yet" $ do
    source <- seed pool 900 1
    _ <- admit pool source "not-open"
    turn <- claimOne pool
    withDb pool (revokeConversationBrowsers (GroupId 900))
    withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime") >>= (`shouldSatisfy` isLeft)

  it "orders clear-all against first browser admission without a lock inversion" $ do
    source <- seed pool 900 1
    _ <- admit pool source "clear-race"
    turn <- claimOne pool
    _ <- concurrently (withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime")) (withDb pool (revokeConversationBrowsers (GroupId 900)))
    withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime") >>= (`shouldSatisfy` isLeft)

  it "keeps waiting workspaces only until their idle TTL and wipes checkpoints at deadline" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "idle"
    turn <- claimOne pool
    Right workspace <- withDb pool (acquireBrowserWorkspace turn.atrTurnId "runtime")
    void $ withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch)
    void $ withDb pool (finishBrowserOperation turn.atrTurnId workspace.bwEpoch (Just "encrypted") True)
    void $ withDb pool (taskReport turn.atrTurnId (report "waiting"))
    withDb pool (finishAgentTurn turn TurnSucceeded 1 Nothing Nothing)
    withDb pool (browserGcCandidates 1800 300) `shouldReturn` []
    void $ withDb pool $ execute "UPDATE browser_workspaces SET last_used_at=now()-interval '31 minutes' WHERE task_id=?" (Only identifier)
    registry <- newHttpRuntime >>= newBrowserRegistry
    withDb pool (browserMaintenance registry)
    saved <- withDb pool $ query "SELECT state,checkpoint,runtime_id FROM browser_workspaces" ()
    saved `shouldBe` [("cold" :: Text, Just ("encrypted" :: Text), Nothing :: Maybe Text)]
    void $ withDb pool $ execute "UPDATE durable_tasks SET deadline=now()-interval '1 second' WHERE task_id=?" (Only identifier)
    withDb pool (browserMaintenance registry)
    erased <- withDb pool $ query "SELECT checkpoint FROM browser_workspaces" ()
    erased `shouldBe` [Only (Nothing :: Maybe Text)]

  it "turn finalization releases control without destroying the task workspace" $ do
    source <- seed pool 900 1
    identifier <- admit pool source "release"
    turn <- claimOne pool
    registry <- newHttpRuntime >>= newBrowserRegistry
    Right workspace <- withDb pool (acquireBrowserWorkspace turn.atrTurnId (browserRuntimeId registry))
    withDb pool (releaseBrowserTurn registry (GroupId 900) turn.atrTurnId)
    rows <- withDb pool $ query "SELECT generation,owner_turn_id,state FROM browser_workspaces WHERE task_id=?" (Only identifier)
    rows `shouldBe` [(workspace.bwGeneration, Nothing :: Maybe Int64, "cold" :: Text)]

  it "isolates profiles by owner and conversation, and fences every bound workspace on revocation" $ do
    source@(_, _, actor) <- seed pool 900 1
    (_, _, other) <- seed pool 900 2
    identifier <- admit pool source "profile-source"
    turn <- claimOne pool
    registry <- newHttpRuntime >>= newBrowserRegistry
    Right workspace <- withDb pool (acquireBrowserWorkspace turn.atrTurnId (browserRuntimeId registry))
    encrypted <- sealBrowserState (browserVault registry) (workspaceIdentity identifier) emptyStorage
    void $ withDb pool (beginBrowserOperation turn.atrTurnId workspace.bwEpoch)
    void $ withDb pool (finishBrowserOperation turn.atrTurnId workspace.bwEpoch (Just encrypted) True)
    let command principal group args = withDb pool (browserCommand registry (GroupId group) principal args)
    command other 900 ["save", "task#1", "account", "https://example.com"] >>= (`shouldSatisfy` isLeft)
    command actor 901 ["save", "task#1", "account", "https://example.com"] >>= (`shouldSatisfy` isLeft)
    command actor 900 ["save", "task#1", "account", "https://example.com"] >>= (`shouldSatisfy` not . isLeft)
    command other 900 ["profiles"] `shouldReturn` Right (toJSON ([] :: [Value]))
    command actor 900 ["use", "task#1", "account"] >>= (`shouldSatisfy` not . isLeft)
    Right bound <- withDb pool (acquireBrowserWorkspace turn.atrTurnId (browserRuntimeId registry))
    bound.bwProfile `shouldBe` Just 1
    command actor 900 ["delete", "account"] >>= (`shouldSatisfy` not . isLeft)
    withDb pool (beginBrowserOperation turn.atrTurnId bound.bwEpoch) `shouldReturn` False
    withDb pool (acquireBrowserWorkspace turn.atrTurnId (browserRuntimeId registry)) >>= (`shouldSatisfy` isLeft)

  it "freezes monitor profile authorization in each occurrence, without sharing its workspace" $ do
    (turn, _, actor@(PrincipalId principal)) <- seed pool 900 1
    now <- getCurrentTime
    Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor turn "watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
    void $ withDb pool $ execute "INSERT INTO browser_profiles(conversation_id,principal_id,name,origin,checkpoint) SELECT conversation_id,?,'account','https://example.com','encrypted' FROM monitors WHERE monitor_id=?" (principal, monitor.mrMonitorId)
    void $ withDb pool $ execute "INSERT INTO browser_monitor_profiles(monitor_id,profile_id,profile_version) VALUES(?,1,1)" (Only monitor.mrMonitorId)
    insertOccurrence pool monitor "first"
    void $ withDb pool $ execute "UPDATE browser_profiles SET version=2 WHERE profile_id=1" ()
    void $ withDb pool $ execute "UPDATE browser_monitor_profiles SET profile_version=2" ()
    insertOccurrence pool monitor "second"
    rows <- withDb pool $ query "SELECT (definition_snapshot->>'browser_profile_version')::bigint FROM monitor_fires ORDER BY fire_id" ()
    rows `shouldBe` [Only (1 :: Int64), Only 2]

emptyStorage :: Value
emptyStorage = object ["storage" .= object ["cookies" .= ([] :: [Value]), "origins" .= ([] :: [Value])]]

browserFixture :: IORef [(Text, Value)] -> IORef Text -> IORef Int -> Application
browserFixture calls failure serial request respond = do
  body <- strictRequestBody request
  let value = fromRight Null (eitherDecode body)
      method = parseMaybe (withObject "request" (.: "method")) value :: Maybe Text
      requestId = parseMaybe (withObject "request" (.: "id")) value :: Maybe Int
      rpc headers payload = respond (responseLBS status200 (("Content-Type", "application/json") : headers) (encode (object ["jsonrpc" .= ("2.0" :: Text), "id" .= requestId, "result" .= payload])))
      success payload = object ["structuredContent" .= payload, "content" .= [object ["type" .= ("text" :: Text), "text" .= ("page snapshot" :: Text)]]]
  case method of
    Just "initialize" -> do
      identifier <- atomicModifyIORef' serial (\current -> (current + 1, current + 1))
      rpc [("Mcp-Session-Id", BS8.pack (show identifier))] (object [])
    Just "tools/call" -> do
      let parsed = parseMaybe (withObject "request" $ \fields -> fields .: "params" >>= withObject "params" (\parameters -> (,) <$> parameters .: "name" <*> parameters .: "arguments")) value
      case parsed of
        Just (name, arguments) -> do
          modifyIORef' calls ((name, arguments) :)
          failing <- readIORef failure
          if name == failing
            then rpc [] (object ["isError" .= True, "content" .= [object ["type" .= ("text" :: Text), "text" .= ("fixture failure" :: Text)]]])
            else do
              identifier <- readIORef serial
              let payload = case name of
                    "browse_session_start" -> object ["sessionId" .= ("session-" <> T.pack (show identifier))]
                    "max_workspace_checkpoint" -> object ["storage" .= object ["cookies" .= [object ["name" .= ("fixture" :: Text), "value" .= ("fixture-auth-cookie" :: Text), "domain" .= ("example.com" :: Text)]], "origins" .= ([] :: [Value])]]
                    _ -> object ["ok" .= True]
              rpc [] (success payload)
        _ -> rpc [] (object [])
    _ | requestMethod request == "DELETE" -> respond (responseLBS status200 [] "")
    _ -> respond (responseLBS status202 [] "")
