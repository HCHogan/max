module Max.Monitor.PolicySpec (spec) where

import Data.Aeson (Result (..), fromJSON, object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Monitor.Policy
import Max.Task.Types (TaskProfile (Basic))
import Test.Hspec

spec :: Spec
spec = describe "monitor occurrence policy" $ do
  it "coalesces an outstanding occurrence and enforces the exact queue boundary" $ do
    map (decideOverlap Coalesce 40) [0, 1, 40] `shouldBe` [PendingOccurrence, CoalescedOccurrence, CoalescedOccurrence]
    map (decideOverlap QueueOccurrences 2) [0, 1, 2, 3] `shouldBe` [PendingOccurrence, PendingOccurrence, OverflowOccurrence, OverflowOccurrence]
  it "round-trips a complete frozen definition and rejects incomplete authority" $ do
    let snapshot = DefinitionSnapshot "original" (Map.singleton "sandbox_exec" "frozen") "owner" Basic True Coalesce 40 Nothing Nothing
    fromJSON (toJSON snapshot) `shouldBe` Success snapshot
    (fromJSON (object ["goal" .= ("incomplete" :: Text)]) :: Result DefinitionSnapshot) `shouldSatisfy` \case Error _ -> True; _ -> False
