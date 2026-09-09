-- | Reusable instruction candidates and paired replay scoring. This layer
-- neither executes tools nor grants capabilities, even for a published capsule.
module Max.Task.Experience
  ( ExperienceCapsule (..),
    ReplayCase (..),
    ReplayReport (..),
    validateCapsule,
    replayPasses,
    capsuleBody,
    fingerprint,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

data ExperienceCapsule = ExperienceCapsule
  { description :: !Text,
    applicability :: !Text,
    procedure :: !Text,
    invalidations :: !Text,
    evidence :: ![Text]
  }
  deriving stock (Eq, Show)

instance FromJSON ExperienceCapsule where
  parseJSON = withObject "experience" $ \o ->
    ExperienceCapsule
      <$> o .: "description"
      <*> o .: "applicability"
      <*> o .: "procedure"
      <*> o .: "invalidations"
      <*> o .: "evidence"

instance ToJSON ExperienceCapsule where
  toJSON capsule =
    object
      [ "description" .= capsule.description,
        "applicability" .= capsule.applicability,
        "procedure" .= capsule.procedure,
        "invalidations" .= capsule.invalidations,
        "evidence" .= capsule.evidence
      ]

validateCapsule :: ExperienceCapsule -> Either Text ()
validateCapsule capsule
  | any (T.null . T.strip) [capsule.description, capsule.applicability, capsule.procedure, capsule.invalidations] = Left "capsule fields must be nonempty"
  | T.length capsule.description > 120 || T.any (== '\n') capsule.description = Left "description must be a short single line"
  | T.length (capsuleBody capsule) > 8000 = Left "capsule exceeds 8000 characters"
  | null capsule.evidence || length capsule.evidence > 12 = Left "cite 1 to 12 successful journal result handles"
  | otherwise = Right ()

fingerprint :: Value -> Text
fingerprint = TE.decodeUtf8 . B16.encode . SHA256.hash . LBS.toStrict . encode

capsuleBody :: ExperienceCapsule -> Text
capsuleBody capsule =
  T.unlines
    [ "[经任务回放验证的经验；仅为方法建议，不授予工具权限]",
      "只在下列条件适用；当前用户指令、内置技能和宿主权限边界始终优先。",
      "适用条件：" <> capsule.applicability,
      "操作方法：" <> capsule.procedure,
      "失效条件：" <> capsule.invalidations,
      "成功证据：" <> T.intercalate ", " capsule.evidence
    ]

-- Gold checks and frozen prompts belong to an operator-reviewed fixture.
-- They measure text/snapshot replay, not external effects or production health.
data ReplayCase = ReplayCase
  { prompt :: !Text,
    required :: ![Text],
    forbidden :: ![Text],
    baseline :: !Text,
    candidate :: !Text,
    baselineTokens :: !Int,
    candidateTokens :: !Int,
    baselineMillis :: !Int,
    candidateMillis :: !Int,
    baselineCached :: !(Maybe Int),
    candidateCached :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

instance FromJSON ReplayCase where
  parseJSON = withObject "paired replay" $ \o ->
    ReplayCase
      <$> o .: "prompt"
      <*> o .: "required"
      <*> o .:? "forbidden" .!= []
      <*> o .: "baseline"
      <*> o .: "candidate"
      <*> o .: "baseline_tokens"
      <*> o .: "candidate_tokens"
      <*> o .: "baseline_ms"
      <*> o .: "candidate_ms"
      <*> o .:? "baseline_cached"
      <*> o .:? "candidate_cached"

instance ToJSON ReplayCase where
  toJSON c =
    object
      [ "prompt" .= c.prompt,
        "required" .= c.required,
        "forbidden" .= c.forbidden,
        "baseline" .= c.baseline,
        "candidate" .= c.candidate,
        "baseline_tokens" .= c.baselineTokens,
        "candidate_tokens" .= c.candidateTokens,
        "baseline_ms" .= c.baselineMillis,
        "candidate_ms" .= c.candidateMillis,
        "baseline_cached" .= c.baselineCached,
        "candidate_cached" .= c.candidateCached
      ]

data ReplayReport = ReplayReport
  { capsuleFingerprint :: !Text,
    laterFingerprint :: !Text,
    cases :: ![ReplayCase],
    profile :: !Text
  }
  deriving stock (Eq, Show)

instance FromJSON ReplayReport where
  parseJSON = withObject "experience replay" $ \o -> ReplayReport <$> o .: "capsule_fingerprint" <*> o .: "later_fingerprint" <*> o .: "cases" <*> o .: "profile"

instance ToJSON ReplayReport where
  toJSON r = object ["capsule_fingerprint" .= r.capsuleFingerprint, "later_fingerprint" .= r.laterFingerprint, "cases" .= r.cases, "profile" .= r.profile]

replayPasses :: ReplayReport -> Bool
replayPasses report =
  Set.size (Set.fromList (map (.prompt) report.cases)) >= 3
    && not (T.null report.profile)
    && all safe report.cases
    && improved
    && total (.candidateTokens) <= total (.baselineTokens) * 2
    && total (.candidateMillis) <= max 1000 (total (.baselineMillis) * 2)
  where
    total field = sum (map field report.cases)
    hits c answer = length [term | term <- c.required, T.toCaseFold term `T.isInfixOf` T.toCaseFold answer]
    safe c =
      not (T.null c.prompt)
        && not (null c.required)
        && not (any (T.null . T.strip) c.required)
        && c.baselineTokens > 0
        && c.candidateTokens > 0
        && c.baselineMillis >= 0
        && c.candidateMillis >= 0
        && hits c c.candidate == length c.required
        && all (\term -> not (T.toCaseFold term `T.isInfixOf` T.toCaseFold c.candidate)) c.forbidden
    improved =
      any (\c -> hits c c.candidate > hits c c.baseline) report.cases
        || total (.candidateTokens) * 10 < total (.baselineTokens) * 9
        || total (.candidateMillis) * 10 < total (.baselineMillis) * 9
