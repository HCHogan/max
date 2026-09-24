module Max.Tool.ReturnsSpec (spec) where

import Data.Maybe (isNothing)
import Data.Text qualified as T
import Max.Tool.Returns (toolReturnType, withReturnType)
import Max.Toolset (inventoryToolNames)
import Test.Hspec

spec :: Spec
spec = describe "tool return types" $ do
  it "declares a result shape for every inventory tool and run_code" $
    [name | name <- "run_code" : inventoryToolNames, isNothing (toolReturnType name)] `shouldBe` []

  it "appends the shape after the description and leaves unknown tools unchanged" $ do
    withReturnType "poke" "戳一戳" `shouldBe` "戳一戳\n返回：{ok: true}"
    withReturnType "not_a_tool" "说明" `shouldBe` "说明"
    T.isInfixOf "next: {cursor: string} | null" (withReturnType "context_read" "") `shouldBe` True
