module Max.SchemaSpec (spec) where

import Data.Aeson (object, toJSON, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Max.Schema
import Max.Tool.Arguments qualified as Args
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (counterexample, property)

spec :: Spec
spec = describe "parsed schemas and argument codecs" $ do
  it "rejects invalid array elements and size before a runner can execute" $ do
    let raw = object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)], "maxItems" .= (1 :: Int)]
    Right schema <- pure (parseSchema ToolSchema raw)
    validateSchemaValue schema (toJSON ([1, 2] :: [Int])) `shouldSatisfy` isLeft
    validateSchemaValue schema (toJSON (["a", "b"] :: [Text])) `shouldSatisfy` isLeft
    validateSchemaValue schema (toJSON (["a"] :: [Text])) `shouldBe` Right ()
    schemaValue schema `shouldBe` raw
  it "checks nested anyOf alternatives and implicit constraints" $ do
    let choice = object ["anyOf" .= [object ["type" .= ("string" :: Text)], object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]]]]
    Right schema <- pure (parseSchema ToolSchema choice)
    validateSchemaValue schema (toJSON ([1] :: [Int])) `shouldSatisfy` isLeft
    validateSchemaValue schema (toJSON (["a"] :: [Text])) `shouldBe` Right ()
    Right implicit <- pure (parseSchema ToolSchema (object ["maxLength" .= (2 :: Int)]))
    validateSchemaValue implicit (toJSON ("long" :: Text)) `shouldSatisfy` isLeft
    validateSchemaValue implicit (toJSON (3 :: Int)) `shouldBe` Right ()
  it "rejects malformed bounds and preserves the stricter workflow dialect" $ do
    parseSchema ToolSchema (object ["type" .= ("array" :: Text), "minItems" .= (4 :: Int), "maxItems" .= (1 :: Int)]) `shouldSatisfy` isLeft
    parseSchema WorkflowContract (object ["type" .= ("object" :: Text)]) `shouldSatisfy` isLeft
    parseSchema WorkflowContract (object ["type" .= ("string" :: Text), "pattern" .= (".*" :: Text)]) `shouldSatisfy` isLeft
  prop "decodes every generated typed argument object advertised by its schema" $ \(label :: String) (count :: Int) ->
    let args = object ["label" .= label, "count" .= count]
        codec = (,) <$> Args.required "label" (Args.text "label") <*> Args.required "count" (Args.int "count")
        checked = do
          schema <- parseSchema ToolSchema (Args.argumentsSchema codec)
          validateSchemaValue schema args
          (_, parsed) <- Args.parseArguments codec args
          pure (parsed == count)
     in either (\detail -> counterexample (show detail) False) property checked
  it "generates requiredness and defaults from the codec" $ do
    let codec = (,) <$> Args.required "label" (Args.text "label") <*> Args.defaulted "count" (7 :: Int) (Args.int "count")
    Args.parseArguments codec (object ["label" .= ("x" :: Text)]) `shouldBe` Right ("x", 7)
    Args.parseArguments codec (object []) `shouldSatisfy` isLeft
    Right schema <- pure (parseSchema ToolSchema (Args.argumentsSchema codec))
    validateSchemaValue schema (object ["count" .= (7 :: Int)]) `shouldSatisfy` isLeft
