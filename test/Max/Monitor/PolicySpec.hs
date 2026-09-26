module Max.Monitor.PolicySpec (spec) where

import Data.Aeson (Result (..), fromJSON, object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Monitor.Policy
import Max.Task.Types (TaskProfile (Basic))
import Test.Hspec

spec :: Spec
spec = describe "monitor occurrence policy" $ do
  it "round-trips a complete frozen definition and rejects incomplete authority" $ do
    let snapshot = DefinitionSnapshot "original" (Map.singleton "sandbox_exec" "frozen") "owner" Basic True Coalesce 40 Nothing Nothing
    fromJSON (toJSON snapshot) `shouldBe` Success snapshot
    (fromJSON (object ["goal" .= ("incomplete" :: Text)]) :: Result DefinitionSnapshot) `shouldSatisfy` \case Error _ -> True; _ -> False
