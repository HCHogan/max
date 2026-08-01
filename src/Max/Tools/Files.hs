-- |
-- File interaction tools: pull files from the group's catalog into
-- a sandbox; push artifacts (images, files) back out to the group.
--
-- == Inbound
--
-- The 'Max.Files' worker downloads incoming files to the blob store
-- and rows them in 'group_files'.  These tools read that catalog and
-- copy bytes from the host blob path into a sandbox via @docker cp@.
--
-- == Outbound
--
-- * Images: @docker cp@ out to a temp file, base64-encode, send as
--   @SegImage (Just "base64://...")@.  Works without any shared
--   filesystem with NapCat — fine up to a few MB per image.
-- * Files: @docker cp@ out to the bot's @var/outbox/@ directory,
--   then call @upload_group_file@ with the container-side path
--   (@\/data\/outbox\/...@) NapCat sees via the bind mount in
--   docker-compose.yml.
module Max.Tools.Files
  ( fileToolsFor,

    -- * Exposed for tests
    captionSegs,
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone)
import Data.UUID qualified as UUID
import Data.UUID.V4 (nextRandom)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.Message (MessageKind (KindChat))
import Max.Effects.Blob (Blob, resolveBlobHostPath)
import Max.Effects.Outbound (Outbound, OutboundRequest (..), SendOutcome (..), sendRecorded)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Reply (chunkSource, planReply)
import Max.ReplySend (modelTextSegs)
import Max.Sandbox.Docker (runCopyFromContainer, runCopyToContainer)
import Max.Sandbox.Registry (SandboxEntry (..), SandboxId (..), SandboxRegistry, listSandbox)
import Max.Time (fmtDateHMS)
import OneBot.Action (Action (UploadGroupFile, UploadPrivateFile), Response (..))
import OneBot.Segment (Segment (..), imageSeg)
import OneBot.Types (GroupId (..), UserId, isPrivateChat, privateChatUserId)
import System.Directory
  ( createDirectoryIfMissing,
    getTemporaryDirectory,
    removeFile,
  )
import System.FilePath (takeFileName, (</>))
import System.IO (hClose, openBinaryTempFile)

