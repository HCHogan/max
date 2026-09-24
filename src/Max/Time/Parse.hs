-- | Pure model-facing wall-clock input parsing.
module Max.Time.Parse (parseTimeArg) where

import Control.Applicative ((<|>))
import Data.Foldable (asum)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (LocalTime, TimeZone, UTCTime, ZonedTime, defaultTimeLocale, localTimeToUTC, parseTimeM, zonedTimeToUTC)

parseTimeArg :: TimeZone -> Text -> Either Text UTCTime
parseTimeArg tz t =
  case (parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" s :: Maybe UTCTime) <|> asum [zonedTimeToUTC <$> (parseTimeM True defaultTimeLocale f s :: Maybe ZonedTime) | f <- zoned] of
    Just instant -> Right instant
    Nothing -> case asum [parseTimeM True defaultTimeLocale f s :: Maybe LocalTime | f <- fmts] of
      Just lt -> Right (localTimeToUTC tz lt)
      Nothing -> Left ("bad time '" <> t <> "': use YYYY-MM-DD, YYYY-MM-DD HH:MM or ISO-8601 with Z/offset")
  where
    s = T.unpack (T.strip t)
    zoned = ["%Y-%m-%dT%H:%M:%S%Q%Ez", "%Y-%m-%dT%H:%M%Ez", "%Y-%m-%dT%H:%M:%S%Q%z"]
    fmts =
      [ "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%d",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M"
      ]
