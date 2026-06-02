-- |
-- Layered config: command line > environment > TOML file > built-in defaults.
--
-- Each source parses into a 'PartialAppConfig' whose every field is 'Maybe';
-- they are combined left-to-right with @<>@ (first 'Just' wins, per
-- 'Alternative'), then materialised, filling in defaults for any field still
-- 'Nothing'. Only @llm.api_key@ is required — everything else has a default
-- baked into 'materialize'.
--
-- TOML file is looked up in this order, first hit wins:
--   * explicit @--config PATH@ (or @MAX_CONFIG=PATH@)
--   * @./max.toml@ in the current working directory
--   * @$XDG_CONFIG_HOME/max/config.toml@ (defaulting to @~/.config@)
module Max.Config
  ( AppConfig (..),
    loadConfig,
    defaultPersona,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.DB.Connection (DbConfig (..))
import Max.Effects.LLM (LLMConfig (..))
import OneBot.Server (ServerConfig (..))
import Options.Applicative qualified as O
import System.Directory (doesFileExist, getXdgDirectory, XdgDirectory (XdgConfig))
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Text.Read (readMaybe)
import Toml (TomlCodec, (.=))
import Toml qualified

-- | Final, fully-resolved application config. Everything required for
-- the bot to boot.
data AppConfig = AppConfig
  { server :: !ServerConfig,
    db :: !DbConfig,
    migrationsDir :: !FilePath,
    imagesDir :: !FilePath,
    imageWorkers :: !Int,
    llm :: !LLMConfig,
    historyWindow :: !Int,
    -- | The "persona" portion of the system prompt — the bit that
    -- shapes voice/identity. The format-guide tail is appended by
    -- "Max.Prompt".
    persona :: !Text
  }
  deriving stock (Show)

-- | Default persona used when no source supplies one.
defaultPersona :: Text
defaultPersona =
  "你是一个 QQ 群里的 AI 助手。群成员会 @你 来让你回答问题。请用自然简洁的中文回答。"

--------------------------------------------------------------------------------
-- Partial config: every field is Maybe, sub-records are nested.

data PartialAppConfig = PartialAppConfig
  { server :: !PartialServer,
    db :: !PartialDb,
    llm :: !PartialLLM,
    migrationsDir :: !(Maybe FilePath),
    imagesDir :: !(Maybe FilePath),
    imageWorkers :: !(Maybe Int),
    historyWindow :: !(Maybe Int),
    persona :: !(Maybe Text)
  }

data PartialServer = PartialServer
  { host :: !(Maybe String),
    port :: !(Maybe Int),
    path :: !(Maybe Text),
    accessToken :: !(Maybe Text)
  }

data PartialDb = PartialDb
  { url :: !(Maybe Text),
    maxConns :: !(Maybe Int)
  }

data PartialLLM = PartialLLM
  { apiKey :: !(Maybe Text),
    baseUrl :: !(Maybe Text),
    model :: !(Maybe Text),
    maxTokens :: !(Maybe Int),
    temperature :: !(Maybe Double),
    timeoutSeconds :: !(Maybe Int)
  }

-- per-field <|>: earlier source wins.

instance Semigroup PartialServer where
  a <> b =
    PartialServer
      { host = a.host <|> b.host,
        port = a.port <|> b.port,
        path = a.path <|> b.path,
        accessToken = a.accessToken <|> b.accessToken
      }

instance Monoid PartialServer where
  mempty = PartialServer Nothing Nothing Nothing Nothing

instance Semigroup PartialDb where
  a <> b =
    PartialDb
      { url = a.url <|> b.url,
        maxConns = a.maxConns <|> b.maxConns
      }

instance Monoid PartialDb where
  mempty = PartialDb Nothing Nothing

instance Semigroup PartialLLM where
  a <> b =
    PartialLLM
      { apiKey = a.apiKey <|> b.apiKey,
        baseUrl = a.baseUrl <|> b.baseUrl,
        model = a.model <|> b.model,
        maxTokens = a.maxTokens <|> b.maxTokens,
        temperature = a.temperature <|> b.temperature,
        timeoutSeconds = a.timeoutSeconds <|> b.timeoutSeconds
      }

instance Monoid PartialLLM where
  mempty = PartialLLM Nothing Nothing Nothing Nothing Nothing Nothing

instance Semigroup PartialAppConfig where
  a <> b =
    PartialAppConfig
      { server = a.server <> b.server,
        db = a.db <> b.db,
        llm = a.llm <> b.llm,
        migrationsDir = a.migrationsDir <|> b.migrationsDir,
        imagesDir = a.imagesDir <|> b.imagesDir,
        imageWorkers = a.imageWorkers <|> b.imageWorkers,
        historyWindow = a.historyWindow <|> b.historyWindow,
        persona = a.persona <|> b.persona
      }

instance Monoid PartialAppConfig where
  mempty =
    PartialAppConfig
      mempty
      mempty
      mempty
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing

--------------------------------------------------------------------------------
-- Materialise: apply defaults; fail on missing required fields.

materialize :: PartialAppConfig -> IO AppConfig
materialize p = do
  apiKey <- case p.llm.apiKey of
    Just k | not (T.null k) -> pure k
    _ ->
      fail $
        "llm.api_key is required\n"
          <> "  set via --llm-api-key, MAX_LLM_API_KEY, or [llm].api_key in the TOML"
  pure
    AppConfig
      { server =
          ServerConfig
            { host = fromMaybe "0.0.0.0" p.server.host,
              port = fromMaybe 8080 p.server.port,
              path = fromMaybe "/onebot" p.server.path,
              accessToken = p.server.accessToken
            },
        db =
          DbConfig
            { url = fromMaybe "postgresql://127.0.0.1:5433/max" p.db.url,
              maxConns = fromMaybe 8 p.db.maxConns
            },
        migrationsDir = fromMaybe "migrations" p.migrationsDir,
        imagesDir = fromMaybe "var/images" p.imagesDir,
        imageWorkers = fromMaybe 4 p.imageWorkers,
        llm =
          LLMConfig
            { apiKey = apiKey,
              baseUrl = fromMaybe "https://api.deepseek.com/v1" p.llm.baseUrl,
              model = fromMaybe "deepseek-chat" p.llm.model,
              maxTokens = fromMaybe 2048 p.llm.maxTokens,
              temperature = fromMaybe 0.7 p.llm.temperature,
              timeoutSeconds = fromMaybe 120 p.llm.timeoutSeconds
            },
        historyWindow = fromMaybe 20 p.historyWindow,
        persona = fromMaybe defaultPersona p.persona
      }

--------------------------------------------------------------------------------
-- Entry point.

loadConfig :: IO AppConfig
loadConfig = do
  (cliConfigPath, cliPartial) <- parseCliArgs
  envPartial <- parseEnvPartial
  filePath <- resolveConfigPath cliConfigPath
  filePartial <- case filePath of
    Nothing -> pure mempty
    Just fp -> parseTomlFile fp
  materialize (cliPartial <> envPartial <> filePartial)

--------------------------------------------------------------------------------
-- CLI.

parseCliArgs :: IO (Maybe FilePath, PartialAppConfig)
parseCliArgs = O.execParser opts
  where
    opts =
      O.info
        (cliP O.<**> O.helper)
        ( O.fullDesc
            <> O.progDesc "QQ group-chat agent over OneBot 11 / NapCatQQ"
            <> O.header "max — Haskell QQ bot"
        )

cliP :: O.Parser (Maybe FilePath, PartialAppConfig)
cliP =
  (,)
    <$> O.optional
      ( O.strOption
          ( O.long "config"
              <> O.metavar "PATH"
              <> O.help "TOML config file (default: ./max.toml, then $XDG_CONFIG_HOME/max/config.toml)"
          )
      )
    <*> partialP

partialP :: O.Parser PartialAppConfig
partialP =
  PartialAppConfig
    <$> serverP
    <*> dbP
    <*> llmP
    <*> O.optional (O.strOption (O.long "migrations-dir" <> O.metavar "DIR"))
    <*> O.optional (O.strOption (O.long "images-dir" <> O.metavar "DIR"))
    <*> O.optional (O.option O.auto (O.long "image-workers" <> O.metavar "N"))
    <*> O.optional (O.option O.auto (O.long "history-window" <> O.metavar "N"))
    <*> O.optional (textOption (O.long "persona" <> O.metavar "TEXT" <> O.help "Bot persona / system-prompt identity segment"))

serverP :: O.Parser PartialServer
serverP =
  PartialServer
    <$> O.optional (O.strOption (O.long "ws-host" <> O.metavar "HOST"))
    <*> O.optional (O.option O.auto (O.long "ws-port" <> O.metavar "PORT"))
    <*> O.optional (textOption (O.long "ws-path" <> O.metavar "PATH"))
    <*> O.optional (textOption (O.long "access-token" <> O.metavar "TOKEN"))

dbP :: O.Parser PartialDb
dbP =
  PartialDb
    <$> O.optional (textOption (O.long "db-url" <> O.metavar "URL"))
    <*> O.optional (O.option O.auto (O.long "db-max-conns" <> O.metavar "N"))

llmP :: O.Parser PartialLLM
llmP =
  PartialLLM
    <$> O.optional (textOption (O.long "llm-api-key" <> O.metavar "KEY"))
    <*> O.optional (textOption (O.long "llm-base-url" <> O.metavar "URL"))
    <*> O.optional (textOption (O.long "llm-model" <> O.metavar "NAME"))
    <*> O.optional (O.option O.auto (O.long "llm-max-tokens" <> O.metavar "N"))
    <*> O.optional (O.option O.auto (O.long "llm-temperature" <> O.metavar "F"))
    <*> O.optional (O.option O.auto (O.long "llm-timeout-seconds" <> O.metavar "N"))

textOption :: O.Mod O.OptionFields String -> O.Parser Text
textOption = fmap T.pack . O.strOption

--------------------------------------------------------------------------------
-- Environment.

parseEnvPartial :: IO PartialAppConfig
parseEnvPartial = do
  -- server
  host <- lookupEnv "MAX_WS_HOST"
  port <- lookupEnvIntMaybe "MAX_WS_PORT"
  path <- fmap T.pack <$> lookupEnv "MAX_WS_PATH"
  tok <- fmap T.pack <$> lookupEnv "MAX_ACCESS_TOKEN"
  -- db
  dbUrl <- fmap T.pack <$> lookupEnv "MAX_DB_URL"
  dbConns <- lookupEnvIntMaybe "MAX_DB_MAX_CONNS"
  -- top-level
  migDir <- lookupEnv "MAX_MIGRATIONS_DIR"
  imgDir <- lookupEnv "MAX_IMAGES_DIR"
  imgWorkers <- lookupEnvIntMaybe "MAX_IMAGE_WORKERS"
  histWin <- lookupEnvIntMaybe "MAX_HISTORY_WINDOW"
  persona <- fmap T.pack <$> lookupEnv "MAX_PERSONA"
  -- llm
  llmKey <- fmap T.pack <$> lookupEnv "MAX_LLM_API_KEY"
  llmBase <- fmap T.pack <$> lookupEnv "MAX_LLM_BASE_URL"
  llmModel <- fmap T.pack <$> lookupEnv "MAX_LLM_MODEL"
  llmMaxTok <- lookupEnvIntMaybe "MAX_LLM_MAX_TOKENS"
  llmTemp <- lookupEnvDoubleMaybe "MAX_LLM_TEMPERATURE"
  llmTimeout <- lookupEnvIntMaybe "MAX_LLM_TIMEOUT_SECONDS"
  pure
    PartialAppConfig
      { server =
          PartialServer
            { host = host,
              port = port,
              path = path,
              accessToken = tok
            },
        db =
          PartialDb
            { url = dbUrl,
              maxConns = dbConns
            },
        llm =
          PartialLLM
            { apiKey = llmKey,
              baseUrl = llmBase,
              model = llmModel,
              maxTokens = llmMaxTok,
              temperature = llmTemp,
              timeoutSeconds = llmTimeout
            },
        migrationsDir = migDir,
        imagesDir = imgDir,
        imageWorkers = imgWorkers,
        historyWindow = histWin,
        persona = persona
      }

lookupEnvIntMaybe :: String -> IO (Maybe Int)
lookupEnvIntMaybe name =
  lookupEnv name >>= \case
    Nothing -> pure Nothing
    Just s -> case readMaybe s of
      Just i -> pure (Just i)
      Nothing -> fail $ name <> " is not an integer: " <> s

lookupEnvDoubleMaybe :: String -> IO (Maybe Double)
lookupEnvDoubleMaybe name =
  lookupEnv name >>= \case
    Nothing -> pure Nothing
    Just s -> case readMaybe s of
      Just d -> pure (Just d)
      Nothing -> fail $ name <> " is not a number: " <> s

--------------------------------------------------------------------------------
-- TOML.

parseTomlFile :: FilePath -> IO PartialAppConfig
parseTomlFile fp = do
  txt <- Toml.decodeFileEither partialAppCodec fp >>= either bad pure
  pure txt
  where
    bad errs = fail $ "TOML parse failed for " <> fp <> ":\n" <> show errs

partialAppCodec :: TomlCodec PartialAppConfig
partialAppCodec =
  PartialAppConfig
    <$> optionalTable partialServerCodec "server" .= (.server)
    <*> optionalTable partialDbCodec "db" .= (.db)
    <*> optionalTable partialLlmCodec "llm" .= (.llm)
    <*> Toml.dioptional (Toml.string "migrations_dir") .= (.migrationsDir)
    <*> Toml.dioptional (Toml.string "images_dir") .= (.imagesDir)
    <*> Toml.dioptional (Toml.int "image_workers") .= (.imageWorkers)
    <*> Toml.dioptional (Toml.int "history_window") .= (.historyWindow)
    <*> Toml.dioptional (Toml.text "persona") .= (.persona)

partialServerCodec :: TomlCodec PartialServer
partialServerCodec =
  PartialServer
    <$> Toml.dioptional (Toml.string "host") .= (.host)
    <*> Toml.dioptional (Toml.int "port") .= (.port)
    <*> Toml.dioptional (Toml.text "path") .= (.path)
    <*> Toml.dioptional (Toml.text "access_token") .= (.accessToken)

partialDbCodec :: TomlCodec PartialDb
partialDbCodec =
  PartialDb
    <$> Toml.dioptional (Toml.text "url") .= (.url)
    <*> Toml.dioptional (Toml.int "max_conns") .= (.maxConns)

partialLlmCodec :: TomlCodec PartialLLM
partialLlmCodec =
  PartialLLM
    <$> Toml.dioptional (Toml.text "api_key") .= (.apiKey)
    <*> Toml.dioptional (Toml.text "base_url") .= (.baseUrl)
    <*> Toml.dioptional (Toml.text "model") .= (.model)
    <*> Toml.dioptional (Toml.int "max_tokens") .= (.maxTokens)
    <*> Toml.dioptional (Toml.double "temperature") .= (.temperature)
    <*> Toml.dioptional (Toml.int "timeout_seconds") .= (.timeoutSeconds)

-- | Decode a subtable, treating its absence as 'mempty' rather than an error.
optionalTable :: Monoid a => TomlCodec a -> Toml.Key -> TomlCodec a
optionalTable inner key =
  Toml.dimap Just (fromMaybe mempty) (Toml.dioptional (Toml.table inner key))

--------------------------------------------------------------------------------
-- Config-file discovery.

resolveConfigPath :: Maybe FilePath -> IO (Maybe FilePath)
resolveConfigPath (Just p) = do
  exists <- doesFileExist p
  when (not exists) (fail $ "config file not found: " <> p)
  pure (Just p)
resolveConfigPath Nothing = do
  mEnv <- lookupEnv "MAX_CONFIG"
  case mEnv of
    Just p -> do
      exists <- doesFileExist p
      when (not exists) (fail $ "MAX_CONFIG points at missing file: " <> p)
      pure (Just p)
    Nothing -> do
      let cwdCandidate = "max.toml"
      cwdHit <- doesFileExist cwdCandidate
      if cwdHit
        then pure (Just cwdCandidate)
        else do
          xdg <- getXdgDirectory XdgConfig "max"
          let xdgCandidate = xdg </> "config.toml"
          xdgHit <- doesFileExist xdgCandidate
          pure $ if xdgHit then Just xdgCandidate else Nothing
