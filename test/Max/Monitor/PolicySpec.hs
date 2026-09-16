module Max.Monitor.PolicySpec (spec) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Monitor.Policy
import Max.Task.Types (TaskProfile (Research, Sandbox))
import Test.Hspec

spec :: Spec
spec = describe "monitor occurrence policy" $ do
  it "coalesces an outstanding occurrence and enforces the exact queue boundary" $ do
    map (decideOverlap Coalesce 40) [0, 1, 40] `shouldBe` [PendingOccurrence, CoalescedOccurrence, CoalescedOccurrence]
    map (decideOverlap QueueOccurrences 2) [0, 1, 2, 3] `shouldBe` [PendingOccurrence, PendingOccurrence, OverflowOccurrence, OverflowOccurrence]
  it "preserves frozen authority when filling absent legacy snapshot fields" $ do
    let stored = object ["goal" .= ("original" :: Text), "grants" .= object ["tool_grants" .= Map.singleton ("web_search" :: Text) ("old-grant" :: Text)]]
    (.grants) <$> restoreSnapshot fallback stored `shouldBe` Just (Map.singleton "web_search" "old-grant")
    (.goal) <$> restoreSnapshot fallback stored `shouldBe` Just "original"
  it "fails closed on malformed present snapshot fields" $ do
    restoreSnapshot fallback (object ["grants" .= (1 :: Int)]) `shouldBe` Nothing
    restoreSnapshot fallback (object ["profile" .= ("not-a-profile" :: Text)]) `shouldBe` Nothing
  it "reads legacy operations snapshots as sandbox without changing frozen grants" $ do
    let stored = object ["profile" .= ("operations" :: Text), "grants" .= object ["tool_grants" .= Map.singleton ("sandbox_exec" :: Text) ("frozen-shell" :: Text)]]
    Just restored <- pure (restoreSnapshot fallback stored)
    restored.profile `shouldBe` Sandbox
    restored.grants `shouldBe` Map.singleton "sandbox_exec" "frozen-shell"

fallback :: DefinitionSnapshot
fallback = DefinitionSnapshot "new definition" (Map.singleton "browser" "new-grant") "owner" Research True Coalesce 40 Nothing Nothing
