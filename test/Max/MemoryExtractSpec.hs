module Max.MemoryExtractSpec (spec) where

import Max.MemoryExtract (ExtractOp (..), parseOps)
import Test.Hspec

spec :: Spec
spec = describe "parseOps" $ do
  it "parses a plain JSON array" $
    parseOps "[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"喜欢 Haskell\"}]"
      `shouldBe` Right [OpAdd "user" (Just 123) "喜欢 Haskell"]

  it "parses update and delete" $
    parseOps "[{\"action\":\"update\",\"id\":5,\"content\":\"新内容\"},{\"action\":\"delete\",\"id\":7}]"
      `shouldBe` Right [OpUpdate 5 "新内容", OpDelete 7]

  it "accepts an empty array" $
    parseOps "[]" `shouldBe` Right []

  it "strips markdown code fences" $
    parseOps "```json\n[{\"action\":\"delete\",\"id\":3}]\n```"
      `shouldBe` Right [OpDelete 3]

  it "tolerates prose around the array" $
    parseOps "好的，以下是操作：\n[{\"action\":\"delete\",\"id\":3}] 完毕"
      `shouldBe` Right [OpDelete 3]

  it "add without user_id defaults later (parses as Nothing)" $
    parseOps "[{\"action\":\"add\",\"scope\":\"group\",\"content\":\"c\"}]"
      `shouldBe` Right [OpAdd "group" Nothing "c"]

  it "rejects unknown actions" $
    parseOps "[{\"action\":\"merge\",\"id\":1}]" `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
