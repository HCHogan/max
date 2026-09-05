module Max.Task.Policy (frontendToolLimit, frontendDeadlineSeconds, retryableFailure) where

import Data.Text (Text)
import Data.Text qualified as T

frontendToolLimit :: Int
frontendToolLimit = 30

frontendDeadlineSeconds :: Int
frontendDeadlineSeconds = 375

retryableFailure :: Text -> Bool
retryableFailure detail =
  any
    (`T.isInfixOf` T.toLower detail)
    [ "http 408",
      "http 429",
      "http 500",
      "http 502",
      "http 503",
      "http 504",
      "status 408",
      "status 429",
      "status 500",
      "status 502",
      "status 503",
      "status 504",
      "timeout",
      "timed out",
      "connection reset",
      "connection refused",
      "connection failed",
      "temporarily unavailable",
      "unexpected eof",
      "rate limit"
    ]
