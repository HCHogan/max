-- | Pure cron calculation in the configured display timezone.
module Max.Monitor.Schedule (nextCronFire) where

import Data.Time (TimeZone, UTCTime, localTimeToUTC, utc, utcToLocalTime)
import System.Cron (CronSchedule, nextMatch)

nextCronFire :: TimeZone -> CronSchedule -> UTCTime -> Maybe UTCTime
nextCronFire tz schedule after = do
  let pseudo = localTimeToUTC utc (utcToLocalTime tz after)
  pseudoNext <- nextMatch schedule pseudo
  pure (localTimeToUTC tz (utcToLocalTime utc pseudoNext))