-- | Where staged outbound files live on the host, and the
-- corresponding path inside the NapCat container (see
-- docker-compose.yml's @volumes@).
outboxHostDir, outboxContainerDir :: FilePath
outboxHostDir = "var/outbox"
outboxContainerDir = "/data/outbox"

fileToolsFor ::
  ( Blob :> es,
    WithConnection :> es,
    PlatformApi :> es,
    Outbound :> es,
    Log :> es,
    IOE :> es
  ) =>
  TimeZone ->
  GroupId ->
  UserId -> -- bot self id, for persisted visible tool output
  SandboxRegistry ->
  [Tool es]
fileToolsFor tz gid selfId sandboxes =
  [ listRecentFilesTool tz gid,
    importFileToSandboxTool gid sandboxes,
    sendImageFromSandboxTool gid selfId sandboxes,
    sendFileFromSandboxTool gid sandboxes
  ]

--------------------------------------------------------------------------------
-- list_recent_files

listRecentFilesTool ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  GroupId ->
  Tool es
listRecentFilesTool tz (GroupId gid) =
  Tool
    { toolName = "list_recent_files",
      toolDescription =
        "List non-image files recently sent to this group (file_id, name, \
        \sender, size, 'ready').  Once ready, import_file_to_sandbox takes \
        \the file_id.",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Max results (default 10, max 50)." :: Text),
                        "default" .= (10 :: Int)
                      ]
                ],
            "required" .= ([] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right lim -> do
          rows <- DBFiles.listRecentInGroup gid (clampLimit lim)
          pure $ Right (toJSON (map summarize rows))
    }
  where
    parseArgs :: Object -> Parser Int
    parseArgs o = do
      mL <- o .:? "limit"
      pure (maybe 10 id mL)
    clampLimit n = max 1 (min 50 n)

    summarize :: FileRecord -> Value
    summarize r =
      object
        [ "file_id" .= r.frFileId,
          -- Useful for correlating with reply context (\"the file in
          -- the message the user just quoted\").
          "message_id" .= r.frMessageId,
          "name" .= r.frFileName,
          "sender_user_id" .= r.frSenderUserId,
          "time" .= fmtDateHMS tz r.frReceivedAt,
          "bytes" .= r.frBytesSize,
          "mime" .= r.frMimeType,
          "ready" .= (case r.frBlobRef of Just _ -> True; Nothing -> False)
        ]

--------------------------------------------------------------------------------
-- import_file_to_sandbox

importFileToSandboxTool ::
  ( Blob :> es,
    WithConnection :> es,
    Log :> es,
    IOE :> es
  ) =>
  GroupId ->
  SandboxRegistry ->
  Tool es
importFileToSandboxTool gid sandboxes =
  Tool
    { toolName = "import_file_to_sandbox",
      toolDescription =
        "Copy a group file (file_id from list_recent_files) into a sandbox's \
        \/work.  Fails while its download hasn't finished (ready=false).",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "file_id" .= stringField "file_id from list_recent_files.",
                  "sandbox_id" .= stringField "Target sandbox.",
                  "dest_path"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Path inside /work (default: original file name)." :: Text)
                      ]
                ],
            "required" .= (["file_id", "sandbox_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (fid, sid, mDest) -> do
          mFile <- DBFiles.fetchByFileId fid
          case mFile of
            Nothing -> pure (Left "unknown file_id (try list_recent_files first)")
            Just r -> case r.frBlobRef of
              Nothing -> pure (Left "file not yet downloaded — try again in a moment")
              Just ref -> do
                mEntry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
                case mEntry of
                  Nothing -> pure (Left "sandbox not found")
                  Just e -> do
                    -- docker cp requires a host path; this is one of the
                    -- deliberately explicit Blob boundary escapes.
                    hostPath <- resolveBlobHostPath ref
                    let destName = maybe r.frFileName id mDest
                        containerPath = "/work/" <> destName
                    cpRes <- liftIO (runCopyToContainer e.seContainer hostPath containerPath)
                    case cpRes of
                      Left err -> pure (Left ("docker cp failed: " <> err))
                      Right () -> do
                        logInfo "file imported to sandbox" $
                          object
                            [ "file_id" .= fid,
                              "sandbox_id" .= sid,
                              "container_path" .= containerPath
                            ]
                        pure $
                          Right $
                            object
                              [ "ok" .= True,
                                "path" .= containerPath
                              ]
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "file_id" <*> o .: "sandbox_id" <*> o .:? "dest_path"

--------------------------------------------------------------------------------
-- send_image_from_sandbox

sendImageFromSandboxTool ::
  ( Outbound :> es,
    Log :> es,
    IOE :> es
  ) =>
  GroupId ->
  UserId ->
  SandboxRegistry ->
  Tool es
sendImageFromSandboxTool gid selfId sandboxes =
  Tool
    { toolName = "send_image_from_sandbox",
      toolDescription =
        "Send an image file from a sandbox into the chat as an inline picture \
        \(charts, screenshots; a few MB max — larger or non-image artifacts go \
        \via send_file_from_sandbox).  Optional 'caption' text precedes it.",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox the image lives in.",
                  "path" .= stringField "Path to the image file (relative to /work, or absolute).",
                  "caption"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Optional caption to send before the image." :: Text)
                      ]
                ],
            "required" .= (["sandbox_id", "path"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (sid, path, mCaption) -> do
          mEntry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
          case mEntry of
            Nothing -> pure (Left "sandbox not found")
            Just e -> do
              eBytes <- liftIO (readSandboxArtifact e.seContainer path)
              case eBytes of
                Left err -> pure (Left err)
                Right bytes -> do
                  let b64 = "base64://" <> TE.decodeUtf8 (B64.encode bytes)
                      segs = captionSegs gid mCaption <> [imageSeg b64]
                  outcome <-
                    sendRecorded
                      OutboundRequest
                        { orKind = KindChat,
                          orGroupId = gid,
                          orSelfId = selfId,
                          orRenderedText = Nothing,
                          orSegments = segs,
                          orTimeoutMs = 30000
                        }
                  case outcome of
                    SendFailed err -> pure (Left ("图片发送失败: " <> err))
                    SentUnrecorded {} -> sent sid bytes
                    SentRecorded {} -> sent sid bytes
    }
  where
    sent sid bytes = do
      logInfo "image sent from sandbox" $
        object
          [ "sandbox_id" .= sid,
            "bytes" .= BS.length bytes
          ]
      pure $
        Right $
          object
            [ "ok" .= True,
              "bytes" .= BS.length bytes
            ]

    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "caption"

-- | The segments an image caption becomes, ahead of the image itself.
--
-- The caption is model-authored text, written under the same format
-- guide as a reply, so it arrives carrying the same placeholders — and
-- this was the last sender that never learned to read them.
-- Production: @"[↩#493645310] 画好了，macOS belike：…"@ went to the
-- group with the token visible, weeks after the reply and narration
-- paths were both taught to consume it.  Pure and top-level for the
-- same reason 'Max.ReplySend.modelTextSegs' is: a sender with
-- its own private idea of what model text means is how this keeps
-- happening.
--
-- One message, so @[split]@ cannot be honoured the way it is elsewhere;
-- plan the caption anyway and rejoin, which eats the markers instead of
-- printing them.  The trailing newline keeps the caption off the image,
-- as it always did.  Mentions are checked for syntax only — a tool has
-- no roster to check membership against.  A caption that is nothing but
-- a quote still quotes: unlike a narration line, the message it rides
-- on is going out regardless.
captionSegs :: GroupId -> Maybe Text -> [Segment]
captionSegs _ Nothing = []
captionSegs gid (Just c)
  | null body = quote
  | otherwise = quote <> body <> [SegText "\n"]
  where
    (mQuoted, body) =
      modelTextSegs
        (isPrivateChat gid)
        Nothing
        (T.intercalate "\n" (map chunkSource (planReply c)))
    quote = [SegReply m | Just m <- [mQuoted]]

-- | Stage a file from a container into a host temp file, read it,
-- delete the temp.  Used for the base64-image path; bytes stay in
-- memory for one HTTP request and then go.
readSandboxArtifact :: Text -> Text -> IO (Either Text BS.ByteString)
readSandboxArtifact container path = do
  bracket
    ( do
        tmpDir <- getTemporaryDirectory
        (p, h) <- openBinaryTempFile tmpDir "max-artifact-"
        hClose h
        pure p
    )
    tryRemove
    ( \tmp -> do
        cpRes <- runCopyFromContainer container path tmp
        case cpRes of
          Left err -> pure (Left err)
          Right () -> Right <$> BS.readFile tmp
    )

tryRemove :: FilePath -> IO ()
tryRemove p = void $ try @IOException (removeFile p)

--------------------------------------------------------------------------------
-- send_file_from_sandbox

sendFileFromSandboxTool ::
  ( PlatformApi :> es,
    Log :> es,
    IOE :> es
  ) =>
  GroupId ->
  SandboxRegistry ->
  Tool es
sendFileFromSandboxTool gid sandboxes =
  Tool
    { toolName = "send_file_from_sandbox",
      toolDescription =
        "Upload a file from a sandbox into the group's 群文件 (any artifact: \
        \.csv/.pdf/.zip/…).  Optional 'name' overrides the displayed filename.",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox the file lives in.",
                  "path" .= stringField "Path to the file (relative to /work, or absolute).",
                  "name"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Display name in QQ (default: basename of path)." :: Text)
                      ]
                ],
            "required" .= (["sandbox_id", "path"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (sid, path, mName) -> do
          mEntry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
          case mEntry of
            Nothing -> pure (Left "sandbox not found")
            Just e -> do
              liftIO (createDirectoryIfMissing True outboxHostDir)
              uuid <- liftIO nextRandom
              let basename = takeFileName (T.unpack path)
                  staged = UUID.toString uuid <> "-" <> basename
                  hostStaged = outboxHostDir </> staged
                  containerStaged = T.pack (outboxContainerDir <> "/" <> staged)
                  displayName = maybe (T.pack basename) id mName
              cpRes <- liftIO (runCopyFromContainer e.seContainer path hostStaged)
              case cpRes of
                Left err -> pure (Left ("docker cp failed: " <> err))
                Right () -> do
                  let uploadAction
                        | isPrivateChat gid =
                            UploadPrivateFile (privateChatUserId gid) containerStaged displayName
                        | otherwise = UploadGroupFile gid containerStaged displayName
                  callRes <- callAction uploadAction 60000
                  case callRes of
                    Left err -> pure (Left ("upload_group_file failed: " <> err))
                    Right (Response _ rc _ _)
                      | rc /= 0 ->
                          pure $
                            Left $
                              "upload_group_file retcode " <> T.pack (show rc)
                    Right _ -> do
                      logInfo "file uploaded from sandbox" $
                        object
                          [ "sandbox_id" .= sid,
                            "name" .= displayName,
                            "staged" .= hostStaged
                          ]
                      pure $
                        Right $
                          object
                            [ "ok" .= True,
                              "name" .= displayName
                            ]
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "name"

--------------------------------------------------------------------------------
-- Helpers.

stringField :: Text -> Value
stringField desc =
  object
    [ "type" .= ("string" :: Text),
      "description" .= desc
    ]
