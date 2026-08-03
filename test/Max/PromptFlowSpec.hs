{-# LANGUAGE TemplateHaskell #-}

module Max.PromptFlowSpec (spec) where

import Data.FileEmbed (embedFile)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Max.PromptFlow (renderPromptFlow)
import Test.Hspec

spec :: Spec
spec = describe "generated prompt-flow documentation" $ do
  it "matches the Prompt → Agent → LLM production path" $
    renderPromptFlow `shouldBe` decodeUtf8 $(embedFile "docs/prompt-flow.md")

  it "shows tiered episode rendering and one-turn source expansion" $ do
    renderPromptFlow `shouldSatisfy` T.isInfixOf "[episode#bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    renderPromptFlow `shouldSatisfy` T.isInfixOf "[episode#cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    renderPromptFlow `shouldSatisfy` T.isInfixOf "[episode#dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    renderPromptFlow `shouldNotSatisfy` T.isInfixOf "[episode#aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    renderPromptFlow `shouldSatisfy` T.isInfixOf "\"source_hash_matches\": true"
    renderPromptFlow `shouldSatisfy` T.isInfixOf "连续唤醒 200 次都没再复位"
