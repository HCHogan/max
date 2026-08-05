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
    captionBody,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Data.UUID qualified as UUID
import Data.UUID.V4 (nextRandom)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.MessageKind (MessageKind (KindChat))
import Max.Effects.Blob (Blob, blobRefSha256, putBlob, resolveBlobHostPath)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), SendOutcome (..), sendRecorded)
import Max.Effects.PlatformApi (PlatformApi, callAction)
import Max.Effects.Tools (Tool (..))
import Max.IR
import Max.IR.Prompt (MentionRoster (..), parseModelChunk)
import Max.Platform.Types (AdvertisedCaps (..), CanonicalMessageId (..))
import Max.Reply (chunkSource, planReply)
import Max.Sandbox.Docker (runCopyFromContainer, runCopyToContainer)
import Max.Sandbox.Registry (SandboxEntry (..), SandboxId (..), SandboxRegistry, listSandbox)
import Max.Time (fmtDateHMS)
import Max.ToolContext (ToolContext, toolConversationScope, toolGroupId, toolOutputCapabilities)
import Max.Tools.Schema (integerParam, stringParam, toolObject, withKeys)
import Max.Util (withTempDirectory)
import OneBot.Action (Action (UploadGroupFile, UploadPrivateFile), Response (..))
import OneBot.Types (GroupId (..), MessageId (..), isPrivateChat, privateChatUserId)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeFileName, (</>))

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
  ToolContext ->
  SandboxRegistry ->
  [Tool es]
