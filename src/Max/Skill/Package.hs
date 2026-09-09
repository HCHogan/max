-- | Versioned skill content, without storage, tools or execution capabilities.
module Max.Skill.Package
  ( SkillPackage (..),
    Workflow (..),
    PinnedPackage (..),
    emptyPackage,
    validatePackage,
    validatePackageName,
    packageInstructions,
    packageDependencies,
  )
where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isDigit)
import Data.Foldable (traverse_)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Skill.Contract (validateContract)

data Workflow = Workflow
  { wfDescription :: !Text,
    wfSource :: !Text,
    wfInput :: !Value,
    wfOutput :: !Value,
    wfTools :: ![Text]
  }
  deriving stock (Show, Eq)

data SkillPackage = SkillPackage
  { spDependencies :: ![Text],
    spWorkflows :: !(Map Text Workflow)
  }
  deriving stock (Show, Eq)

-- This value is minted by the loader and persisted only in trusted receipts.
data PinnedPackage = PinnedPackage
  { ppRevision :: !Integer,
    ppContent :: !SkillPackage,
    ppContracts :: !(Map Text Text)
  }
  deriving stock (Show, Eq)

emptyPackage :: SkillPackage
emptyPackage = SkillPackage [] Map.empty

instance ToJSON Workflow where
  toJSON w = object ["description" .= w.wfDescription, "source" .= w.wfSource, "input" .= w.wfInput, "output" .= w.wfOutput, "tools" .= w.wfTools]

instance FromJSON Workflow where
  parseJSON = withObject "workflow" $ \o -> do
    unless (all (`elem` ["description", "source", "input", "output", "tools"]) (KM.keys o)) (fail "unknown workflow field")
    Workflow <$> o .: "description" <*> o .: "source" <*> o .: "input" <*> o .: "output" <*> o .: "tools"

instance ToJSON SkillPackage where
  toJSON p = object ["dependencies" .= p.spDependencies, "workflows" .= p.spWorkflows]

instance FromJSON SkillPackage where
  parseJSON = withObject "skill package" $ \o -> do
    unless (all (`elem` ["dependencies", "workflows"]) (KM.keys o)) (fail "unknown package field")
    p <- SkillPackage <$> o .:? "dependencies" .!= [] <*> o .:? "workflows" .!= Map.empty
    either (fail . T.unpack) (const (pure p)) (validatePackage p)

instance ToJSON PinnedPackage where
  toJSON p = object ["revision" .= p.ppRevision, "content" .= p.ppContent, "contracts" .= p.ppContracts]

instance FromJSON PinnedPackage where
  parseJSON = withObject "pinned package" $ \o -> PinnedPackage <$> o .: "revision" <*> o .: "content" <*> o .: "contracts"

validatePackage :: SkillPackage -> Either Text ()
validatePackage p = do
  when (LBS.length (encode p) > 262144) (Left "skill package exceeds 256 KiB")
  -- JSONB cannot store NUL; source must never be silently rewritten at journal admission.
  when (containsNul (toJSON p)) (Left "skill package cannot contain NUL")
  when (length p.spDependencies > 16 || length (nub p.spDependencies) /= length p.spDependencies) (Left "dependencies must be unique, at most 16")
  traverse_ validatePackageName p.spDependencies
  when (Map.size p.spWorkflows > 8) (Left "skill package has more than 8 workflows")
  traverse_ validateWorkflow (Map.toList p.spWorkflows)
  where
    validateWorkflow (name, w) = do
      validatePackageName name
      when (T.null (T.strip w.wfDescription) || T.length w.wfDescription > 240) (Left "workflow description must contain 1..240 characters")
      when (T.null (T.strip w.wfSource) || LBS.length (LBS.fromStrict (TE.encodeUtf8 w.wfSource)) > 65536) (Left "workflow source must contain 1..65536 UTF-8 bytes")
      when (length w.wfTools > 64 || nub w.wfTools /= w.wfTools) (Left "workflow tool requirements must be unique, at most 64")
      traverse_ (\name' -> when (T.null name' || T.length name' > 256 || name' == "run_code") (Left "invalid workflow tool requirement")) w.wfTools
      validateContract w.wfInput
      validateContract w.wfOutput

packageDependencies :: SkillPackage -> [Text]
packageDependencies p = nub (p.spDependencies <> ["codemode" | not (Map.null p.spWorkflows)])

-- Complete invocation contracts, without repeatedly putting executable source in context.
packageInstructions :: Text -> SkillPackage -> Text
packageInstructions name p
  | Map.null p.spWorkflows = ""
  | otherwise =
      "\n\n已保存工作流（run_code 使用 workflow 和 args；执行本次加载固定的版本）：\n"
        <> TE.decodeUtf8 (LBS.toStrict (encode [object ["workflow" .= (name <> "/" <> entry), "description" .= w.wfDescription, "input" .= w.wfInput, "output" .= w.wfOutput, "tools" .= w.wfTools] | (entry, w) <- Map.toList p.spWorkflows]))

containsNul :: Value -> Bool
containsNul (String value) = T.any (== '\0') value
containsNul (Object fields) = any (T.any (== '\0') . Key.toText) (KM.keys fields) || any containsNul fields
containsNul (Array values) = any containsNul values
containsNul _ = False

validatePackageName :: Text -> Either Text ()
validatePackageName name = unless (not (T.null name) && T.length name <= 64 && T.all (\c -> isAsciiLower c || isDigit c || c `elem` ['-', '_']) name) (Left "package names require lowercase ASCII letters, digits, - or _")
