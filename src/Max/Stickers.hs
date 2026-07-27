-- |
-- Background sticker captioning: polls @stickers@ rows whose
-- @description@ is NULL, loads the image bytes from the blob store,
-- and asks a vision-capable LLM profile for a retrieval-friendly
-- caption (what's in it, any text, the emotion, when you'd send it).
-- The embed worker then vectorises the caption for send_sticker's
-- semantic search.
--
-- Same polling shape as "Max.Embedder": no write-path plumbing, free
-- backfill of everything the ingest layer recorded before this
-- worker existed.  A row that keeps failing stops being retried
-- after 'maxCaptionAttempts' — one poison GIF must not wedge the
-- queue.  The model can also answer SKIP to flag content that has
-- no business being resent (real-people photos, screenshots with
-- personal info); those rows get banned instead of captioned.
module Max.Stickers
  ( stickerCaptionWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (forever)
import Data.Foldable (traverse_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query_)
import Max.Effects.LLM
  ( ChatCtx (..),
    ChatMessage (..),
    ChatResponse (..),
    ContentBlock (..),
    LLM,
    chat,
  )
import Max.Util (catchSync)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Process (readProcessWithExitCode)

maxCaptionAttempts :: Int
maxCaptionAttempts = 5

batchSize :: Int
batchSize = 4

idleMicros :: Int
idleMicros = 30_000_000

busyMicros :: Int
busyMicros = 2_000_000

errorMicros :: Int
errorMicros = 60_000_000

-- | Image bigger than this is not worth captioning (and providers
-- reject it anyway).
maxCaptionBytes :: Int
maxCaptionBytes = 5 * 1024 * 1024

stickerCaptionWorker ::
  (WithConnection :> es, LLM :> es, Log :> es, IOE :> es) =>
  Text -> -- vision-capable LLM profile name
  FilePath -> -- blob store root
  Eff es ()
stickerCaptionWorker profile blobRoot = localDomain "sticker-caption" $ do
  logInfo "sticker caption worker started" $ object ["profile" .= profile]
  forever $
    tick `catchSync` \e -> do
      logAttention "caption: tick crashed" $ object ["error" .= T.pack (show e)]
      liftIO (threadDelay errorMicros)
  where
    tick = do
      rows <-
        query_ . fromString $
          "SELECT s.sha256, i.mime_type, i.local_path, s.summary \
          \ FROM stickers s JOIN images i USING (sha256) \
          \ WHERE s.description IS NULL AND NOT s.banned \
          \   AND s.caption_attempts < "
            <> show maxCaptionAttempts
            <> " ORDER BY s.last_seen_at DESC LIMIT "
            <> show batchSize
      if null (rows :: [(Text, Text, Text, Maybe Text)])
        then liftIO (threadDelay idleMicros)
        else do
          traverse_ (captionOne profile blobRoot) rows
          liftIO (threadDelay busyMicros)

captionOne ::
  (WithConnection :> es, LLM :> es, Log :> es, IOE :> es) =>
  Text ->
  FilePath ->
  (Text, Text, Text, Maybe Text) ->
  Eff es ()
captionOne profile blobRoot (sha, mime, path, mSummary) = do
  ebytes <- liftIO (try @IOException (BS.readFile (blobRoot </> T.unpack path)))
  case ebytes of
    Left e -> failed ("read: " <> T.pack (show e))
    Right bytes
      | BS.length bytes > maxCaptionBytes ->
          failed ("too large: " <> T.pack (show (BS.length bytes)))
      | otherwise -> do
          -- Animated GIFs get a first-frame PNG extracted (several
          -- providers only take static images); if ffmpeg isn't
          -- around, try our luck with the GIF itself.
          (mime', bytes') <-
            if mime == "image/gif"
              then liftIO (firstFrame bytes)
              else pure (mime, bytes)
          let dataUrl =
                "data:" <> mime' <> ";base64," <> TE.decodeUtf8 (B64.encode bytes')
              hint = case mSummary of
                Just s | not (T.null s) -> "（发送方标注：" <> s <> "）"
                _ -> ""
          eres <-
            chat
              (ChatCtx "caption" Nothing)
              profile
              [ MsgSystem captionSystem,
                MsgUserBlocks [TextBlock ("这个表情包" <> hint <> "："), ImageDataUrl dataUrl]
              ]
              []
          case eres of
            Left err -> failed ("chat: " <> err)
            Right (ToolCallsResp _ _ _) -> failed "chat: unexpected tool calls"
            Right (ContentResp raw) -> apply (T.strip raw)
  where
    failed reason = do
      logAttention "caption: failed" $ object ["sha" .= sha, "reason" .= reason]
      _ <-
        execute
          "UPDATE stickers SET caption_attempts = caption_attempts + 1 WHERE sha256 = ?"
          (Only sha)
      pure ()
    apply t
      | T.null t = failed "chat: empty caption"
      | "SKIP" `T.isPrefixOf` T.toUpper t = do
          _ <-
            execute
              "UPDATE stickers SET banned = true, description = '(skipped by captioner)' \
              \ WHERE sha256 = ?"
              (Only sha)
          logInfo "caption: banned by model" $ object ["sha" .= sha]
      | otherwise = do
          _ <-
            execute
              "UPDATE stickers SET description = ? WHERE sha256 = ?"
              (T.take 600 t, sha)
          logInfo "caption: stored" $
            object ["sha" .= sha, "caption" .= T.take 80 t]

captionSystem :: Text
captionSystem =
  T.unlines
    [ "你在为 QQ 群的表情包库写检索用简介。看图，输出 1-2 句中文描述：",
      "画面内容、图里的文字（原样引用）、表达的情绪，以及适合的使用场合",
      "（如：嘲讽、幸灾乐祸、无语、赞同、开心、贴贴、催促）。",
      "直接输出描述本身，不要任何开场白或引号。",
      "如果这张图不适合被 bot 转发使用（真人照片、含隐私信息的聊天截图、",
      "纯粹的普通照片而非表情包），只输出 SKIP。"
    ]

-- | Extract the first frame of a GIF as PNG via ffmpeg.  Falls back
-- to the original bytes on any failure.
firstFrame :: ByteString -> IO (Text, ByteString)
firstFrame gif = do
  r <- try @IOException run
  pure $ case r of
    Right (Just png) -> ("image/png", png)
    _ -> ("image/gif", gif)
  where
    run = do
      tmp <- getTemporaryDirectory
      (inPath, h) <- openTempFile tmp "max-sticker.gif"
      hClose h
      BS.writeFile inPath gif
      let outPath = inPath <> ".png"
      (code, _, _) <-
        readProcessWithExitCode
          "ffmpeg"
          ["-y", "-loglevel", "error", "-i", inPath, "-frames:v", "1", outPath]
          ""
      out <- case code of
        ExitSuccess -> Just <$> BS.readFile outPath
        ExitFailure _ -> pure Nothing
      _ <- try @IOException (removeFile inPath)
      _ <- try @IOException (removeFile outPath)
      pure out
