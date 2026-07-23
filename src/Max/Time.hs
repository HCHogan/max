-- |
-- Timezone-aware rendering of the UTC timestamps we store.  Every
-- clock the model or a user reads — the prompt's 现在/[HH:MM] lines,
-- tool result timestamps — goes through here so they all agree on one
-- wall clock (the configured display zone, 'AppConfig.timezone',
-- default UTC+8).  Stored/compared times stay UTC; only presentation
-- is localized.
module Max.Time
  ( fmtHM,
    fmtDate,
    fmtDateHM,
    fmtDateHMS,
    fmtEnvStamp,
    fmtDurationSec,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, defaultTimeLocale, formatTime, utcToZonedTime)

fmtWith :: String -> TimeZone -> UTCTime -> Text
fmtWith fmt tz = T.pack . formatTime defaultTimeLocale fmt . utcToZonedTime tz

-- | @HH:MM@ — the context-line clock.
fmtHM :: TimeZone -> UTCTime -> Text
fmtHM = fmtWith "%H:%M"

-- | @YYYY-MM-DD@.
fmtDate :: TimeZone -> UTCTime -> Text
fmtDate = fmtWith "%Y-%m-%d"

-- | @YYYY-MM-DD HH:MM@.
fmtDateHM :: TimeZone -> UTCTime -> Text
fmtDateHM = fmtWith "%Y-%m-%d %H:%M"

-- | @YYYY-MM-DD HH:MM:SS@.
fmtDateHMS :: TimeZone -> UTCTime -> Text
fmtDateHMS = fmtWith "%Y-%m-%d %H:%M:%S"

-- | Full date + Chinese weekday + time for the prompt's environment
-- block, e.g. @2026-07-13（周日） 15:42@.
fmtEnvStamp :: TimeZone -> UTCTime -> Text
fmtEnvStamp tz t =
  fmtDate tz t
    <> "（"
    <> weekdayCN tz t
    <> "）"
    <> fmtWith " %H:%M" tz t

weekdayCN :: TimeZone -> UTCTime -> Text
weekdayCN tz t = case formatTime defaultTimeLocale "%u" (utcToZonedTime tz t) of
  "1" -> "周一"
  "2" -> "周二"
  "3" -> "周三"
  "4" -> "周四"
  "5" -> "周五"
  "6" -> "周六"
  _ -> "周日"

-- | Chinese-readable duration from seconds: @29 秒@ / @3 分 05 秒@ /
-- @1 小时 02 分@.  Used for the video labels the prompt renders — the
-- model's own duration perception from sampled frames is unreliable,
-- so we always state the probed truth.
fmtDurationSec :: Double -> Text
fmtDurationSec secs
  | h > 0 = T.pack (show h) <> " 小时 " <> pad2 m <> " 分"
  | m > 0 = T.pack (show m) <> " 分 " <> pad2 sec <> " 秒"
  | otherwise = T.pack (show sec) <> " 秒"
  where
    s = max 0 (round secs) :: Int
    (h, rest) = s `divMod` 3600
    (m, sec) = rest `divMod` 60
    pad2 n = (if n < 10 then "0" else "") <> T.pack (show n)
