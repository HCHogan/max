-- | Applicative argument codecs: one declaration produces the model schema
-- and the typed value consumed by the runner. Constructors stay private.
module Max.Tool.Arguments
  ( Arguments,
    Parameter,
    required,
    optional,
    defaulted,
    text,
    int,
    int64,
    integer,
    boolean,
    strings,
    decodedObject,
    argumentsSchema,
    parseArguments,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    Key,
    KeyValue ((.=)),
    Object,
    ToJSON (toJSON),
    Value (Object),
    object,
    withObject,
    (.:),
    (.:?),
  )
import Data.Aeson.Key qualified as Key (toText)
import Data.Aeson.KeyMap qualified as KM (insert)
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T (pack)
import Max.Tools.Schema
  ( boolParam,
    integerParam,
    stringArrayParam,
    stringParam,
    toolObject,
  )

data Parameter a = Parameter !Value (Value -> Parser a)

data Arguments a = Arguments ![(Key, Value)] ![Text] (Object -> Parser a)

instance Functor Arguments where
  fmap f (Arguments fields needed parse) = Arguments fields needed (fmap f . parse)

instance Applicative Arguments where
  pure value = Arguments [] [] (const (pure value))
  Arguments fs ns pf <*> Arguments xs ms px = Arguments (fs <> xs) (ns <> ms) (\o -> pf o <*> px o)

required :: Key -> Parameter a -> Arguments a
required key (Parameter schema parse) = Arguments [(key, schema)] [Key.toText key] $ \o -> o .: key >>= parse

optional :: Key -> Parameter a -> Arguments (Maybe a)
optional key (Parameter schema parse) = Arguments [(key, schema)] [] $ \o -> do
  value <- o .:? key
  traverse parse value

defaulted :: (ToJSON a) => Key -> a -> Parameter a -> Arguments a
defaulted key fallback parameter@(Parameter schema _) = case optional key parameter of
  Arguments _ needed parse -> Arguments [(key, annotate schema)] needed (fmap (fromMaybe fallback) . parse)
  where
    annotate (Object fields) = Object (KM.insert "default" (toJSON fallback) fields)
    annotate value = value

text :: Text -> Parameter Text
text description = Parameter (stringParam description) parseJSON

int :: Text -> Parameter Int
int description = Parameter (integerParam description) parseJSON

int64 :: Text -> Parameter Int64
int64 description = Parameter (integerParam description) parseJSON

integer :: Text -> Parameter Integer
integer description = Parameter (integerParam description) parseJSON

boolean :: Text -> Parameter Bool
boolean description = Parameter (boolParam description) parseJSON

strings :: Text -> Parameter [Text]
strings description = Parameter (stringArrayParam description) parseJSON

-- | Structured domain documents retain their own FromJSON invariant checks.
decodedObject :: (FromJSON a) => Text -> Parameter a
decodedObject description = Parameter (object ["type" .= ("object" :: Text), "description" .= description]) (withObject "object" (parseJSON . Object))

argumentsSchema :: Arguments a -> Value
argumentsSchema (Arguments fields needed _) = toolObject fields needed

parseArguments :: Arguments a -> Value -> Either Text a
parseArguments (Arguments _ _ parse) = either (Left . T.pack) Right . parseEither (withObject "arguments" parse)
