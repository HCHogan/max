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
import Max.Effects.FileTransfer (FileTransfer, runFileTransfer)
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (..),
    OutboundRequest (..),
    PublicationResult (..),
    sendRecorded,
  )
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
    SandboxRegistry,
    ensureSandbox,
    readSandboxBytes,
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
  (Blob :> es, Outbound :> es, Log :> es, WithConnection :> es, IOE :> es) =>
  ToolContext -> SandboxRegistry -> Eff (FileTransfer : es) a -> Eff es a
runFileTransferWithDatabase context sandboxes = runFileTransfer image file
  where
    gid = toolGroupId context
    output = toolTurnOutputContext context
    resolveCaption = captionBody (toolOutputCapabilities context) gid
    -- Publish exactly the bytes read here: later writes to the same path in
    -- a concurrent command cannot change what this call sends.
    artifact path =
      liftIO $
        ensureSandbox sandboxes gid >>= \case
          Left err -> pure (Left err)
          Right entry -> readSandboxBytes sandboxes gid entry.seId path
    image path mCaption =
      artifact path >>= \case
        Left err -> pure (Left err)
        Right bytes -> do
          blob <- putBlob bytes
          (replyTo, caption) <- resolveCaption mCaption
          let source = mediaBlobRef (blobRefSha256 blob)
              body = Body (caption.nodes <> [NMedia source (imageMeta bytes)])
          turnOutput <- traverse (liftIO . nextTurnOutputLink) output
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
            Published canonical -> do
              logInfo "image sent from sandbox" $ object ["path" .= path, "bytes" .= BS.length bytes]
              pure (Right (published canonical ["bytes" .= BS.length bytes]))
    file path override =
      artifact path >>= \case
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
            Published canonical -> Right (published canonical ["name" .= name])
    -- The public message id can be quoted with [reply#id]; the journal keeps
    -- its own private copy.
    published canonical fields =
      object $
        ["ok" .= True, "message_id" .= canonical.unCanonicalMessageId, "_max_journal_canonical_message_id" .= canonical.unCanonicalMessageId]
          <> fields
    imageMeta bytes =
      MediaMeta
        { kind = MImage,
          mime = Just "image/png",
          sizeBytes = Just (fromIntegral (BS.length bytes)),
          name = Just "sandbox.png",
          description = Nothing,
          raw = Nothing
        }
