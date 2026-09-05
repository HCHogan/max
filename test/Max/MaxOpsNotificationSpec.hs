module Max.MaxOpsNotificationSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.MaxOps.Notifications
import Test.Hspec

spec :: Spec
spec = describe "maxops notification parsing" $ do
  it "only accepts configured host alerts and ignores body-supplied destinations" $ do
    let payload = object ["version" .= text "4", "status" .= text "firing", "groups" .= [99 :: Int], "alerts" .= [alertValue "alpha", alertValue "private"]]
    fmap length (parseAlerts ["alpha"] payload) `shouldBe` Right 1
    parseAlerts [] payload `shouldBe` Right []
  it "rejects malformed, excessive and wrongly versioned notifications" $ do
    mapM_
      (\payload -> parseAlerts ["alpha"] payload `shouldSatisfy` isLeft)
      [ object ["version" .= text "3", "status" .= text "firing", "alerts" .= ([] :: [Value])],
        object ["version" .= text "4", "status" .= text "firing", "alerts" .= replicate 101 (alertValue "alpha")],
        object ["version" .= text "4", "status" .= text "firing", "alerts" .= [object ["status" .= text "invalid"]]]
      ]
  it "deduplicates changing annotations but keeps resolution and new episodes distinct" $ do
    alert <- case parseAlerts ["alpha"] (object ["version" .= text "4", "status" .= text "firing", "alerts" .= [alertValue "alpha"]]) of
      Right [parsed] -> pure parsed
      _ -> fail "fixture failed to parse"
    alertKey alert `shouldBe` alertKey (alert {alertAnnotations = Map.singleton "summary" "new details"})
    alertKey alert `shouldNotBe` alertKey (alert {alertStatus = "resolved", alertEndsAt = Just alert.alertStartsAt})
    alertKey alert `shouldNotBe` alertKey (alert {alertStartsAt = read "2026-09-07 00:00:00 UTC"})
    T.length (renderAlert (alert {alertAnnotations = Map.fromList [("summary", T.replicate 10000 "x"), ("description", T.replicate 10000 "y")]})) `shouldSatisfy` (< 1400)
  it "requires loopback, a runtime credential and explicit groups and hosts" $ do
    let config = NotificationConfig "127.0.0.1" 9722 "/run/credentials/token" [42] ["alpha"]
    validateNotificationConfig config `shouldBe` []
    mapM_
      (\bad -> validateNotificationConfig bad `shouldSatisfy` (not . null))
      [config {ncHost = "0.0.0.0"}, config {ncGroups = []}, config {ncHosts = []}, config {ncGroups = [-1]}, config {ncTokenFile = "/nix/store/token"}]

alertValue :: Text -> Value
alertValue host = object ["status" .= text "firing", "labels" .= object ["instance" .= host, "alertname" .= text "HostDown", "severity" .= text "critical"], "annotations" .= object ["summary" .= text "fixture"], "startsAt" .= text "2026-09-06T00:00:00Z"]

text :: Text -> Text
text = id
