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

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone)
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.Log
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.MediaQuery (MediaQuery, readImages)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
import Max.History.Types (HistoryItem (..), bestName)
import Max.Media.Types (StoredImage (..))
import Max.Time (fmtHM)
import Max.Tool.Types (ToolSpec (..))
import Max.ToolContext (ToolContext, toolMultimodal)
import Max.Tools.Schema (integerParam, toolObject)

-- | Same per-image cap as the prompt builder's inline path.
maxImageBytes :: Int
maxImageBytes = 20 * 1024 * 1024

imageToolsFor ::
  (Blob :> es, MediaQuery :> es, Log :> es, ToolOutput :> es) =>
  TimeZone -> -- display timezone for the image label's HH:MM
  ToolContext ->
  (Text -> BS.ByteString -> Eff es (Text, BS.ByteString)) ->
  [Tool es]
imageToolsFor tz dc prepare
  | toolMultimodal dc = [viewImageTool tz prepare]
  | otherwise = []

viewImageTool ::
  (Blob :> es, MediaQuery :> es, Log :> es, ToolOutput :> es) =>
  TimeZone ->
  (Text -> BS.ByteString -> Eff es (Text, BS.ByteString)) ->
  Tool es
viewImageTool tz prepare =
  Tool
    { toolName = viewImageSpec.specName,
      toolDescription = viewImageSpec.specDescription,
      toolSchema = viewImageSpec.specSchema,
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mid, seg) -> do
          (message, rows) <- readImages mid seg
          case rows of
            [] -> pure $ Left "这条消息没有已存的图片（id 写错了？或图片没下载成功）"
            imgs -> do
              let label = imageLabel mid message
              let refs = [(i.storedImageMime, i.storedImageSha256) | i <- imgs]
              attached <- attachAll label (zip [1 :: Int ..] refs) (length refs)
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
    parseArgs :: Object -> Parser (Int64, Maybe Int)
    parseArgs o = (,) <$> o .: "message_id" <*> o .:? "seg_index"

    -- "[10:32 Alice] 消息里的图片" — mirrors the label the prompt
    -- builder puts on inline images, so both kinds read the same.
    imageLabel mid = \case
      Nothing -> "[message " <> T.pack (show mid) <> "] 里的图片"
      Just h ->
        "["
          <> fmtHM tz h.receivedAt
          <> " "
          <> bestName h
          <> "] 消息里的图片"

    attachAll _ [] _ = pure (0 :: Int)
    attachAll label ((i, (mime, sha)) : rest) total = do
      let numbered
            | total == 1 = label <> ":"
            | otherwise = label <> " (" <> T.pack (show i) <> "/" <> T.pack (show total) <> "):"
      case blobRefFromSha256 sha of
        Nothing -> do
          logAttention "view_image: invalid blob ref" $ object ["sha256" .= sha]
          attachAll label rest total
        Just ref -> do
          eres <- try @IOException (readBlob ref)
          case eres of
            Left e -> do
              logAttention "view_image: read failed" $
                object ["sha256" .= sha, "error" .= T.pack (show e)]
              attachAll label rest total
            Right bytes0 -> do
              (mime', bytes) <- prepare mime bytes0
              if BS.length bytes > maxImageBytes
                then do
                  logAttention "view_image: skipped (too large)" $
                    object ["sha256" .= sha, "bytes" .= BS.length bytes]
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
        "查看上下文里标记为 [image#<id>.<seg>] 的图片：把这两个数字分别传给\
        \ message_id 和 seg_index，那张图会附在下一条消息里给你看；省略\
        \ seg_index 就是那条消息的全部图片。只在图片跟当前话题相关时用；\
        \与 view_avatar 共用每次任务 8 张的配额。",
      specSchema =
        toolObject
          [ ("message_id", integerParam "[image#<id>.<seg>] 里 . 前面那个数字"),
            ("seg_index", integerParam "[image#<id>.<seg>] 里 . 后面那个数字；省略就看这条消息的全部图片")
          ]
          ["message_id"]
    }
