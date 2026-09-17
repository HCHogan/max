-- | A validated workflow contract. Construction parses the closed contract
-- dialect once; execution never reinterprets unvalidated JSON as a schema.
module Max.Skill.Contract (Contract, parseContract, contractValue, validateValue) where

import Data.Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Max.Schema
  ( Schema,
    SchemaDialect (WorkflowContract),
    parseSchema,
    schemaValue,
    validateSchemaValue,
  )

newtype Contract = Contract Schema deriving stock (Eq, Show)

parseContract :: Value -> Either Text Contract
parseContract = fmap Contract . parseSchema WorkflowContract

contractValue :: Contract -> Value
contractValue (Contract schema) = schemaValue schema

instance ToJSON Contract where
  toJSON = contractValue

instance FromJSON Contract where
  parseJSON value = either (fail . T.unpack) pure (parseContract value)

validateValue :: Contract -> Value -> Either Text ()
validateValue (Contract schema) = validateSchemaValue schema
