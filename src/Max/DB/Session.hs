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
    upsertSession,
    switchActiveBranch,
    listBranches,
  )
where

import Control.Monad (void)
import Data.Aeson (Value, eitherDecode, encode, toJSON)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (FromRow, Only (..))
import Database.PostgreSQL.Simple.FromField (FromField, fromField, returnError, ResultError (ConversionFailed))
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
data Row = Row
  { rGroupId :: !Int64,
    rBranch :: !Text,
    rModel :: !(Maybe Text),
    rPersona :: !(Maybe Text),
    rHistory :: !JsonbCol,
    rBtwNotes :: !JsonbCol
  }

newtype JsonbCol = JsonbCol {unJsonbCol :: Value}

instance FromField JsonbCol where
  fromField f mdata = do
    bs <- fromField f mdata
    case eitherDecode (LBS.fromStrict (TE.encodeUtf8 bs)) of
      Left e -> returnError ConversionFailed f e
      Right v -> pure (JsonbCol v)

instance FromRow Row where
  fromRow = Row <$> field <*> field <*> field <*> field <*> field <*> field

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
      "SELECT s.group_id, s.branch, s.model, s.persona, s.history, s.btw_notes \
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
                history = [],
                btwNotes = []
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
      hist = Jsonb (toJSON s.history)
      btw = Jsonb (toJSON s.btwNotes)
  void $
    execute
      "INSERT INTO sessions (group_id, branch, model, persona, history, btw_notes) \
      \ VALUES (?,?,?,?,?,?) \
      \ ON CONFLICT (group_id, branch) DO UPDATE SET \
      \   model      = EXCLUDED.model, \
      \   persona    = EXCLUDED.persona, \
      \   history    = EXCLUDED.history, \
      \   btw_notes  = EXCLUDED.btw_notes, \
      \   updated_at = now()"
      (gid, s.branch, s.model, s.persona, hist, btw)

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

--------------------------------------------------------------------------------

rowToSession :: Text -> Row -> Session
rowToSession defaultModel r =
  let hist = case decodeHistory (unJsonbCol r.rHistory) of
        Right xs -> xs
        Left _ -> []
      notes = case decodeNotes (unJsonbCol r.rBtwNotes) of
        Right xs -> xs
        Left _ -> []
   in Session
        { groupId = GroupId r.rGroupId,
          branch = r.rBranch,
          model = case r.rModel of
            Just m | not (T.null m) -> m
            _ -> defaultModel,
          persona = r.rPersona,
          history = hist,
          btwNotes = notes
        }
  where
    decodeHistory v = eitherDecode (encode v)
    decodeNotes v = eitherDecode (encode v)
