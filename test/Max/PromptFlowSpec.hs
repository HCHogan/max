{-# LANGUAGE TemplateHaskell #-}

module Max.PromptFlowSpec (spec) where

import Data.FileEmbed (embedFile)
import Data.Text.Encoding (decodeUtf8)
import Max.PromptFlow (renderPromptFlow)
import Test.Hspec

spec :: Spec
spec =
  describe "generated prompt-flow documentation" $
    it "matches the Prompt → Agent → LLM production path" $
      renderPromptFlow `shouldBe` decodeUtf8 $(embedFile "docs/prompt-flow.md")
