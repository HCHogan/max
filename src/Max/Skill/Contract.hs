-- | Deliberately small, recursively checked JSON contracts. Unknown schema
-- keywords fail closed; this is not a permissive full JSON Schema interpreter.
module Max.Skill.Contract (validateContract, validateValue) where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList, traverse_)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T

validateContract :: Value -> Either Text ()
validateContract = go (0 :: Int)
  where
    go depth (Object fields) = do
      when (depth > 16) (Left "contract nesting exceeds 16")
      kind <- case KM.lookup "type" fields of
        Just (String t) | t `elem` ["object", "array", "string", "number", "integer", "boolean", "null"] -> Right t
        _ -> Left "contract requires one supported type"
      let keywords =
            ["type", "description", "enum"] <> case kind of
              "object" -> ["properties", "required", "additionalProperties"]
              "array" -> ["items", "minItems", "maxItems"]
              "string" -> ["minLength", "maxLength"]
              "number" -> ["minimum", "maximum"]
              "integer" -> ["minimum", "maximum"]
              _ -> []
      traverse_ (\k -> unless (k `elem` keywords) (Left ("unsupported contract keyword: " <> Key.toText k))) (KM.keys fields)
      case KM.lookup "description" fields of
        Nothing -> pure ()
        Just (String _) -> pure ()
        _ -> Left "description must be a string"
      case KM.lookup "enum" fields of
        Nothing -> pure ()
        Just (Array values) | not (null values) -> traverse_ (validateValue (Object (KM.delete "enum" fields))) values
        _ -> Left "enum must be a nonempty array"
      case kind of
        "object" -> do
          props <- properties fields
          traverse_ (go (depth + 1)) props
          needed <- required fields
          traverse_ (\k -> unless (KM.member (Key.fromText k) props) (Left "required property has no schema")) needed
          case KM.lookup "additionalProperties" fields of
            Just (Bool _) -> pure ()
            _ -> Left "object contracts require explicit additionalProperties boolean"
        "array" -> maybe (Left "array contract requires items") (go (depth + 1)) (KM.lookup "items" fields) >> bounds fields "minItems" "maxItems" True
        "string" -> bounds fields "minLength" "maxLength" True
        "number" -> bounds fields "minimum" "maximum" False
        "integer" -> bounds fields "minimum" "maximum" False
        _ -> pure ()
    go _ _ = Left "contract must be an object"
    bounds fields lo hi nonnegative = do
      traverse_
        ( \key -> case KM.lookup key fields of
            Nothing -> pure ()
            Just (Number n) | not nonnegative || (n >= 0 && isInteger n) -> pure ()
            _ -> Left ("invalid bound: " <> Key.toText key)
        )
        [lo, hi]
      case (KM.lookup lo fields, KM.lookup hi fields) of
        (Just (Number a), Just (Number b)) | a > b -> Left "contract bounds are reversed"
        _ -> pure ()

validateValue :: Value -> Value -> Either Text ()
validateValue = go "$"
  where
    go path (Object fields) value = do
      let failAt :: Text -> Either Text a
          failAt message = Left (path <> ": " <> message)
          bounded lo hi n = do
            case KM.lookup lo fields of
              Just (Number minimumValue) | n < minimumValue -> failAt ("below " <> Key.toText lo)
              _ -> pure ()
            case KM.lookup hi fields of
              Just (Number maximumValue) | n > maximumValue -> failAt ("above " <> Key.toText hi)
              _ -> pure ()
      case (KM.lookup "type" fields, value) of
        (Just (String "object"), Object args) -> do
          props <- properties fields
          needed <- required fields
          traverse_ (\name -> unless (KM.member (Key.fromText name) args) (failAt ("missing " <> name))) needed
          traverse_
            ( \(key, item) -> case KM.lookup key props of
                Just contract -> go (path <> "." <> Key.toText key) contract item
                Nothing | KM.lookup "additionalProperties" fields == Just (Bool True) -> pure ()
                _ -> failAt ("unknown property " <> Key.toText key)
            )
            (KM.toList args)
        (Just (String "array"), Array values) -> do
          bounded "minItems" "maxItems" (fromIntegral (length values))
          contract <- maybe (failAt "missing items schema") Right (KM.lookup "items" fields)
          traverse_ (\(i, item) -> go (path <> "[" <> T.pack (show i) <> "]") contract item) (zip [0 :: Int ..] (toList values))
        (Just (String "string"), String t) -> bounded "minLength" "maxLength" (fromIntegral (T.length t))
        (Just (String "number"), Number n) -> bounded "minimum" "maximum" n
        (Just (String "integer"), Number n) | isInteger n -> bounded "minimum" "maximum" n
        (Just (String "boolean"), Bool _) -> pure ()
        (Just (String "null"), Null) -> pure ()
        _ -> failAt "value has the wrong type"
      case KM.lookup "enum" fields of
        Just (Array allowed) | value `notElem` allowed -> failAt "value is outside enum"
        _ -> pure ()
    go path _ _ = Left (path <> ": invalid contract")

properties :: Object -> Either Text Object
properties fields = case KM.lookup "properties" fields of
  Nothing -> Right KM.empty
  Just (Object props) -> Right props
  _ -> Left "properties must be an object"

required :: Object -> Either Text [Text]
required fields = case KM.lookup "required" fields of
  Nothing -> Right []
  Just (Array values) -> traverse (\case String t -> Right t; _ -> Left "required must contain strings") (toList values)
  _ -> Left "required must be an array"

isInteger :: Scientific -> Bool
isInteger n = case floatingOrInteger @Double @Integer n of
  Right _ -> True
  Left _ -> False