fileToolsFor tz dc sandboxes =
  [ listRecentFilesTool tz gid,
    importFileToSandboxTool (toolConversationScope dc) gid sandboxes,
    sendImageFromSandboxTool (toolOutputCapabilities dc) gid sandboxes,
    sendFileFromSandboxTool gid sandboxes
  ]
  where
    gid = toolGroupId dc

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
        toolObject
          [("limit", withKeys ["default" .= (10 :: Int)] (integerParam "Max results (default 10, max 50)."))]
          [],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right lim -> do
          rows <- DBFiles.listRecentInGroup gid (clamp (1, 50) lim)
          pure $ Right (toJSON (map summarize rows))
    }
  where
    parseArgs :: Object -> Parser Int
    parseArgs o = do
      mL <- o .:? "limit"
      pure (fromMaybe 10 mL)

    summarize :: FileRecord -> Value
    summarize r =
      object
        [ "file_id" .= r.frFileId,
          -- Useful for correlating with reply context (\"the file in
          -- the message the user just quoted\").
          "message_id" .= r.frCanonicalMessageId,
          "name" .= r.frFileName,
          "sender_user_id" .= r.frSenderUserId,
          "time" .= fmtDateHMS tz r.frReceivedAt,
          "bytes" .= r.frBytesSize,
          "mime" .= r.frMimeType,
          "ready" .= isJust r.frBlobRef
        ]

--------------------------------------------------------------------------------
-- import_file_to_sandbox

importFileToSandboxTool ::
  ( Blob :> es,
    WithConnection :> es,
    Log :> es,
    IOE :> es
  ) =>
  ConversationScope ->
  GroupId ->
  SandboxRegistry ->
  Tool es
importFileToSandboxTool scope gid sandboxes =
  Tool
    { toolName = "import_file_to_sandbox",
      toolDescription =
        "Copy a group file (file_id from list_recent_files) into a sandbox's \
        \/work.  Fails while its download hasn't finished (ready=false).",
      toolSchema =
        toolObject
          [ ("file_id", stringParam "file_id from list_recent_files."),
            ("sandbox_id", stringParam "Target sandbox."),
            ("dest_path", stringParam "Path inside /work (default: original file name).")
          ]
          ["file_id", "sandbox_id"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (fid, sid, mDest) -> do
          mFile <- DBFiles.fetchByFileIdInScope scope fid
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
                    let destName = fromMaybe r.frFileName mDest
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
  ( Blob :> es,
    Outbound :> es,
    Log :> es,
    IOE :> es
  ) =>
  AdvertisedCaps ->
  GroupId ->
  SandboxRegistry ->
  Tool es
sendImageFromSandboxTool outputCaps gid sandboxes =
  Tool
    { toolName = "send_image_from_sandbox",
      toolDescription =
        "Send an image file from a sandbox into the chat as an inline picture \
        \(charts, screenshots; a few MB max — larger or non-image artifacts go \
        \via send_file_from_sandbox).  Optional 'caption' text precedes it.",
      toolSchema =
        toolObject
          [ ("sandbox_id", stringParam "Sandbox the image lives in."),
            ("path", stringParam "Path to the image file (relative to /work, or absolute)."),
            ("caption", stringParam "Optional caption to send before the image.")
          ]
          ["sandbox_id", "path"],
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
                  blob <- putBlob bytes
                  let source = mediaBlobRef (blobRefSha256 blob)
                      (replyTo, caption) = captionBody outputCaps gid mCaption
                      body = Body (caption.nodes <> [NMedia source (imageMeta bytes)])
                  outcome <-
                    sendRecorded
                      OutboundRequest
                        { orKind = KindChat,
                          orGroupId = gid,
                          orBody = body,
                          orReplyTo = replyTo,
                          orDeliveryScope = DeliverConversation
                        }
                  case outcome of
                    SendFailed err -> pure (Left ("图片发送失败: " <> err))
                    SentUnrecorded {} -> sent sid bytes
                    SentRecorded {} -> sent sid bytes
    }
  where
    imageMeta bytes =
      MediaMeta
        { kind = MImage,
          mime = Just "image/png",
          sizeBytes = Just (fromIntegral (BS.length bytes)),
          name = Just "sandbox.png",
          description = Nothing,
          raw = Nothing
        }

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

-- | Parse a model-authored image caption directly into ingest IR.
--
-- The caption is model-authored text, written under the same format
-- guide as a reply, so it arrives carrying the same placeholders — and
-- this was the last sender that never learned to read them.
-- Production: @"[↩#493645310] 画好了，macOS belike：…"@ went to the
-- group with the token visible, weeks after the reply and narration
-- paths were both taught to consume it.  Pure and top-level for the
-- It shares the model-token codec with ordinary replies; model-only media
-- handles are deliberately dropped because the image tool has already chosen
-- the attachment it is publishing.
--
-- One message, so @[split]@ cannot be honoured the way it is elsewhere;
-- plan the caption anyway and rejoin, which eats the markers instead of
-- printing them.  The trailing newline keeps the caption off the image,
-- as it always did.  Mentions are checked for syntax only — a tool has
-- no roster to check membership against.  A caption that is nothing but
-- a quote still quotes: unlike a narration line, the message it rides
-- on is going out regardless.
--
-- Mentions fold to text unconditionally.  A caption is written by a tool,
-- not by the reply path, so there is nothing here to resolve a principal
-- against an account with — and "@name" is the honest rendering of an
-- unresolved mention everywhere else too.
captionBody ::
  AdvertisedCaps -> GroupId -> Maybe Text -> (Maybe CanonicalMessageId, Body 'Canonical)
captionBody _ _ Nothing = (Nothing, Body [])
captionBody outputCaps _ (Just caption) =
  ( CanonicalMessageId <$> if outputCaps.canReply then quoted else Nothing,
    Body (if null body then [] else body <> [NText "\n"])
  )
  where
    (quoted, parsed) =
      parseModelChunk
        MentionRoster {names = []}
        (T.intercalate "\n" (map chunkSource (planReply caption)))
    body = trimEdges (mergeText (concatMap resolve parsed.nodes))
    resolve = \case
      NText text -> [NText text]
      NMention _ display -> [NText (mentionToken display)]
      NEmote emote
        | outputCaps.canFace -> [NEmote emote]
        | otherwise -> []
      NMedia {} -> []
      NCard card -> [NCard card]

-- | Stage a file from a container into a host temp file, read it,
-- delete the temp.  Used for the base64-image path; bytes stay in
-- memory for one HTTP request and then go.
readSandboxArtifact :: Text -> Text -> IO (Either Text BS.ByteString)
readSandboxArtifact container path =
  withTempDirectory "max-artifact-" $ \workspace -> do
    let tmp = workspace </> "artifact"
    cpRes <- runCopyFromContainer container path tmp
    case cpRes of
      Left err -> pure (Left err)
      Right () -> Right <$> BS.readFile tmp

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
        toolObject
          [ ("sandbox_id", stringParam "Sandbox the file lives in."),
            ("path", stringParam "Path to the file (relative to /work, or absolute)."),
            ("name", stringParam "Display name in QQ (default: basename of path).")
          ]
          ["sandbox_id", "path"],
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
                  displayName = fromMaybe (T.pack basename) mName
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
