-- |
-- Minimal OpenAI-compatible embeddings client (@POST {base}/embeddings@).
-- Plain-IO handle in the style of "Max.MCP.Client": the worker and the
-- search tools call it via 'liftIO'; no effect wrapper needed for a
-- pure request/response client.
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
  )
where

import Control.Exception (SomeException)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Util (trySyncIO)
import Network.HTTP.Client
  ( Manager,
    Request (..),
    RequestBody (..),
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

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
    emManager :: !Manager
  }

newEmbedClient :: EmbeddingConfig -> IO EmbedClient
newEmbedClient cfg = EmbedClient cfg <$> newManager tlsManagerSettings

-- | Embed a batch of texts; the result list lines up with the input
-- (the API's @index@ field is respected, not assumed).
embedTexts :: EmbedClient -> [Text] -> IO (Either Text [[Float]])
embedTexts _ [] = pure (Right [])
embedTexts c texts = do
  let cfg = c.emCfg
      url = T.unpack (T.dropWhileEnd (== '/') cfg.ecBaseUrl) <> "/embeddings"
      body = encode (object ["model" .= cfg.ecModel, "input" .= texts])
  ereq <- trySyncIO (parseRequest ("POST " <> url))
  case ereq of
    Left (e :: SomeException) -> pure (Left ("bad embedding url: " <> T.pack (show e)))
    Right req0 -> do
      let req =
            req0
              { requestHeaders =
                  [("Content-Type", "application/json")]
                    <> [ ("Authorization", "Bearer " <> TE.encodeUtf8 k)
                       | Just k <- [cfg.ecApiKey]
                       ],
                requestBody = RequestBodyLBS body,
                responseTimeout = responseTimeoutMicro (cfg.ecTimeoutSeconds * 1_000_000)
              }
      eresp <- trySyncIO (httpLbs req c.emManager)
      pure $ case eresp of
        Left (e :: SomeException) -> Left ("embedding request failed: " <> T.pack (show e))
        Right resp ->
          let code = statusCode (responseStatus resp)
              rbody = responseBody resp
           in if code >= 400
                then
                  Left $
                    "embedding HTTP "
                      <> T.pack (show code)
                      <> ": "
                      <> T.take 300 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
                else case eitherDecode rbody >>= parseEither embeddingsP of
                  Left e -> Left ("embedding parse: " <> T.pack e)
                  Right vs
                    | length vs /= length texts ->
                        Left "embedding count mismatch"
                    | otherwise -> Right vs

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
