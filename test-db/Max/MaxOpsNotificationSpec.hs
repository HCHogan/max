module Max.MaxOpsNotificationSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Simple (execute_, query_)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.IR.Lower (outboundCapsFromValue)
import Max.MaxOps.Notifications
import Max.Platform.Store (ensureLegacyEndpoint)
import Max.Platform.Types
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (statusCode)
import Network.Wai.Handler.Warp qualified as Warp
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "durable maxops notifications" $ do
  it "commits deduplication, canonical output and delivery together without an agent turn" $ do
    prepare pool
    withDb pool (enqueueAlerts [42] [fixture]) `shouldReturn` 1
    withDb pool (enqueueAlerts [42] [fixture]) `shouldReturn` 0
    counts pool `shouldReturn` (1, 1, 1, 0)
  it "deduplicates concurrent retries and permits four-hour reminders and resolution" $ do
    prepare pool
    (first, second) <- concurrently (withDb pool (enqueueAlerts [42] [fixture])) (withDb pool (enqueueAlerts [42] [fixture]))
    first + second `shouldBe` 1
    withConn pool $ \connection -> do
      _ <- execute_ connection "UPDATE maxops_notifications SET last_notified_at=now()-interval '4 hours 1 minute'"
      pure ()
    withDb pool (enqueueAlerts [42] [fixture]) `shouldReturn` 1
    withDb pool (enqueueAlerts [42] [fixture {alertStatus = "resolved", alertEndsAt = Just fixture.alertStartsAt}]) `shouldReturn` 1
    counts pool `shouldReturn` (2, 3, 3, 0)
  it "rolls back all targets and dedupe state if one destination is unavailable" $ do
    prepare pool
    outcome <- try (withDb pool (enqueueAlerts [42, 99] [fixture])) :: IO (Either SomeException Int)
    outcome `shouldSatisfy` either (const True) (const False)
    counts pool `shouldReturn` (0, 0, 0, 0)
    withDb pool (enqueueAlerts [42] [fixture]) `shouldReturn` 1
  it "authenticates a real webhook, bounds its body and pins its destination" $
    withSystemTempDirectory "maxops-notify-test" $ \directory -> do
      prepare pool
      let path = directory <> "/token"
          token = BS8.replicate 40 'a'
          config = NotificationConfig "127.0.0.1" 9722 path [42] ["alpha"]
          payload = object ["version" .= text "4", "status" .= text "firing", "groups" .= [99 :: Int], "alerts" .= [fixtureValue]]
      BS.writeFile path token
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      Warp.testWithApplication (notificationApplication config (withDb pool . enqueueAlerts [42])) $ \port -> do
        base <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/v1/alerts")
        let send requestHeaders body = do
              response <- HTTP.httpLbs (base {HTTP.method = "POST", HTTP.requestHeaders = requestHeaders, HTTP.requestBody = HTTP.RequestBodyLBS body, HTTP.proxy = Nothing}) manager
              pure (statusCode (HTTP.responseStatus response))
            headers = [("Authorization", "Bearer " <> token), ("Content-Type", "application/json")]
        send [] (encode payload) `shouldReturn` 401
        send (headers <> [("Authorization", "Bearer " <> token)]) (encode payload) `shouldReturn` 401
        send headers (encode (object ["oversized" .= replicate (256 * 1024) 'x'])) `shouldReturn` 413
        send headers (encode payload) `shouldReturn` 202
        send headers (encode payload) `shouldReturn` 202
        counts pool `shouldReturn` (1, 1, 1, 0)
        BS.writeFile path (BS8.replicate 40 'b')
        send headers (encode payload) `shouldReturn` 401

prepare :: DbPool -> IO ()
prepare pool = do
  _ <- withDb pool (ensureLegacyEndpoint PlatformQQ (NativeAccountId "9") (NativeConversationId "42") ConversationGroup 42 (outboundCapsFromValue (object [])))
  pure ()

counts :: DbPool -> IO (Int64, Int64, Int64, Int64)
counts pool = withConn pool $ \connection -> do
  [row] <- query_ connection "SELECT (SELECT count(*) FROM maxops_notifications), (SELECT count(*) FROM messages WHERE message_origin='outbound'), (SELECT count(*) FROM message_deliveries), (SELECT count(*) FROM agent_turns)"
  pure row

fixture :: Alert
fixture = Alert "firing" (Map.fromList [("instance", "alpha"), ("alertname", "HostDown"), ("severity", "critical")]) Map.empty (read "2026-09-06 00:00:00 UTC") Nothing

fixtureValue :: Value
fixtureValue = object ["status" .= fixture.alertStatus, "labels" .= fixture.alertLabels, "startsAt" .= fixture.alertStartsAt]

text :: Text -> Text
text = id
