-- |
-- @web_search@ tool, backed by Tavily and the shared outbound HTTP runtime.
--
-- The tool is registered into the agent's tool factory only when an
-- API key is configured ('Max.Config.AppConfig.search' is @Just@) —
-- otherwise it doesn't exist as far as the model is concerned, so we
-- never have to invent a "search unavailable" failure mode.
--
-- Response is compacted before being returned to the model: keep
-- @title@ / @url@ / @snippet@ for each result, plus Tavily's
-- synthesised @answer@ when present.  Drop @score@, @raw_content@,
-- and @images@ to keep prompt tokens down.
module Max.Tools.Search
  ( SearchConfig (..),
    searchToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Max.Effects.Tools (Tool (..))
import Max.Http.Failure (renderResponseFailure)
import Max.Http.Json (postAndParse)
import Max.HttpRuntime (HttpRuntime)
import Max.Tools.Schema (integerParam, stringParam, toolObject, withKeys)
import Max.Tools.Search.Types (SearchConfig (..))
import Max.Util (tshow)

searchToolsFor ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  SearchConfig ->
  [Tool es]
searchToolsFor runtime cfg = [webSearchTool runtime cfg]

--------------------------------------------------------------------------------
-- web_search

webSearchTool ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  SearchConfig ->
  Tool es
webSearchTool runtime cfg =
  Tool
    { toolName = "web_search",
      toolDescription =
        T.unwords
          [ "Search the web via Tavily.  Use for current events, news,",
            "documentation lookups, definitions, library references —",
            "anything you're not sure about or that may have changed",
            "since your training cutoff.  Returns the top results with",
            "title / url / snippet, plus a synthesised 'answer' when",
            "Tavily can produce one.  Prefer following up with curl /",
            "fetch from a sandbox if you need the full page text."
          ],
      toolSchema =
        toolObject
          [ ("query", stringParam "Natural-language search query."),
            ( "max_results",
              withKeys
                ["default" .= cfg.scDefaultMaxResults]
                (integerParam ("Number of results to return (default " <> tshow cfg.scDefaultMaxResults <> ", max 10)."))
            )
          ]
          ["query"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q, mMax) -> do
          let maxR = clamp (1, 10) (fromMaybe cfg.scDefaultMaxResults mMax)
          logInfo "search: tavily request" $
            object ["query" .= q, "max_results" .= maxR]
          eres <- callTavily runtime cfg q maxR
          case eres of
            Left err -> do
              logAttention "search: tavily failed" $ object ["error" .= err]
              pure (Left err)
            Right v -> do
              logInfo "search: tavily ok" $
                object
                  [ "result_count" .= countResults v
                  ]
              pure (Right v)
    }
  where
    parseArgs :: Object -> Parser (Text, Maybe Int)
    parseArgs o = (,) <$> o .: "query" <*> o .:? "max_results"

    countResults v = case parseEither extractCount v of
      Right n -> n
      Left _ -> -1

    extractCount :: Value -> Parser Int
    extractCount = withObject "out" $ \o -> do
      rs <- o .: "results" :: Parser [Value]
      pure (length rs)

--------------------------------------------------------------------------------
-- HTTP.

callTavily ::
  (Log :> es, IOE :> es) =>
  HttpRuntime ->
  SearchConfig ->
  Text ->
  Int ->
  Eff es (Either Text Value)
callTavily runtime cfg query maxResults = do
  let body =
        LBS.toStrict $
          encode $
            object
              [ "query" .= query,
                "max_results" .= maxResults,
                "search_depth" .= ("basic" :: Text),
                "include_answer" .= True,
                "include_raw_content" .= False,
                "include_images" .= False
              ]
      headers =
        [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.scTavilyApiKey),
          ("Content-Type", "application/json")
        ]
  first renderResponseFailure <$> postAndParse runtime cfg.scTimeoutSeconds headers "https://api.tavily.com/search" body compactResponse

-- | Strip everything we don't want surfaced to the model: scores
-- (it'll just second-guess them), raw_content (already capped at
-- snippet), images (separate feature).  Keep answer + title/url/snippet.
compactResponse :: Value -> Parser Value
compactResponse = withObject "TavilyResponse" $ \o -> do
  mAnswer <- o .:? "answer"
  results <- o .: "results" :: Parser [Value]
  trimmedResults <- traverse trimResult results
  pure $
    object
      [ "answer" .= (mAnswer :: Maybe Text),
        "results" .= trimmedResults
      ]

trimResult :: Value -> Parser Value
trimResult = withObject "TavilyResult" $ \o -> do
  title <- o .: "title" :: Parser Text
  url <- o .: "url" :: Parser Text
  content <- o .: "content" :: Parser Text
  pure $
    object
      [ "title" .= title,
        "url" .= url,
        "snippet" .= content
      ]
