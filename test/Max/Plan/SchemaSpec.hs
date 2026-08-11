module Max.Plan.SchemaSpec (spec) where

import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Data.Vector qualified as V
import Max.Plan.Schema
import Max.Tools.Schema (enumParam, stringArrayParam, stringParam, toolObject)
import Test.Hspec

person :: PlanSchema
person =
  SchemaObject
    [ SchemaField {sfName = "name", sfSchema = SchemaText, sfRequired = True},
      SchemaField {sfName = "age", sfSchema = SchemaInt, sfRequired = False}
    ]

expected :: Either SchemaError () -> Maybe Text
expected = either (Just . (.schExpected)) (const Nothing)

spec :: Spec
spec = do
  describe "checkValue" $ do
    it "accepts a value matching every declared field" $
      checkValue person (object ["name" .= ("hank" :: Text), "age" .= (34 :: Int)])
        `shouldBe` Right ()

    it "accepts an absent optional field" $
      checkValue person (object ["name" .= ("hank" :: Text)]) `shouldBe` Right ()

    it "accepts an explicit null for an optional field" $
      checkValue person (object ["name" .= ("hank" :: Text), "age" .= Null])
        `shouldBe` Right ()

    it "names the missing required field in the path" $ do
      let result = checkValue person (object ["age" .= (34 :: Int)])
      fmap (.schPath) (either Just (const Nothing) result) `shouldBe` Just [".name"]
      expected result `shouldBe` Just "text"

    it "rejects an unknown field rather than tolerating it" $ do
      let result = checkValue person (object ["name" .= ("hank" :: Text), "sudo" .= True])
      expected result `shouldBe` Just "only the declared fields"

    it "separates ints from other numbers" $ do
      checkValue SchemaInt (Number 3) `shouldBe` Right ()
      expected (checkValue SchemaInt (Number 3.5)) `shouldBe` Just "int"
      checkValue SchemaNumber (Number 3.5) `shouldBe` Right ()

    it "holds an enum to its closed vocabulary" $ do
      checkValue (SchemaEnum ["a", "b"]) (String "a") `shouldBe` Right ()
      expected (checkValue (SchemaEnum ["a", "b"]) (String "c"))
        -- Spelled the way a plan would have to spell it, so the rejection
        -- quotes something writable rather than a second notation.
        `shouldBe` Just "enum(\"a\", \"b\")"

    it "admits null only where the type says so" $ do
      checkValue (SchemaNullable SchemaText) Null `shouldBe` Right ()
      checkValue (SchemaNullable SchemaText) (String "x") `shouldBe` Right ()
      expected (checkValue SchemaText Null) `shouldBe` Just "text"

    it "reports the index of the element that failed" $ do
      let result = checkValue (SchemaArray SchemaText) (Array (V.fromList [String "a", Number 1]))
      fmap (.schPath) (either Just (const Nothing) result) `shouldBe` Just ["[1]"]

  describe "projection typing" $ do
    it "projects a required field to its bare type" $
      projectField "name" person `shouldBe` Right SchemaText

    it "projects an optional field to a nullable type" $
      projectField "age" person `shouldBe` Right (SchemaNullable SchemaInt)

    it "refuses a field that was never declared" $
      expected (void (projectField "sudo" person)) `shouldBe` Just "a declared field"

    it "refuses to project through a non-object" $
      expected (void (projectField "name" SchemaText)) `shouldBe` Just "object"

    it "types an index as nullable, since no schema carries a length" $
      projectIndex (SchemaArray SchemaText) `shouldBe` Right (SchemaNullable SchemaText)

    it "propagates null through a projection instead of dead-ending" $ do
      -- hits[0].name : text?  — the shape every plan reaching into a result
      -- list needs, and the reason projection is null-propagating.
      (projectIndex (SchemaArray person) >>= projectField "name")
        `shouldBe` Right (SchemaNullable SchemaText)

    it "still reports the underlying mismatch through a nullable source" $
      expected (void (projectField "name" (SchemaNullable SchemaText))) `shouldBe` Just "object"

    it "does not stack nullability" $
      nullable (nullable SchemaText) `shouldBe` SchemaNullable SchemaText

  describe "schemaFromJson" $ do
    it "reads a hand-written tool schema" $
      schemaFromJson (toolObject [("query", stringParam "what to search")] ["query"])
        `shouldBe` Right
          (SchemaObject [SchemaField {sfName = "query", sfSchema = SchemaText, sfRequired = True}])

    it "reads enums and arrays" $ do
      schemaFromJson (enumParam ["asc", "desc"] "order") `shouldBe` Right (SchemaEnum ["asc", "desc"])
      schemaFromJson (stringArrayParam "tags") `shouldBe` Right (SchemaArray SchemaText)

    it "carries the required set onto the right fields" $ do
      let declared =
            toolObject
              [("query", stringParam "q"), ("limit", stringParam "n")]
              ["query"]
      schemaFromJson declared
        `shouldBe` Right
          ( SchemaObject
              [ SchemaField {sfName = "limit", sfSchema = SchemaText, sfRequired = False},
                SchemaField {sfName = "query", sfSchema = SchemaText, sfRequired = True}
              ]
          )

    it "refuses a composition keyword instead of ignoring it" $
      schemaFromJson (object ["type" .= ("string" :: Text), "oneOf" .= ([] :: [Value])])
        `shouldBe` Left "unsupported schema keyword \"oneOf\""

    it "refuses a schema with no type at all" $
      schemaFromJson (object ["description" .= ("free-form" :: Text)])
        `shouldBe` Left "schema without a \"type\""

    it "refuses an array without an element schema" $
      schemaFromJson (object ["type" .= ("array" :: Text)])
        `shouldBe` Left "array schema without \"items\""
