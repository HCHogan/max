-- |
-- Postgres CRUD for the @sessions@ table, one row per group.
--
-- 'fetchOrInit' is the boot-time path: read the group's row if it
-- exists, otherwise create a fresh one with the given default model.
-- 'upsertSession' writes through on every mutation.
module Max.DB.Session
  ( fetchOrInit,
    upsertSession,
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
    rThinkingOverride :: !(Maybe Bool),
    rDebugOverride :: !(Maybe Bool),
    rStickerOverride :: !(Maybe Bool),
    rProactiveOverride :: !(Maybe Bool)
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

-- | Load a group's session, creating a fresh row (with the given
-- default model) if nothing exists yet.
fetchOrInit ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Text -> -- default model name (used when creating)
  Eff es Session
fetchOrInit (GroupId gid) defaultModel = do
  rows <-
    query
      "SELECT group_id, model, persona, cleared_at, pinned, thinking_override, debug_override, sticker_override, proactive_override \
      \  FROM sessions \
      \  WHERE group_id = ?"
      (Only gid)
  case rows :: [Row] of
    (r : _) -> pure (rowToSession defaultModel r)
    [] -> do
      let initial =
            Session
              { groupId = GroupId gid,
                model = defaultModel,
                persona = Nothing,
                clearedAt = Nothing,
                pinned = [],
                thinkingOverride = Nothing,
                debugOverride = Nothing,
                stickerOverride = Nothing,
                proactiveOverride = Nothing
              }
      upsertSession initial
      pure initial

-- | Idempotent write of one session row.  Updates 'updated_at'.
upsertSession :: (WithConnection :> es, IOE :> es) => Session -> Eff es ()
upsertSession s = do
  let GroupId gid = s.groupId
      pin = Jsonb (toJSON s.pinned)
  void $
    execute
      "INSERT INTO sessions (group_id, model, persona, cleared_at, pinned, thinking_override, debug_override, sticker_override, proactive_override) \
      \ VALUES (?,?,?,?,?,?,?,?,?) \
      \ ON CONFLICT (group_id) DO UPDATE SET \
      \   model              = EXCLUDED.model, \
      \   persona            = EXCLUDED.persona, \
      \   cleared_at         = EXCLUDED.cleared_at, \
      \   pinned             = EXCLUDED.pinned, \
      \   thinking_override  = EXCLUDED.thinking_override, \
      \   debug_override     = EXCLUDED.debug_override, \
      \   sticker_override   = EXCLUDED.sticker_override, \
      \   proactive_override = EXCLUDED.proactive_override, \
      \   updated_at         = now()"
      ((gid, s.model, s.persona, s.clearedAt, pin) :. (s.thinkingOverride, s.debugOverride, s.stickerOverride, s.proactiveOverride))

--------------------------------------------------------------------------------

rowToSession :: Text -> Row -> Session
rowToSession defaultModel r =
  Session
    { groupId = GroupId r.rGroupId,
      model = case r.rModel of
        Just m | not (T.null m) -> m
        _ -> defaultModel,
      persona = r.rPersona,
      clearedAt = r.rClearedAt,
      pinned = decodeOrEmpty r.rPinned,
      thinkingOverride = r.rThinkingOverride,
      debugOverride = r.rDebugOverride,
      stickerOverride = r.rStickerOverride,
      proactiveOverride = r.rProactiveOverride
    }
  where
    -- Tolerate junk in jsonb columns (e.g. older shape we don't know
    -- how to read) by silently falling back to empty.  Better than
    -- crashing the dispatch and dropping the user's question.
    decodeOrEmpty v = case fromJSON v of
      Success xs -> xs
      Error _ -> []
