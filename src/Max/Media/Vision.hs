-- | Vision-token accounting for a provider's declared envelope
-- ('VisionLimits'). Costs follow the Qwen-VL geometry NInfer uses: one token
-- per 32×32 merged patch, two video frames per temporal patch. A request over
-- any bound is rejected whole, so Max plans renditions to fit and evicts the
-- oldest media of a turn instead of sending an oversized request.
module Max.Media.Vision
  ( imageDimensions,
    imageVisionTokens,
    imageTokenCap,
    imageGrid,
    blockVisionTokens,
    VideoSource (..),
    VideoWindow (..),
    wholeVideo,
    VideoPlan (..),
    VideoAttachment (..),
    planVideo,
    videoTokenCap,
    videoVisionTokens,
    videoNote,
    fitVisionBudget,
    evictMedia,
  )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.List (mapAccumL)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.LLM.Types (ChatMessage (..), ContentBlock (..))
import Max.ModelCatalog (VisionLimits (..))
import Max.Time (fmtDurationSec)
import Numeric (showFFloat)

-- | Pixel width and height from a PNG, JPEG, GIF or WebP header.
imageDimensions :: ByteString -> Maybe (Int, Int)
imageDimensions bytes
  | BS.isPrefixOf "\x89PNG\r\n\x1a\n" bytes = (,) <$> be32 16 <*> be32 20
  | BS.isPrefixOf "GIF8" bytes = (,) <$> le16 6 <*> le16 8
  | BS.isPrefixOf "\xff\xd8" bytes = jpeg 2
  | BS.isPrefixOf "RIFF" bytes && BS.take 4 (BS.drop 8 bytes) == "WEBP" = webp (BS.take 4 (BS.drop 12 bytes))
  | otherwise = Nothing
  where
    byte i = fromIntegral <$> BS.indexMaybe bytes i :: Maybe Int
    be16 i = (\a b -> a `shiftL` 8 .|. b) <$> byte i <*> byte (i + 1)
    be32 i = (\a b -> a `shiftL` 16 .|. b) <$> be16 i <*> be16 (i + 2)
    le16 i = (\a b -> b `shiftL` 8 .|. a) <$> byte i <*> byte (i + 1)
    le24 i = (\a b -> b `shiftL` 16 .|. a) <$> le16 i <*> byte (i + 2)
    -- Walk marker segments to the first start-of-frame; standalone markers
    -- carry no length.
    jpeg i = do
      0xff <- byte i
      marker <- byte (i + 1)
      case marker of
        0xff -> jpeg (i + 1)
        _
          | marker `elem` [0xc0 .. 0xcf] && marker `notElem` [0xc4, 0xc8, 0xcc] -> (,) <$> be16 (i + 7) <*> be16 (i + 5)
          | marker `elem` 0x01 : [0xd0 .. 0xd8] -> jpeg (i + 2)
          | otherwise -> be16 (i + 2) >>= \len -> jpeg (i + 2 + len)
    webp = \case
      "VP8 " -> pair ((.&. 0x3fff) <$> le16 26) ((.&. 0x3fff) <$> le16 28)
      "VP8L" -> do
        b0 <- byte 21
        b1 <- byte 22
        b2 <- byte 23
        b3 <- byte 24
        pure (1 + ((b1 .&. 0x3f) `shiftL` 8 .|. b0), 1 + ((b3 .&. 0x0f) `shiftL` 10 .|. b2 `shiftL` 2 .|. (b1 .&. 0xc0) `shiftR` 6))
      "VP8X" -> pair ((+ 1) <$> le24 24) ((+ 1) <$> le24 27)
      _ -> Nothing
    pair a b = (,) <$> a <*> b

