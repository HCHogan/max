module Max.MaxOps.Client
  ( maxOpsOperations,
    MaxOpsClient (..),
    maxOpsClient,
    maxOpsQuery,
    maxOpsExecute,
    maxOpsInvoke,
    maxOpsRequest,
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.HttpRuntime
  ( BufferedResponse (..),
    HttpPool (NonReusingPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    runBuffered,
  )
import Max.MaxOps.Protocol
import Max.MaxOps.Types
import Max.Util (trySyncIO)
import Network.HTTP.Client qualified as HTTP
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Timeout (timeout)

-- Process-owned fleet capability. Consumers cannot select arbitrary HTTP
-- methods, paths, authentication headers, or transports.
data MaxOpsClient = MaxOpsClient
  { invokeOperation :: MaxOpsConfig -> Operation -> Value -> Maybe Text -> IO (Either Text Value),
    discoverOperations :: MaxOpsConfig -> CatalogAccess -> IO (Either Text Value)
  }

maxOpsClient :: HttpRuntime -> MaxOpsClient
maxOpsClient runtime = MaxOpsClient (maxOpsInvoke runtime) (maxOpsOperations runtime)

maxOpsOperations :: HttpRuntime -> MaxOpsConfig -> CatalogAccess -> IO (Either Text Value)
maxOpsOperations runtime config access = fmap (catalogValue access) <$> loadCatalog runtime config

loadCatalog :: HttpRuntime -> MaxOpsConfig -> IO (Either Text Catalog)
loadCatalog runtime config = do
  result <- maxOpsRequest runtime config "GET" "/v1/operations?view=tools" Nothing Nothing
  pure (result >>= parseCatalog)

maxOpsQuery :: HttpRuntime -> MaxOpsConfig -> Text -> Value -> IO (Either Text Value)
maxOpsQuery runtime config operation params = do
  result <- maxOpsCall runtime config True operation params Nothing
  pure (result >>= withLogText)

-- | Submissions return durable handles immediately. Polling, cancellation and
-- reconciliation use the same registry; no HTTP failure automatically replays
-- a write, including controls whose only protection is remote revision CAS.
maxOpsExecute :: HttpRuntime -> MaxOpsConfig -> Text -> Value -> Maybe Text -> IO (Either Text Value)
maxOpsExecute runtime config = maxOpsCall runtime config False

maxOpsCall :: HttpRuntime -> MaxOpsConfig -> Bool -> Text -> Value -> Maybe Text -> IO (Either Text Value)
maxOpsCall runtime config readOnly operation params key
  | not (isObject params) = pure (Left "maxops params must be an object")
  | LBS.length (encode request) > 2 * 1024 * 1024 = pure (Left "maxops request exceeds 2 MiB")
  | maybe False (not . validateIdempotencyKey) key = pure (Left "maxops idempotency_key must contain 1..128 printable ASCII characters without spaces")
  | otherwise = do
      catalog <- loadCatalog runtime config
      case catalog of
        Left failure -> pure (Left failure)
        Right available -> case find ((== operation) . (.name)) available.operations of
          Just entry | entry.readOnly == readOnly -> case (entry.requiresKey, key) of
            (True, Nothing) -> pure (Left "maxops operation requires a stable idempotency_key")
            (False, Just _) -> pure (Left "maxops operation does not accept idempotency_key; use its current revision or job handle")
            _ -> maxOpsRequest runtime config "POST" "/v1/execute" (Just request) key
          _ -> pure (Left (if readOnly then "maxops operation is unavailable or not read-only; call maxops_operations" else "maxops operation is unavailable or not a write; call maxops_operations"))
  where
    request = object ["op" .= operation, "params" .= params]
    isObject (Object _) = True
    isObject _ = False

maxOpsRequest :: HttpRuntime -> MaxOpsConfig -> BS.ByteString -> Text -> Maybe Value -> Maybe Text -> IO (Either Text Value)
maxOpsRequest runtime config method path payload key
  | not config.mocEnabled || not (null (validateMaxOpsConfig config)) = pure (Left "maxops is not configured")
  | otherwise = do
      result <- timeout 30_000_000 $ do
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
                          runBuffered runtime NonReusingPool (2 * 1024 * 1024) 4096 $
                            HTTP.setRequestIgnoreStatus $
                              request
                                { HTTP.method = method,
                                  HTTP.requestHeaders = [("Authorization", "Bearer " <> token), ("Content-Type", "application/json"), ("Accept", "application/json")] <> [("Idempotency-Key", TE.encodeUtf8 value) | Just value <- [key]],
                                  HTTP.requestBody = maybe (HTTP.RequestBodyBS BS.empty) (HTTP.RequestBodyLBS . encode) payload,
                                  HTTP.redirectCount = 0,
                                  HTTP.proxy = Nothing,
                                  HTTP.responseTimeout = HTTP.responseTimeoutMicro 30_000_000
                                }
                        pure $ case response of
                          Left failure -> Left (safeFailure failure)
                          Right body -> either (const (Left "maxops returned invalid JSON")) Right (eitherDecodeStrict' body.body)
      pure (fromMaybe (Left "maxops request timed out") result)

safeFailure :: TransportFailure -> Text
safeFailure = \case
  HttpStatusFailure code _ body _ ->
    let prefix = "maxops HTTP " <> T.pack (show code)
     in case eitherDecodeStrict' body of
          Right (Object fields)
            | Just (String machineCode) <- KeyMap.lookup "code" fields,
              Just (String retry) <- KeyMap.lookup "retry" fields,
              machineCode `elem` ["unsupported_operation", "idempotency_conflict", "revision_conflict", "stale_baseline", "cursor_invalid", "workflow_conflict", "unauthenticated", "forbidden", "not_found", "state_conflict", "cursor_expired", "busy", "invalid_request", "unavailable"],
              retry `elem` ["refresh_catalog", "never", "refresh", "replan", "restart_listing", "observe", "backoff", "observe_before_retry"] ->
                prefix <> " code=" <> machineCode <> " retry=" <> retry
          _ -> prefix
  ResponseBodyLimitExceeded _ -> "maxops response exceeds 2 MiB"
  ResponseTimeoutFailure -> "maxops request timed out"
  ConnectionTimeoutFailure -> "maxops connection timed out"
  _ -> "maxops transport unavailable"

-- The load receipt pins the registry metadata. Hub reauthorizes every call;
-- there is no discovery round trip per operation and no write transport retry.
maxOpsInvoke :: HttpRuntime -> MaxOpsConfig -> Operation -> Value -> Maybe Text -> IO (Either Text Value)
maxOpsInvoke runtime config operation params key
  | not validIdentity = pure (Left "maxops invocation identity does not match operation metadata")
  | not (isObject params) = pure (Left "maxops params must be an object")
  | LBS.length (encode request) > 2 * 1024 * 1024 = pure (Left "maxops request exceeds 2 MiB")
  | otherwise = do
      response <-
        maxOpsRequest
          runtime
          config
          "POST"
          "/v1/execute?view=summary&encoding=text"
          (Just request)
          key
      pure (response >>= withLogText)
  where
    request = object ["op" .= operation.name, "params" .= params]
    validIdentity = case (operation.requiresKey, key) of
      (True, Just value) -> validateIdempotencyKey value
      (False, Nothing) -> True
      _ -> False
    isObject (Object _) = True
    isObject _ = False
