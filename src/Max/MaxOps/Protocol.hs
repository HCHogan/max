-- | The hub registry owns operation names and schemas. This module checks
-- protocol and effect metadata without reimplementing its operation table.
module Max.MaxOps.Protocol
  ( CatalogAccess (..),
    Catalog (..),
    Operation (..),
    parseCatalog,
    catalogValue,
    validateIdempotencyKey,
    withLogText,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base64 qualified as Base64
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)

data CatalogAccess = ReadOnlyCatalog | ManagementCatalog
  deriving stock (Eq, Show)

data Catalog = Catalog {version :: !Int, operations :: ![Operation]}
  deriving stock (Eq, Show)

data Operation = Operation
  { name :: !Text,
    readOnly :: !Bool,
    requiresKey :: !Bool,
    wireValue :: !Value
  }
  deriving stock (Eq, Show)

parseCatalog :: Value -> Either Text Catalog
parseCatalog = either (const (Left "maxops returned an invalid or unsupported operation catalog")) Right . parseEither parser
  where
    parser = withObject "maxops catalog" $ \fields -> do
      version <- fields .: "version"
      unless (version `elem` [1, 2 :: Int]) (fail "unsupported protocol")
      values <- fields .: "operations"
      entries <- traverse (parseOperation version) values
      let operations = catMaybes entries
          names = map (.name) operations
      unless (Set.size (Set.fromList names) == length names) (fail "duplicate operations")
      pure Catalog {version, operations}

    parseOperation version = withObject "operation" $ \fields -> do
      name <- fields .: "name"
      readOnly <- fields .: "read_only"
      schema <- fields .: "params_schema"
      unless (not (T.null name) && isObject schema) (fail "invalid operation")
      if version == 1
        then pure $ if readOnly then Just (Operation name True False (Object fields)) else Nothing
        else do
          kind <- fields .: "kind" :: Parser Text
          idempotency <- fields .: "idempotency" :: Parser Text
          minimumVersion <- fields .: "minimum_protocol_version" :: Parser Int
          response <- fields .: "response_schema"
          unless (minimumVersion >= 1 && minimumVersion <= version && isObject response) (fail "unsupported operation")
          let valid = case kind of
                "observation" -> readOnly && idempotency == "none"
                "job_submission" -> not readOnly && idempotency == "required"
                "job_control" -> idempotency == "none"
                _ -> False
          unless valid (fail "inconsistent effect metadata")
          pure (Just (Operation name readOnly (idempotency == "required") (Object fields)))

    isObject (Object _) = True
    isObject _ = False

catalogValue :: CatalogAccess -> Catalog -> Value
catalogValue access catalog = object
  ["version" .= catalog.version, "operations" .= [entry.wireValue | entry <- catalog.operations, access == ManagementCatalog || entry.readOnly]]

validateIdempotencyKey :: Text -> Bool
validateIdempotencyKey key = not (T.null key) && T.length key <= 128 && T.all (\c -> c >= '!' && c <= '~') key

-- | A binary log envelope retains its exact bytes and pagination metadata.
-- Derived text lets the model read output, including chunks split inside UTF-8.
-- This is presentation only; it does not select or dispatch an operation.
withLogText :: Value -> Either Text Value
withLogText (Object fields)
  | KeyMap.lookup "encoding" fields == Just (String "base64"),
    Just (String stdout) <- KeyMap.lookup "stdout_base64" fields,
    Just (String stderr) <- KeyMap.lookup "stderr_base64" fields = do
      out <- decode stdout
      err <- decode stderr
      pure (Object (KeyMap.insert "stdout_text" (String out) . KeyMap.insert "stderr_text" (String err) . KeyMap.insert "text_decoding" (String "utf8_with_replacement") $ fields))
  where
    decode = either (const (Left "maxops returned invalid base64 logs")) (Right . TE.decodeUtf8With lenientDecode) . Base64.decode . TE.encodeUtf8
withLogText value = Right value
