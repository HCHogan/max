module Max.Config
  ( AppConfig (..),
    loadFromEnv,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text ()
import Data.Text qualified as T
import OneBot.Server (ServerConfig (..))
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

newtype AppConfig = AppConfig
  { server :: ServerConfig
  }
  deriving stock (Show)

loadFromEnv :: IO AppConfig
loadFromEnv = do
  host <- envOr "MAX_WS_HOST" "0.0.0.0"
  portRaw <- envOr "MAX_WS_PORT" "8080"
  path <- envOr "MAX_WS_PATH" "/onebot"
  token <- lookupEnv "MAX_ACCESS_TOKEN"
  port <- case readMaybe portRaw of
    Just p -> pure p
    Nothing -> fail $ "MAX_WS_PORT is not an integer: " <> portRaw
  pure
    AppConfig
      { server =
          ServerConfig
            { host = host,
              port = port,
              path = T.pack path,
              accessToken = T.pack <$> token
            }
      }

envOr :: String -> String -> IO String
envOr name dflt = fromMaybe dflt <$> lookupEnv name
