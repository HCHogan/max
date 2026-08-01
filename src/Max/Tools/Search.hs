-- |
-- @web_search@ tool, backed by Tavily.  Self-contained: owns its own
-- HTTP 'Manager' and POSTs to @https://api.tavily.com/search@.
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

import Control.Lens ((&), (.~))
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Effectful.Wreq qualified as W
import Max.Effects.Tools (Tool (..))
import Max.Wreq (postAndParse)
import Network.Wreq qualified as Wreq
import Network.Wreq.Lens qualified as WL

-- | Knobs for the Tavily-backed search.  Everything except the key is
-- defaulted in 'Max.Config.materialize'.
data SearchConfig = SearchConfig
  { -- | Tavily API key.  Sent as @Authorization: Bearer ...@.
    scTavilyApiKey :: !Text,
    -- | Default and hard cap for @max_results@.
    scDefaultMaxResults :: !Int,
    -- | Per-call HTTP timeout (seconds).
    scTimeoutSeconds :: !Int
  }
  deriving stock (Show)

searchToolsFor ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  SearchConfig ->
  [Tool es]
searchToolsFor cfg = [webSearchTool cfg]

--------------------------------------------------------------------------------
-- web_search

webSearchTool ::
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  SearchConfig ->
  Tool es
webSearchTool cfg =
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
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Natural-language search query." :: Text)
                      ],
                  "max_results"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description"
                          .= ( "Number of results to return (default "
                                 <> T.pack (show cfg.scDefaultMaxResults)
                                 <> ", max 10)."
                             ),
                        "default" .= cfg.scDefaultMaxResults
                      ]
                ],
            "required" .= (["query"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q, mMax) -> do
          let maxR = clamp (1, 10) (fromMaybe cfg.scDefaultMaxResults mMax)
          logInfo "search: tavily request" $
            object ["query" .= q, "max_results" .= maxR]
          eres <- callTavily cfg q maxR
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
  (W.Wreq :> es, Log :> es, IOE :> es) =>
  SearchConfig ->
  Text ->
  Int ->
  Eff es (Either Text Value)
callTavily cfg query maxResults = do
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
      opts =
        Wreq.defaults
          & WL.header "Authorization" .~ ["Bearer " <> TE.encodeUtf8 cfg.scTavilyApiKey]
          & WL.header "Content-Type" .~ ["application/json"]
  postAndParse cfg.scTimeoutSeconds opts "https://api.tavily.com/search" body compactResponse

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
