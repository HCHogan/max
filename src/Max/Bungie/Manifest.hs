-- | The local manifest copy: background sync of the projected tables, plus
-- lookup by hash and search by name for the destiny tools.
--
-- Bungie publishes each table as one JSON object keyed by hash. Tables are
-- streamed to a temporary file and folded entry by entry, so the ~200 MB item
-- table never has to fit in memory as one value. Each table is replaced in a
-- single transaction; readers see the previous version until it commits.
module Max.Bungie.Manifest
  ( manifestWorker,
    syncManifest,
    lookupDefinitions,
    searchDefinitions,
    SearchHit (..),

    -- * Exposed for tests
    foldTable,
  )
where

import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, forever, unless, void)
import Data.Aeson
import Data.Aeson.Decoding (toEitherValue)
import Data.Aeson.Decoding.ByteString.Lazy (lbsToTokens)
import Data.Aeson.Decoding.Tokens (TkRecord (..), Tokens (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, executeMany, query, query_)
import Max.Bungie.Api (ApiHost (..), ApiTarget (..))
import Max.Bungie.Client (callBungie, renderBungieFailure)
import Max.Bungie.Definitions
import Max.Bungie.Runtime (BungieRuntime (..))
import Max.DB.Transaction (withTransaction)
import Max.HttpRuntime (HttpPool (StandardPool), parseRequestEither, renderTransportFailure, withStreamingResponse)
import Max.Util (trySync, tshow)
import Network.HTTP.Client (brRead)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, openBinaryTempFile)
import Text.Read (readMaybe)

-- | Sync at startup, then look for a new version every six hours.
manifestWorker :: (WithConnection :> es, Log :> es, Concurrent :> es, IOE :> es) => BungieRuntime -> Eff es ()
manifestWorker runtime = localDomain "destiny-manifest" . forever $ do
  trySync (syncManifest runtime) >>= \case
    Left e -> logAttention "destiny manifest: sync failed" (object ["error" .= T.pack (show e)])
    Right () -> pure ()
  threadDelay (6 * 3600 * 1_000_000)

syncManifest :: (WithConnection :> es, Log :> es, IOE :> es) => BungieRuntime -> Eff es ()
syncManifest runtime =
  liftIO (callBungie runtime.brHttp runtime.brConfig 8_000_000 Nothing (ApiTarget MainHost ["Destiny2", "Manifest"] []) Nothing) >>= \case
    Left failure -> logAttention "destiny manifest: index unavailable" (object ["error" .= renderBungieFailure failure])
    Right index -> case (stringAt ["version"] index, pathsFor "zh-chs" index, pathsFor "en" index) of
      (Just version, Just localized, Just english) -> do
        current <- Map.fromList <$> query_ "SELECT kind, version FROM destiny_manifest_kinds"
        let stale = [kind | kind <- syncedKinds, Map.lookup kind current /= Just version]
        unless (null stale) $ logInfo "destiny manifest: syncing" (object ["version" .= version, "kinds" .= length stale])
        forM_ stale $ \kind -> case (KeyMap.lookup (Key.fromText kind) localized, KeyMap.lookup (Key.fromText kind) english) of
          (Just (String zhPath), Just (String enPath)) -> syncKind runtime version kind zhPath enPath
          _ -> logAttention "destiny manifest: table missing from index" (object ["kind" .= kind])
      _ -> logAttention "destiny manifest: unexpected index shape" (object [])
  where
    pathsFor locale index = case at' ["jsonWorldComponentContentPaths", locale] index of
      Just (Object paths) -> Just paths
      _ -> Nothing