-- | Tokens the server spends on an image of this size, including its
-- rounding to 32-pixel patches and its upscaling of tiny images. Images above
-- the item bound are downscaled by the server; callers cap at 'itemTokens'.
imageVisionTokens :: Int -> Int -> Int
imageVisionTokens width height
  | width <= 0 || height <= 0 = minimumTokens
  | rows * columns < minimumTokens = max minimumTokens (up height * up width)
  | otherwise = rows * columns
  where
    rows = round (fromIntegral height / 32 :: Double)
    columns = round (fromIntegral width / 32 :: Double)
    beta = sqrt (fromIntegral (minimumTokens * 1024) / (fromIntegral width * fromIntegral height)) :: Double
    up side = ceiling (fromIntegral side * beta / 32)
    minimumTokens = 64

-- | Per-image preparation bound: half an item, so one image never crowds out
-- a video.
imageTokenCap :: VisionLimits -> Int
imageTokenCap limits = max 256 (limits.itemTokens `div` 2)

-- | The largest patch grid (columns, rows) within a token budget that keeps
-- the aspect ratio and never exceeds the source resolution.
imageGrid :: Int -> Int -> Int -> (Int, Int)
imageGrid tokens width height = (columns, rows)
  where
    aspect = fromIntegral (max 1 width) / fromIntegral (max 1 height) :: Double
    maxRows = max 1 (round (fromIntegral height / 32 :: Double))
    maxColumns = max 1 (round (fromIntegral width / 32 :: Double))
    rows = min maxRows (max 1 (floor (sqrt (fromIntegral (max 1 tokens) / aspect))))
    columns = max 1 (minimum [max 1 tokens `div` rows, maxColumns, max 1 (round (aspect * fromIntegral rows))])

-- | Vision tokens of one block as sent. Unknown sizes count as a whole item.
blockVisionTokens :: VisionLimits -> ContentBlock -> Int
blockVisionTokens limits = \case
  ImageDataUrl url -> min limits.itemTokens (maybe limits.itemTokens (uncurry imageVisionTokens) (dataUrlDimensions url))
  VideoDataUrl _ tokens -> maybe (videoTokenCap limits) (min (videoTokenCap limits)) tokens
  _ -> 0

-- Decode only the header region of an inline image.
dataUrlDimensions :: Text -> Maybe (Int, Int)
dataUrlDimensions url = case T.breakOn ";base64," url of
  (_, rest) | not (T.null rest) -> imageDimensions (B64.decodeLenient (TE.encodeUtf8 (T.take 349524 (T.drop 8 rest))))
  _ -> Nothing

data VideoSource = VideoSource
  { sourceWidth :: !Int,
    sourceHeight :: !Int,
    sourceSeconds :: !Double
  }
  deriving stock (Show, Eq)

-- | Part of a video to show, in source seconds.
data VideoWindow = VideoWindow
  { windowStart :: !Double,
    windowEnd :: !(Maybe Double)
  }
  deriving stock (Show, Eq)

wholeVideo :: VideoWindow
wholeVideo = VideoWindow 0 Nothing

-- | A rendition that fits one item: a source window, time compression when
-- the window is longer than the server accepts, and a frame rate and patch
-- grid within the token budget.
data VideoPlan = VideoPlan
  { planStart :: !Double,
    planSeconds :: !Double,
    planSpeed :: !Double,
    planFps :: !Double,
    planColumns :: !Int,
    planRows :: !Int,
    planFrames :: !Int,
    planTokens :: !Int
  }
  deriving stock (Show, Eq)

-- | A video ready to attach: its data URL, its vision tokens when prepared
-- for a declared envelope, and a label note (duration, window, speed).
data VideoAttachment = VideoAttachment
  { attachmentDataUrl :: !Text,
    attachmentTokens :: !(Maybe Int),
    attachmentNote :: !Text
  }

