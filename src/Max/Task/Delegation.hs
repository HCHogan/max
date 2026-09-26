-- | Closed request and normalized report for awaited workflow children.
-- These values describe requested work; they never grant authority.
module Max.Task.Delegation
  ( AgentRequest (..),
    parseAgentRequest,
    parseJobResult,
  )
where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Skill.Contract (Contract, validateValue)
import Max.Task.Types

data AgentRequest = AgentRequest
  { objective :: !Text,
    inputs :: !Value,
    profile :: !TaskProfile,
    outputContract :: !(Maybe Contract)
  }
  deriving stock (Eq, Show)

instance ToJSON AgentRequest where
  toJSON request = object ["objective" .= request.objective, "inputs" .= request.inputs, "profile" .= profileName request.profile, "output_contract" .= request.outputContract]

parseAgentRequest :: Value -> Either Text AgentRequest
parseAgentRequest raw = do
  request <-
    either (Left . T.pack) Right $
      parseEither
        ( withObject "agent request" $ \o -> do
            unless (all (`elem` ["objective", "inputs", "profile", "output_contract"]) (KM.keys o)) (fail "unknown agent argument")
            name <- o .: "profile"
            profile <- maybe (fail "unknown capability profile") pure (parseProfile name)
            AgentRequest . T.strip <$> o .: "objective" <*> o .:? "inputs" .!= Null <*> pure profile <*> o .:? "output_contract"
        )
        raw
  unless (not (T.null request.objective) && T.length request.objective <= 40000 && LBS.length (encode raw) <= 65536) (Left "agent objective/input exceeds its bound")
  pure request

parseJobResult :: JobSpec -> Text -> Either Text JobResult
parseJobResult spec body = do
  when (T.null (T.strip body)) (Left "job response is empty")
  when (T.length body > reportLimit) (Left ("job response exceeds " <> T.pack (show reportLimit) <> " characters"))
  case spec.contract of
    Nothing -> Right (JobResult body Nothing)
    Just contract -> do
      payload <- either (Left . T.pack) Right (eitherDecodeStrict' (TE.encodeUtf8 (unfence body)))
      validateValue contract payload
      summary <- case spec.monitor of
        Nothing -> Right body
        Just _ -> do
          (summary, observation) <- either (Left . T.pack) Right $ parseEither (withObject "monitor result" $ \fields -> (,) <$> fields .: "summary" <*> fields .: "observation") payload
          case observation of
            Object fields | not (KM.null fields) && not (T.null (T.strip summary)) -> Right summary
            _ -> Left "change-only reminder requires a nonempty observation and summary"
      Right (JobResult summary (Just payload))

reportLimit :: Int
reportLimit = 100000

-- | Models often wrap contract JSON in a Markdown fence; the fence is not data.
unfence :: Text -> Text
unfence body = case T.stripPrefix "```" (T.strip body) of
  Just rest
    | Just inner <- T.stripSuffix "```" (T.strip rest) -> T.drop 1 (T.dropWhile (/= '\n') inner)
  _ -> body
