module Max.Search.Runtime
  ( SearchRuntime,
    newSearchRuntime,
    searchToolsWithRuntime,
    searchExa,
    decodeMcpResponse,
    compactApiResponse,
    cooldownUntil,
    retrySearch,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, defaultTimeLocale, diffUTCTime, getCurrentTime, parseTimeM)
import Effectful (Eff, IOE, liftIO, type (:>))
import Effectful.Log (Log, logAttention)
import Max.Effects.Search (runSearch)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Http.Failure (ResponseFailure (..), TransportFailure (..), renderResponseFailure, retryableResponseFailure)
import Max.HttpRuntime (BufferedResponse (body), HttpPool (StandardPool), HttpRuntime, parseRequestEither, runBuffered)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Search.Types (SearchConfig (..))
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (Header)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data SearchRuntime = SearchRuntime
  { config :: !SearchConfig,
    freeState :: !(MVar (UTCTime, Maybe ResponseFailure)),
    apiState :: !(MVar (UTCTime, Maybe ResponseFailure))
  }

newSearchRuntime :: SearchConfig -> IO SearchRuntime
newSearchRuntime config = do
  now <- getCurrentTime
  SearchRuntime config <$> newMVar (now, Nothing) <*> newMVar (now, Nothing)

searchToolsWithRuntime :: (Log :> es, IOE :> es) => HttpRuntime -> SearchRuntime -> [Tool es]
searchToolsWithRuntime runtime search = map (hoistTool (runSearch (searchExa runtime search))) (searchToolsFor search.config.scDefaultMaxResults)

