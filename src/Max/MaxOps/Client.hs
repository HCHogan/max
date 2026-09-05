module Max.MaxOps.Client
  ( maxOpsOperations,
    maxOpsQuery,
  )
where

import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.HttpRuntime
  ( BufferedResponse (..),
    HttpPool (NonReusingPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    runBuffered,
  )
import Max.MaxOps.Types
import Max.Util (trySyncIO)
import Network.HTTP.Client qualified as HTTP
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Timeout (timeout)

maxOpsOperations :: HttpRuntime -> MaxOpsConfig -> IO (Either Text Value)
maxOpsOperations runtime config = do
  result <- maxOpsRequest runtime config "GET" "/v1/operations" Nothing
  pure $ do
    catalog <- result >>= parseCatalog
    pure (object ["version" .= (1 :: Int), "operations" .= catalog])

maxOpsQuery :: HttpRuntime -> MaxOpsConfig -> Text -> Value -> IO (Either Text Value)
maxOpsQuery runtime config operation params
  | not (isObject params) = pure (Left "maxops params must be an object")
  | LBS.length (encode request) > 4096 = pure (Left "maxops request exceeds 4096 bytes")
  | otherwise = do
      catalog <- maxOpsOperations runtime config
      case catalog >>= parseCatalog of
        Left failure -> pure (Left failure)
        Right operations
          | any ((== Just operation) . operationName) operations ->
              maxOpsRequest runtime config "POST" "/v1/execute" (Just request)
          | otherwise -> pure (Left "maxops operation is unavailable or not read-only; call maxops_operations")
  where
    request = object ["op" .= operation, "params" .= params]
    isObject (Object _) = True
    isObject _ = False

parseCatalog :: Value -> Either Text [Value]
parseCatalog value = case parseEither parser value of
  Left _ -> Left "maxops returned an invalid operation catalog"
  Right operations -> Right operations
  where
    parser = withObject "maxops catalog" $ \fields -> do
      version <- fields .: "version" :: Parser Int
      unless (version == 1) (fail "unsupported catalog version")
      operations <- fields .: "operations" :: Parser [Value]
      filterMReadOnly operations
    filterMReadOnly =
      fmap concat
        . traverse
          ( withObject "operation" $ \fields -> do
              name <- fields .: "name" :: Parser Text
              readOnly <- fields .: "read_only" :: Parser Bool
              schema <- fields .: "params_schema" :: Parser Value
              unless (not (T.null name) && isObject schema) (fail "invalid operation")
              pure [Object fields | readOnly]
          )
    isObject (Object _) = True
    isObject _ = False

operationName :: Value -> Maybe Text
operationName value = either (const Nothing) Just (parseEither (withObject "operation" (.: "name")) value)

maxOpsRequest :: HttpRuntime -> MaxOpsConfig -> BS.ByteString -> Text -> Maybe Value -> IO (Either Text Value)
maxOpsRequest runtime config method path payload
  | not config.mocEnabled || not (null (validateMaxOpsConfig config)) = pure (Left "maxops is not configured")
  | otherwise = do
      result <- timeout 15_000_000 $ do
        credential <- trySyncIO $ withBinaryFile config.mocTokenFile ReadMode (`BS.hGet` 515)
        case credential of
          Left _ -> pure (Left "maxops credential file is unavailable")
          Right bytes ->
            let token = BS.dropWhileEnd (\byte -> byte == 10 || byte == 13) bytes
             in if BS.length bytes >= 515 || BS.length token < 32 || BS.length token > 512 || not (BS.all (\byte -> byte >= 33 && byte <= 126) token)
                  then pure (Left "maxops credential file is invalid")
                  else do
                    parsed <- parseRequestEither (T.unpack (T.dropWhileEnd (== '/') config.mocBaseUrl <> path))
                    case parsed of
                      Left _ -> pure (Left "maxops endpoint is invalid")
                      Right request -> do
                        response <-
                          runBuffered runtime NonReusingPool (2 * 1024 * 1024) 0 $
                            HTTP.setRequestIgnoreStatus $
                              request
                                { HTTP.method = method,
                                  HTTP.requestHeaders = [("Authorization", "Bearer " <> token), ("Content-Type", "application/json"), ("Accept", "application/json")],
                                  HTTP.requestBody = maybe (HTTP.RequestBodyBS BS.empty) (HTTP.RequestBodyLBS . encode) payload,
                                  HTTP.redirectCount = 0,
                                  HTTP.proxy = Nothing,
                                  HTTP.responseTimeout = HTTP.responseTimeoutMicro 15_000_000
                                }
                        pure $ case response of
                          Left failure -> Left (safeFailure failure)
                          Right body -> either (const (Left "maxops returned invalid JSON")) Right (eitherDecodeStrict' body.body)
      pure (fromMaybe (Left "maxops request timed out") result)

safeFailure :: TransportFailure -> Text
safeFailure = \case
  HttpStatusFailure code _ _ _ -> "maxops HTTP " <> T.pack (show code)
  ResponseBodyLimitExceeded _ -> "maxops response exceeds 2 MiB"
  ResponseTimeoutFailure -> "maxops request timed out"
  ConnectionTimeoutFailure -> "maxops connection timed out"
  _ -> "maxops transport unavailable"