syncKind :: (WithConnection :> es, Log :> es, IOE :> es) => BungieRuntime -> Text -> Text -> Text -> Text -> Eff es ()
syncKind runtime version kind zhPath enPath = do
  english <-
    liftIO . withDownloadIO runtime enPath $ \path ->
      foldTable path Map.empty $ \names hash value -> pure (maybe names (\name -> Map.insert hash name names) (englishName kind value))
  outcome <- case english of
    Left failure -> pure (Left failure)
    -- Download first, then replace the table from the local file, so the
    -- transaction never waits on the network.
    Right names -> withSeqEffToIO $ \run -> withDownloadIO runtime zhPath (run . replaceKind version kind names)
  case outcome of
    Right count -> logInfo "destiny manifest: synced" (object ["kind" .= kind, "rows" .= count, "version" .= version])
    Left failure -> logAttention "destiny manifest: table failed" (object ["kind" .= kind, "error" .= failure])

-- A failed fold throws inside the transaction so the old rows survive.
replaceKind :: (WithConnection :> es, IOE :> es) => Text -> Text -> Map Int64 Text -> FilePath -> Eff es (Either Text Int)
replaceKind version kind names path = either (Left . tshow) Right <$> trySync (withTransaction replace)
  where
    replace = do
      void (execute "DELETE FROM destiny_definitions WHERE kind = ?" (Only kind))
      folded <- withSeqEffToIO $ \run -> do
        pending <- newIORef []
        total <- newIORef (0 :: Int)
        let flush = do
              rows <- readIORef pending
              unless (null rows) $ do
                void (run (executeMany "INSERT INTO destiny_definitions (kind, hash, name, name_en, data) VALUES (?,?,?,?,?)" rows))
                modifyIORef' total (+ length rows)
                writeIORef pending []
        scanned <- foldTable path (0 :: Int) $ \buffered hash value -> case projectDefinition kind value of
          Nothing -> pure buffered
          Just (name, projected) -> do
            modifyIORef' pending ((kind, hash, name, Map.findWithDefault "" hash names, projected) :)
            if buffered + 1 >= 500 then flush >> pure 0 else pure (buffered + 1)
        flush
        traverse (const (readIORef total)) scanned
      count <- either (liftIO . throwIO . userError . T.unpack) pure folded
      void $
        execute
          "INSERT INTO destiny_manifest_kinds (kind, version, row_count) VALUES (?,?,?) \
          \ON CONFLICT (kind) DO UPDATE SET version = EXCLUDED.version, row_count = EXCLUDED.row_count, synced_at = now()"
          (kind, version, count)
      pure count

-- | Download a manifest file to a temporary path for the duration of @use@.
withDownloadIO :: BungieRuntime -> Text -> (FilePath -> IO (Either Text a)) -> IO (Either Text a)
withDownloadIO runtime path use = do
  temporary <- getTemporaryDirectory
  bracket (openBinaryTempFile temporary "destiny-manifest.json") (\(file, handle) -> hClose handle >> removeFile file) $ \(file, handle) ->
    parseRequestEither (T.unpack ("https://www.bungie.net" <> path)) >>= \case
      Left failure -> pure (Left (renderTransportFailure failure))
      Right request -> do
        written <- withStreamingResponse runtime.brHttp StandardPool 1024 request $ \_ body ->
          let copy remaining = do
                chunk <- brRead body
                if BS.null chunk
                  then pure True
                  else
                    if BS.length chunk > remaining
                      then pure False
                      else BS.hPut handle chunk >> copy (remaining - BS.length chunk)
           in copy maxTableBytes
        hClose handle
        case written of
          Left failure -> pure (Left (renderTransportFailure failure))
          Right False -> pure (Left "manifest table exceeds the download limit")
          Right True -> use file

maxTableBytes :: Int
maxTableBytes = 1024 * 1024 * 1024

