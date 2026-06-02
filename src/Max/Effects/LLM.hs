{-# LANGUAGE TypeFamilies #-}

-- |
-- Multi-profile OpenAI-compatible chat client.  The interpreter holds
-- a map of named 'LLMProfile's (each one has its own api_key,
-- base_url, model, etc.); callers pick which profile to use per call.
--
-- The Agent layer (Phase 6b) sits on top of this; this effect stays
-- raw — one HTTP request in, structured response out, no looping.
module Max.Effects.LLM
  ( LLM,
    LLMProfile (..),
    LLMRegistry (..),
    ChatMessage (..),
    runLLM,
    chat,
    listProfiles,
    defaultProfile,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    Response,
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

-- | A single named LLM endpoint.  Materialized from
-- @[llm.profiles.<name>]@ in TOML.
data LLMProfile = LLMProfile
  { -- | e.g. @https://api.deepseek.com/v1@.  We append @/chat/completions@.
    baseUrl :: !Text,
    apiKey :: !Text,
    -- | Model id; @deepseek-chat@, @gpt-4o-mini@, @qwen2.5:7b@, etc.
    model :: !Text,
    maxTokens :: !Int,
    temperature :: !Double,
    -- | HTTP timeout for one chat completion.  LLMs are slow, default 120.
    timeoutSeconds :: !Int
  }
  deriving stock (Show)

-- | The full profile registry: the name of the default profile + every
-- known profile keyed by name.  'runLLM' takes one of these; everything
-- downstream picks profiles by name.
data LLMRegistry = LLMRegistry
  { defaultName :: !Text,
    profiles :: !(Map Text LLMProfile)
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

instance FromJSON ChatMessage where
  parseJSON = withObject "ChatMessage" $ \o ->
    ChatMessage <$> o .: "role" <*> o .: "content"

data LLM :: Effect where
  -- | Run one chat completion against the named profile.
  Chat :: Text -> [ChatMessage] -> LLM m (Either Text Text)
  -- | List configured profile names (so commands like @!model list@
  -- have something to enumerate).
  ListProfiles :: LLM m [Text]
  -- | The default profile name, for command resolution.
  DefaultProfile :: LLM m Text

type instance DispatchOf LLM = Dynamic

-- | One 'Manager' shared across all profiles — they're all just HTTPS
-- endpoints, so we don't gain anything by pooling per host.
runLLM ::
  (Log :> es, IOE :> es) =>
  LLMRegistry ->
  Eff (LLM : es) a ->
  Eff es a
runLLM reg m = do
  mgr <- liftIO (newManager tlsManagerSettings)
  interpret
    ( \_ -> \case
        Chat name msgs -> case Map.lookup name reg.profiles of
          Nothing -> do
            logAttention "llm: unknown profile" $ object ["profile" .= name]
            pure $ Left ("unknown llm profile: " <> name)
          Just cfg -> do
            logInfo "llm: chat request" $
              object
                [ "msg_count" .= length msgs,
                  "profile" .= name,
                  "model" .= cfg.model
                ]
            r <- liftIO (callChat mgr cfg msgs)
            case r of
              Left err ->
                logAttention "llm: error" $
                  object ["error" .= err, "profile" .= name]
              Right text ->
                logInfo "llm: got response" $
                  object ["len" .= T.length text, "profile" .= name]
            pure r
        ListProfiles -> pure (Map.keys reg.profiles)
        DefaultProfile -> pure reg.defaultName
    )
    m

chat :: LLM :> es => Text -> [ChatMessage] -> Eff es (Either Text Text)
chat name msgs = send (Chat name msgs)

listProfiles :: LLM :> es => Eff es [Text]
listProfiles = send ListProfiles

defaultProfile :: LLM :> es => Eff es Text
defaultProfile = send DefaultProfile

-- | OpenAI-compatible @POST {baseUrl}/chat/completions@.
callChat :: Manager -> LLMProfile -> [ChatMessage] -> IO (Either Text Text)
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
