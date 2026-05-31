module Max.Config
  ( AppConfig (..),
    loadFromEnv,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Max.DB.Connection (DbConfig (..))
import OneBot.Server (ServerConfig (..))
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

data AppConfig = AppConfig
  { server :: !ServerConfig,
    db :: !DbConfig,
    migrationsDir :: !FilePath,
    imagesDir :: !FilePath,
    imageWorkers :: !Int
  }
  deriving stock (Show)

loadFromEnv :: IO AppConfig
loadFromEnv = do
  host <- envOr "MAX_WS_HOST" "0.0.0.0"
  portRaw <- envOr "MAX_WS_PORT" "8080"
  path <- envOr "MAX_WS_PATH" "/onebot"
  token <- lookupEnv "MAX_ACCESS_TOKEN"
  dbUrl <- envOr "MAX_DB_URL" "postgresql://127.0.0.1:5433/max"
  dbConnsRaw <- envOr "MAX_DB_MAX_CONNS" "8"
  migDir <- envOr "MAX_MIGRATIONS_DIR" "migrations"
  imgDir <- envOr "MAX_IMAGES_DIR" "var/images"
  imgWorkersRaw <- envOr "MAX_IMAGE_WORKERS" "4"
  port <- case readMaybe portRaw of
    Just p -> pure p
    Nothing -> fail $ "MAX_WS_PORT is not an integer: " <> portRaw
  dbConns <- case readMaybe dbConnsRaw of
    Just n -> pure n
    Nothing -> fail $ "MAX_DB_MAX_CONNS is not an integer: " <> dbConnsRaw
  imgWorkers <- case readMaybe imgWorkersRaw of
    Just n | n >= 1 -> pure n
    _ -> fail $ "MAX_IMAGE_WORKERS must be a positive integer: " <> imgWorkersRaw
  pure
    AppConfig
      { server =
          ServerConfig
            { host = host,
              port = port,
              path = T.pack path,
              accessToken = T.pack <$> token
            },
        db =
          DbConfig
            { url = T.pack dbUrl,
              maxConns = dbConns
            },
        migrationsDir = migDir,
        imagesDir = imgDir,
        imageWorkers = imgWorkers
      }

envOr :: String -> String -> IO String
envOr name dflt = fromMaybe dflt <$> lookupEnv name
