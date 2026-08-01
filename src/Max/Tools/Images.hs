-- |
-- On-demand loading of context images.  The prompt builder inlines
-- only the images the user is plausibly pointing at (reply target /
-- trigger / pins); everything else in the group history renders as an
-- @[image#\<id\>]@ marker, and this tool is how the model turns such a
-- marker back into pixels — same injection channel (and per-dispatch
-- budget) as @view_avatar@.
module Max.Tools.Images
  ( imageToolsFor,
    viewImageSpec,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.History (HistoryItem (..), bestName, fetchMessage)
import Max.Effects.LLM (ToolSpec (..))
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
import Max.ImagePrep (prepareImageForLLM)
import Max.Time (fmtHM)
import Max.ToolContext (ToolContext, toolMultimodal)
import System.FilePath ((</>))

-- | Same per-image cap as the prompt builder's inline path.
maxImageBytes :: Int
maxImageBytes = 20 * 1024 * 1024

imageToolsFor ::
  (WithConnection :> es, Log :> es, ToolOutput :> es, IOE :> es) =>
  TimeZone -> -- display timezone for the image label's HH:MM
  FilePath -> -- blob store root ('AppConfig.imagesDir')
  ToolContext ->
  [Tool es]
imageToolsFor tz blobRoot dc
  | toolMultimodal dc = [viewImageTool tz blobRoot]
  | otherwise = []

viewImageTool ::
  (WithConnection :> es, Log :> es, ToolOutput :> es, IOE :> es) =>
  TimeZone ->
  FilePath ->
  Tool es
viewImageTool tz blobRoot =
  Tool
    { toolName = viewImageSpec.specName,
      toolDescription = viewImageSpec.specDescription,
      toolSchema = viewImageSpec.specSchema,
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> do
          rows <-
            query
              "SELECT i.mime_type, i.local_path \
              \  FROM message_images mi \
              \  JOIN images i ON i.sha256 = mi.sha256 \
              \  WHERE mi.message_id = ? \
              \  ORDER BY mi.seg_index"
              (Only mid)
          case rows :: [(Text, Text)] of
            [] -> pure $ Left "这条消息没有已存的图片（id 写错了？或图片没下载成功）"
            imgs -> do
              label <- imageLabel mid
              attached <- attachAll label (zip [1 :: Int ..] imgs) (length imgs)
              pure $
                if attached == 0
                  then Left "图片没能附上（配额用完或文件缺失，看日志）"
                  else
                    Right $
                      object
                        [ "attached" .= attached,
                          "total" .= length imgs,
                          "note" .= ("图片已附在下一条消息里" :: Text)
                        ]
    }
  where
    parseArgs :: Object -> Parser Int64
    parseArgs o = o .: "message_id"

    -- "[10:32 Alice] 消息里的图片" — mirrors the label the prompt
    -- builder puts on inline images, so both kinds read the same.
    imageLabel mid =
      fetchMessage mid >>= \case
        Nothing -> pure ("[message " <> T.pack (show mid) <> "] 里的图片")
        Just h ->
          pure $
            "["
              <> fmtHM tz h.receivedAt
              <> " "
              <> fromMaybe (T.pack (show h.userId)) (bestName h)
              <> "] 消息里的图片"

    attachAll _ [] _ = pure (0 :: Int)
    attachAll label ((i, (mime, path)) : rest) total = do
      let numbered
            | total == 1 = label <> ":"
            | otherwise = label <> " (" <> T.pack (show i) <> "/" <> T.pack (show total) <> "):"
      eres <- liftIO (try (BS.readFile (blobRoot </> T.unpack path)))
      case eres of
        Left (e :: IOException) -> do
          logAttention "view_image: read failed" $
            object ["path" .= path, "error" .= T.pack (show e)]
          attachAll label rest total
        Right bytes0 -> do
          (mime', bytes) <- liftIO (prepareImageForLLM mime bytes0)
          if BS.length bytes > maxImageBytes
            then do
              logAttention "view_image: skipped (too large)" $
                object ["path" .= path, "bytes" .= BS.length bytes]
              attachAll label rest total
            else do
              let b64 = TE.decodeUtf8 (B64.encode bytes)
                  dataUrl = "data:" <> mime' <> ";base64," <> b64
              ok <- queueInlineMedia (InlineMedia numbered dataUrl)
              if ok
                then (1 +) <$> attachAll label rest total
                else pure 0

-- | Protocol-neutral metadata advertised for @view_image@.  Kept apart
-- from the effectful runner so request renderers (including the generated
-- prompt-flow reference) can use the exact live schema without needing a
-- database or blob store.
viewImageSpec :: ToolSpec
viewImageSpec =
  ToolSpec
    { specName = "view_image",
      specDescription =
        "查看上下文里标记为 [image#<id>] 的图片：传 message_id，那条消息的图\
        \会附在下一条消息里给你看。只在图片跟当前话题相关时用；\
        \与 view_avatar 共用每次任务 8 张的配额。",
      specSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("[image#<id>] 里的那个 id" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ]
    }
