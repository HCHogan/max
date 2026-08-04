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
-- Files under @skills\/@ (currently: self-knowledge, sandbox, web,
-- office) are baked into the binary (file-embed, same deployment
-- story as the admin panel's assets) and seeded into the registry
-- with negative ids.  They exist for content that is coupled
-- to the code it ships with — @self-knowledge@ is THIS binary's
-- self-inspection entry point: a navigation map over the embedded
-- source snapshot plus the live command help.  Behaviour, design and
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
{-# LANGUAGE TemplateHaskell #-}

module Max.Skills
  ( Skill (..),
    SkillRegistry,
    newSkillRegistry,
    loadSkills,
    skillsForGroup,
    lookupSkill,
    listAllSkills,
    NewSkill (..),
    createSkill,
    updateSkill,
    deleteSkill,
    validateSkill,
  )
where

import Control.Concurrent.STM
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Char (isSpace)
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
import Effectful.Exception (try)
import Effectful.PostgreSQL (WithConnection, execute, query, query_)
import Max.Command.Help (helpText)
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
    skillUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

-- | The whole table in one TVar, keyed by id.  Builtins sit under
-- negative keys, DB rows under their (positive) primary keys.
newtype SkillRegistry = SkillRegistry (TVar (Map Int64 Skill))

-- | Every @skills\/*.md@ in the repo, baked in at compile time.
builtinSkillFiles :: [(FilePath, ByteString)]
builtinSkillFiles = $(embedDir "skills")

-- | Parse one embedded file: first line = description, everything
-- after the first blank line = body.  Files that don't parse are a
-- programming error in the repo, but a broken one shipping should
-- degrade to "skill missing", not "bot won't boot" — hence Maybe.
--
-- @{{commands}}@ in a body splices the live @!help@ text — the one piece
-- of self-knowledge that is runtime-generated rather than readable from
-- the source snapshot, so it cannot drift from the shipped commands.
parseBuiltin :: UTCTime -> Int64 -> (FilePath, ByteString) -> Maybe Skill
parseBuiltin bootTime sid (path, bytes)
  | takeExtension path /= ".md" = Nothing
  | T.null name || T.null desc || T.null body = Nothing
  | otherwise =
      Just
        Skill
          { skillId = sid,
            skillName = name,
            skillGroup = Nothing,
            skillDescription = desc,
            skillBody = body,
            skillEnabled = True,
            skillCreatedBy = Nothing,
            skillUpdatedAt = bootTime
          }
  where
    name = T.pack (dropExtension path)
    (descLine, rest) = T.breakOn "\n" (TE.decodeUtf8Lenient bytes)
    desc = T.strip descLine
    body =
      T.replace "{{commands}}" (T.strip (helpText Nothing)) (T.strip rest)

newSkillRegistry :: IO SkillRegistry
newSkillRegistry = do
  bootTime <- getCurrentTime
  let parsed =
        [s | file <- builtinSkillFiles, Just s <- [parseBuiltin bootTime 0 file]]
      builtins = [s {skillId = sid} | (sid, s) <- zip [-1, -2 ..] parsed]
  SkillRegistry <$> newTVarIO (Map.fromList [(s.skillId, s) | s <- builtins])

-- | Boot-time load of every DB row, layered over the builtins seeded
-- by 'newSkillRegistry'.  Returns the total count for the startup log
-- line.
loadSkills :: (WithConnection :> es, IOE :> es) => SkillRegistry -> Eff es Int
loadSkills (SkillRegistry t) = do
  rows <-
    query_
      "SELECT id, name, group_id, description, body, enabled, created_by, updated_at \
      \  FROM skills ORDER BY id"
  let skills = map fromRow rows
  liftIO . atomically $ do
    m <- readTVar t
    let builtins = Map.filterWithKey (\k _ -> k < 0) m
    writeTVar t (Map.fromList [(s.skillId, s) | s <- skills] <> builtins)
  Map.size <$> liftIO (readTVarIO t)
  where
    fromRow ((i, n, g, d, b, e) :. (cb, up)) =
      Skill
        { skillId = i,
          skillName = n,
          skillGroup = g,
          skillDescription = d,
          skillBody = b,
          skillEnabled = e,
          skillCreatedBy = cb,
          skillUpdatedAt = up
        }

-- | What one group's dispatches see: enabled skills, global + this
-- group's own, sorted by name (determinism keeps the rendered index
-- byte-stable).  Name collisions resolve most-specific-first:
-- group-scoped over DB-global over builtin — so a DB row hot-fixes a
-- builtin, and a group specialises either.
skillsForGroup :: SkillRegistry -> GroupId -> IO [Skill]
skillsForGroup (SkillRegistry t) (GroupId gid) = do
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
listAllSkills (SkillRegistry t) = Map.elems <$> readTVarIO t

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
    nsCreatedBy :: !(Maybe Int64)
  }

-- | Size caps.  The description is a permanent line in every
-- dispatch's system prompt, so it gets the tightest one; the body is
-- paid only on use but still bounded — a "skill" past this size is a
-- document, and documents belong in sandbox files.
maxNameLen, maxDescriptionLen, maxBodyLen :: Int
maxNameLen = 64
maxDescriptionLen = 120
maxBodyLen = 49152

-- | Shared shape check for create and patch.  'Left' is a
-- user-showable reason.
validateSkill :: Text -> Text -> Text -> Either Text ()
validateSkill name desc body
  | T.null name = Left "name 不能为空"
  | T.length name > maxNameLen = Left ("name 太长（上限 " <> tshow maxNameLen <> " 字符）")
  | T.any isSpace name = Left "name 不能含空白字符（用 - 连接）"
  | T.null (T.strip desc) = Left "description 不能为空"
  | T.length desc > maxDescriptionLen = Left ("description 太长（上限 " <> tshow maxDescriptionLen <> " 字符，它是常驻提示词）")
  | T.any (== '\n') desc = Left "description 必须是单行"
  | T.null (T.strip body) = Left "body 不能为空"
  | T.length body > maxBodyLen = Left ("body 太长（上限 " <> tshow maxBodyLen <> " 字符；更长的材料放 sandbox 文件）")
  | otherwise = Right ()

-- | Insert a new skill.  'Left' carries a user-showable reason
-- (validation, duplicate name).
createSkill ::
  (WithConnection :> es, IOE :> es) =>
  SkillRegistry ->
  NewSkill ->
  Eff es (Either Text Skill)
createSkill (SkillRegistry t) ns =
  case validateSkill ns.nsName ns.nsDescription ns.nsBody of
    Left err -> pure (Left err)
    Right () -> do
      eres <-
        try @SqlError $
          query
            "INSERT INTO skills (name, group_id, description, body, enabled, created_by) \
            \ VALUES (?,?,?,?,?,?) RETURNING id, updated_at"
            (ns.nsName, ns.nsGroup, ns.nsDescription, ns.nsBody, ns.nsEnabled, ns.nsCreatedBy)
      case eres of
        Left e
          | sqlState e == "23505" ->
              pure (Left ("已存在同名技能：" <> ns.nsName))
          | otherwise -> pure (Left ("insert failed: " <> TE.decodeUtf8Lenient (sqlErrorMsg e)))
        Right [(sid, up)] -> do
          let s =
                Skill
                  { skillId = sid,
                    skillName = ns.nsName,
                    skillGroup = ns.nsGroup,
                    skillDescription = ns.nsDescription,
                    skillBody = ns.nsBody,
                    skillEnabled = ns.nsEnabled,
                    skillCreatedBy = ns.nsCreatedBy,
                    skillUpdatedAt = up
                  }
          liftIO . atomically $ modifyTVar' t (Map.insert sid s)
          pure (Right s)
        Right _ -> pure (Left "insert failed: unexpected result shape")

-- | Apply a pure edit to one skill.  The edit can touch name, scope,
-- description, body and the enabled flag; id and provenance are
-- fixed.  'Left' carries a user-showable reason ("not found",
-- validation, duplicate name).
updateSkill ::
  (WithConnection :> es, IOE :> es) =>
  SkillRegistry ->
  Int64 ->
  (Skill -> Skill) ->
  Eff es (Either Text Skill)
updateSkill (SkillRegistry t) sid f
  | sid < 0 = pure (Left "内置技能（随二进制发布）不可修改；建一个同名技能即可覆盖它")
  | otherwise = do
      m <- liftIO (readTVarIO t)
      case Map.lookup sid m of
        Nothing -> pure (Left "not found")
        Just old -> do
          let new0 = f old
              new = new0 {skillId = old.skillId, skillCreatedBy = old.skillCreatedBy}
          case validateSkill new.skillName new.skillDescription new.skillBody of
            Left err -> pure (Left err)
            Right () -> do
              eres <-
                try @SqlError $
                  query
                    "UPDATE skills SET name = ?, group_id = ?, description = ?, body = ?, \
                    \ enabled = ?, updated_at = now() WHERE id = ? RETURNING updated_at"
                    (new.skillName, new.skillGroup, new.skillDescription, new.skillBody, new.skillEnabled, sid)
              case eres of
                Left e
                  | sqlState e == "23505" ->
                      pure (Left ("已存在同名技能：" <> new.skillName))
                  | otherwise -> pure (Left ("update failed: " <> TE.decodeUtf8Lenient (sqlErrorMsg e)))
                Right [Only up] -> do
                  let new' = new {skillUpdatedAt = up}
                  liftIO . atomically $ modifyTVar' t (Map.insert sid new')
                  pure (Right new')
                Right _ -> pure (Left "not found")

-- | Remove a skill.  'False' when the id doesn't exist; builtins
-- (negative ids) are not deletable and the cache entry must survive,
-- so they never reach the DELETE.
deleteSkill ::
  (WithConnection :> es, IOE :> es) =>
  SkillRegistry ->
  Int64 ->
  Eff es Bool
deleteSkill (SkillRegistry t) sid
  | sid < 0 = pure False
  | otherwise = do
      n <- execute "DELETE FROM skills WHERE id = ?" (Only sid)
      when (n > 0) . liftIO . atomically $ modifyTVar' t (Map.delete sid)
      pure (n > 0)

tshow :: Show a => a -> Text
tshow = T.pack . show
