module Max.DB.BrowserSpec (Max.DB.BrowserSpec.spec) where

import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Char8 qualified as BS8
import Data.Either (fromRight, isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import JobFixture
import Max.Browser.Profile (browserCommand, browserCommandOnce)
import Max.Browser.Registry
import Max.Browser.Runtime (browserMaintenance, releaseBrowserTurn)
import Max.Browser.ToolRuntime (browserToolsFor)
import Max.DB.Connection (DbPool)
import Max.DB.Monitor (ElaboratedMonitorFire (..), armLedgerMatchMonitor, pendingElaboratedMonitorFires)
import Max.DB.Monitor.Admission
import Max.DB.Monitor.Control qualified as MonitorControl
import Max.DB.Transaction (withTransaction)
import Max.Effects.ToolOutput (newToolOutputQueue, runToolOutput)
import Max.Effects.Tools (Tool (..), toolRun)
import Max.HttpRuntime (newHttpRuntime)
import Max.Jobs qualified as Jobs
import Max.Monitor.Control (PendingPolicy (RetainPending))
import Max.Monitor.Policy (OverlapPolicy (QueueOccurrences))
import Max.Monitor.Types
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Task.State (TaskStatus (Succeeded))
import Max.Task.Types
import Max.ToolContext
import Max.Turn.Types
import Network.HTTP.Types (status200, status202, status404)
import Network.Wai (Application, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec hiding (context)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "process-owned browser workspaces" $ do
  it "deduplicates explicit profile commands without replaying interrupted commands" $ do
    running <- runningJob pool Browser Map.empty
    registry <- newHttpRuntime >>= newBrowserRegistry
    let invoke = withDb pool (browserCommandOnce running.jobs registry (GroupId 900) running.job.spec.principal running.job.spec.source ["profiles"])
    first <- invoke
    invoke `shouldReturn` first
    withDb pool (query "SELECT count(*) FROM browser_command_events" ()) `shouldReturn` [Only (1 :: Int64)]
    void $ withDb pool $ execute "UPDATE browser_command_receipts SET result=NULL" ()
    interrupted <- invoke
    show interrupted `shouldContain` "not replayed"

  it "freezes explicit browser profile bindings for reminder occurrences" $
    withBrowser $ \registry _ _ -> do
      running <- runningJob pool Browser Map.empty
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      command pool running registry ["save", taskHandle running.job.run.jobId, "login", "https://example.com"] >>= (`shouldSatisfy` not . isLeft)
      now <- getCurrentTime
      let actor = running.job.spec.principal
      Right monitor <- withDb pool (armLedgerMatchMonitor (GroupId 900) actor running.turn "browser watch" (LedgerMatchSpec Nothing (Just "match") Nothing False) 0 (addUTCTime 86400 now) 100 Map.empty)
      Right _ <- withDb pool (withTransaction (MonitorControl.controlMonitor 900 actor.unPrincipalId False monitor.mrMonitorOrdinal.unMonitorOrdinal (MonitorControl.ConfigureMonitor 1 "browser watch" QueueOccurrences 10 RetainPending (Just (Browser, True))) False))
      let handle = monitorHandleText monitor.mrMonitorOrdinal
          admit = do
            [fire] <- withDb pool (pendingElaboratedMonitorFires now 10)
            Right (MonitorTaskAdmitted _ job) <- withDb pool (withTransaction (admitMonitorTaskWithin fire.emfFireId Nothing Map.empty running.job.spec.source.unCanonicalMessageId))
            pure job
      command pool running registry ["monitor", handle, "login"] >>= (`shouldSatisfy` not . isLeft)
      insertOccurrence pool monitor "bound"
      command pool running registry ["unmonitor", handle] >>= (`shouldSatisfy` not . isLeft)
      [binding] <- withDb pool (query "SELECT profile_id,version FROM browser_profiles" ())
      old <- admit
      old.browserProfile `shouldBe` Just binding
      insertOccurrence pool monitor "unbound"
      new <- admit
      new.browserProfile `shouldBe` Nothing

  it "keeps a live workspace, saves only on explicit request, and restores only an authorized profile" $
    withBrowser $ \registry calls _ -> do
      running <- runningJob pool Browser Map.empty
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      runBrowser pool running registry "snapshot" >>= (`shouldSatisfy` not . isLeft)
      observed <- readIORef calls
      count "browse_session_start" observed `shouldBe` 1
      count "max_workspace_checkpoint" observed `shouldBe` 0
      saved <- command pool running registry ["save", taskHandle running.job.run.jobId, "login", "https://example.com"]
      saved `shouldSatisfy` not . isLeft
      raw <- withDb pool (query "SELECT checkpoint FROM browser_profiles" ())
      show (raw :: [Only Text]) `shouldNotContain` "fixture-auth-cookie"
      restored <- command pool running registry ["use", taskHandle running.job.run.jobId, "login"]
      restored `shouldSatisfy` not . isLeft
      result <- runBrowser pool running registry "open"
      result `shouldSatisfy` not . isLeft
      show result `shouldNotContain` "fixture-auth-cookie"
      callsAfter <- readIORef calls
      count "max_workspace_checkpoint" callsAfter `shouldBe` 1
      show [args | (name, args) <- callsAfter, name == "browse_session_start"] `shouldContain` "fixture-auth-cookie"
      withDb pool (query "SELECT count(*) FROM browser_workspaces" ()) `shouldReturn` [Only (0 :: Int64)]

  it "never replays an uncertain action and requires confirmed closure before reset" $
    withBrowser $ \registry calls failure -> do
      running <- runningJob pool Browser Map.empty
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      writeIORef failure "transport:browse_session_action"
      runBrowser pool running registry "click" >>= (`shouldSatisfy` isLeft)
      afterFailure <- readIORef calls
      runBrowser pool running registry "click" >>= (`shouldSatisfy` isLeft)
      runBrowser pool running registry "open" >>= (`shouldSatisfy` isLeft)
      readIORef calls `shouldReturn` afterFailure
      writeIORef failure "max_workspace_revoke"
      command pool running registry ["reset", taskHandle running.job.run.jobId] >>= (`shouldSatisfy` isLeft)
      writeIORef failure ""
      command pool running registry ["reset", taskHandle running.job.run.jobId] >>= (`shouldSatisfy` not . isLeft)
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      count "browse_session_action" <$> readIORef calls `shouldReturn` 1

  it "binds profile access to owner and conversation, and checks revocation before further actions" $
    withBrowser $ \registry calls _ -> do
      running <- runningJob pool Browser Map.empty
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      command pool running registry ["save", taskHandle running.job.run.jobId, "login", "https://example.com"] >>= (`shouldSatisfy` not . isLeft)
      let use group actor = withDb pool (browserCommand running.jobs registry group actor ["use", taskHandle running.job.run.jobId, "login"])
      use (GroupId 901) running.job.spec.principal >>= (`shouldSatisfy` isLeft)
      use (GroupId 900) (PrincipalId 999999) >>= (`shouldSatisfy` isLeft)
      use (GroupId 900) running.job.spec.principal >>= (`shouldSatisfy` not . isLeft)
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      command pool running registry ["delete", "login"] >>= (`shouldSatisfy` not . isLeft)
      observed <- readIORef calls
      runBrowser pool running registry "open" >>= (`shouldSatisfy` isLeft)
      readIORef calls `shouldReturn` observed

  it "revokes unopened jobs on clear and permits only an explicit owner reset" $
    withBrowser $ \registry calls _ -> do
      running <- runningJob pool Browser Map.empty
      Jobs.setJobBrowserAccess running.jobs running.job.run False
      runBrowser pool running registry "open" >>= (`shouldSatisfy` isLeft)
      readIORef calls `shouldReturn` []
      command pool running registry ["reset", taskHandle running.job.run.jobId] >>= (`shouldSatisfy` not . isLeft)
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)

  it "retains a finished session for explicit save, then releases it after the grace period" $
    withBrowser $ \registry _ _ -> do
      running <- runningJob pool Browser Map.empty
      runBrowser pool running registry "open" >>= (`shouldSatisfy` not . isLeft)
      Jobs.completeJob running.jobs running.job.run Succeeded (JobResult "finished" Nothing)
      withDb pool (releaseBrowserTurn running.jobs registry (GroupId 900) running.turn.atrTurnId)
      command pool running registry ["save", taskHandle running.job.run.jobId, "login", "https://example.com"] >>= (`shouldSatisfy` not . isLeft)
      withDb pool (browserMaintenance (configureBrowserRegistry (browserVault registry) 1800 0 registry))
      jobBrowser registry running.job.run.jobId `shouldReturn` Nothing

withBrowser :: (BrowserRegistry -> IORef [(Text, Value)] -> IORef Text -> IO ()) -> IO ()
withBrowser action = do
  calls <- newIORef []
  failure <- newIORef ""
  serial <- newIORef 0
  testWithApplication (pure (browserFixture calls failure serial)) $ \port -> do
    http <- newHttpRuntime
    registry <- newBrowserRegistryWithHost http (GroupId 900) ("http://127.0.0.1:" <> show port <> "/mcp") "localhost"
    action registry calls failure

runBrowser :: DbPool -> RunningJob -> BrowserRegistry -> Text -> IO (Either Text Value)
runBrowser pool running registry action = do
  output <- newTurnOutputContext running.turn
  let context = mkToolContext (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 99) running.job.spec.principal Nothing (Just output)) (TurnCapabilities True False False noAdvertisedCaps False Map.empty Nothing True)
      arguments = object ["action" .= action, "url" .= ("https://example.com" :: Text), "selector" .= ("#button" :: Text)]
  withDb pool $ case [tool | tool <- browserToolsFor running.jobs context registry Nothing, tool.toolName == "browser"] of
    [tool] -> do
      queue <- newToolOutputQueue 0
      runToolOutput queue (toolRun tool arguments)
    _ -> error "browser tool missing"

command :: DbPool -> RunningJob -> BrowserRegistry -> [Text] -> IO (Either Text Value)
command pool running registry pieces = withDb pool (browserCommand running.jobs registry (GroupId 900) running.job.spec.principal pieces)

count :: Text -> [(Text, Value)] -> Int
count name = length . filter ((== name) . fst)

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
          if failing == "transport:" <> name
            then do
              writeIORef failure ""
              respond (responseLBS status404 [] "session lost")
            else
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
