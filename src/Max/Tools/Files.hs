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
-- Both images and files publish blob-backed canonical messages. The endpoint
-- delivery worker owns platform emission, receipts and recovery.
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.Effects.Blob (Blob, blobRefSha256, putBlob, resolveBlobHostPath)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), PublicationResult (..), sendRecorded)
import Max.Effects.Tools (Tool (..))
import Max.IR
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Store (ConversationRoster (..), RosterIdentity (..), conversationRoster)
import Max.Platform.Types (AdvertisedCaps (..), CanonicalMessageId (..))
import Max.Reply (chunkSource, planReply)
import Max.Reply.Resolve
import Max.Sandbox.Docker (readSandboxArtifact, runCopyToContainer)
import Max.Sandbox.Registry (SandboxEntry (..), SandboxId (..), SandboxRegistry, listSandbox)
import Max.Time (fmtDateHMS)
import Max.ToolContext (ToolContext, toolConversationScope, toolGroupId, toolOutputCapabilities, toolTurnOutputContext)
import Max.Tools.Schema (integerParam, stringParam, toolObject, withKeys)
import Max.Turn.Types (TurnOutputContext, nextTurnOutputLink)
import OneBot.Types (GroupId (..))
import System.FilePath (takeFileName)

fileToolsFor ::
  ( Blob :> es,
    WithConnection :> es,
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
    sendImageFromSandboxTool (toolOutputCapabilities dc) (toolTurnOutputContext dc) gid sandboxes,
    sendFileFromSandboxTool (toolTurnOutputContext dc) gid sandboxes
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
    WithConnection :> es,
    Outbound :> es,
    Log :> es,
    IOE :> es
  ) =>
  AdvertisedCaps ->
  Maybe TurnOutputContext ->
  GroupId ->
  SandboxRegistry ->
  Tool es
sendImageFromSandboxTool outputCaps turnOutputContext gid sandboxes =
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
                  (replyTo, caption) <- captionBody outputCaps gid mCaption
                  let source = mediaBlobRef (blobRefSha256 blob)
                      body = Body (caption.nodes <> [NMedia source (imageMeta bytes)])
                  turnOutput <- traverse (liftIO . nextTurnOutputLink) turnOutputContext
                  outcome <-
                    sendRecorded
                      OutboundRequest
                        { orKind = KindChat,
                          orGroupId = gid,
                          orBody = body,
                          orReplyTo = replyTo,
                          orDeliveryScope = DeliverConversation,
                          orTurnOutput = turnOutput,
                          orMonitorFireId = Nothing
                        }
                  case outcome of
                    PublicationFailed err -> pure (Left ("图片发送失败: " <> err))
                    Published canonical -> sent sid bytes (Just canonical)
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

    sent sid bytes canonical = do
      logInfo "image sent from sandbox" $
        object
          [ "sandbox_id" .= sid,
            "bytes" .= BS.length bytes
          ]
      pure $
        Right $
          object $
            [ "ok" .= True,
              "bytes" .= BS.length bytes
            ]
              <> [ "_max_journal_canonical_message_id" .= message.unCanonicalMessageId
                 | Just message <- [canonical]
                 ]

    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "caption"

-- | Captions share the canonical resolver, including scoped reply and mention
-- lookup. Layout folds to one message; the attachment supplies its own media.
captionBody ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AdvertisedCaps -> GroupId -> Maybe Text -> Eff es (Maybe CanonicalMessageId, Body 'Canonical)
captionBody _ _ Nothing = pure (Nothing, Body [])
captionBody caps gid@(GroupId group) (Just caption) = do
  roster <- conversationRoster group
  let target =
        ResolveContext
          gid
          [(name, identity.riPrincipalId) | identity <- roster.crIdentities, Just name <- [identity.riDisplayName]]
          Nothing
          False
          caps.canReply
          caps.canMention
          caps.canFace
          False
  (_, reply, body) <-
    resolveModelText
      target
      Set.empty
      (T.intercalate "\n" (map chunkSource (planReply (cleanModelText caption))))
  pure (reply, Body (if null body.nodes then [] else body.nodes <> [NText "\n"]))

--------------------------------------------------------------------------------
-- send_file_from_sandbox

sendFileFromSandboxTool ::
  (Blob :> es, Outbound :> es, IOE :> es) =>
  Maybe TurnOutputContext -> GroupId -> SandboxRegistry -> Tool es
sendFileFromSandboxTool output gid sandboxes =
  Tool
    { toolName = "send_file_from_sandbox",
      toolDescription = "Publish a sandbox artifact (.csv/.pdf/.zip/...) as a file in this conversation. Optional name overrides the filename. Maximum 64 MiB.",
      toolSchema =
        toolObject
          [ ("sandbox_id", stringParam "Sandbox containing the file."),
            ("path", stringParam "File path relative to /work, or absolute."),
            ("name", stringParam "Optional displayed filename.")
          ]
          ["sandbox_id", "path"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (sid, path, override) -> do
          entry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
          case entry of
            Nothing -> pure (Left "sandbox not found")
            Just sandbox ->
              liftIO (readSandboxArtifact sandbox.seContainer path) >>= \case
                Left err -> pure (Left err)
                Right bytes -> do
                  blob <- putBlob bytes
                  link <- traverse (liftIO . nextTurnOutputLink) output
                  let name = fromMaybe (T.pack (takeFileName (T.unpack path))) override
                      meta = MediaMeta MFile Nothing (Just (fromIntegral (BS.length bytes))) (Just name) Nothing Nothing
                  outcome <-
                    sendRecorded
                      OutboundRequest
                        { orKind = KindChat,
                          orGroupId = gid,
                          orBody = Body [NMedia (mediaBlobRef (blobRefSha256 blob)) meta],
                          orReplyTo = Nothing,
                          orDeliveryScope = DeliverConversation,
                          orTurnOutput = link,
                          orMonitorFireId = Nothing
                        }
                  pure $ case outcome of
                    PublicationFailed err -> Left ("file publication failed: " <> err)
                    Published canonical ->
                      Right
                        ( object
                            [ "ok" .= True,
                              "name" .= name,
                              "_max_journal_canonical_message_id" .= canonical.unCanonicalMessageId
                            ]
                        )
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "name"
