-- |
-- Minimal OpenAI-compatible embeddings client (@POST {base}/embeddings@).
-- Plain-IO handle in the style of "Max.MCP.Client": the worker and the
-- search tools call it via 'liftIO'; request execution is injected from
-- "Max.HttpRuntime", with no extra effect wrapper or private manager.
--
-- Works against any endpoint speaking the OpenAI embeddings shape —
-- cloud (OpenAI, siliconflow, jina) or local (Ollama's @/v1@ compat
-- layer, LM Studio, llama.cpp server).  @api_key@ is optional because
-- local servers don't check one.
module Max.Embedding
  ( EmbeddingConfig (..),
    EmbedClient,
    newEmbedClient,
    embedTexts,
    renderVector,
    -- * Exposed for tests
    embeddingRequest,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.HttpRuntime
  ( BufferedResponse (body),
    HttpPool (StandardPool),
    HttpRuntime,
    TransportFailure (..),
    parseRequestEither,
    renderTransportFailure,
    runBuffered,
  )
import Network.HTTP.Client
  ( Request (..),
    RequestBody (..),
    responseTimeoutMicro,
  )

-- | From the optional @embedding@ config section; presence enables
-- the embed worker and the semantic search surfaces.
data EmbeddingConfig = EmbeddingConfig
  { -- | e.g. @https://api.siliconflow.cn/v1@ or @http://127.0.0.1:11434/v1@ (Ollama).
    ecBaseUrl :: !Text,
    ecApiKey :: !(Maybe Text),
    -- | e.g. @bge-m3@ / @qwen3-embedding@ / @text-embedding-3-small@.
    ecModel :: !Text,
    ecTimeoutSeconds :: !Int
  }
  deriving stock (Show)

data EmbedClient = EmbedClient
  { emCfg :: !EmbeddingConfig,
    emHttp :: !HttpRuntime
  }

newEmbedClient :: HttpRuntime -> EmbeddingConfig -> EmbedClient
newEmbedClient runtime cfg = EmbedClient cfg runtime

-- | Embed a batch of texts; the result list lines up with the input
-- (the API's @index@ field is respected, not assumed).
embedTexts :: EmbedClient -> [Text] -> IO (Either Text [[Float]])
embedTexts _ [] = pure (Right [])
embedTexts c texts = do
  let cfg = c.emCfg
  ereq <- embeddingRequest cfg texts
  case ereq of
    Left failure -> pure (Left ("bad embedding url: " <> renderTransportFailure failure))
    Right request ->
      runBuffered c.emHttp StandardPool maxEmbeddingResponseBytes statusPreviewBytes request >>= \case
        Left (HttpStatusFailure code _ responsePreview _) ->
          pure . Left $
            "embedding HTTP "
              <> T.pack (show code)
              <> ": "
              <> T.take 300 (TE.decodeUtf8Lenient responsePreview)
        Left failure ->
          pure (Left ("embedding request failed: " <> renderTransportFailure failure))
        Right response ->
          pure $ case eitherDecodeStrict' response.body >>= parseEither embeddingsP of
            Left err -> Left ("embedding parse: " <> T.pack err)
            Right vectors
              | length vectors /= length texts ->
                  Left "embedding count mismatch"
              | otherwise -> Right vectors

embeddingRequest :: EmbeddingConfig -> [Text] -> IO (Either TransportFailure Request)
embeddingRequest cfg texts = do
  let url = T.unpack (T.dropWhileEnd (== '/') cfg.ecBaseUrl) <> "/embeddings"
      body = encode (object ["model" .= cfg.ecModel, "input" .= texts])
  fmap
    ( fmap $ \request0 ->
        request0
          { method = "POST",
            requestHeaders =
              [("Content-Type", "application/json")]
                <> [ ("Authorization", "Bearer " <> TE.encodeUtf8 key)
                   | Just key <- [cfg.ecApiKey]
                   ],
            requestBody = RequestBodyLBS body,
            responseTimeout = responseTimeoutMicro (cfg.ecTimeoutSeconds * 1_000_000)
          }
    )
    (parseRequestEither url)

embeddingsP :: Value -> Parser [[Float]]
embeddingsP = withObject "resp" $ \o -> do
  rows <- o .: "data"
  indexed <- traverse rowP rows
  pure (map snd (sortOn fst indexed))
  where
    rowP = withObject "row" $ \r -> do
      i <- r .: "index" :: Parser Int
      e <- r .: "embedding"
      pure (i, e)

-- | pgvector text literal — bind as a parameter and cast @?::vector@.
renderVector :: [Float] -> Text
renderVector xs = "[" <> T.intercalate "," (map (T.pack . show) xs) <> "]"

maxEmbeddingResponseBytes :: Int
maxEmbeddingResponseBytes = 64 * 1024 * 1024

statusPreviewBytes :: Int
statusPreviewBytes = 1024
