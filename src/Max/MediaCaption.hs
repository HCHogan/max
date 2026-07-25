-- |
-- Background captioning of ordinary chat media, the sibling of
-- "Max.Stickers": polls @images@ / @videos@ rows whose @description@
-- is NULL, loads the bytes from the blob store, and asks the vision
-- profile for a short description.  "Max.Prompt" then renders the
-- markers as @[image#\<id\>: \<简介\>]@ / @[video#\<id\>: \<简介\>]@ —
-- one vision call per blob (content-addressed, so a reposted picture
-- is captioned once), instead of the model re-viewing the same image
-- every dispatch through @view_image@.
--
-- Same polling shape as "Max.Stickers" / "Max.Embedder": no
-- write-path plumbing, attempts-capped so a poison row can't wedge
-- the queue.  Only media first seen in the last 'recencyDays' is
-- considered — captioning years of backlog would be pure spend, the
-- prompt window only ever shows recent history.
--
-- Sticker shas are excluded (their captions live on @stickers@ and
-- feed retrieval, not just display).  Videos are captioned from
-- their first frame (ffmpeg), so an image-only vision profile works.
module Max.MediaCaption
  ( mediaCaptionWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Foldable (traverse_)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query_)
import Max.Effects.LLM
  ( ChatMessage (..),
    ChatResponse (..),
    ContentBlock (..),
    LLM,
    chat,
  )
import Max.ImagePrep (prepareImageForLLM)
import Max.Util (catchSync)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

maxCaptionAttempts :: Int
maxCaptionAttempts = 5

batchSize :: Int
batchSize = 4

-- | Media older than this never gets captioned: the prompt's history
-- window only shows recent messages, so old backlog is dead spend.
recencyDays :: Int
recencyDays = 14

idleMicros :: Int
idleMicros = 30_000_000

busyMicros :: Int
busyMicros = 2_000_000

errorMicros :: Int
errorMicros = 60_000_000

-- | Same provider-side ceiling as the sticker captioner.
maxCaptionBytes :: Int
maxCaptionBytes = 5 * 1024 * 1024

mediaCaptionWorker ::
  (WithConnection :> es, LLM :> es, Log :> es, IOE :> es) =>
  Text -> -- vision-capable LLM profile name
  FilePath -> -- blob store root
  Eff es ()
mediaCaptionWorker profile blobRoot = localDomain "media-caption" $ do
  logInfo "media caption worker started" $ object ["profile" .= profile]
  forever $
    tick `catchSync` \e -> do
      logAttention "media-caption: tick crashed" $ object ["error" .= T.pack (show e)]
      liftIO (threadDelay errorMicros)
  where
    tick = do
      imgs <-
        query_ . fromString $
          "SELECT i.sha256, i.mime_type, i.local_path \
          \ FROM images i \
          \ WHERE i.description IS NULL AND i.caption_attempts < "
            <> show maxCaptionAttempts
            <> "   AND i.first_seen_at > now() - interval '"
            <> show recencyDays
            <> " days' \
              \ AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = i.sha256) \
              \ ORDER BY i.first_seen_at DESC LIMIT "
            <> show batchSize
      vids <-
        query_ . fromString $
          "SELECT v.sha256, v.mime_type, v.local_path \
          \ FROM videos v \
          \ WHERE v.description IS NULL AND v.caption_attempts < "
            <> show maxCaptionAttempts
            <> "   AND v.first_seen_at > now() - interval '"
            <> show recencyDays
            <> " days' \
              \ ORDER BY v.first_seen_at DESC LIMIT "
            <> show batchSize
      if null (imgs :: [(Text, Text, Text)]) && null (vids :: [(Text, Text, Text)])
        then liftIO (threadDelay idleMicros)
        else do
          traverse_ (captionOne "images" imageSystem False) imgs
          traverse_ (captionOne "videos" videoSystem True) vids
          liftIO (threadDelay busyMicros)

    captionOne table sys isVideo (sha, mime, path) = do
      let file = blobRoot </> T.unpack path
          failed reason = do
            logAttention "media-caption: failed" $
              object ["table" .= (table :: Text), "sha" .= sha, "reason" .= (reason :: Text)]
            _ <-
              execute
                (fromString ("UPDATE " <> T.unpack table <> " SET caption_attempts = caption_attempts + 1 WHERE sha256 = ?"))
                (Only sha)
            pure ()
          store t = do
            _ <-
              execute
                (fromString ("UPDATE " <> T.unpack table <> " SET description = ? WHERE sha256 = ?"))
                (T.take 300 t, sha)
            logInfo "media-caption: stored" $
              object ["table" .= (table :: Text), "sha" .= sha, "caption" .= T.take 80 t]
      epayload <-
        if isVideo || mime == "image/gif"
          -- Videos always go through a first-frame extraction; GIFs
          -- too (several providers only take static images).  A 4K
          -- frame decodes to a multi-MB PNG, so it gets the same
          -- shrink pass as regular photos.
          then
            liftIO (firstFrame file) >>= \case
              Nothing -> pure (Left "ffmpeg: no frame")
              Just png -> Right <$> liftIO (prepareImageForLLM "image/png" png)
          else do
            ebytes <- liftIO (try @IOException (BS.readFile file))
            case ebytes of
              Left e -> pure (Left ("read: " <> T.pack (show e)))
              Right bytes -> Right <$> liftIO (prepareImageForLLM mime bytes)
      case epayload of
        Left reason -> failed reason
        Right (mime', bytes)
          | BS.length bytes > maxCaptionBytes ->
              failed ("too large: " <> T.pack (show (BS.length bytes)))
          | otherwise -> do
              let dataUrl = "data:" <> mime' <> ";base64," <> TE.decodeUtf8 (B64.encode bytes)
              eres <-
                chat
                  profile
                  [ MsgSystem sys,
                    MsgUserBlocks [TextBlock lead, ImageDataUrl dataUrl]
                  ]
                  []
              case eres of
                Left err -> failed ("chat: " <> err)
                Right (ToolCallsResp _ _ _) -> failed "chat: unexpected tool calls"
                Right (ContentResp raw)
                  | T.null (T.strip raw) -> failed "chat: empty caption"
                  | otherwise -> store (T.strip raw)
      where
        lead
          | isVideo = "这段视频的第一帧："
          | otherwise = "这张图片："

imageSystem :: Text
imageSystem =
  T.unlines
    [ "你在为 QQ 群聊记录里出现过的图片写简介，给之后回看记录、看不到原图的读者用。",
      "看图输出 1-2 句中文：画面主要内容；是截图就说明是什么内容（报错、代码、网页、",
      "聊天记录等），关键文字原样摘录（报错信息、标题）。",
      "直接输出描述本身，不要任何开场白或引号。"
    ]

videoSystem :: Text
videoSystem =
  T.unlines
    [ "你在为 QQ 群聊里的一段视频写简介，手头只有它的第一帧画面。",
      "据此输出 1 句中文，说明视频大概是什么内容；只描述看得到的，不要编造后续情节。",
      "直接输出描述本身，不要任何开场白或引号。"
    ]

-- | First frame of a media file as PNG via ffmpeg (input format is
-- sniffed from content, the path's extension doesn't matter).
firstFrame :: FilePath -> IO (Maybe ByteString)
firstFrame inPath = do
  r <- try @IOException run
  pure $ case r of
    Right out -> out
    Left _ -> Nothing
  where
    run = do
      tmp <- getTemporaryDirectory
      (outPath, h) <- openTempFile tmp "max-frame.png"
      hClose h
      (code, _, _) <-
        readProcessWithExitCode
          "ffmpeg"
          ["-y", "-loglevel", "error", "-i", inPath, "-frames:v", "1", outPath]
          ""
      out <- case code of
        ExitSuccess -> Just <$> BS.readFile outPath
        ExitFailure _ -> pure Nothing
      _ <- try @IOException (removeFile outPath)
      pure out
