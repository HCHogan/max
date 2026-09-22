module Max.ChatViewSpec (spec) where

import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, runEff)
import Effectful.Log (Log, LogLevel (LogTrace), runLog)
import Effectful.PostgreSQL (WithConnection, execute)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertRawMessage, silentLogger, truncateAll, withDb)
import Max.Blob.Reference (BlobRef, blobRefSha256, blobRefStoredPath)
import Max.DB.Connection (DbPool)
import Max.DB.Files (insertSeen, markStored)
import Max.Effects.Blob (putBlob, runBlob)
import Max.Effects.BlobHost (BlobHost, runBlobHost)
import Max.Effects.ChatView (linkChatMedia)
import Max.File.ChatView (backfillChatView, runChatView)
import OneBot.Types (GroupId (..))
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Directory.ByteString qualified as PosixDirectory
import System.Posix.Files qualified as Posix
import System.Posix.Files.ByteString qualified as PosixFiles
import Test.Hspec

data Stored = Stored {ref :: BlobRef, sha :: Text, path :: FilePath}

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "conversation /chat views" $ do
  it "backfills every stored file, image and video by its prompt handle as a read-only hardlink" $
    withStore $ \objects views -> do
      now <- getCurrentTime
      message <- insertRawMessage pool 1 900 7 999 now Nothing "看这个"
      old <- insertRawMessage pool 2 900 7 999 (addUTCTime (negate (86400 * 400)) now) Nothing "去年的图"
      elsewhere <- insertRawMessage pool 3 901 7 999 now Nothing "别的群"
      image <- store objects "png bytes"
      sticker <- store objects "sticker bytes"
      oldImage <- store objects "old bytes"
      video <- store objects "video bytes"
      report <- store objects "report bytes"
      withDb pool $ do
        recordImage image "image/png"
        recordImage sticker "image/gif"
        recordImage oldImage "image/jpeg"
        linkImage message image 0
        linkImage message sticker 1
        linkImage old oldImage 0
        linkImage elsewhere image 0
        -- A sticker is a reaction, not material; old media stay in.
        void $ execute "INSERT INTO stickers(sha256,kind) VALUES(?,'custom')" [sticker.sha]
        void $ execute "INSERT INTO videos(sha256,mime_type,bytes_size,local_path) VALUES(?,'video/mp4',5,'x')" [video.sha]
        void $ execute "INSERT INTO message_videos(canonical_message_id,sha256,seg_index) VALUES(?,?,2)" (message, video.sha)
        -- One stored file and one still downloading share a message.
        insertSeen "f-stored" 900 (Just message) 7 "季度报告.pdf" Nothing
        insertSeen "f-pending" 900 (Just message) 7 "later.zip" Nothing
        markStored "f-stored" report.ref (Just "application/pdf") 12
        void $ execute "UPDATE group_files SET received_at = now() - interval '1 minute' WHERE file_id = 'f-stored'" ()
      -- Objects stored before views existed are owner-only until linked.
      Posix.setFileMode report.path 0o600
      createDirectory (views </> "900")
      run objects (backfillChatView views (GroupId 900))
      let named = T.pack (show message)
          expected = sort [named <> ".0.png", named <> ".2.mp4", named <> ".0-季度报告.pdf", T.pack (show old) <> ".0.jpg"]
      entries (views </> "900") `shouldReturn` expected
      sameObject (views </> "900") (named <> ".0-季度报告.pdf") report.path `shouldReturn` True
      mode <- Posix.fileMode <$> Posix.getFileStatus report.path
      Posix.intersectFileModes mode 0o777 `shouldBe` 0o444
      -- Backfill is idempotent, and a conversation without a view gets none.
      run objects (backfillChatView views (GroupId 900))
      entries (views </> "900") `shouldReturn` expected
      run objects (backfillChatView views (GroupId 901))
      doesDirectoryExist (views </> "901") `shouldReturn` False

  it "links at ingest only once the broker has created the conversation's view" $
    withStore $ \objects views -> do
      late <- store objects "late file"
      let ingest name = run objects (runChatView (Just views) (linkChatMedia (GroupId 900) name late.ref))
      ingest "10-late.txt"
      doesDirectoryExist (views </> "900") `shouldReturn` False
      createDirectory (views </> "900")
      ingest "10-late.txt"
      ingest "10-late.txt"
      ingest "../escape"
      entries (views </> "900") `shouldReturn` ["10-late.txt"]
      sameObject (views </> "900") "10-late.txt" late.path `shouldReturn` True
      -- Without a configured root, ingest links nothing.
      run objects (runChatView Nothing (linkChatMedia (GroupId 900) "11-other.txt" late.ref))
      entries (views </> "900") `shouldReturn` ["10-late.txt"]
  where
    withStore action = withSystemTempDirectory "max-chat-view" $ \root -> do
      let objects = root </> "objects"
          views = root </> "views"
      createDirectoryIfMissing True objects
      createDirectoryIfMissing True views
      action objects views
    run :: FilePath -> Eff '[BlobHost, WithConnection, Log, IOE] a -> IO a
    run objects = runEff . runLog "max-test" silentLogger LogTrace . runWithConnectionPool pool . runBlobHost objects
    recordImage stored mime = void $ execute "INSERT INTO images(sha256,mime_type,bytes_size,local_path) VALUES(?,?,5,'x')" (stored.sha, mime :: Text)
    linkImage canonical stored seg = void $ execute "INSERT INTO message_images(canonical_message_id,sha256,seg_index) VALUES(?,?,?)" (canonical, stored.sha, seg :: Int)

-- | Store through the real content-addressed writer.
store :: FilePath -> ByteString -> IO Stored
store objects bytes = do
  ref <- runEff (runBlob objects (putBlob bytes))
  pure (Stored ref (blobRefSha256 ref) (objects </> T.unpack (blobRefStoredPath ref)))

-- | Entry names as UTF-8, independent of the test process locale.
entries :: FilePath -> IO [Text]
entries directory = do
  stream <- PosixDirectory.openDirStream (raw directory)
  let go names = do
        entry <- PosixDirectory.readDirStream stream
        if BS.null entry then pure names else go (entry : names)
  names <- go []
  PosixDirectory.closeDirStream stream
  pure (sort [TE.decodeUtf8 name | name <- names, name `notElem` [".", ".."]])

sameObject :: FilePath -> Text -> FilePath -> IO Bool
sameObject directory name object = do
  entry <- PosixFiles.getFileStatus (raw directory <> "/" <> TE.encodeUtf8 name)
  target <- Posix.getFileStatus object
  pure (Posix.fileID entry == Posix.fileID target && Posix.deviceID entry == Posix.deviceID target)

raw :: FilePath -> ByteString
raw = TE.encodeUtf8 . T.pack