-- | Prefer legible frames (at least 256 tokens, about 512×512) over frame
-- rate; the server samples at most 2 fps and its frame cap. One spare frame
-- absorbs encoder rounding.
planVideo :: VisionLimits -> Int -> VideoSource -> VideoWindow -> VideoPlan
planVideo limits budget source window =
  VideoPlan
    { planStart = start,
      planSeconds = span',
      planSpeed = speed,
      planFps = fromIntegral frames / output,
      planColumns = columns,
      planRows = rows,
      planFrames = frames + 1,
      planTokens = videoVisionTokens (frames + 1) columns rows
    }
  where
    duration = max 0.5 source.sourceSeconds
    start = min (max 0 window.windowStart) (max 0 (duration - 0.5))
    end = maybe duration (min duration . max (start + 0.5)) window.windowEnd
    span' = end - start
    limit = max 1 (fromIntegral limits.videoMaxSeconds - 1)
    speed = max 1 (span' / limit)
    output = span' / speed
    tokens = videoTokenCap limits `min` max 64 budget
    legibleGroups = max 1 (tokens `div` 256)
    frames = max 1 (minimum [floor (output * 2), limits.videoMaxFrames - 1, 2 * legibleGroups - 1])
    (columns, rows) = imageGrid (tokens `div` groups (frames + 1)) source.sourceWidth source.sourceHeight

-- | Most tokens one video keeps on the server: its item bound, or less when
-- the video processor downscales a larger pixel volume.
videoTokenCap :: VisionLimits -> Int
videoTokenCap limits = max 64 (min limits.itemTokens (limits.videoMaxPixels `div` 2048))

-- | Tokens of a video with this many frames at a patch grid.
videoVisionTokens :: Int -> Int -> Int -> Int
videoVisionTokens frames columns rows = max 64 (groups frames * columns * rows)

groups :: Int -> Int
groups frames = (max 1 frames + 1) `div` 2

-- | Label text telling the model how rendition time maps to the source:
-- source duration, window start and length, and time compression.
videoNote :: Double -> Double -> Double -> Double -> Text
videoNote sourceSeconds start span' speed =
  "（" <> T.intercalate "，" (["时长 " <> fmtDurationSec sourceSeconds] <> window <> timing) <> "）"
  where
    partial = start > 0.5 || start + span' < sourceSeconds - 0.5
    compressed = speed > 1.05
    factor = T.pack (showFFloat (Just 1) speed "")
    window = ["片段 " <> fmtDurationSec start <> "–" <> fmtDurationSec (start + span') | partial]
    timing =
      ["已压缩为 " <> factor <> " 倍速概览，画面时间 ×" <> factor <> (if start > 0.5 then " 再加片段起点" else "") <> " 才是原片时间" | compressed]
        <> ["画面时间加 " <> fmtDurationSec start <> " 为原片时间" | start > 0.5, not compressed]

-- | Evict the oldest media until the request fits its declared envelope.
-- Returns the messages and how many media were evicted.
fitVisionBudget :: VisionLimits -> [ChatMessage] -> ([ChatMessage], Int)
fitVisionBudget limits messages
  | excess <= 0 = (messages, 0)
  | otherwise = evictMedia (1 + length (takeWhile (< excess) (scanl1 (+) costs))) messages
  where
    costs = [blockVisionTokens limits block | MsgUserBlocks blocks <- messages, block <- blocks, media block]
    excess = sum costs - limits.requestTokens

-- | Replace the oldest @n@ media with a text note, merging the text around it.
evictMedia :: Int -> [ChatMessage] -> ([ChatMessage], Int)
evictMedia n messages = (evicted, n - remaining)
  where
    (remaining, evicted) = mapAccumL message n messages
    message left = \case
      MsgUserBlocks blocks | left > 0 && any media blocks ->
        let (left', blocks') = mapAccumL block left blocks
         in (left', MsgUserBlocks (mergeText blocks'))
      other -> (left, other)
    block left b
      | left > 0 && media b = (left - 1, TextBlock placeholder)
      | otherwise = (left, b)
    placeholder = "[这个附件已移出上下文，为后来的图片或视频腾出视觉预算；需要时可以重新查看]"
    mergeText = \case
      TextBlock a : TextBlock b : rest -> mergeText (TextBlock (a <> "\n" <> b) : rest)
      x : rest -> x : mergeText rest
      [] -> []

media :: ContentBlock -> Bool
media = \case
  ImageDataUrl _ -> True
  VideoDataUrl _ _ -> True
  _ -> False
