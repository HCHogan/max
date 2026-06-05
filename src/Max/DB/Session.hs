-- |
-- Postgres CRUD for the @sessions@ + @session_active_branch@ tables.
-- The active branch for a group is a one-row pointer; branch rows
-- themselves are keyed by @(group_id, branch)@.
--
-- 'fetchActiveOrInit' is the boot-time path: read the active branch
-- if it exists, otherwise create a fresh @main@ branch with the given
-- default model.  'upsertSession' writes through on every mutation.
module Max.DB.Session
  ( fetchActiveOrInit,
    fetchBranch,
    upsertSession,
    switchActiveBranch,
    listBranches,
    branchExists,
    getActiveBranch,
    deleteBranch,
  )
where

import Control.Monad (void)
import Data.Aeson (Result (..), Value, fromJSON, toJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (FromRow, Only (..), (:.) (..))
import Database.PostgreSQL.Simple.FromRow (field, fromRow)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
-- Session lives in Max.Session; we avoid the circular import by
-- redefining the row shape locally and converting.
import Max.Session.Types (Session (..))
import OneBot.Types (GroupId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

-- | One row from @sessions@ alongside the active-branch pointer.  We
-- pull both in one round trip via a join so we can detect "active
-- branch points at a deleted row" cleanly.
--
-- Note: jsonb columns deserialise via @postgresql-simple@'s built-in
-- 'Value' instance — DON'T wrap them in a Text/ByteString newtype
-- (jsonb has no FromField for those, you'll get @errHaskellType =
-- "Text"@).
data Row = Row
  { rGroupId :: !Int64,
    rBranch :: !Text,
    rModel :: !(Maybe Text),
    rPersona :: !(Maybe Text),
    rBtwNotes :: !Value,
    rClearedAt :: !(Maybe UTCTime),
    rPinned :: !Value,
    rThinkingOverride :: !(Maybe Bool)
  }

instance FromRow Row where
  fromRow =
    Row
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | Load the active branch's session for a group, creating a fresh
-- @main@ branch (with the given default model) if nothing exists yet.
fetchActiveOrInit ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- default model name (used when creating)
  Eff es Session
fetchActiveOrInit (GroupId gid) defaultModel = do
  rows <-
    query
      "SELECT s.group_id, s.branch, s.model, s.persona, s.btw_notes, s.cleared_at, s.pinned, s.thinking_override \
      \  FROM session_active_branch a \
      \  JOIN sessions s \
      \    ON s.group_id = a.group_id AND s.branch = a.branch \
      \  WHERE a.group_id = ?"
      (Only gid)
  case rows :: [Row] of
    (r : _) -> pure (rowToSession defaultModel r)
    [] -> do
      -- No active branch — create main.
      let initial =
            Session
              { groupId = GroupId gid,
                branch = "main",
                model = defaultModel,
                persona = Nothing,
                btwNotes = [],
                clearedAt = Nothing,
                pinned = [],
                thinkingOverride = Nothing
              }
      upsertSession initial
      _ <-
        execute
          "INSERT INTO session_active_branch (group_id, branch) VALUES (?, ?) \
          \ ON CONFLICT (group_id) DO UPDATE SET branch = EXCLUDED.branch, updated_at = now()"
          (gid, "main" :: Text)
      pure initial

-- | Idempotent write of one session row.  Updates 'updated_at'.
upsertSession :: (WithConnection :> es, IOE :> es) => Session -> Eff es ()
upsertSession s = do
  let GroupId gid = s.groupId
      btw = Jsonb (toJSON s.btwNotes)
      pin = Jsonb (toJSON s.pinned)
  void $
    execute
      "INSERT INTO sessions (group_id, branch, model, persona, btw_notes, cleared_at, pinned, thinking_override) \
      \ VALUES (?,?,?,?,?,?,?,?) \
      \ ON CONFLICT (group_id, branch) DO UPDATE SET \
      \   model             = EXCLUDED.model, \
      \   persona           = EXCLUDED.persona, \
      \   btw_notes         = EXCLUDED.btw_notes, \
      \   cleared_at        = EXCLUDED.cleared_at, \
      \   pinned            = EXCLUDED.pinned, \
      \   thinking_override = EXCLUDED.thinking_override, \
      \   updated_at        = now()"
      ((gid, s.branch, s.model, s.persona, btw, s.clearedAt, pin) :. Only s.thinkingOverride)

switchActiveBranch ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- branch name
  Eff es ()
switchActiveBranch (GroupId gid) name =
  void $
    execute
      "INSERT INTO session_active_branch (group_id, branch) VALUES (?,?) \
      \ ON CONFLICT (group_id) DO UPDATE SET branch = EXCLUDED.branch, updated_at = now()"
      (gid, name)

listBranches :: (WithConnection :> es, IOE :> es) => GroupId -> Eff es [Text]
listBranches (GroupId gid) = do
  rows <-
    query
      "SELECT branch FROM sessions WHERE group_id = ? ORDER BY branch"
      (Only gid)
  pure [b | Only b <- rows :: [Only Text]]

-- | Load a specific branch of a group.  Returns 'Nothing' if the
-- branch row doesn't exist.
fetchBranch ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- branch name
  Text -> -- default model (used when row.model is NULL/empty)
  Eff es (Maybe Session)
fetchBranch (GroupId gid) name defaultModel = do
  rows <-
    query
      "SELECT group_id, branch, model, persona, btw_notes, cleared_at, pinned, thinking_override \
      \  FROM sessions \
      \  WHERE group_id = ? AND branch = ? \
      \  LIMIT 1"
      (gid, name)
  pure $ case rows :: [Row] of
    (r : _) -> Just (rowToSession defaultModel r)
    [] -> Nothing

branchExists :: (WithConnection :> es, IOE :> es) => GroupId -> Text -> Eff es Bool
branchExists (GroupId gid) name = do
  rows <-
    query
      "SELECT 1 FROM sessions WHERE group_id = ? AND branch = ? LIMIT 1"
      (gid, name)
  pure $ not (null (rows :: [Only Int]))

getActiveBranch ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Eff es (Maybe Text)
getActiveBranch (GroupId gid) = do
  rows <-
    query
      "SELECT branch FROM session_active_branch WHERE group_id = ? LIMIT 1"
      (Only gid)
  pure $ case rows :: [Only Text] of
    (Only b : _) -> Just b
    [] -> Nothing

-- | Remove a non-active branch row.  Caller must check it's not the
-- active branch (this function will happily delete the active row,
-- leaving a dangling 'session_active_branch' pointer).
deleteBranch :: (WithConnection :> es, IOE :> es) => GroupId -> Text -> Eff es ()
deleteBranch (GroupId gid) name =
  void $
    execute
      "DELETE FROM sessions WHERE group_id = ? AND branch = ?"
      (gid, name)

--------------------------------------------------------------------------------

rowToSession :: Text -> Row -> Session
rowToSession defaultModel r =
  Session
    { groupId = GroupId r.rGroupId,
      branch = r.rBranch,
      model = case r.rModel of
        Just m | not (T.null m) -> m
        _ -> defaultModel,
      persona = r.rPersona,
      btwNotes = decodeOrEmpty r.rBtwNotes,
      clearedAt = r.rClearedAt,
      pinned = decodeOrEmpty r.rPinned,
      thinkingOverride = r.rThinkingOverride
    }
  where
    -- Tolerate junk in jsonb columns (e.g. older shape we don't know
    -- how to read) by silently falling back to empty.  Better than
    -- crashing the dispatch and dropping the user's question.
    decodeOrEmpty v = case fromJSON v of
      Success xs -> xs
      Error _ -> []
