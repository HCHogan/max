-- | Capacity policy scales with the selected profile's effective input budget.
-- These are injection/work sizes, never retention or deletion policies.
module Max.Context.Capacity (rawHighTokens, rawLowTokens, summaryTokens, readPageTokens, historianSourceTokens) where

import Max.ModelCatalog (ContextLimits, contextInputBudget)

rawHighTokens, rawLowTokens, summaryTokens, readPageTokens :: ContextLimits -> Bool -> Int
rawHighTokens limits media = contextInputBudget limits media `div` 2
rawLowTokens limits media = contextInputBudget limits media `div` 4
summaryTokens limits media = contextInputBudget limits media `div` 8
-- The byte ceiling is a transport guard, not a model-window default.
readPageTokens limits media = max 1 (min 16384 (contextInputBudget limits media `div` 32))

historianSourceTokens :: Int -> Int
historianSourceTokens inputBudget = max 1 (inputBudget * 2 `div` 3)
