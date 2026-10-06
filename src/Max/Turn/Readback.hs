-- | How a stored journal entry reads back to the model through context_resume.
-- The journal keeps execution evidence (fuel, digests, the pinned catalog) for
-- audit; a model resuming work needs what was asked and what came back, so
-- code-mode entries show the workflow or source and the program's value.
module Max.Turn.Readback
  ( readbackTool,
    readbackInput,
    readbackResult,
    orderedJson,
  )
where

import Data.Aeson (Key, Value (..), encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- | Code-mode programs are journaled under their host reference; the model
-- knows them as run_code.
readbackTool :: Maybe Text -> Maybe Text
readbackTool = fmap (\ref -> if codeMode (Just ref) then "run_code" else ref)

-- | A program's workflow reference and arguments, or its source and args.
readbackInput :: Maybe Text -> Value -> Value
readbackInput ref input
  | codeMode ref,
    Object fields <- input,
    Just (Object program) <- KeyMap.lookup "program" fields =
      case KeyMap.lookup "workflow" program of
        Just (Object workflow) ->
          object (["workflow" .= reference | Just reference <- [KeyMap.lookup "reference" workflow]] <> ["args" .= args | Just args <- [KeyMap.lookup "args" workflow]])
        _ -> object (["code" .= KeyMap.lookup "source" program] <> ["args" .= args | Just args <- [KeyMap.lookup "args" program]])
  | otherwise = input

-- | A program's status and returned value, without the per-call receipts.
readbackResult :: Maybe Text -> Value -> Value
readbackResult ref result
  | codeMode ref,
    Object fields <- result =
      Object (KeyMap.filterWithKey (\key _ -> key `elem` ["status", "exit", "value", "call_count", "run"]) fields)
  | otherwise = result

codeMode :: Maybe Text -> Bool
codeMode = maybe False ("host:wasm" `T.isPrefixOf`)

-- | JSON text with fields in the given order: what is read first is what a
-- paged reader reaches first.
orderedJson :: [(Key, Value)] -> Text
orderedJson fields =
  "{" <> T.intercalate "," [encodeText (String (Key.toText key)) <> ":" <> encodeText value | (key, value) <- fields] <> "}"
  where
    encodeText = TE.decodeUtf8 . LBS.toStrict . encode