-- | Fold the top-level @{hash: definition}@ object one entry at a time.
foldTable :: FilePath -> acc -> (acc -> Int64 -> Value -> IO acc) -> IO (Either Text acc)
foldTable path initial step = do
  bytes <- LBS.readFile path
  case lbsToTokens bytes of
    TkRecordOpen record -> go initial record
    TkErr e -> pure (Left (T.pack e))
    _ -> pure (Left "manifest table is not a JSON object")
  where
    go acc = \case
      TkPair key tokens -> case toEitherValue tokens of
        Left e -> pure (Left (T.pack e))
        Right (value, rest) -> case readMaybe (T.unpack (Key.toText key)) >>= unsignedHash of
          Just hash -> do
            acc' <- step acc hash value
            acc' `seq` go acc' rest
          Nothing -> go acc rest
      TkRecordEnd _ -> pure (Right acc)
      TkRecordErr e -> pure (Left (T.pack e))

-- | Projected definitions by hash. Hashes absent locally (an unsynced table,
-- or content newer than the local copy) are fetched from Bungie, at most 25
-- per call; the rest are reported missing.
lookupDefinitions :: (WithConnection :> es, IOE :> es) => BungieRuntime -> Text -> [Int64] -> Eff es (Map Int64 Value, [Int64])
lookupDefinitions runtime kind hashes = do
  rows <- query "SELECT hash, data FROM destiny_definitions WHERE kind = ? AND hash = ANY(?)" (kind, PGArray hashes)
  let local = Map.fromList rows
      absent = filter (`Map.notMember` local) hashes
      (fetchable, skipped) = splitAt 25 absent
  fetched <- liftIO . fmap concat . traverse (fetchOne kind) $ fetchable
  let found = local <> Map.fromList fetched
  pure (found, [h | h <- absent, h `Map.notMember` found] <> filter (`Map.notMember` found) skipped)
  where
    fetchOne table hash = do
      result <- callBungie runtime.brHttp runtime.brConfig 4_000_000 Nothing (ApiTarget MainHost ["Destiny2", "Manifest", table, T.pack (show hash)] [("lc", "zh-chs")]) Nothing
      pure $ case result of
        Right definition | Just (_, projected) <- projectDefinition table definition -> [(hash, projected)]
        _ -> []

data SearchHit = SearchHit
  { shKind :: !Text,
    shHash :: !Int64,
    shName :: !Text,
    shNameEn :: !Text,
    shData :: !Value
  }
  deriving stock (Show)

-- | Name search over the synced tables (localized or English, substring,
-- exact matches first). @Nothing@ means nothing has been synced yet.
searchDefinitions :: (WithConnection :> es, IOE :> es) => Maybe Text -> Text -> Int -> Eff es (Maybe [SearchHit])
searchDefinitions kind term limit = do
  synced <- query_ "SELECT count(*) FROM destiny_manifest_kinds"
  case synced of
    [Only (0 :: Int64)] -> pure Nothing
    _ -> do
      let pattern = "%" <> escapeLike (T.strip term) <> "%"
          exact = T.toLower (T.strip term)
      rows <-
        query
          "SELECT kind, hash, name, name_en, data FROM destiny_definitions \
          \ WHERE (?::text IS NULL OR kind = ?) AND name <> '' AND (name ILIKE ? OR name_en ILIKE ?) \
          \ ORDER BY (lower(name) = ? OR lower(name_en) = ?) DESC, (kind = 'DestinyInventoryItemDefinition') DESC, length(name), hash \
          \ LIMIT ?"
          (kind, kind, pattern, pattern, exact, exact, limit)
      pure (Just [SearchHit k h n e d | (k, h, n, e, d) <- rows])
  where
    escapeLike = T.concatMap (\c -> if c `elem` ['%', '_', '\\'] then T.pack ['\\', c] else T.singleton c)

stringAt :: [Text] -> Value -> Maybe Text
stringAt path value = case at' path value of
  Just (String t) -> Just t
  _ -> Nothing

at' :: [Text] -> Value -> Maybe Value
at' [] value = Just value
at' (key : rest) (Object o) = KeyMap.lookup (Key.fromText key) o >>= at' rest
at' _ _ = Nothing
