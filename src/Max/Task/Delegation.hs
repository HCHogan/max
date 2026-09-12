-- | Closed request and normalized report for awaited workflow children.
-- These values describe requested work; they never grant authority.
module Max.Task.Delegation
  ( AgentRequest (..),
    parseAgentRequest,
    agentCallKey,
    agentReport,
    validateAgentPayload,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as T
import Max.Skill.Contract (validateContract, validateValue)
import Max.Task.Experience (fingerprint)
import Max.Task.State
import Max.Task.Types

data AgentRequest = AgentRequest
  { objective :: !Text,
    inputs :: !Value,
    profile :: !TaskProfile,
    outputContract :: !(Maybe Value)
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
  traverse_ validateContract request.outputContract
  pure request

-- Source edits create new journal steps. Unchanged semantic calls can still
-- reuse their child in the same parent revision. Loaded receipts are part of
-- the call identity, so a package update invalidates that reuse.
agentCallKey :: Value -> AgentRequest -> Text
agentCallKey receipts request = "agent:" <> fingerprint (object ["receipts" .= receipts, "request" .= request])

validateAgentPayload :: Maybe Value -> TaskReport -> Either Text ()
validateAgentPayload Nothing _ = Right ()
validateAgentPayload (Just contract) report
  | report.status == ReportSucceeded = maybe (Left "succeeded requires payload for the requested output_contract") (validateValue contract) report.payload
  | otherwise = traverse_ (validateValue contract) report.payload

agentReport :: TaskStatus -> TaskReport -> Maybe Value -> Value
agentReport status report contract =
  object
    [ "status" .= status,
      "findings" .= report.summary,
      "evidence" .= report.evidence,
      "unresolved" .= report.unresolved,
      "payload" .= (if validateAgentPayload contract report == Right () then report.payload else Nothing),
      "payload_valid" .= either (const False) (const True) (validateAgentPayload contract report)
    ]
