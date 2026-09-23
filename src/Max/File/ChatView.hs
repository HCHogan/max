-- | Per-conversation sandbox views: @views/<group>/<name>@ hardlinks to
-- immutable objects. The broker creates each view directory when a sandbox
-- starts; Max adds entries at ingest and backfills a view after the broker
-- (re)creates it. Objects are 0444, so a link is readable in the guest and
-- writable by no one. This adapter alone maps content references to host paths.
module Max.File.ChatView (runChatView, backfillChatView) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, when)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Function (on)
import Data.Int (Int64)
import Data.List (groupBy)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.Blob.Reference (BlobRef, blobRefFromSha256)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Files (listConversationFilesInScope)
import Max.DB.Media (ChatMediaRow (..), fetchConversationImagesInScope, fetchConversationVideosInScope)
import Max.Effects.BlobHost (BlobHost, resolveBlobHostPath)
import Max.Effects.ChatView (ChatView, runChatViewWith)
import Max.File.Types (FileRecord (..))
import Max.Sandbox.Chat (ChatKind (..), chatFileNames, chatMediaName, validChatName)
import Max.Util (catchSync)
import OneBot.Types (GroupId (..))
import System.Directory (doesDirectoryExist)
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Directory.ByteString qualified as PosixDirectory
import System.Posix.Files qualified as Posix
import System.Posix.Files.ByteString qualified as PosixFiles

-- | Link at ingest. Without a configured root, or before a sandbox has
-- created the conversation's view, this does nothing: the view is backfilled
-- when the broker creates it.
runChatView :: (BlobHost :> es, Log :> es, IOE :> es) => Maybe FilePath -> Eff (ChatView : es) a -> Eff es a
runChatView views = runChatViewWith $ \group name ref -> for_ views $ \root -> do
  outcome <- link root group name ref
  for_ outcome $ \failure' ->
    logAttention "chat view link failed" $
      object ["group_id" .= groupNumber group, "name" .= name, "error" .= failure']

-- | Link every stored file, image and video of a conversation that its view
-- lacks. Idempotent and never throws; stale names are left in place because
-- message media never change.
backfillChatView :: (BlobHost :> es, WithConnection :> es, Log :> es, IOE :> es) => FilePath -> GroupId -> Eff es ()
backfillChatView root group = backfill `catchSync` \err ->
  logAttention "chat view backfill failed" $ object ["group_id" .= groupNumber group, "error" .= T.pack (show err)]
  where
    backfill = backfillView root group

backfillView :: (BlobHost :> es, WithConnection :> es, Log :> es, IOE :> es) => FilePath -> GroupId -> Eff es ()
backfillView root group = do
  let view = viewPath root group
  present <- liftIO (doesDirectoryExist view)
  when present $ do
    let scope = conversationScopeFor group
    images <- fetchConversationImagesInScope scope
    videos <- fetchConversationVideosInScope scope
    files <- listConversationFilesInScope scope
    existing <- liftIO (entryNames view)
    let wanted =
          [(chatMediaName ChatImage row.cmrMessageId row.cmrSegment (Just row.cmrMime), ref) | row <- images, Just ref <- [blobRefFromSha256 row.cmrSha256]]
            <> [(chatMediaName ChatVideo row.cmrMessageId row.cmrSegment (Just row.cmrMime), ref) | row <- videos, Just ref <- [blobRefFromSha256 row.cmrSha256]]
            <> concatMap messageFiles (groupBy ((==) `on` (.frCanonicalMessageId)) files)
        missing = [entry | entry@(name, _) <- wanted, name `Set.notMember` existing]
    failures <- fmap concat . traverse (\(name, ref) -> maybe [] (\err -> [(name, err)]) <$> link root group name ref) $ missing
    logInfo "chat view backfilled" $
      object ["group_id" .= groupNumber group, "linked" .= (length missing - length failures), "present" .= Set.size existing]
    forM_ (take 5 failures) $ \(name, err) ->
      logAttention "chat view link failed" $
        object ["group_id" .= groupNumber group, "name" .= name, "error" .= err, "failures" .= length failures]
  where
    -- Numbering needs every file of the message, stored or not; only stored
    -- ones have bytes to link.
    messageFiles records = case records of
      first : _
        | Just message <- first.frCanonicalMessageId ->
            [(name, ref) | (name, record) <- zip (chatFileNames message (map (.frFileName) records)) records, Just ref <- [record.frBlobRef]]
      _ -> []

-- | One hardlink, named in UTF-8 whatever the process locale. An existing
-- name is already this message's media. Returns a failure description.
link :: (BlobHost :> es, IOE :> es) => FilePath -> GroupId -> Text -> BlobRef -> Eff es (Maybe Text)
link root group name ref
  | not (validChatName name) = pure (Just "invalid chat view name")
  | otherwise = do
      source <- resolveBlobHostPath ref
      let view = viewPath root group
      liftIO $ do
        present <- doesDirectoryExist view
        if not present
          then pure Nothing
          else do
            result <- try @IOException $ do
              -- Objects stored before views existed may still be 0600.
              Posix.setFileMode source 0o444
              PosixFiles.createLink (raw source) (raw view <> "/" <> TE.encodeUtf8 name)
            pure $ case result of
              Right () -> Nothing
              Left err
                | isAlreadyExistsError err -> Nothing
                | otherwise -> Just (T.pack (show err))

entryNames :: FilePath -> IO (Set.Set Text)
entryNames view = bracket (PosixDirectory.openDirStream (raw view)) PosixDirectory.closeDirStream (go Set.empty)
  where
    go names stream = do
      entry <- PosixDirectory.readDirStream stream
      if BS.null entry
        then pure names
        else go (if entry `elem` [".", ".."] then names else Set.insert (TE.decodeUtf8With lenientDecode entry) names) stream

viewPath :: FilePath -> GroupId -> FilePath
viewPath root group = root </> show (groupNumber group)

groupNumber :: GroupId -> Int64
groupNumber (GroupId value) = value

raw :: FilePath -> BS.ByteString
raw = TE.encodeUtf8 . T.pack
