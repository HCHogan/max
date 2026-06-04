-- |
-- Layered config: command line > environment > TOML file > built-in defaults.
--
-- Each source parses into a 'PartialAppConfig' whose every field is 'Maybe';
-- they are combined left-to-right with @<>@ (first 'Just' wins, per
-- 'Alternative'), then materialised, filling in defaults for any field still
-- 'Nothing'.
--
-- TOML file is looked up in this order, first hit wins:
--   * explicit @--config PATH@ (or @MAX_CONFIG=PATH@)
--   * @./max.toml@ in the current working directory
--   * @$XDG_CONFIG_HOME/max/config.toml@ (defaulting to @~/.config@)
--
-- == LLM profiles
--
-- The bot can be wired to several OpenAI-compatible endpoints at once.
-- Each is a named 'LLMProfile' in the TOML:
--
-- > [llm]
-- > default = "main"
-- >
-- > [llm.profiles.main]
-- > api_key = "sk-..."
-- > model   = "deepseek-chat"
-- >
-- > [llm.profiles.reasoner]
-- > api_key = "sk-..."
-- > model   = "deepseek-reasoner"
-- >
-- > [llm.profiles.local]
-- > base_url = "http://localhost:8080/v1"
-- > model    = "qwen2.5:7b"
-- > api_key  = "any"
--
-- The env/CLI single-profile flags (@MAX_LLM_API_KEY@, @--llm-model@, ...)
-- write into the @default@-named profile.  If no TOML exists and only env
-- is set, the bot synthesises a single profile named @"default"@ from
-- those values.
module Max.Config
  ( AppConfig (..),
    loadConfig,
    defaultPersona,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.DB.Connection (DbConfig (..))
import Max.Effects.LLM (LLMProfile (..), LLMRegistry (..), Protocol (..), parseProtocol)
import Max.Tools.Search (SearchConfig (..))
import OneBot.Server (ServerConfig (..))
import Options.Applicative qualified as O
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Text.Read (readMaybe)
import Toml (TomlCodec, (.=))
import Toml qualified

-- | Final, fully-resolved application config.
data AppConfig = AppConfig
  { server :: !ServerConfig,
    db :: !DbConfig,
    migrationsDir :: !FilePath,
    imagesDir :: !FilePath,
    imageWorkers :: !Int,
    llm :: !LLMRegistry,
    historyWindow :: !Int,
    -- | Persona used when a session hasn't overridden it.
    persona :: !Text,
    -- | Web-search backend, if configured.  When 'Nothing' the
    -- @web_search@ tool is not registered (model doesn't see it).
    search :: !(Maybe SearchConfig)
  }
  deriving stock (Show)

-- | Default persona used when neither config nor session supplies one.
defaultPersona :: Text
defaultPersona =
  "你是一个 QQ 群里的 AI 助手。群成员会 @你 来让你回答问题。请用自然简洁的中文回答。"

--------------------------------------------------------------------------------
-- Partial config: every field is Maybe, sub-records are nested.

data PartialAppConfig = PartialAppConfig
  { server :: !PartialServer,
    db :: !PartialDb,
    llm :: !PartialLLM,
    search :: !PartialSearch,
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

data PartialSearch = PartialSearch
  { tavilyApiKey :: !(Maybe Text),
    maxResults :: !(Maybe Int),
    timeoutSeconds :: !(Maybe Int)
  }

-- | Multi-profile LLM partial.  'defaultName' selects which profile is the
-- default; 'profiles' is the raw map.  CLI/env flags write into a profile
-- named @"default"@ (which is also the implicit name when no TOML exists).
data PartialLLM = PartialLLM
  { defaultName :: !(Maybe Text),
    profiles :: !(Map Text PartialProfile)
  }

data PartialProfile = PartialProfile
  { apiKey :: !(Maybe Text),
    baseUrl :: !(Maybe Text),
    model :: !(Maybe Text),
    maxTokens :: !(Maybe Int),
    temperature :: !(Maybe Double),
    timeoutSeconds :: !(Maybe Int),
    protocol :: !(Maybe Protocol),
    thinking :: !(Maybe Bool)
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

instance Semigroup PartialSearch where
  a <> b =
    PartialSearch
      { tavilyApiKey = a.tavilyApiKey <|> b.tavilyApiKey,
        maxResults = a.maxResults <|> b.maxResults,
        timeoutSeconds = a.timeoutSeconds <|> b.timeoutSeconds
      }

instance Monoid PartialSearch where
  mempty = PartialSearch Nothing Nothing Nothing

instance Semigroup PartialProfile where
  a <> b =
    PartialProfile
      { apiKey = a.apiKey <|> b.apiKey,
        baseUrl = a.baseUrl <|> b.baseUrl,
        model = a.model <|> b.model,
        maxTokens = a.maxTokens <|> b.maxTokens,
        temperature = a.temperature <|> b.temperature,
        timeoutSeconds = a.timeoutSeconds <|> b.timeoutSeconds,
        protocol = a.protocol <|> b.protocol,
        thinking = a.thinking <|> b.thinking
      }

instance Monoid PartialProfile where
  mempty =
    PartialProfile
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing
      Nothing

instance Semigroup PartialLLM where
  a <> b =
    PartialLLM
      { defaultName = a.defaultName <|> b.defaultName,
        profiles = Map.unionWith (<>) a.profiles b.profiles
      }

instance Monoid PartialLLM where
  mempty = PartialLLM Nothing Map.empty

instance Semigroup PartialAppConfig where
  a <> b =
    PartialAppConfig
      { server = a.server <> b.server,
        db = a.db <> b.db,
        llm = a.llm <> b.llm,
        search = a.search <> b.search,
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
  registry <- materializeLLM p.llm
  let search = materializeSearch p.search
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
        llm = registry,
        historyWindow = fromMaybe 20 p.historyWindow,
        persona = fromMaybe defaultPersona p.persona,
        search = search
      }

-- | If no API key, search is disabled.  Otherwise build a
-- 'SearchConfig' with sensible defaults for the optional knobs.
materializeSearch :: PartialSearch -> Maybe SearchConfig
materializeSearch p = case p.tavilyApiKey of
  Just key | not (T.null key) ->
    Just
      SearchConfig
        { scTavilyApiKey = key,
          scDefaultMaxResults = fromMaybe 5 p.maxResults,
          scTimeoutSeconds = fromMaybe 30 p.timeoutSeconds
        }
  _ -> Nothing

materializeLLM :: PartialLLM -> IO LLMRegistry
materializeLLM (PartialLLM dn rawProfiles) = do
  let resolvedDefault = case dn of
        Just n -> n
        Nothing -> case Map.keys rawProfiles of
          [single] -> single
          _ -> "default"
  -- Ensure the default profile exists in the map even if no source
  -- declared it (single-profile env-only path).
  let withDefault =
        Map.insertWith
          (\_ existing -> existing)
          resolvedDefault
          mempty
          rawProfiles
  resolved <- Map.traverseWithKey (resolveProfile resolvedDefault) withDefault
  pure LLMRegistry {defaultName = resolvedDefault, profiles = resolved}
  where
    resolveProfile def name partial = do
      apiKey <- case partial.apiKey of
        Just k | not (T.null k) -> pure k
        _ ->
          fail $
            "llm profile '"
              <> T.unpack name
              <> "' has no api_key"
              <> ( if name == def
                     then "\n  set via --llm-api-key, MAX_LLM_API_KEY, or [llm.profiles." <> T.unpack name <> "].api_key"
                     else "\n  set via [llm.profiles." <> T.unpack name <> "].api_key"
                 )
      pure
        LLMProfile
          { apiKey = apiKey,
            baseUrl = fromMaybe "https://api.deepseek.com/v1" partial.baseUrl,
            model = fromMaybe "deepseek-v4-flash" partial.model,
            maxTokens = fromMaybe 2048 partial.maxTokens,
            temperature = fromMaybe 0.7 partial.temperature,
            timeoutSeconds = fromMaybe 120 partial.timeoutSeconds,
            protocol = fromMaybe ProtocolOpenAI partial.protocol,
            thinking = partial.thinking
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
    <*> searchP
    <*> O.optional (O.strOption (O.long "migrations-dir" <> O.metavar "DIR"))
    <*> O.optional (O.strOption (O.long "images-dir" <> O.metavar "DIR"))
    <*> O.optional (O.option O.auto (O.long "image-workers" <> O.metavar "N"))
    <*> O.optional (O.option O.auto (O.long "history-window" <> O.metavar "N"))
    <*> O.optional (textOption (O.long "persona" <> O.metavar "TEXT" <> O.help "Default bot persona / system-prompt identity segment"))

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

searchP :: O.Parser PartialSearch
searchP =
  PartialSearch
    <$> O.optional (textOption (O.long "tavily-api-key" <> O.metavar "KEY" <> O.help "Tavily API key (enables the web_search tool)"))
    <*> O.optional (O.option O.auto (O.long "search-max-results" <> O.metavar "N"))
    <*> O.optional (O.option O.auto (O.long "search-timeout-seconds" <> O.metavar "N"))

-- | CLI flags only operate on the default profile; defining additional
-- profiles requires TOML.
llmP :: O.Parser PartialLLM
llmP =
  build
    <$> O.optional (textOption (O.long "llm-default-profile" <> O.metavar "NAME" <> O.help "Which TOML profile is the default (default: \"default\")"))
    <*> O.optional (textOption (O.long "llm-api-key" <> O.metavar "KEY"))
    <*> O.optional (textOption (O.long "llm-base-url" <> O.metavar "URL"))
    <*> O.optional (textOption (O.long "llm-model" <> O.metavar "NAME"))
    <*> O.optional (O.option O.auto (O.long "llm-max-tokens" <> O.metavar "N"))
    <*> O.optional (O.option O.auto (O.long "llm-temperature" <> O.metavar "F"))
    <*> O.optional (O.option O.auto (O.long "llm-timeout-seconds" <> O.metavar "N"))
    <*> O.optional (O.option protoReader (O.long "llm-protocol" <> O.metavar "openai|anthropic"))
    <*> O.optional (O.option O.auto (O.long "llm-thinking" <> O.metavar "true|false" <> O.help "DeepSeek thinking mode (omit to use upstream default)"))
  where
    build dn key url mdl mt temp to proto think =
      let profile =
            PartialProfile
              { apiKey = key,
                baseUrl = url,
                model = mdl,
                maxTokens = mt,
                temperature = temp,
                timeoutSeconds = to,
                protocol = proto,
                thinking = think
              }
          name = fromMaybe "default" dn
       in PartialLLM
            { defaultName = dn,
              profiles =
                if profile == mempty
                  then Map.empty
                  else Map.singleton name profile
            }
    protoReader = O.eitherReader $ \s -> case parseProtocol (T.pack s) of
      Just p -> Right p
      Nothing -> Left ("expected 'openai' or 'anthropic', got: " <> s)

instance Eq PartialProfile where
  a == b =
    a.apiKey == b.apiKey
      && a.baseUrl == b.baseUrl
      && a.model == b.model
      && a.maxTokens == b.maxTokens
      && a.temperature == b.temperature
      && a.timeoutSeconds == b.timeoutSeconds
      && a.protocol == b.protocol
      && a.thinking == b.thinking

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
  -- llm: default profile + its field overrides
  llmDefault <- fmap T.pack <$> lookupEnv "MAX_LLM_DEFAULT_PROFILE"
  llmKey <- fmap T.pack <$> lookupEnv "MAX_LLM_API_KEY"
  llmBase <- fmap T.pack <$> lookupEnv "MAX_LLM_BASE_URL"
  llmModel <- fmap T.pack <$> lookupEnv "MAX_LLM_MODEL"
  llmMaxTok <- lookupEnvIntMaybe "MAX_LLM_MAX_TOKENS"
  llmTemp <- lookupEnvDoubleMaybe "MAX_LLM_TEMPERATURE"
  llmTimeout <- lookupEnvIntMaybe "MAX_LLM_TIMEOUT_SECONDS"
  llmProto <- lookupEnvProtocol "MAX_LLM_PROTOCOL"
  llmThinking <- lookupEnvBoolMaybe "MAX_LLM_THINKING"
  -- search
  tavilyKey <- fmap T.pack <$> lookupEnv "MAX_TAVILY_API_KEY"
  searchMax <- lookupEnvIntMaybe "MAX_SEARCH_MAX_RESULTS"
  searchTimeout <- lookupEnvIntMaybe "MAX_SEARCH_TIMEOUT_SECONDS"
  let envProfile =
        PartialProfile
          { apiKey = llmKey,
            baseUrl = llmBase,
            model = llmModel,
            maxTokens = llmMaxTok,
            temperature = llmTemp,
            timeoutSeconds = llmTimeout,
            protocol = llmProto,
            thinking = llmThinking
          }
      envProfileName = fromMaybe "default" llmDefault
      envLlm =
        PartialLLM
          { defaultName = llmDefault,
            profiles =
              if envProfile == mempty
                then Map.empty
                else Map.singleton envProfileName envProfile
          }
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
        llm = envLlm,
        search =
          PartialSearch
            { tavilyApiKey = tavilyKey,
              maxResults = searchMax,
              timeoutSeconds = searchTimeout
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

lookupEnvProtocol :: String -> IO (Maybe Protocol)
lookupEnvProtocol name =
  lookupEnv name >>= \case
    Nothing -> pure Nothing
    Just s -> case parseProtocol (T.pack s) of
      Just p -> pure (Just p)
      Nothing -> fail $ name <> " must be 'openai' or 'anthropic', got: " <> s

lookupEnvBoolMaybe :: String -> IO (Maybe Bool)
lookupEnvBoolMaybe name =
  lookupEnv name >>= \case
    Nothing -> pure Nothing
    Just s -> case T.toLower (T.strip (T.pack s)) of
      "true" -> pure (Just True)
      "1" -> pure (Just True)
      "yes" -> pure (Just True)
      "on" -> pure (Just True)
      "false" -> pure (Just False)
      "0" -> pure (Just False)
      "no" -> pure (Just False)
      "off" -> pure (Just False)
      _ -> fail $ name <> " must be true/false (got: " <> s <> ")"

--------------------------------------------------------------------------------
-- TOML.

parseTomlFile :: FilePath -> IO PartialAppConfig
parseTomlFile fp =
  Toml.decodeFileEither partialAppCodec fp >>= either bad pure
  where
    bad errs = fail $ "TOML parse failed for " <> fp <> ":\n" <> show errs

partialAppCodec :: TomlCodec PartialAppConfig
partialAppCodec =
  PartialAppConfig
    <$> optionalTable partialServerCodec "server" .= (.server)
    <*> optionalTable partialDbCodec "db" .= (.db)
    <*> optionalTable partialLlmCodec "llm" .= (.llm)
    <*> optionalTable partialSearchCodec "search" .= (.search)
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

partialSearchCodec :: TomlCodec PartialSearch
partialSearchCodec =
  PartialSearch
    <$> Toml.dioptional (Toml.text "tavily_api_key") .= (.tavilyApiKey)
    <*> Toml.dioptional (Toml.int "max_results") .= (.maxResults)
    <*> Toml.dioptional (Toml.int "timeout_seconds") .= (.timeoutSeconds)

-- | TOML LLM section.  Profiles are an array of tables, each carrying
-- its own @name@:
--
-- >   [llm]
-- >   default = "main"
-- >
-- >   [[llm.profiles]]
-- >   name      = "main"
-- >   api_key   = "..."
-- >   model     = "..."
-- >
-- >   [[llm.profiles]]
-- >   name    = "reasoner"
-- >   api_key = "..."
--
-- The @[[...]]@ syntax is needed because tomland's @tableMap@ doesn't
-- traverse @[llm.profiles.<name>]@ subtable headers — it only sees
-- inline-table values at the @profiles@ key.  Array-of-tables works
-- cleanly and lets each profile span multiple lines.
partialLlmCodec :: TomlCodec PartialLLM
partialLlmCodec = build
  <$> Toml.dioptional (Toml.text "default") .= (.defaultName)
  <*> Toml.list partialProfileEntryCodec "profiles" .= profilesAsEntries
  where
    build dn entries =
      PartialLLM
        { defaultName = dn,
          profiles =
            Map.fromList
              [(e.entryName, e.entryProfile) | e <- entries]
        }
    profilesAsEntries p =
      [ PartialProfileEntry {entryName = n, entryProfile = pp}
        | (n, pp) <- Map.toList p.profiles
      ]

-- | One row in the @[[llm.profiles]]@ array.  Internal to the codec;
-- materialise transforms back to a plain 'Map'.
data PartialProfileEntry = PartialProfileEntry
  { entryName :: !Text,
    entryProfile :: !PartialProfile
  }

partialProfileEntryCodec :: TomlCodec PartialProfileEntry
partialProfileEntryCodec =
  PartialProfileEntry
    <$> Toml.text "name" .= (.entryName)
    <*> partialProfileCodec .= (.entryProfile)

partialProfileCodec :: TomlCodec PartialProfile
partialProfileCodec =
  PartialProfile
    <$> Toml.dioptional (Toml.text "api_key") .= (.apiKey)
    <*> Toml.dioptional (Toml.text "base_url") .= (.baseUrl)
    <*> Toml.dioptional (Toml.text "model") .= (.model)
    <*> Toml.dioptional (Toml.int "max_tokens") .= (.maxTokens)
    <*> Toml.dioptional (Toml.double "temperature") .= (.temperature)
    <*> Toml.dioptional (Toml.int "timeout_seconds") .= (.timeoutSeconds)
    <*> Toml.dioptional protocolCodec .= (.protocol)
    <*> Toml.dioptional (Toml.bool "thinking") .= (.thinking)

-- | TOML codec for the @protocol@ field; matches "openai" / "anthropic".
protocolCodec :: TomlCodec Protocol
protocolCodec =
  Toml.textBy renderProto parseProtoToml "protocol"
  where
    renderProto ProtocolOpenAI = "openai"
    renderProto ProtocolAnthropic = "anthropic"
    parseProtoToml t = case parseProtocol t of
      Just p -> Right p
      Nothing -> Left ("expected 'openai' or 'anthropic', got: " <> t)

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
