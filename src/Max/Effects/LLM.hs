{-# LANGUAGE TypeFamilies #-}

module Max.Effects.LLM
  ( LLM,
    LLMConfig (..),
    ChatMessage (..),
    runLLM,
    chat,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log
import Network.HTTP.Client
  ( Manager,
    Response,
    RequestBody (RequestBodyLBS),
    httpLbs,
    method,
    newManager,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeout,
    responseTimeoutMicro,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)

data LLMConfig = LLMConfig
  { -- | e.g. @https://api.deepseek.com/v1@. We append @/chat/completions@.
    baseUrl :: !Text,
    apiKey :: !Text,
    -- | Model id; @deepseek-chat@, @gpt-4o-mini@, @qwen2.5:7b@, etc.
    model :: !Text,
    maxTokens :: !Int,
    temperature :: !Double,
    -- | HTTP timeout for one chat completion. LLMs are slow, default 120.
    timeoutSeconds :: !Int
  }
  deriving stock (Show)

data ChatMessage = ChatMessage
  { -- | @system@ | @user@ | @assistant@
    role :: !Text,
    content :: !Text
  }
  deriving stock (Show)

instance ToJSON ChatMessage where
  toJSON m = object ["role" .= m.role, "content" .= m.content]

data LLM :: Effect where
  Chat :: [ChatMessage] -> LLM m (Either Text Text)

type instance DispatchOf LLM = Dynamic

-- | Interpreter holds its own 'Manager' so the LLM's HTTP stack is
-- independent from the image worker's (different latency profile,
-- different timeout, different host pool).
runLLM ::
  (Log :> es, IOE :> es) =>
  LLMConfig ->
  Eff (LLM : es) a ->
  Eff es a
runLLM cfg m = do
  mgr <- liftIO (newManager tlsManagerSettings)
  interpret
    ( \_ -> \case
        Chat msgs -> do
          logInfo "llm: chat request" $
            object
              [ "msg_count" .= length msgs,
                "model" .= cfg.model
              ]
          r <- liftIO (callChat mgr cfg msgs)
          case r of
            Left err ->
              logAttention "llm: error" $ object ["error" .= err]
            Right text ->
              logInfo "llm: got response" $
                object ["len" .= T.length text]
          pure r
    )
    m

chat :: LLM :> es => [ChatMessage] -> Eff es (Either Text Text)
chat msgs = send (Chat msgs)

-- | OpenAI-compatible @POST {baseUrl}/chat/completions@.
callChat :: Manager -> LLMConfig -> [ChatMessage] -> IO (Either Text Text)
callChat mgr cfg msgs = do
  let body =
        object
          [ "model" .= cfg.model,
            "messages" .= msgs,
            "max_tokens" .= cfg.maxTokens,
            "temperature" .= cfg.temperature,
            "stream" .= False
          ]
  req0 <- parseRequest (T.unpack (cfg.baseUrl <> "/chat/completions"))
  let req =
        req0
          { method = "POST",
            requestHeaders =
              [ ("Authorization", "Bearer " <> TE.encodeUtf8 cfg.apiKey),
                ("Content-Type", "application/json")
              ],
            requestBody = RequestBodyLBS (encode body),
            responseTimeout = responseTimeoutMicro (cfg.timeoutSeconds * 1_000_000)
          }
  eres <- try (httpLbs req mgr)
  case eres :: Either SomeException (Response LBS.ByteString) of
    Left e -> pure (Left ("http: " <> T.pack (show e)))
    Right resp ->
      let code = statusCode (responseStatus resp)
          rbody = responseBody resp
       in if code >= 400
            then
              pure $
                Left $
                  "HTTP "
                    <> T.pack (show code)
                    <> ": "
                    <> T.take 500 (TE.decodeUtf8Lenient (LBS.toStrict rbody))
            else case eitherDecode rbody of
              Left e -> pure (Left ("parse: " <> T.pack e))
              Right v -> case parseEither extractContent v of
                Left e -> pure (Left ("extract: " <> T.pack e))
                Right t -> pure (Right t)

-- | Pull @choices[0].message.content@ from an OpenAI-style chat response.
extractContent :: Value -> Parser Text
extractContent = withObject "ChatResponse" $ \o -> do
  choices <- o .: "choices"
  case choices of
    (c : _) -> withObject "Choice" choiceContent c
    [] -> fail "no choices in response"
  where
    choiceContent o' = do
      msg <- o' .: "message"
      withObject "Message" (\m -> m .: "content") msg
