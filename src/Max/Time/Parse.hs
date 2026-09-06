-- | Pure model-facing wall-clock input parsing.
module Max.Time.Parse (parseTimeArg) where

import Data.Foldable (asum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (LocalTime, TimeZone, UTCTime, defaultTimeLocale, localTimeToUTC, parseTimeM)

parseTimeArg :: TimeZone -> Text -> Either Text UTCTime
parseTimeArg tz t =
  case asum [parseTimeM True defaultTimeLocale f s :: Maybe LocalTime | f <- fmts] of
    Just lt -> Right (localTimeToUTC tz lt)
    Nothing -> Left ("bad time '" <> t <> "': use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM'")
  where
    s = T.unpack (T.strip t)
    fmts =
      [ "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
        "%Y-%m-%dT%H:%M:%S%QZ",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M"
      ]
