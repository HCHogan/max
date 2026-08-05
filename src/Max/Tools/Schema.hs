-- | The JSON-Schema vocabulary every tool declaration speaks.
--
-- Tool schemas are the model's contract, so they are written by hand — but
-- they were written by hand /fifteen times/, and every one of them respelled
-- @object [\"type\" .= (\"string\" :: Text), \"description\" .= …]@ from
-- scratch.  These combinators say the same thing in one line and make an
-- inconsistent spelling impossible.
module Max.Tools.Schema
  ( toolObject,
    noArguments,
    stringParam,
    integerParam,
    boundedIntegerParam,
    numberParam,
    boolParam,
    enumParam,
    stringArrayParam,
    paramOfType,
    withKeys,
  )
where

import Data.Aeson (Value (Object), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.Text (Text)

-- | One tool's argument object: named parameters plus the required subset.
toolObject :: [(Key, Value)] -> [Text] -> Value
toolObject properties required =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object [name .= schema | (name, schema) <- properties],
      "required" .= required
    ]

-- | A tool the model calls with no arguments at all.
noArguments :: Value
noArguments = object ["type" .= ("object" :: Text), "properties" .= object []]

stringParam :: Text -> Value
stringParam = param "string"

integerParam :: Text -> Value
integerParam = param "integer"

numberParam :: Text -> Value
numberParam = param "number"

boolParam :: Text -> Value
boolParam = param "boolean"

-- | An integer parameter whose bounds are its whole documentation: minimum,
-- maximum and default, no prose.
boundedIntegerParam :: Int -> Int -> Int -> Value
boundedIntegerParam low high fallback =
  object
    [ "type" .= ("integer" :: Text),
      "minimum" .= low,
      "maximum" .= high,
      "default" .= fallback
    ]

-- | A string parameter restricted to a closed vocabulary.
enumParam :: [Text] -> Text -> Value
enumParam values = withKeys ["enum" .= values] . param "string"

stringArrayParam :: Text -> Value
stringArrayParam =
  withKeys ["items" .= object ["type" .= ("string" :: Text)]] . param "array"

-- | Decorate a parameter with the schema keys only it needs — @minimum@,
-- @maximum@, @default@.  Later keys win, so a caller can override.
withKeys :: [Pair] -> Value -> Value
withKeys extra = \case
  Object fields -> Object (fields <> KeyMap.fromList extra)
  other -> other

-- | A parameter with no prose at all: its type, plus whatever 'withKeys' adds,
-- is the entire contract.  Rare — the model reads descriptions.
paramOfType :: Text -> Value
paramOfType jsonType = object ["type" .= jsonType]

param :: Text -> Text -> Value
param jsonType description =
  object ["type" .= jsonType, "description" .= description]
