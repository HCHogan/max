-- | Import catalogued group files into sandboxes and publish blob-backed
-- images/files. The delivery worker owns platform sends and receipts.
module Max.Tools.Files
  ( fileToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Max.Effects.FileTransfer
  ( FileTransfer,
    importGroupFile,
    sendSandboxFile,
    sendSandboxImage,
  )
import Max.Effects.MediaQuery (MediaQuery)
import Max.Effects.MediaQuery qualified as MediaQuery
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.File.Types (FileRecord (..))
import Max.Time (fmtDateHMS)
import Max.Tools.Schema
  ( integerParam,
    stringParam,
    toolObject,
    withKeys,
  )

fileToolsFor :: (MediaQuery :> es, FileTransfer :> es) => TimeZone -> [Tool es]
fileToolsFor tz = [listRecentFilesTool tz, importFileToSandboxTool, sendImageFromSandboxTool, sendFileFromSandboxTool]

--------------------------------------------------------------------------------
-- list_recent_files

listRecentFilesTool ::
  (MediaQuery :> es) =>
  TimeZone ->
  Tool es
listRecentFilesTool tz =
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
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right lim -> do
          rows <- MediaQuery.listFiles lim
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

importFileToSandboxTool :: (FileTransfer :> es) => Tool es
importFileToSandboxTool =
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
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (fid, sid, mDest) -> importGroupFile fid sid mDest
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "file_id" <*> o .: "sandbox_id" <*> o .:? "dest_path"

--------------------------------------------------------------------------------
-- send_image_from_sandbox

sendImageFromSandboxTool :: (FileTransfer :> es) => Tool es
sendImageFromSandboxTool =
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
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (sid, path, mCaption) -> sendSandboxImage sid path mCaption
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "caption"

-- send_file_from_sandbox

sendFileFromSandboxTool :: (FileTransfer :> es) => Tool es
sendFileFromSandboxTool =
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
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (sid, path, override) -> sendSandboxFile sid path override
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Maybe Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .:? "name"
