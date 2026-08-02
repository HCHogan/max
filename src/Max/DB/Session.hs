-- |
-- Postgres CRUD for the @sessions@ table, one row per group.
--
-- 'fetchRecordOrInit' is the boot-time path: atomically ensure the group's row
-- exists, then return both its value and optimistic revision.
module Max.DB.Session
  ( SessionRecord (..),
    fetchOrInit,
    fetchRecordOrInit,
    fetchRecord,
    saveSessionCAS,
    listSessions,
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

-- | One row from @sessions@.
--
-- Note: jsonb columns deserialise via @postgresql-simple@'s built-in
-- 'Value' instance — DON'T wrap them in a Text/ByteString newtype
-- (jsonb has no FromField for those, you'll get @errHaskellType =
-- "Text"@).
data Row = Row
  { rGroupId :: !Int64,
    rModel :: !(Maybe Text),
    rPersona :: !(Maybe Text),
    rClearedAt :: !(Maybe UTCTime),
    rPinned :: !Value,
    rDebugOverride :: !(Maybe Bool),
    rStickerOverride :: !(Maybe Bool),
    rProactiveOverride :: !(Maybe Bool),
    rEffortOverride :: !(Maybe Text),
    rRevision :: !Int64
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
      <*> field
      <*> field

-- | A Session value paired with the database revision it was read from.
-- Callers must present the complete record to 'saveSessionCAS'.
data SessionRecord = SessionRecord
  { session :: !Session,
    revision :: !Int64
  }
  deriving stock (Show)

-- | Load a group's session, creating a fresh row (with the given
-- default model) if nothing exists yet.
fetchOrInit ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- default model name (used when creating)
  Eff es Session
fetchOrInit gid defaultModel = (.session) <$> fetchRecordOrInit gid defaultModel

-- | Atomically create a default row when absent, then return the exact stored
-- revision.  Concurrent initializers converge on the same row.
fetchRecordOrInit ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text ->
  Eff es SessionRecord
fetchRecordOrInit gid@(GroupId gidRaw) defaultModel = do
  void $
    execute
      "INSERT INTO sessions (group_id, model) VALUES (?, ?) \
      \ ON CONFLICT (group_id) DO NOTHING"
      (gidRaw, defaultModel)
  fetchRecord gid defaultModel >>= \case
    Just record -> pure record
    Nothing -> error "session disappeared after initialization"

-- | Read an existing row without creating it.  Used after a failed CAS so the
-- registry can refresh and retry; a missing row remains an explicit failure.
fetchRecord ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text ->
  Eff es (Maybe SessionRecord)
fetchRecord (GroupId gid) defaultModel = do
  rows <-
    query
      "SELECT group_id, model, persona, cleared_at, pinned, debug_override, sticker_override, proactive_override, effort_override, revision \
      \  FROM sessions \
      \  WHERE group_id = ?"
      (Only gid)
  case rows :: [Row] of
    r : _ -> pure (Just (rowToRecord defaultModel r))
    [] -> pure Nothing

-- | Every session row, resolved the same way 'fetchOrInit' resolves
-- one (NULL model → the default).  The admin surface's group list —
-- note these are the DB rows, not the in-memory registry: a group the
-- bot has never spoken in has no row yet.
listSessions :: (WithConnection :> es, IOE :> es) => Text -> Eff es [Session]
listSessions defaultModel = do
  rows <-
    query
      "SELECT group_id, model, persona, cleared_at, pinned, debug_override, sticker_override, proactive_override, effort_override, revision \
      \  FROM sessions ORDER BY group_id"
      ()
  pure (map ((.session) . rowToRecord defaultModel) (rows :: [Row]))

-- | Replace a complete row only when its revision still matches.  Returns the
-- committed record on success and 'Nothing' for a stale or missing row.
saveSessionCAS ::
  (WithConnection :> es, IOE :> es) =>
  SessionRecord ->
  Session ->
  Eff es (Maybe SessionRecord)
saveSessionCAS old new
  | old.session.groupId /= new.groupId = pure Nothing
  | otherwise = do
      let GroupId gid = new.groupId
          pin = Jsonb (toJSON new.pinned)
          nextRevision = old.revision + 1
      changed <-
        execute
          "UPDATE sessions SET \
          \   model = ?, persona = ?, cleared_at = ?, pinned = ?, \
          \   debug_override = ?, sticker_override = ?, proactive_override = ?, \
          \   effort_override = ?, \
          \   revision = ?, updated_at = now() \
          \ WHERE group_id = ? AND revision = ?"
          ((new.model, new.persona, new.clearedAt, pin) :. (new.debugOverride, new.stickerOverride, new.proactiveOverride, new.effortOverride, nextRevision, gid, old.revision))
      pure $
        if changed == 1
          then Just (SessionRecord new nextRevision)
          else Nothing

--------------------------------------------------------------------------------

rowToRecord :: Text -> Row -> SessionRecord
rowToRecord defaultModel r =
  SessionRecord
    { session =
        Session
          { groupId = GroupId r.rGroupId,
            model = case r.rModel of
              Just m | not (T.null m) -> m
              _ -> defaultModel,
            persona = r.rPersona,
            clearedAt = r.rClearedAt,
            pinned = decodeOrEmpty r.rPinned,
            debugOverride = r.rDebugOverride,
            stickerOverride = r.rStickerOverride,
            proactiveOverride = r.rProactiveOverride,
            effortOverride = r.rEffortOverride
          },
      revision = r.rRevision
    }
  where
    -- Tolerate junk in jsonb columns (e.g. older shape we don't know
    -- how to read) by silently falling back to empty.  Better than
    -- crashing the dispatch and dropping the user's question.
    decodeOrEmpty v = case fromJSON v of
      Success xs -> xs
      Error _ -> []
