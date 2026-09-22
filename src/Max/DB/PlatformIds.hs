-- |
-- Typed SQL over @platform_ids@ (migration 025): the two-way mapping
-- between foreign platforms' string ids and the synthetic bigints
-- the rest of max speaks.  See "Max.Platform" for the range scheme.
module Max.DB.PlatformIds
  ( mappedId,
    nativeId,
    compatibilityId,
  )
where

import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T (unpack)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, type (:>))
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Codec (exactlyOne)
import Text.Read (readMaybe)

-- | The synthetic bigint for a native id, allocating one on first
-- sight.  Idempotent under races: the conflict arm re-selects.
mappedId ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- platform
  Text -> -- kind: user | channel | message
  Text -> -- native id
  Eff es Int64
mappedId platform kind native = do
  rows <-
    query
      "INSERT INTO platform_ids (platform, kind, native_id) \
      \ VALUES (?,?,?) \
      \ ON CONFLICT (platform, kind, native_id) \
      \ DO UPDATE SET native_id = EXCLUDED.native_id \
      \ RETURNING mapped_id"
      (platform, kind, native)
  case rows of
    (Only i : _) -> pure i
    -- unreachable: the upsert always returns a row
    [] -> pure 0

-- | Reverse lookup: the native string behind a synthetic id.
nativeId ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- platform
  Text -> -- kind
  Int64 ->
  Eff es (Maybe Text)
nativeId platform kind mapped = do
  rows <-
    query
      "SELECT native_id FROM platform_ids \
      \ WHERE platform = ? AND kind = ? AND mapped_id = ?"
      (platform, kind, mapped)
  pure (fromOnly <$> listToMaybe rows)

compatibilityId ::
  (WithConnection :> es, IOE :> es) =>
  Text ->
  Text ->
  Text ->
  Eff es Int64
compatibilityId platformName kind native =
  case platformName of
    "qq" | Just numeric <- readMaybe (T.unpack native) -> pure numeric
    _ -> do
      rows <-
        query
          "INSERT INTO platform_ids (platform, kind, native_id) VALUES (?, ?, ?) \
          \ ON CONFLICT (platform, kind, native_id) DO UPDATE SET native_id = EXCLUDED.native_id \
          \ RETURNING mapped_id"
          (platformName, kind, native)
      pure (exactlyOne "compatibilityId" rows)