searchExa :: (Log :> es, IOE :> es) => HttpRuntime -> SearchRuntime -> Text -> Int -> Eff es (Either Text Value)
searchExa runtime search query limit
  | T.null (T.strip query) = pure (Left "search query must not be empty")
  | otherwise = do
      free <- liftIO $ withCooldown search.freeState 0.55 $ post "https://mcp.exa.ai/mcp" [] mcpBody (decodeMcpResponse count)
      case (free, search.config.scExaApiKey) of
        (Right value, _) -> pure (Right value)
        (Left failure, _) | invalidQuery failure -> pure (Left (renderResponseFailure failure))
        (Left failure, Nothing) -> pure (Left ("Exa free MCP unavailable; no API fallback key configured: " <> renderResponseFailure failure))
        (Left failure, Just key) -> do
          logAttention "search: exa API fallback" (object ["reason" .= renderResponseFailure failure])
          paid <- liftIO $ withCooldown search.apiState 0 $ post "https://api.exa.ai/search" [("x-api-key", TE.encodeUtf8 key)] apiBody decodeApi
          pure (first (\err -> "Exa API fallback failed: " <> renderResponseFailure err) paid)
  where
    count = max 1 (min 10 limit)
    mcpBody = object ["jsonrpc" .= ("2.0" :: Text), "id" .= (1 :: Int), "method" .= ("tools/call" :: Text), "params" .= object ["name" .= ("web_search_exa" :: Text), "arguments" .= object ["query" .= query, "numResults" .= count]]]
    apiBody = object ["query" .= query, "numResults" .= count, "type" .= ("auto" :: Text), "contents" .= object ["highlights" .= True]]
    decodeApi bytes = first ResponseDecode $ first T.pack (eitherDecodeStrict' bytes) >>= first T.pack . parseEither (compactApiResponse count)
    post url headers body decoder = do
      result <- postSearch runtime search.config.scTimeoutSeconds url headers body
      pure (result >>= decoder)

withCooldown :: MVar (UTCTime, Maybe ResponseFailure) -> NominalDiffTime -> IO (Either ResponseFailure value) -> IO (Either ResponseFailure value)
withCooldown stateVar interval attempt = modifyMVar stateVar $ \state@(next, failure) -> do
  now <- getCurrentTime
  case failure of
    Just previous | now < next -> pure (state, Left previous)
    _ -> do
      when (now < next) (threadDelay (ceiling (diffUTCTime next now * 1_000_000)))
      result <- attempt
      finished <- getCurrentTime
      let updated = case result of
            Left err | not (invalidQuery err) -> (cooldownUntil finished err, Just err)
            _ -> (addUTCTime interval finished, Nothing)
      pure (updated, result)

invalidQuery :: ResponseFailure -> Bool
invalidQuery (ResponseTransport (HttpStatusFailure code _ _ _)) = code == 400 || code == 422
invalidQuery _ = False

postSearch :: HttpRuntime -> Int -> String -> [Header] -> Value -> IO (Either ResponseFailure BS.ByteString)
postSearch runtime seconds url headers body = do
  result <- timeout (seconds * 1_000_000) $ retrySearch threadDelay $ do
    parsed <- parseRequestEither url
    response <- case parsed of
      Left failure -> pure (Left failure)
      Right request ->
        fmap (.body)
          <$> runBuffered
            runtime
            StandardPool
            (1024 * 1024)
            1024
            request
              { HTTP.method = "POST",
                HTTP.requestHeaders = [("Content-Type", "application/json"), ("Accept", "application/json, text/event-stream")] <> headers,
                HTTP.requestBody = HTTP.RequestBodyLBS (encode body),
                HTTP.responseTimeout = HTTP.responseTimeoutMicro (min 10 seconds * 1_000_000),
                HTTP.redirectCount = 0
              }
    pure (first ResponseTransport response)
  pure (fromMaybe (Left (ResponseTransport ResponseTimeoutFailure)) result)

retrySearch :: (Int -> IO ()) -> IO (Either ResponseFailure value) -> IO (Either ResponseFailure value)
retrySearch sleep attempt = go [1, 3]
  where
    go remaining = do
      result <- attempt
      case (result, remaining) of
        (Left (ResponseTransport (HttpStatusFailure 429 _ _ _)), _) -> pure result
        (Left (ResponseTransport (HttpStatusFailure _ headers _ _)), _) | Just _ <- lookup "Retry-After" headers -> pure result
        (Left failure, delay : rest) | retryableResponseFailure failure -> sleep (delay * 1_000_000) >> go rest
        _ -> pure result

cooldownUntil :: UTCTime -> ResponseFailure -> UTCTime
cooldownUntil now failure = fromMaybe (addUTCTime 60 now) $ do
  ResponseTransport (HttpStatusFailure _ headers _ _) <- Just failure
  bytes <- lookup "Retry-After" headers
  raw <- either (const Nothing) Just (TE.decodeUtf8' bytes)
  let value = T.unpack (T.strip raw)
  case readMaybe value :: Maybe Integer of
    Just seconds | seconds >= 0 -> Just (addUTCTime (fromInteger (max 1 seconds)) now)
    _ -> max (addUTCTime 1 now) <$> parseTimeM True defaultTimeLocale "%a, %d %b %Y %H:%M:%S GMT" value

decodeMcpResponse :: Int -> BS.ByteString -> Either ResponseFailure Value
decodeMcpResponse limit bytes = first ResponseDecode $ do
  let raw = TE.decodeUtf8Lenient bytes
      frames = T.splitOn "\n\n" (T.replace "\r\n" "\n" raw)
      payloads =
        if "{" `T.isPrefixOf` T.stripStart raw
          then [bytes]
          else [TE.encodeUtf8 (T.intercalate "\n" fields) | frame <- frames, let fields = [T.dropWhile (== ' ') field | line <- T.lines frame, Just field <- [T.stripPrefix "data:" line]], not (null fields)]
  values <- traverse (first T.pack . eitherDecodeStrict') payloads
  messages <- traverse (first T.pack . parseEither response) values
  case catMaybes messages of
    [value] -> Right value
    _ -> Left "Exa MCP returned no unique response for request 1"
  where
    response = withObject "MCP response" $ \root -> do
      identifier <- root .:? "id" :: Parser (Maybe Value)
      failure <- root .:? "error" :: Parser (Maybe Value)
      case (identifier, failure) of
        (Nothing, Nothing) -> pure Nothing
        (_, Just err) -> fail ("Exa MCP RPC error: " <> show err)
        (Just (Number 1), Nothing) -> do
          result <- root .: "result"
          Just <$> parseResult result
        _ -> pure Nothing
    parseResult = withObject "MCP tool result" $ \result -> do
      failed <- result .:? "isError" .!= False
      when failed (fail "Exa MCP tool reported an error")
      structured <- result .:? "structuredContent"
      case structured of
        Just value -> compactApiResponse limit value
        Nothing -> do
          content <- result .: "content" :: Parser [Value]
          texts <-
            catMaybes
              <$> traverse
                ( withObject
                    "MCP content"
                    ( \block -> do
                        kind <- block .: "type" :: Parser Text
                        if kind == "text" then Just <$> block .: "text" else pure Nothing
                    )
                )
                content
          parseSearchText limit (T.intercalate "\n\n---\n\n" texts)

parseSearchText :: Int -> Text -> Parser Value
parseSearchText limit body
  | T.strip body == "No search results found. Please try a different query." = pure (searchResult [])
  | T.null (T.strip body) = fail "Exa MCP returned empty content"
  | otherwise = searchResult <$> traverse parseRow (take limit blocks)
  where
    blocks = case T.splitOn "\n\n---\n\nTitle: " body of
      firstBlock : rest -> firstBlock : map ("Title: " <>) rest
      [] -> []
    parseRow block = case T.lines block of
      titleLine : urlLine : remaining -> do
        title <- maybe (fail "missing Exa title") pure (T.stripPrefix "Title: " titleLine)
        url <- maybe (fail "missing Exa URL") pure (T.stripPrefix "URL: " urlLine)
        unless ("https://" `T.isPrefixOf` url || "http://" `T.isPrefixOf` url) (fail "invalid Exa result URL")
        let source = dropWhile (\line -> any (`T.isPrefixOf` line) ["Published:", "Author:"]) remaining
            snippet = case source of
              "Highlights:" : rest -> T.unlines rest
              firstLine : rest -> T.unlines (fromMaybe firstLine (T.stripPrefix "Text: " firstLine) : rest)
              [] -> ""
        pure (searchRow title url (T.strip snippet))
      _ -> fail "unrecognized Exa result format"

compactApiResponse :: Int -> Value -> Parser Value
compactApiResponse limit = withObject "Exa response" $ \root -> do
  results <- root .: "results" :: Parser [Value]
  rows <-
    traverse
      ( withObject "Exa result" $ \row -> do
          title <- row .:? "title" .!= ""
          url <- row .: "url"
          highlights <- row .:? "highlights" .!= [] :: Parser [Text]
          text <- row .:? "text" .!= ""
          pure (searchRow title url (if null highlights then text else T.intercalate "\n" highlights))
      )
      (take limit results)
  pure (searchResult rows)

searchResult :: [Value] -> Value
searchResult rows = object ["answer" .= Null, "results" .= rows]

searchRow :: Text -> Text -> Text -> Value
searchRow title url snippet = object ["title" .= T.take 300 title, "url" .= url, "snippet" .= T.take 2000 snippet]
