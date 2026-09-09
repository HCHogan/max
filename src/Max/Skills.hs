{-# LANGUAGE TemplateHaskell #-}

-- |
-- Skills: named instruction packs the model pulls into context on
-- demand — progressive disclosure in the Claude Code sense, sized for
-- a chat bot.  The system prompt carries only a byte-stable index
-- (name + one-line description per skill, rendered by
-- 'Max.Prompt.systemPrompt'); the full body enters the conversation
-- as a @use_skill@ tool result, so it costs tokens only in the
-- dispatches that need it and never destabilises the provider prefix
-- cache.
--
-- Mirrors "Max.Session"'s write-through shape: an in-process cache
-- backed by the @skills@ table, where the cache is authoritative once
-- loaded and every mutation writes through to Postgres before
-- returning.  A row edited behind the registry's back is a skill the
-- bot never sees — the admin API mutates through here, same rule as
-- sessions.  Unlike sessions the whole table rides in one TVar:
-- skills are few, small, and read whole on every dispatch.
--
-- Scoping: @skillGroup Nothing@ is global (every group sees it),
-- @Just g@ confines the skill to one group and shadows a global skill
-- of the same name — a group can specialise a shared recipe without
-- touching it.
--
-- == Builtin skills
--
-- Files under @skills\/@ (self-knowledge, sandbox, web, office, maxops, codemode)
-- are baked into the binary (file-embed, same deployment
-- story as the admin panel's assets) and seeded into the registry
-- with negative ids.  They exist for content that is coupled
-- to the code it ships with — @self-knowledge@ is THIS binary's
-- self-inspection entry point: a navigation map over the embedded
-- source snapshot, plus the live command help and this build's
-- identity spliced in at registry init.  Behaviour, design and
-- architecture questions are answered from the snapshot via
-- @inspect_source@, never from doc copies that would go stale a
-- little more every release.  Builtins are immutable through the API;
-- to hot-fix one without a release, create a DB skill with the same
-- name — shadowing prefers group over DB-global over builtin.
--
-- File format: the first line is the description (the index line),
-- everything after the first blank line is the body.  The name is the
-- filename minus @.md@.
--
-- Caveat: 'embedDir' registers only the files it saw as compile
-- dependencies, so ADDING a file under @skills\/@ does not recompile
-- this module on its own (and @touch@ doesn't either — cabal tracks
-- content hashes).  Make any byte-level change here when adding one.
module Max.Skills
  ( Skill (..),
    SkillRegistry,
    newSkillRegistry,
    loadSkills,
    refreshExperienceSkills,
    skillsForGroup,
    lookupSkill,
    listAllSkills,
    NewSkill (..),
    createSkill,
    updateSkill,
    updateSkillAtRevision,
    deleteSkill,
    publishSkillTransaction,
    validateSkill,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Monad (when)
import Data.Aeson (Result (..), Value, eitherDecodeStrict', fromJSON, toJSON)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), SqlError (..), (:.) (..))
import Effectful
import Effectful.Exception (bracket_, mask_, throwIO, try)
import Effectful.PostgreSQL (WithConnection, execute, query, query_)
import Max.Command.Help (helpText)
import Max.Command.Version (buildIdentityLines, readOsPretty)
import Max.DB.Transaction (withCommittedTransaction)
import Max.Skill.Metadata (validateSkillText)
import Max.Skill.Package (SkillPackage, emptyPackage, validatePackage, validatePackageName)
import OneBot.Types (GroupId (..))
import System.FilePath (dropExtension, takeExtension)

-- | One skill row, cached verbatim.
data Skill = Skill
  { skillId :: !Int64,
    -- | Slug the model passes to @use_skill@; unique within its scope.
    skillName :: !Text,
    -- | 'Nothing' = global.
    skillGroup :: !(Maybe Int64),
    -- | The index line — the only part of the skill every dispatch
    -- pays for, and the only signal the model picks it by.
    skillDescription :: !Text,
    -- | The full instructions, fetched via @use_skill@.
    skillBody :: !Text,
    skillEnabled :: !Bool,
    -- | QQ uid that taught it from chat; 'Nothing' = admin API.
    skillCreatedBy :: !(Maybe Int64),
    skillUpdatedAt :: !UTCTime,
    skillRevision :: !Integer,
    skillPackage :: !SkillPackage
  }
  deriving stock (Show, Eq)

-- | The whole table in one TVar, keyed by id.  Builtins sit under
-- negative keys, DB rows under their (positive) primary keys.
data SkillRegistry = SkillRegistry (TVar (Map Int64 Skill)) (MVar ())

-- | Every @skills\/*.md@ in the repo, baked in at compile time.
builtinSkillFiles :: [(FilePath, ByteString)]
builtinSkillFiles = $(embedDir "skills")

-- | Parse one embedded file: first line = description, everything
-- after the first blank line = body.  Files that don't parse are a
-- programming error in the repo, but a broken one shipping should
-- degrade to "skill missing", not "bot won't boot" — hence Maybe.
--
-- Two placeholders splice the pieces of self-knowledge that are
-- runtime-generated rather than readable from the source snapshot, so
-- neither can drift from what the bot actually ships: @{{commands}}@
-- takes the live @!help@ text, @{{version}}@ the build-identity half
-- of the @!version@ card (the half that is fixed for this process —
-- uptime and per-group counts stay with the command, which reads them
-- per invocation).
parseBuiltin :: UTCTime -> Text -> Int64 -> (FilePath, ByteString) -> Maybe Skill
parseBuiltin bootTime osName sid (path, bytes)
  | takeExtension path /= ".md" = Nothing
  | T.null name || T.null desc || T.null body = Nothing
  | otherwise =
      do
        package <- case lookup (dropExtension path <> ".json") builtinSkillFiles of
          Nothing -> Just emptyPackage
          Just source -> either (const Nothing) Just (eitherDecodeStrict' source)
        Just
          Skill
            { skillId = sid,
              skillName = name,
              skillGroup = Nothing,
              skillDescription = desc,
              skillBody = body,
              skillEnabled = True,
              skillCreatedBy = Nothing,
              skillUpdatedAt = bootTime,
              skillRevision = 1,
              skillPackage = package
            }
  where
    name = T.pack (dropExtension path)
    (descLine, rest) = T.breakOn "\n" (TE.decodeUtf8Lenient bytes)
    desc = T.strip descLine
    body =
      T.replace "{{commands}}" (T.strip (helpText Nothing))
        . T.replace "{{version}}" (T.intercalate "\n" (buildIdentityLines osName))
        $ T.strip rest

newSkillRegistry :: IO SkillRegistry
newSkillRegistry = do
  bootTime <- getCurrentTime
  osName <- readOsPretty
  let parsed =
        [s | file <- builtinSkillFiles, Just s <- [parseBuiltin bootTime osName 0 file]]
      builtins = [s {skillId = sid} | (sid, s) <- zip [-1, -2 ..] parsed]
  SkillRegistry <$> newTVarIO (Map.fromList [(s.skillId, s) | s <- builtins]) <*> newMVar ()

-- | Boot-time load of every DB row, layered over the builtins seeded
-- by 'newSkillRegistry'.  Returns the total count for the startup log
-- line.
loadSkills :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Eff es Int
loadSkills reg@(SkillRegistry t _) = withMutation reg $ do
  rows <-
    query_
      "SELECT id, name, group_id, description, body, enabled, created_by, updated_at, revision, package \
      \  FROM skills ORDER BY id"
  skills <- traverse skillFromRow rows
  liftIO . atomically $ do
    m <- readTVar t
    let builtins = Map.filterWithKey (\k _ -> k < 0) m
    writeTVar t (Map.fromList [(s.skillId, s) | s <- skills] <> builtins)
  Map.size <$> liftIO (readTVarIO t)

skillFromRow :: (IOE :> es) => ((Int64, Text, Maybe Int64, Text, Text, Bool) :. (Maybe Int64, UTCTime, Integer, Value)) -> Eff es Skill
skillFromRow ((i, n, g, d, b, e) :. (cb, up, revision, raw :: Value)) = do
  package <- case fromJSON raw of
    Error err -> liftIO (ioError (userError ("invalid persisted skill package: " <> err)))
    Success value -> pure value
  pure
    Skill
      { skillId = i,
        skillName = n,
        skillGroup = g,
        skillDescription = d,
        skillBody = b,
        skillEnabled = e,
        skillCreatedBy = cb,
        skillUpdatedAt = up,
        skillRevision = revision,
        skillPackage = package
      }

-- Only this reserved namespace is refreshed by experience maintenance. Ordinary
-- admin skill mutations remain write-through and cannot race a full reload.
refreshExperienceSkills :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Eff es ()
refreshExperienceSkills reg@(SkillRegistry registry _) = withMutation reg $ do
  rows <-
    query_
      "SELECT id,name,group_id,description,body,enabled,created_by,updated_at,revision,package FROM skills WHERE name LIKE 'learned-task-%'"
  learned <- traverse skillFromRow rows
  liftIO . atomically $ modifyTVar' registry $ \current ->
    Map.fromList [(skill.skillId, skill) | skill <- learned] <> Map.filter (not . T.isPrefixOf "learned-task-" . (.skillName)) current

-- | What one group's dispatches see: enabled skills, global + this
-- group's own, sorted by name (determinism keeps the rendered index
-- byte-stable).  Name collisions resolve most-specific-first:
-- group-scoped over DB-global over builtin — so a DB row hot-fixes a
-- builtin, and a group specialises either.
skillsForGroup :: SkillRegistry -> GroupId -> IO [Skill]
skillsForGroup (SkillRegistry t _) (GroupId gid) = do
  m <- readTVarIO t
  let visible =
        [ s
        | s <- Map.elems m,
          s.skillEnabled,
          maybe True (== gid) s.skillGroup
        ]
      rank s
        | isJust s.skillGroup = 2 :: Int
        | s.skillId > 0 = 1
        | otherwise = 0
      -- fromListWith calls the function as (new, old).
      pick new old = if rank new > rank old then new else old
  pure (Map.elems (Map.fromListWith pick [(s.skillName, s) | s <- visible]))

-- | Resolve a @use_skill@ argument under the same visibility rules as
-- 'skillsForGroup'.
lookupSkill :: SkillRegistry -> GroupId -> Text -> IO (Maybe Skill)
lookupSkill reg gid name = do
  skills <- skillsForGroup reg gid
  pure (lookup name [(s.skillName, s) | s <- skills])

-- | Every row, enabled or not — the admin surface.
listAllSkills :: SkillRegistry -> IO [Skill]
listAllSkills (SkillRegistry t _) = Map.elems <$> readTVarIO t

--------------------------------------------------------------------------------
-- Mutations (write-through: Postgres first, cache second).

-- | Everything a caller decides about a new skill; the DB mints the
-- rest (id, timestamps).
data NewSkill = NewSkill
  { nsName :: !Text,
    nsGroup :: !(Maybe Int64),
    nsDescription :: !Text,
    nsBody :: !Text,
    nsEnabled :: !Bool,
    nsCreatedBy :: !(Maybe Int64),
    nsPackage :: !SkillPackage
  }

-- | Size caps.  The description is a permanent line in every
-- dispatch's system prompt, so it gets the tightest one; the body is
-- paid only on use but still bounded — a "skill" past this size is a
-- document, and documents belong in sandbox files.
validateSkill :: Text -> Text -> Text -> Either Text ()
validateSkill = validateSkillText

-- | Insert a new skill.  'Left' carries a user-showable reason
-- (validation, duplicate name).
createSkill ::
  (WithConnection :> es, IOE :> es) =>
  SkillRegistry ->
  NewSkill ->
  Eff es (Either Text Skill)
createSkill reg@(SkillRegistry t _) ns = withMutation reg $
  case validateSkill ns.nsName ns.nsDescription ns.nsBody >> validateNamedPackage ns.nsName ns.nsPackage of
    Left err -> pure (Left err)
    Right () -> do
      result <- try @SqlError . withCommittedTransaction $ do
        rows <-
          query
            "INSERT INTO skills (name, group_id, description, body, enabled, created_by, package) VALUES (?,?,?,?,?,?,?) RETURNING id, updated_at"
            (ns.nsName, ns.nsGroup, ns.nsDescription, ns.nsBody, ns.nsEnabled, ns.nsCreatedBy, toJSON ns.nsPackage)
        case rows of
          [(sid, up)] -> do
            recordVersion sid
            pure (Right (Skill sid ns.nsName ns.nsGroup ns.nsDescription ns.nsBody ns.nsEnabled ns.nsCreatedBy up 1 ns.nsPackage))
          _ -> pure (Left "insert failed: unexpected result shape")
      publish t result

-- | Existing callers still get CAS against their observed cache revision.
updateSkill :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Int64 -> (Skill -> Skill) -> Eff es (Either Text Skill)
updateSkill registry sid = updateSkillAtRevision registry sid Nothing

updateSkillAtRevision :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Int64 -> Maybe Integer -> (Skill -> Skill) -> Eff es (Either Text Skill)
updateSkillAtRevision reg@(SkillRegistry t _) sid expected edit
  | sid < 0 = pure (Left "内置技能不可修改；创建独立名称的工作流包")
  | otherwise = withMutation reg $ do
      current <- Map.lookup sid <$> liftIO (readTVarIO t)
      case current of
        Nothing -> pure (Left "not found")
        Just old
          | "learned-task-" `T.isPrefixOf` old.skillName -> pure (Left "任务经验需重新回放审核，禁用请使用 experience invalidate")
          | maybe False (/= old.skillRevision) expected -> pure (Left "skill revision conflict")
          | otherwise -> do
              let changed = edit old
                  new = changed {skillId = old.skillId, skillCreatedBy = old.skillCreatedBy, skillRevision = old.skillRevision + 1}
              case validateSkill new.skillName new.skillDescription new.skillBody >> validateNamedPackage new.skillName new.skillPackage of
                Left err -> pure (Left err)
                Right () -> do
                  result <- try @SqlError . withCommittedTransaction $ do
                    rows <-
                      query
                        "UPDATE skills SET name=?, group_id=?, description=?, body=?, enabled=?, revision=?, package=?, updated_at=now() WHERE id=? AND revision=? RETURNING updated_at"
                        (new.skillName, new.skillGroup, new.skillDescription, new.skillBody, new.skillEnabled, new.skillRevision, toJSON new.skillPackage, sid, old.skillRevision)
                    case rows of
                      [Only up] -> recordVersion sid >> pure (Right new {skillUpdatedAt = up})
                      _ -> pure (Left "skill revision conflict")
                  publish t result

recordVersion :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
recordVersion sid = do
  _ <- execute "INSERT INTO skill_versions (skill_id, revision, snapshot) SELECT id, revision, to_jsonb(skills) FROM skills WHERE id=?" (Only sid)
  pure ()

publish :: (IOE :> es) => TVar (Map Int64 Skill) -> Either SqlError (Either Text Skill) -> Eff es (Either Text Skill)
publish t = \case
  Left e
    | sqlState e == "23505" -> pure (Left "已存在同名技能或版本")
    | otherwise -> pure (Left ("skill write failed: " <> TE.decodeUtf8Lenient (sqlErrorMsg e)))
  Right (Left err) -> pure (Left err)
  Right (Right skill) -> do
    liftIO . atomically $ modifyTVar' t (Map.insert skill.skillId skill)
    pure (Right skill)

-- | Trusted publication adapter: serialize the standalone SQL commit and cache
-- update together. The supplied operation must return the exact committed row.
-- Public tool effects never receive this callback or the registry capability.
publishSkillTransaction :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Eff es (Either Text Int64) -> Eff es (Either Text Skill)
publishSkillTransaction reg@(SkillRegistry cache _) action = withMutation reg $ do
  result <- try @SqlError . withCommittedTransaction $ do
    changed <- action
    case changed of
      Left err -> pure (Left err)
      Right sid -> do
        rows <- query "SELECT id,name,group_id,description,body,enabled,created_by,updated_at,revision,package FROM skills WHERE id=?" (Only sid)
        case rows of
          [row] -> Right <$> skillFromRow row
          _ -> liftIO (ioError (userError "published skill row is missing"))
  case result of
    -- A lost COMMIT acknowledgement must stay an exception so the tool kernel
    -- records outcome-unknown. Only a definite uniqueness rollback is a normal
    -- before-effect rejection.
    Left failure | sqlState failure /= "23505" -> throwIO failure
    _ -> publish cache result

-- Serialize DB commits and cache publication; cancellation cannot land in the
-- commit-to-cache gap. SQL still uses CAS across independent registry instances.
withMutation :: (IOE :> es) => SkillRegistry -> Eff es a -> Eff es a
withMutation (SkillRegistry _ gate) action =
  bracket_ (liftIO (takeMVar gate)) (liftIO (putMVar gate ())) (mask_ action)

deleteSkill :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Int64 -> Eff es Bool
deleteSkill reg@(SkillRegistry t _) sid
  | sid < 0 = pure False
  | otherwise = withMutation reg $ do
      n <- withCommittedTransaction (execute "DELETE FROM skills WHERE id = ?" (Only sid))
      when (n > 0) . liftIO . atomically $ modifyTVar' t (Map.delete sid)
      pure (n > 0)

validateNamedPackage :: Text -> SkillPackage -> Either Text ()
validateNamedPackage name package = do
  validatePackage package
  when (package /= emptyPackage) (validatePackageName name)
