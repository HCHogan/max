-- | Tavily transport and credentials live at the host boundary.
module Max.Search.Runtime (searchToolsWithRuntime) where

import Data.Aeson
  ( KeyValue ((.=)),
    Value,
    encode,
    object,
    withObject,
    (.:),
    (.:?),
  )
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS (toStrict)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE (encodeUtf8)
import Effectful (Eff, IOE, type (:>))
import Effectful.Log (Log)
import Max.Effects.Search (runSearch)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Http.Failure (renderResponseFailure)
import Max.Http.Json (postAndParse)
import Max.HttpRuntime (HttpRuntime)
import Max.Tools.Search (searchToolsFor)
import Max.Tools.Search.Types (SearchConfig (..))

searchToolsWithRuntime :: (Log :> es, IOE :> es) => HttpRuntime -> SearchConfig -> [Tool es]
searchToolsWithRuntime runtime config = map (hoistTool (runSearch (callTavily runtime config))) (searchToolsFor config.scDefaultMaxResults)

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
