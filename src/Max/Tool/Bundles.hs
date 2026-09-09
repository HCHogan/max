-- | Fixed instruction/tool ownership. This is visibility metadata, never an
-- authority grant. Loading receipts are host values, not model control JSON.
module Max.Tool.Bundles
  ( SkillLoad (..),
    skillDependencies,
    toolBundle,
    toolVisible,
    mergeSkillLoads,
    skillLoadVersion,
    skillReceiptVersion,
    checkSkillLoadBudget,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON (..), ToJSON (..), Value, encode, object, withObject, (.:), (.:?), (.=))
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Skill.Package (PinnedPackage)

data SkillLoad = SkillLoad
  { slName :: !Text,
    slVersion :: !Text,
    slInstructions :: !Text,
    slMetadata :: !(Maybe Value),
    slPackage :: !(Maybe PinnedPackage)
  }
  deriving stock (Eq, Show)

instance ToJSON SkillLoad where
  toJSON load = object ["name" .= load.slName, "version" .= load.slVersion, "instructions" .= load.slInstructions, "metadata" .= load.slMetadata, "package" .= load.slPackage]

-- Only durable host receipts use this decoder. ToolControl has no JSON decoder.
instance FromJSON SkillLoad where
  parseJSON = withObject "persisted skill load" $ \fields ->
    SkillLoad <$> fields .: "name" <*> fields .: "version" <*> fields .: "instructions" <*> fields .:? "metadata" <*> fields .:? "package"

skillLoadVersion :: Text -> Text
skillLoadVersion = TE.decodeUtf8 . B16.encode . SHA256.hash . TE.encodeUtf8

skillDependencies :: Text -> [Text]
skillDependencies "office" = ["sandbox"]
skillDependencies _ = []

toolBundle :: Text -> Maybe Text
toolBundle name
  | name `elem` ["skill_save", "skill_validate", "skill_inspect", "skill_publish"] = Just "skill-authoring"
  | name == "inspect_source" = Just "self-knowledge"
  | name `elem` ["web_search", "view_zhihu", "view_bilibili"] || "browser_" `T.isPrefixOf` name = Just "web"
  | "sandbox_" `T.isPrefixOf` name || name `elem` ["nix_search", "list_recent_files", "import_file_to_sandbox", "send_image_from_sandbox", "send_file_from_sandbox"] = Just "sandbox"
  | "maxops_" `T.isPrefixOf` name = Just "maxops"
  | otherwise = Nothing

toolVisible :: Map Text SkillLoad -> Text -> Bool
toolVisible loaded = maybe True (`Map.member` loaded) . toolBundle

-- The first successful activation pins instructions/metadata for this execution.
mergeSkillLoads :: Map Text SkillLoad -> [SkillLoad] -> Map Text SkillLoad
mergeSkillLoads old additions = old `Map.union` Map.fromList [(load.slName, load) | load <- additions]

-- Include executable content and pinned contracts, while retaining legacy receipts.
skillReceiptVersion :: SkillLoad -> Text
skillReceiptVersion load = skillLoadVersion $ load.slInstructions <> maybe "" (TE.decodeUtf8 . LBS.toStrict . encode) load.slPackage

-- The same complete-load limit gates activation and authoring publication.
checkSkillLoadBudget :: Map Text SkillLoad -> [SkillLoad] -> Either Text [SkillLoad]
checkSkillLoadBudget previous loads
  | length allLoads > 32 || sum (map (T.length . (.slInstructions)) allLoads) > 120000 || LBS.length (encode allLoads) > 512000 = Left "技能包超过完整加载上限，不能静默截断"
  | otherwise = Right loads
  where
    allLoads = loads <> Map.elems previous
