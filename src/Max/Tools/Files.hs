-- | Publish sandbox files into the conversation as blob-backed messages.
-- Incoming chat files need no tool: the sandbox mirrors them under /chat.
-- The delivery worker owns platform sends and receipts.
module Max.Tools.Files
  ( fileTools,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.FileTransfer
  ( FileTransfer,
    sendSandboxFile,
    sendSandboxImage,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Tools.Schema
  ( stringParam,
    toolObject,
  )

fileTools :: (FileTransfer :> es) => [Tool es]
fileTools = [sendImageTool, sendFileTool]

--------------------------------------------------------------------------------
-- send_image

sendImageTool :: (FileTransfer :> es) => Tool es
sendImageTool =
  Tool
    { toolName = "send_image",
      toolDescription =
        "Post an image file from the sandbox into the chat as an inline picture \
        \(charts, screenshots; a few MB max — other artifacts go via send_file). \
        \Optional 'caption' text precedes it.  Returns the new message_id.",
      toolSchema =
        toolObject
          [ ("path", stringParam "Image path in the sandbox (absolute, or relative to /work)."),
            ("caption", stringParam "Optional caption to send before the image.")
          ]
          ["path"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (path, mCaption) -> sendSandboxImage path mCaption
    }
  where
    parseArgs :: Object -> Parser (Text, Maybe Text)
    parseArgs o = (,) <$> o .: "path" <*> o .:? "caption"

--------------------------------------------------------------------------------
-- send_file

sendFileTool :: (FileTransfer :> es) => Tool es
sendFileTool =
  Tool
    { toolName = "send_file",
      toolDescription = "Publish a sandbox file (.csv/.pdf/.zip/...) as a file in this conversation. Optional name overrides the filename. Maximum 64 MiB. Returns the new message_id.",
      toolSchema =
        toolObject
          [ ("path", stringParam "File path in the sandbox (absolute, or relative to /work)."),
            ("name", stringParam "Optional displayed filename.")
          ]
          ["path"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" parseArgs) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (path, override) -> sendSandboxFile path override
    }
  where
    parseArgs :: Object -> Parser (Text, Maybe Text)
    parseArgs o = (,) <$> o .: "path" <*> o .:? "name"
