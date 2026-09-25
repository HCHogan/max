module Max.DB.UsageSpec (Max.DB.UsageSpec.spec) where

import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.Usage (UsageDay (..), insertUsage, usageDaily)
import Max.LLM.Types (CallCost (..), TokenUsage (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "llm usage" $
  it "sums estimated cost per currency beside unpriced calls" $ do
    rows <- withDb pool $ do
      insertUsage (Just 1) "turn" "deepseek" (TokenUsage 1000 10 (Just 800) (Just (CallCost "CNY" 0.25)))
      insertUsage (Just 1) "turn" "deepseek" (TokenUsage 2000 20 Nothing (Just (CallCost "CNY" 0.5)))
      insertUsage (Just 1) "turn" "deepseek" (TokenUsage 300 3 Nothing Nothing)
      usageDaily 480 1
    [(u.udCalls, u.udPrompt, u.udCachedPrompt, u.udCost, u.udCurrency) | u <- rows]
      `shouldBe` [(1, 300, 0, Nothing, Nothing), (2, 3000, 800, Just 0.75, Just "CNY")]
