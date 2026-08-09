module Max.Turn.TypesSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Data.List (sort)
import Max.Turn.Types
import Test.Hspec

spec :: Spec
spec = describe "Max.Turn.Types" $ do
  describe "parseTurnHandle" $ do
    it "accepts only the explicit conversation-scoped handle grammar" $ do
      parseTurnHandle "t#12" `shouldBe` Just (ParsedTurn (TurnOrdinal 12))
      parseTurnHandle "  t#12:r3  "
        `shouldBe` Just (ParsedTurnResult (TurnOrdinal 12) (ExecutionOrdinal 3))
      parseTurnHandle "12" `shouldBe` Nothing
      parseTurnHandle "t#0" `shouldBe` Nothing
      parseTurnHandle "t#1:r0" `shouldBe` Nothing
      parseTurnHandle "t#1:r2:extra" `shouldBe` Nothing

    it "renders handles that parse back to the same ordinals" $ do
      turnHandleText (TurnOrdinal 7) `shouldBe` "t#7"
      resultHandleText (TurnOrdinal 7) (ExecutionOrdinal 11) `shouldBe` "t#7:r11"
      parseTurnHandle (resultHandleText (TurnOrdinal 7) (ExecutionOrdinal 11))
        `shouldBe` Just (ParsedTurnResult (TurnOrdinal 7) (ExecutionOrdinal 11))

  describe "TurnOutputContext" $ do
    it "allocates one monotonic, collision-free chunk namespace across concurrent outputs" $ do
      let ref = AgentTurnRef (AgentTurnId 42) (TurnOrdinal 3)
      outputContext <- newTurnOutputContext ref
      links <- mapConcurrently (const (nextTurnOutputLink outputContext)) [1 .. 100 :: Int]
      sort links
        `shouldBe` [TurnOutputLink (AgentTurnId 42) chunk | chunk <- [0 .. 99]]
      turnOutputAgentTurn outputContext `shouldBe` ref

    it "continues after a host-derived recovery seed" $ do
      let ref = AgentTurnRef (AgentTurnId 42) (TurnOrdinal 3)
      outputContext <- newTurnOutputContextAt ref 7
      first <- nextTurnOutputLink outputContext
      second <- nextTurnOutputLink outputContext
      [first, second]
        `shouldBe` [TurnOutputLink (AgentTurnId 42) 7, TurnOutputLink (AgentTurnId 42) 8]
