-- | Conversation-bound artifact transfer. Host paths, sandbox registry and
-- output identity allocation never enter the model protocol module.
module Max.File.TransferRuntime (runFileTransferWithDatabase) where

import Data.Aeson (KeyValue ((.=)), object)
import Data.ByteString qualified as BS (length)
import Data.Maybe (fromMaybe)
import Data.Text qualified as T (pack, unpack)
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Log (Log, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.Effects.BlobHost (BlobHost, resolveBlobHostPath)
import Max.Effects.FileTransfer (FileTransfer, runFileTransfer)
import Max.Effects.MediaQuery (MediaQuery)
import Max.Effects.MediaQuery qualified as MediaQuery
  ( readStoredFile,
  )
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (..),
    OutboundRequest (..),
    PublicationResult (..),
    sendRecorded,
  )
import Max.File.Types (FileRecord (..))
import Max.IR
  ( Body (Body, nodes),
    MediaKind (MFile, MImage),
    MediaMeta
      ( MediaMeta,
        description,
        kind,
        mime,
        name,
        raw,
        sizeBytes
      ),
    Node (NMedia),
    mediaBlobRef,
  )
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Reply.Caption (captionBody)
import Max.Sandbox.Registry
  ( SandboxEntry (..),
    SandboxId (..),
    SandboxRegistry,
    listSandbox,
  )
import Max.Sandbox.Runtime
  ( readSandboxArtifact,
    runCopyToContainer,
  )
import Max.ToolContext
  ( ToolContext,
    toolGroupId,
    toolOutputCapabilities,
    toolTurnOutputContext,
  )
import Max.Turn.Types (nextTurnOutputLink)
import System.FilePath (takeFileName)

runFileTransferWithDatabase ::
  (BlobHost :> es, Blob :> es, MediaQuery :> es, Outbound :> es, Log :> es, WithConnection :> es, IOE :> es) =>
  ToolContext -> SandboxRegistry -> Eff (FileTransfer : es) a -> Eff es a
runFileTransferWithDatabase context sandboxes = runFileTransfer copy image file
  where
    gid = toolGroupId context
    turnOutputContext = toolTurnOutputContext context
    output = turnOutputContext
    resolveCaption = captionBody (toolOutputCapabilities context) gid
    copy fid sid mDest = do
      mFile <- MediaQuery.readStoredFile fid
      case mFile of
        Nothing -> pure (Left "unknown file_id (try list_recent_files first)")
        Just r -> case r.frBlobRef of
          Nothing -> pure (Left "file not yet downloaded — try again in a moment")
          Just ref -> do
            mEntry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
            case mEntry of
              Nothing -> pure (Left "sandbox not found")
              Just e -> do
                -- the runtime client opens a host path; this is one of the
                -- deliberately explicit Blob boundary escapes.
                hostPath <- resolveBlobHostPath ref
                let destName = fromMaybe r.frFileName mDest
                    containerPath = "/work/" <> destName
                cpRes <- liftIO (runCopyToContainer e.seContainer hostPath containerPath)
                case cpRes of
                  Left err -> pure (Left ("sandbox copy failed: " <> err))
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
    image sid path mCaption = do
      mEntry <- liftIO (listSandbox sandboxes gid (SandboxId sid))
      case mEntry of
        Nothing -> pure (Left "sandbox not found")
        Just e -> do
          eBytes <- liftIO (readSandboxArtifact e.seContainer path)
          case eBytes of
            Left err -> pure (Left err)
            Right bytes -> do
              blob <- putBlob bytes
              (replyTo, caption) <- resolveCaption mCaption
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
    file sid path override = do
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
