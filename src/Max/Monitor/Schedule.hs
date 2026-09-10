-- | Pure cron calculation in the configured display timezone.
module Max.Monitor.Schedule (nextCronFire, TimePolicy (..), resolveTimeSpec) where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, addUTCTime, localTimeToUTC, utc, utcToLocalTime)
import Max.Time.Parse (parseTimeArg)
import System.Cron (CronSchedule, nextMatch)
import System.Cron.Parser (parseCronSchedule)

nextCronFire :: TimeZone -> CronSchedule -> UTCTime -> Maybe UTCTime
nextCronFire tz schedule after = do
  let pseudo = localTimeToUTC utc (utcToLocalTime tz after)
  pseudoNext <- nextMatch schedule pseudo
  pure (localTimeToUTC tz (utcToLocalTime utc pseudoNext))

-- | Tool-specific horizon and corrective error wording; time interpretation
-- itself is shared. Optional-argument normalization belongs to the caller.
data TimePolicy = TimePolicy
  { maximumMinutes :: !Int,
    horizonError :: !Text,
    missingError :: !Text,
    multipleError :: !Text
  }

resolveTimeSpec :: TimePolicy -> TimeZone -> UTCTime -> Maybe Int -> Maybe Text -> Maybe Text -> Either Text (Maybe Text, UTCTime)
resolveTimeSpec policy tz now minutes absolute cron = case (minutes, absolute, cron) of
  (Just count, Nothing, Nothing)
    | count <= 0 -> Left "in_minutes 必须是正整数"
    | count > policy.maximumMinutes -> Left policy.horizonError
    | otherwise -> Right (Nothing, addUTCTime (fromIntegral count * 60) now)
  (Nothing, Just value, Nothing) -> do
    fireAt <- parseTimeArg tz value
    if fireAt <= now then Left "指定的时间已经过去了" else Right (Nothing, fireAt)
  (Nothing, Nothing, Just expression) -> case parseCronSchedule (T.strip expression) of
    Left err -> Left ("cron 表达式无效：" <> T.pack err)
    Right schedule -> case nextCronFire tz schedule now of
      Nothing -> Left "这个 cron 表达式算不出下一次触发时间"
      Just fireAt -> Right (Just (T.strip expression), fireAt)
  (Nothing, Nothing, Nothing) -> Left policy.missingError
  _ -> Left policy.multipleError
