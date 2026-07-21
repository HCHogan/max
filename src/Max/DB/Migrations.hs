module Max.DB.Migrations
  ( runMigrations,
  )
where

import Data.Foldable (for_)
import Data.ByteString qualified as BS
import Data.List (isSuffixOf, sort)
import Data.Set qualified as Set
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Types (Query (Query))
import Max.DB.Connection (DbPool, withConn)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

-- | Apply any .sql files in @dir@ that haven't been recorded in
-- @schema_migrations@ yet, in filename order. Returns the list of files
-- that were applied in this run.
runMigrations :: DbPool -> FilePath -> IO [String]
runMigrations pool dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else withConn pool $ \c -> do
      ensureTable c
      done <- listApplied c
      files <- sort . filter (".sql" `isSuffixOf`) <$> listDirectory dir
      let pending = filter (`Set.notMember` done) files
      for_ pending (applyOne c dir)
      pure pending

ensureTable :: Connection -> IO ()
ensureTable c = do
  _ <-
    execute_
      c
      "CREATE TABLE IF NOT EXISTS schema_migrations \
      \ (filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"
  pure ()

listApplied :: Connection -> IO (Set.Set String)
listApplied c = do
  rows <- query_ c "SELECT filename FROM schema_migrations" :: IO [Only String]
  pure (Set.fromList [fn | Only fn <- rows])

applyOne :: Connection -> FilePath -> String -> IO ()
applyOne c dir fn = withTransaction c $ do
  sql <- BS.readFile (dir </> fn)
  _ <- execute_ c (Query sql)
  _ <-
    execute
      c
      "INSERT INTO schema_migrations (filename) VALUES (?)"
      (Only fn)
  pure ()
