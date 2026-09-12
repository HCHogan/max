-- | Draft content and validation facts. No persistence or execution authority.
module Max.Skill.Authoring
  ( DraftContent (..),
    Fixture (..),
    FixtureCall (..),
    DraftVersion (..),
    ValidationReport (..),
    validateDraft,
    validatorVersion,
    validationPassed,
    validationContext,
    authoredTools,
    draftDiff,
  )
where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.Skill.Contract (validateValue)
import Max.Skill.Metadata (validateSkillText)
import Max.Skill.Package

data FixtureCall = FixtureCall {fcTool :: !Text, fcArgs :: !Value, fcResult :: !(Either Text Value)} deriving stock (Show, Eq)

data Fixture = Fixture {fxEntry :: !Text, fxArgs :: !Value, fxCalls :: ![FixtureCall], fxExpected :: !Value} deriving stock (Show, Eq)

data DraftContent = DraftContent {dcName :: !Text, dcDescription :: !Text, dcBody :: !Text, dcPackage :: !SkillPackage, dcFixtures :: ![Fixture]} deriving stock (Show, Eq)

data DraftVersion = DraftVersion {dvRevision :: !Integer, dvContent :: !DraftContent} deriving stock (Show, Eq)

newtype ValidationReport = ValidationReport {vrFailures :: [Text]} deriving stock (Show, Eq)

instance ToJSON FixtureCall where
  toJSON c = object $ ["tool" .= c.fcTool, "args" .= c.fcArgs] <> either (\e -> ["error" .= e]) (\v -> ["result" .= v]) c.fcResult

instance FromJSON FixtureCall where
  parseJSON = withObject "fixture call" $ \o -> do
    unless (all (`elem` ["tool", "args", "error", "result"]) (KM.keys o)) (fail "unknown fixture call field")
    result <- case (KM.lookup "result" o, KM.lookup "error" o) of
      (Just value, Nothing) -> pure (Right value)
      (Nothing, Just (String err)) -> pure (Left err)
      _ -> fail "exactly one of result or error is required"
    FixtureCall <$> o .: "tool" <*> o .: "args" <*> pure result

instance ToJSON Fixture where
  toJSON f = object ["entry" .= f.fxEntry, "args" .= f.fxArgs, "calls" .= f.fxCalls, "expected" .= f.fxExpected]

instance FromJSON Fixture where
  parseJSON = withObject "fixture" $ \o -> do
    unless (all (`elem` ["entry", "args", "calls", "expected"]) (KM.keys o)) (fail "unknown fixture field")
    Fixture <$> o .: "entry" <*> o .: "args" <*> o .: "calls" <*> o .: "expected"

instance ToJSON DraftContent where
  toJSON d = object ["name" .= d.dcName, "description" .= d.dcDescription, "body" .= d.dcBody, "package" .= d.dcPackage, "fixtures" .= d.dcFixtures]

instance FromJSON DraftContent where
  parseJSON = withObject "draft" $ \o -> do
    unless (all (`elem` ["name", "description", "body", "package", "fixtures"]) (KM.keys o)) (fail "unknown draft field")
    DraftContent <$> o .: "name" <*> o .: "description" <*> o .: "body" <*> o .: "package" <*> o .: "fixtures"

instance ToJSON DraftVersion where
  toJSON v = object ["revision" .= v.dvRevision, "content" .= v.dvContent]

instance ToJSON ValidationReport where
  toJSON r = object ["passed" .= validationPassed r, "failures" .= r.vrFailures]

instance FromJSON ValidationReport where
  parseJSON = withObject "validation report" $ \o -> ValidationReport <$> o .: "failures"

validatorVersion :: Text
validatorVersion = "skill-fixtures/v2"

validationPassed :: ValidationReport -> Bool
validationPassed = null . vrFailures

validateDraft :: DraftContent -> Either Text ()
validateDraft d = do
  validateSkillText d.dcName d.dcDescription d.dcBody
  validatePackageName d.dcName
  validatePackage d.dcPackage
  when (LBS.length (encode d) > 512 * 1024) (Left "draft exceeds 512 KiB")
  when (containsNul (toJSON d)) (Left "draft cannot contain NUL")
  unless (length d.dcFixtures <= 16) (Left "at most 16 fixtures")
  unless (all (`elem` map (.fxEntry) d.dcFixtures) (Map.keys d.dcPackage.spWorkflows)) (Left "every workflow requires a fixture")
  traverse_ checkFixture d.dcFixtures
  where
    checkFixture f = do
      workflow <- maybe (Left "fixture names missing workflow") Right (Map.lookup f.fxEntry d.dcPackage.spWorkflows)
      validateValue workflow.wfInput f.fxArgs
      validateValue workflow.wfOutput f.fxExpected
      unless (length f.fxCalls <= 32) (Left "at most 32 calls per fixture")
      traverse_ (\c -> unless ((case c.fcTool of "agent" -> "task_start"; "phase" -> "task_progress"; name -> name) `elem` workflow.wfTools) (Left "fixture tool is not declared")) f.fxCalls
    containsNul (String value) = T.any (== '\0') value
    containsNul (Array values) = any containsNul values
    containsNul (Object fields) = any containsNul (KM.elems fields) || any (T.any (== '\0') . Key.toText) (KM.keys fields)
    containsNul _ = False

authoredTools :: SkillPackage -> [Text]
authoredTools = nub . concatMap (.wfTools) . Map.elems . (.spWorkflows)

validationContext :: Integer -> PublicationContract -> Value
validationContext revision contract = object ["validator" .= validatorVersion, "draft_revision" .= revision, "evidence" .= ValidatedSkill contract]

-- Bounded structural diff; full source remains an explicit exact-version read.
draftDiff :: DraftContent -> DraftContent -> Value
draftDiff before after =
  object
    [ "fields"
        .= changed
          [ ("description", before.dcDescription /= after.dcDescription),
            ("body", before.dcBody /= after.dcBody),
            ("dependencies", before.dcPackage.spDependencies /= after.dcPackage.spDependencies),
            ("fixtures", before.dcFixtures /= after.dcFixtures)
          ],
      "workflows" .= [entry name old new | name <- Map.keys (oldWork <> newWork), let old = Map.lookup name oldWork, let new = Map.lookup name newWork, old /= new]
    ]
  where
    oldWork = before.dcPackage.spWorkflows
    newWork = after.dcPackage.spWorkflows
    changed :: [(Text, Bool)] -> [Text]
    changed values = [name | (name, True) <- values]
    entry name (Just old) (Just new) =
      object
        [ "entry" .= name,
          "change" .= ("modified" :: Text),
          "fields" .= changed [("description", old.wfDescription /= new.wfDescription), ("source", old.wfSource /= new.wfSource), ("input", old.wfInput /= new.wfInput), ("output", old.wfOutput /= new.wfOutput), ("tools", old.wfTools /= new.wfTools)]
        ]
    entry name old _ = object ["entry" .= name, "change" .= (maybe "added" (const "removed") old :: Text)]
