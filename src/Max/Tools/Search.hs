-- | Tavily search through the shared HTTP runtime, enabled when configured.
-- Return title/URL/snippet and an optional answer; omit bulky raw content,
-- images and ranking metadata from the model-facing result.
module Max.Tools.Search
  ( SearchConfig (..),
    searchToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Ord (clamp)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.Search (Search, searchWeb)
import Max.Effects.Tools (Tool (..))
import Max.Tool.Arguments qualified as Args
  ( defaulted,
    int,
    required,
    text,
  )
import Max.Tool.Protocol (argumentTool, readResult)
import Max.Tools.Search.Types (SearchConfig (..))
import Max.Util (tshow)

searchToolsFor ::
  (Search :> es, Log :> es) =>
  Int ->
  [Tool es]
searchToolsFor defaultMaxResults = [webSearchTool defaultMaxResults]

--------------------------------------------------------------------------------
-- web_search

webSearchTool ::
  (Search :> es, Log :> es) =>
  Int ->
  Tool es
webSearchTool defaultMaxResults =
  argumentTool
    "web_search"
    ( T.unwords
        [ "Search the web via Tavily.  Use for current events, news,",
          "documentation lookups, definitions, library references —",
          "anything you're not sure about or that may have changed",
          "since your training cutoff.  Returns the top results with",
          "title / url / snippet, plus a synthesised 'answer' when",
          "Tavily can produce one.  Prefer following up with curl /",
          "fetch from a sandbox if you need the full page text."
        ]
    )
    ( (,)
        <$> Args.required "query" (Args.text "Natural-language search query.")
        <*> Args.defaulted "max_results" defaultMaxResults (Args.int ("Number of results to return (default " <> tshow defaultMaxResults <> ", max 10)."))
    )
    $ \(q, requested) -> do
      let maxR = clamp (1, 10) requested
      logInfo "search: tavily request" $
        object ["query" .= q, "max_results" .= maxR]
      eres <- searchWeb q maxR
      case eres of
        Left err -> do
          logAttention "search: tavily failed" $ object ["error" .= err]
          pure (readResult (Left err))
        Right v -> do
          logInfo "search: tavily ok" $
            object
              [ "result_count" .= countResults v
              ]
          pure (readResult (Right v))
  where
    countResults v = case parseEither extractCount v of
      Right n -> n
      Left _ -> -1

    extractCount :: Value -> Parser Int
    extractCount = withObject "out" $ \o -> do
      rs <- o .: "results" :: Parser [Value]
      pure (length rs)
