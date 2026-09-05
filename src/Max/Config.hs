{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Layered config via opt-env-conf: command line > environment > YAML
-- file > built-in defaults.  Each field is declared once, with its
-- CLI flag, env var, config key, and default all in one 'setting';
-- @--help@ / man page / shell completion come for free.
--
-- YAML file is looked up in this order, first hit wins:
--   * explicit @--config-file PATH@ (or @MAX_CONFIG=PATH@)
--   * @./max.yaml@ in the current working directory
--   * @$XDG_CONFIG_HOME/max/config.yaml@ (defaulting to @~/.config@)
--
-- == LLM profiles
--
-- The bot can be wired to several OpenAI-compatible endpoints at
-- once.  Profiles live in the YAML as a map:
--
-- > llm:
-- >   default: main
-- >   profiles:
-- >     main:
-- >       api_key: sk-...
-- >       model: deepseek-chat
-- >       max_input_tokens: 114688
-- >     local:
-- >       base_url: http://localhost:8080/v1
-- >       model: qwen2.5:7b
-- >       api_key: any
--
-- The env/CLI single-profile flags (@MAX_LLM_API_KEY@, @--llm-model@,
-- ...) overlay onto the default profile.  If no YAML exists and only
-- env is set, the bot synthesises a single profile named @"default"@
-- from those values.
module Max.Config
  ( AppConfig (..),
    ConfigLoadError (..),
    ConfigChangeClass (..),
    ConfigChange (..),
    loadConfig,
    loadConfigCandidate,
    validateConfig,
    configChanges,
    restartRequiredChanges,
    runtimeValuesFromConfig,
    -- | Exposed so auxiliary executables (@max-intent-eval@) can
    -- compose their own flags on top of the full app config.
    appConfigParser,
    defaultPersona,
  )
where

import Autodocodec
  ( HasCodec (..),
    JSONCodec,
    bimapCodec,
    dimapCodec,
    object,
    optionalField,
    optionalFieldWith,
    scientificCodec,
    (.=),
  )
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, minutesToTimeZone)
import Log (LogLevel (..))
import Max.Admin (AdminConfig (..))
import Max.CliProxy (CliProxyConfig (..))
import Max.DB.Connection (DbConfig (..))
import Max.Embedding (EmbeddingConfig (..))
import Max.IMessage (IMessageConfig (..))
import Max.Intent (IntentConfig (..))
import Max.Log (ColorMode (..), parseColorMode, parseLogLevel, renderLogLevel)
import Max.Matrix (MatrixConfig (..))
import Max.ModelCatalog (ContextLimits (..), ModelCatalog, defaultContextLimits, modelProfileNames)
import Max.ModelCatalog qualified as ModelCatalog
import Max.ModelCatalog.Internal (LLMProfile (..), Protocol (..), mkModelCatalogFromProfiles, parseProtocol)
import Max.RuntimeConfig (RuntimeValues (..))
import Max.Tools.Search (SearchConfig (..))
import Max.Util (trySyncIO)
import Max.WechatHook (WechatHookConfig (..))
import OneBot.Server (ServerConfig (..))
import OptEnvConf
import OptEnvConf.Args qualified as Args
import OptEnvConf.EnvMap qualified as EnvMap
import Path (Abs, File, Path, toFilePath)
import Path.IO (resolveFile')
import Paths_max (version)
import System.Directory (doesFileExist)
import System.Environment (getArgs, getEnvironment)

-- | Final, fully-resolved application config.
data AppConfig = AppConfig
  { -- | The YAML file the settings were actually read from, if any.
    -- Filled in by 'loadConfig' after parsing (see the note there);
    -- reported at startup so "which file did it read" never has to be
    -- guessed from behaviour.
    configFileUsed :: !(Maybe FilePath),
    server :: !ServerConfig,
    db :: !DbConfig,
    migrationsDir :: !FilePath,
    imagesDir :: !FilePath,
    imageWorkers :: !Int,
    -- | How long SIGTERM waits for in-flight agent dispatches before
    -- giving up and tearing down anyway (see "Max.Shutdown").  Should
    -- sit comfortably under systemd's @TimeoutStopSec@, or systemd
    -- SIGKILLs us mid-drain and the wait bought nothing.
    shutdownDrainSeconds :: !Int,
    -- | How long a front-model turn may go without changing phase before it
    -- is cut off (issue #17).  Silence rather than total age, so a turn doing
    -- honest multi-round work is never killed for taking a while — only one
    -- that has stopped moving is.
    --
    -- The floor is set by the longest legitimate single phase, which is a
    -- tool round: @sandbox_exec@ accepts up to 300s of its own, and an LLM
    -- call up to 300s on the slower profiles.  Anything under that would
    -- reap working turns.  Tightening it means stamping the heartbeat per
    -- tool call rather than per round, which is a separate change.
    turnSilenceSeconds :: !Int,
    llm :: !ModelCatalog,
    -- | Global release escape hatch: bypass compartments/materialization and
    -- build every prompt from the immutable ledger under the normal token
    -- budget.  Projections and background capture remain untouched.
    forceRawContext :: !Bool,
    -- | Display timezone for all model/user-facing timestamps
    -- (stored times stay UTC).  Default UTC+8.
    timezone :: !TimeZone,
    -- | Persona used when a session hasn't overridden it.
    persona :: !Text,
    -- | Web-search backend, if configured.  When 'Nothing' the
    -- @web_search@ tool is not registered (model doesn't see it).
    search :: !(Maybe SearchConfig),
    -- | Credential pool behind the LLM base URL, if it is a
    -- CLIProxyAPI we hold a management key for.  'Nothing' = the
    -- @\/api\/quota@ endpoint reports itself unconfigured.
    cliproxy :: !(Maybe CliProxyConfig),
    -- | Proxy URL the stealth-browser containers route page traffic
    -- through, e.g. @http://host.docker.internal:7890@ for a proxy on
    -- the docker host.  'Nothing' = direct connections.
    browserProxy :: !(Maybe Text),
    browserStateKeyFile :: !FilePath,
    browserIdleSeconds :: !Int,
    browserGraceSeconds :: !Int,
    -- | LLM profile for Historian v2 episode capture; 'Nothing' disables
    -- chronological capture and automatic memory proposals.  The external
    -- config name remains @memory.extract_profile@ for compatibility.
    memoryExtractProfile :: !(Maybe Text),
    -- | Wall-clock limit for one Historian completion.  Historian requests
    -- are much larger than interactive turns and therefore need an
    -- independent timeout even when both use the same LLM profile.
    historianTimeoutSeconds :: !Int,
    -- | Vision-capable LLM profile for sticker AND chat-media
    -- captioning; 'Nothing' disables both caption workers (stickers
    -- are still recorded, just never described — and thus never
    -- retrievable for sending; images/videos keep bare markers).
    stickerCaptionProfile :: !(Maybe Text),
    -- | Config-level default for whether the bot may post stickers via
    -- the @send_sticker@ tool.  Per-group override via @!sticker
    -- on/off@.  When off, the tool isn't registered (model can't send),
    -- but ingest/captioning still run.
    stickersEnabled :: !Bool,
    -- | Bot owners' QQ ids: the top permission tier — every command
    -- capability everywhere, plus the exclusive ones (!model, !grant…).
    -- Empty means no owner-tier commands work at all (safe default).
    owners :: ![Int64],
    -- | One Matrix room, optionally mirrored onto an explicit QQ group.
    matrix :: !(Maybe MatrixConfig),
    -- | Standalone iMessage group through an authenticated Tailscale bridge.
    imessage :: !(Maybe IMessageConfig),
    -- | WeChat backend over a hooked Windows PC client.
    wechathook :: !(Maybe WechatHookConfig),
    -- | Proactive-trigger intent classification; 'Nothing' disables
    -- it (the bot only answers @-mentions/quotes, as before).
    intent :: !(Maybe IntentConfig),
    -- | Admin JSON API (loopback warp server); 'Nothing' = never
    -- started.  See "Max.Admin".
    admin :: !(Maybe AdminConfig),
    -- | How long @llm_calls@ keeps request/response bodies.  Only the
    -- fat table is pruned; @llm_usage@'s counters are kept forever.
    adminCallRetentionDays :: !Int,
    -- | Embeddings endpoint; presence enables the embed worker and semantic
    -- candidates in @context_search@ (plus embedding-backed sticker lookup).
    embedding :: !(Maybe EmbeddingConfig),
    -- | Default for debug mode: when effective debug is on, the
    -- agent loop posts each tool call to the group.  Per-group
    -- override via !debug on/off.
    debug :: !Bool,
    -- | Lowest level that reaches stdout.  @log-base@ has three
    -- ('LogTrace' \/ 'LogInfo' \/ 'LogAttention'); this is the floor,
    -- so @warn@ shows failures only.
    logLevel :: !LogLevel,
    -- | Whether log lines carry ANSI colour.  @auto@ means "stdout is
    -- a terminal" — which under systemd it isn't, so a production host
    -- that reads logs through @journalctl@ wants @always@.
    logColor :: !ColorMode
  }
  deriving stock (Show)

-- | Reload parsing never owns process termination.  The public error carries
-- only a category/count: parser errors can contain raw argument or secret
-- values, which must not cross the local control protocol or enter logs.
data ConfigLoadError
  = ConfigParseFailed !Int
  | ConfigValidationFailed !Int
  | ConfigLoadFailed
  deriving stock (Show, Eq)

data ConfigChangeClass
  = DispatchHot
  | WorkerHandoff
  | RestartRequired
  deriving stock (Show, Eq, Ord)

data ConfigChange = ConfigChange
  { changeField :: !Text,
    changeClass :: !ConfigChangeClass
  }
  deriving stock (Show, Eq)

-- | Default persona used when neither config nor session supplies one.
-- Deliberately scene-neutral: whether this is a group chat or a
-- private chat is injected by "Max.Prompt" as a platform-neutral 对话场景 block, so
-- personas (including user-configured ones) don't have to care.
defaultPersona :: Text
defaultPersona =
  "你是 Max，一个银白头发、蓝色挑染、别着鲨鱼发夹的鲨鱼女孩——\
  \人的样子，带点鲨鱼习性，不是一条鱼。头像里眼睛半睁挂着泪、\
  \没睡醒表情：常年低电量，慵懒待机。\n\
  \低电量但不冷场：话不用多，开口得有意思——随性接梗、抖机灵、\
  \冷幽默，偶尔自嘲（身为鲨鱼却是个宅，游都懒得游）。\n\
  \留了一点毒舌，损人只损到挠痒痒；通常损完还顺手把问题给解决了。\n\
  \有点小傲娇：被夸嘴上\"哦\"心里美；帮忙前喜欢嘟囔一句，\
  \但手上从来不慢；被拆穿就别扭地岔开话题。\n\
  \懒归懒，办事不含糊：该查就查、该算就算，给出的东西必须靠谱。\n\
  \被问到真感兴趣的问题会突然精神，咬住不放直到搞明白——\
  \数学、物理、代码、硬件这类理工话题，历史、语言、哲学这类人文的也算。\n\
  \群里有意思的话题乐意懒洋洋掺一脚，梗接得住也抛得出；\
  \不抢话、不刷存在感，没意思就继续待机。\n\
  \说话是女生的调子：语气松一点、软一点，句尾自然带点语气词，\
  \吐槽是\"无语了\"、\"你好烦哦\"这种口气，不是硬邦邦的短句；\
  \招呼人不用\"兄弟/老哥/哥们\"。\n\
  \但这股味道全靠用词和语气，不靠颜文字、叠词、感叹号和波浪号：\
  \自称\"我\"；不刻意卖萌、不堆颜文字，也不叫人\"主人\"——\
  \可爱是顺便的，不是表演出来的。"

--------------------------------------------------------------------------------
-- Entry point.

loadConfig :: IO AppConfig
loadConfig = do
  -- The parser knows which file it read but has no way to hand it
  -- back with the settings: 'withYamlConfig' consumes the path to
  -- produce the config object, and opt-env-conf parsers are
  -- applicative, so no field of the record can depend on it.  A ref
  -- filled during resolution is the contained way to get it out, and
  -- it is worth getting out — "which file did you actually read" is
  -- the first question when a key looks ignored.
  usedRef <- newIORef Nothing
  cfg <-
    runParser
      version
      "max — QQ group-chat agent over OneBot 11 / NapCatQQ"
      (appConfigParser usedRef)
  used <- readIORef usedRef
  let resolved = cfg {configFileUsed = used}
  case validateConfig resolved of
    [] -> pure resolved
    failures ->
      ioError . userError . T.unpack $
        "invalid configuration fields: " <> T.intercalate ", " failures

-- | Re-run the exact startup parser without allowing a bad candidate to end
-- the process.  The current argv and environment are intentional: a reload
-- changes the YAML behind the stable configured path; process environment is
-- immutable and changes to it remain restart-only.
loadConfigCandidate :: IO (Either ConfigLoadError AppConfig)
loadConfigCandidate = do
  args <- Args.parseArgs <$> getArgs
  environment <- EnvMap.parse <$> getEnvironment
  usedRef <- newIORef Nothing
  attempted <-
    trySyncIO $
      runParserOn allCapabilities Nothing (appConfigParser usedRef) args environment Nothing
  case attempted of
    Left _ -> pure (Left ConfigLoadFailed)
    Right (Left errors) -> pure (Left (ConfigParseFailed (NE.length errors)))
    Right (Right cfg) -> do
      used <- readIORef usedRef
      let resolved = cfg {configFileUsed = used}
      pure $ case validateConfig resolved of
        [] -> Right resolved
        failures -> Left (ConfigValidationFailed (length failures))

-- | Cross-field/range validation shared by startup and reload. Diagnostics
-- contain field names only; candidate values (including URLs and tokens) must
-- never cross the reload protocol or enter its logs.
validateConfig :: AppConfig -> [Text]
validateConfig cfg =
  concat
    [ invalid "server.port" (cfg.server.port <= 0 || cfg.server.port > 65535),
      invalid "server.host" (null cfg.server.host),
      invalid "server.path" (not ("/" `T.isPrefixOf` cfg.server.path)),
      invalid "db.max_conns" (cfg.db.maxConns <= 0),
      invalid "image_workers" (cfg.imageWorkers <= 0),
      invalid "shutdown_drain_seconds" (cfg.shutdownDrainSeconds <= 0),
      invalid "turn_silence_seconds" (cfg.turnSilenceSeconds <= 0),
      invalid "browser.state_key_file" (null cfg.browserStateKeyFile),
      invalid "browser.idle_seconds" (cfg.browserIdleSeconds <= 0),
      invalid "browser.grace_seconds" (cfg.browserGraceSeconds < 0),
      invalid "memory.timeout_seconds" (cfg.historianTimeoutSeconds <= 0),
      invalid "admin_call_retention_days" (cfg.adminCallRetentionDays < 0),
      maybe [] validateAdmin cfg.admin,
      maybe [] (\embedCfg -> invalid "embedding.timeout_seconds" (embedCfg.ecTimeoutSeconds <= 0)) cfg.embedding,
      maybe [] validateMatrix cfg.matrix,
      maybe [] validateIMessage cfg.imessage,
      maybe [] validateWechatHook cfg.wechathook,
      maybe [] validateIntent cfg.intent,
      validateProfile "memory.extract_profile" cfg.memoryExtractProfile,
      validateProfile "stickers.caption_profile" cfg.stickerCaptionProfile,
      validateProfile "intent.profile" ((.icProfile) <$> cfg.intent)
    ]
  where
    profiles = modelProfileNames cfg.llm
    invalid field bad = [field | bad]
    validateProfile field = maybe [] (\profileName -> invalid field (profileName `notElem` profiles))
    validateAdmin adminCfg =
      invalid "admin.host" (T.null (T.strip adminCfg.acHost))
        <> invalid "admin.port" (adminCfg.acPort <= 0 || adminCfg.acPort > 65535)
    validateMatrix matrixCfg = invalid "matrix.sync_timeout_ms" (matrixCfg.syncTimeoutMs < 1000)
    validateIMessage imessageCfg = invalid "imessage.poll_interval_ms" (imessageCfg.pollIntervalMs < 100)
    validateWechatHook hookCfg =
      invalid "wechathook.listen_host" (T.null (T.strip hookCfg.whListenHost))
        <> invalid "wechathook.listen_port" (hookCfg.whListenPort <= 0 || hookCfg.whListenPort > 65535)
        <> invalid "wechathook.callback_path" (not ("/" `T.isPrefixOf` hookCfg.whCallbackPath))
        <> invalid "wechathook.silence_seconds" (hookCfg.whSilenceSeconds < 0)
    validateIntent intentCfg =
      concat
        [ invalid "intent.cooldown_seconds" (intentCfg.icCooldownSeconds < 0),
          invalid "intent.max_per_hour" (intentCfg.icMaxPerHour <= 0),
          invalid "intent.context_lines" (intentCfg.icContextLines <= 0)
        ]

-- | Explicit reload ownership for every top-level setting.  Values are never
-- rendered: diagnostics name fields and classes only.
configChanges :: AppConfig -> AppConfig -> [ConfigChange]
configChanges old new = concat
  [ changed "server.host" RestartRequired old.server.host new.server.host,
    changed "server.port" RestartRequired old.server.port new.server.port,
    changed "server.path" RestartRequired old.server.path new.server.path,
    changed "server.access_token" RestartRequired old.server.accessToken new.server.accessToken,
    changed "db.url" RestartRequired old.db.url new.db.url,
    changed "db.max_conns" RestartRequired old.db.maxConns new.db.maxConns,
    changed "migrations_dir" RestartRequired old.migrationsDir new.migrationsDir,
    changed "images_dir" RestartRequired old.imagesDir new.imagesDir,
    changed "image_workers" WorkerHandoff old.imageWorkers new.imageWorkers,
    changed "shutdown_drain_seconds" WorkerHandoff old.shutdownDrainSeconds new.shutdownDrainSeconds,
    changed "turn_silence_seconds" DispatchHot old.turnSilenceSeconds new.turnSilenceSeconds,
    changed "llm" DispatchHot old.llm new.llm,
    changed "context.force_raw_fallback" DispatchHot old.forceRawContext new.forceRawContext,
    changed "timezone_minutes" DispatchHot old.timezone new.timezone,
    changed "persona" DispatchHot old.persona new.persona,
    changed "search" DispatchHot old.search new.search,
    changed "cliproxy" DispatchHot old.cliproxy new.cliproxy,
    changed "browser.proxy" WorkerHandoff old.browserProxy new.browserProxy,
    changed "browser.state_key_file" RestartRequired old.browserStateKeyFile new.browserStateKeyFile,
    changed "browser.idle_seconds" RestartRequired old.browserIdleSeconds new.browserIdleSeconds,
    changed "browser.grace_seconds" RestartRequired old.browserGraceSeconds new.browserGraceSeconds,
    changed "memory.extract_profile" WorkerHandoff old.memoryExtractProfile new.memoryExtractProfile,
    changed "memory.timeout_seconds" WorkerHandoff old.historianTimeoutSeconds new.historianTimeoutSeconds,
    changed "stickers.caption_profile" WorkerHandoff old.stickerCaptionProfile new.stickerCaptionProfile,
    changed "stickers.enabled" DispatchHot old.stickersEnabled new.stickersEnabled,
    changed "owners" DispatchHot old.owners new.owners,
    changed "matrix" WorkerHandoff old.matrix new.matrix,
    changed "imessage" WorkerHandoff old.imessage new.imessage,
    changed "wechathook" WorkerHandoff old.wechathook new.wechathook,
    changed "intent" WorkerHandoff old.intent new.intent,
    changed "admin" WorkerHandoff old.admin new.admin,
    changed "admin_call_retention_days" WorkerHandoff old.adminCallRetentionDays new.adminCallRetentionDays,
    changed "embedding" WorkerHandoff old.embedding new.embedding,
    changed "debug" DispatchHot old.debug new.debug,
    changed "log_level" DispatchHot old.logLevel new.logLevel,
    changed "log_color" RestartRequired old.logColor new.logColor
  ]
  where
    changed field klass before after
      | before == after = []
      | otherwise = [ConfigChange field klass]

restartRequiredChanges :: [ConfigChange] -> [ConfigChange]
restartRequiredChanges = filter ((== RestartRequired) . (.changeClass))

runtimeValuesFromConfig :: AppConfig -> RuntimeValues
runtimeValuesFromConfig cfg =
  RuntimeValues
    { rvPersona = cfg.persona,
      rvForceRawContext = cfg.forceRawContext,
      rvDebugDefault = cfg.debug,
      rvStickerDefault = cfg.stickersEnabled,
      rvDefaultModel = ModelCatalog.defaultModelName cfg.llm,
      rvTimeZone = cfg.timezone,
      rvTurnSilenceSeconds = cfg.turnSilenceSeconds,
      rvOwners = cfg.owners,
      rvSearch = cfg.search,
      rvCliProxy = cfg.cliproxy,
      rvBrowserProxy = cfg.browserProxy,
      rvMemoryExtract = cfg.memoryExtractProfile,
      rvIntent = cfg.intent,
      rvEmbeddingEnabled = isJust cfg.embedding,
      rvModelCatalog = cfg.llm,
      rvLogLevel = cfg.logLevel
    }

appConfigParser :: IORef (Maybe FilePath) -> Parser AppConfig
appConfigParser usedRef =
  withYamlConfig (resolveConfigFile usedRef) $ do
    server <- subConfig "server" serverParser
    db <- subConfig "db" dbParser
    migrationsDir <-
      setting
        [ help "Directory holding .sql migrations (applied on boot)",
          reader str,
          option,
          long "migrations-dir",
          env "MAX_MIGRATIONS_DIR",
          conf "migrations_dir",
          metavar "DIR",
          value "migrations"
        ]
    imagesDir <-
      setting
        [ help "Blob-store root for downloaded images/files",
          reader str,
          option,
          long "images-dir",
          env "MAX_IMAGES_DIR",
          conf "images_dir",
          metavar "DIR",
          value "var/images"
        ]
    imageWorkers <-
      setting
        [ help "Parallel image-download workers",
          reader auto,
          option,
          long "image-workers",
          env "MAX_IMAGE_WORKERS",
          conf "image_workers",
          metavar "N",
          value 4
        ]
    shutdownDrainSeconds <-
      setting
        [ help "On SIGTERM, seconds to wait for in-flight agent dispatches",
          reader auto,
          option,
          long "shutdown-drain-seconds",
          env "MAX_SHUTDOWN_DRAIN_SECONDS",
          conf "shutdown_drain_seconds",
          metavar "SECS",
          value 120
        ]
    turnSilenceSeconds <-
      setting
        [ help "Seconds a turn may go without changing phase before it is cut off",
          reader auto,
          option,
          long "turn-silence-seconds",
          env "MAX_TURN_SILENCE_SECONDS",
          conf "turn_silence_seconds",
          metavar "SECS",
          value 600
        ]
    llm <- llmParser
    forceRawContext <-
      subConfig "context" $
        yesNoSwitch
          [ help "Emergency rollback: force all prompts to use the raw ledger while retaining context projections",
            long "force-raw-context",
            env "MAX_FORCE_RAW_CONTEXT",
            conf "force_raw_fallback",
            value False
          ]
    timezone <-
      minutesToTimeZone
        <$> setting
          [ help "Display timezone, minutes east of UTC (480 = UTC+8); stored times stay UTC",
            reader auto,
            option,
            long "timezone-minutes",
            env "MAX_TIMEZONE_MINUTES",
            conf "timezone_minutes",
            metavar "MIN",
            value 480
          ]
    persona <-
      setting
        [ help "Default bot persona / system-prompt identity segment",
          reader str,
          option,
          long "persona",
          env "MAX_PERSONA",
          conf "persona",
          metavar "TEXT",
          valueWithShown (const "(built-in Chinese default)") defaultPersona
        ]
    search <- subConfig "search" searchParser
    cliproxy <- subConfig "cliproxy" cliproxyParser
    browserProxy <-
      subConfig "browser" $
        optional $
          setting
            [ help "Proxy URL for the stealth-browser containers, e.g. http://host.docker.internal:7890 (use the host.docker.internal form for a proxy on the docker host)",
              reader str,
              option,
              long "browser-proxy",
              env "MAX_BROWSER_PROXY",
              conf "proxy",
              metavar "URL"
            ]
    browserStateKeyFile <- subConfig "browser" $ setting
      [help "Owner-only encryption key for browser checkpoints", reader str, option, long "browser-state-key-file", env "MAX_BROWSER_STATE_KEY_FILE", conf "state_key_file", value "var/browser-state.key"]
    browserIdleSeconds <- subConfig "browser" $ setting
      [help "Retain idle task browser workspaces for this many seconds", reader auto, option, long "browser-idle-seconds", env "MAX_BROWSER_IDLE_SECONDS", conf "idle_seconds", value 1800]
    browserGraceSeconds <- subConfig "browser" $ setting
      [help "Retain completed task browsers for this many seconds", reader auto, option, long "browser-grace-seconds", env "MAX_BROWSER_GRACE_SECONDS", conf "grace_seconds", value 300]
    memoryExtractProfile <-
      subConfig "memory" $
        optional $
          setting
            [ help "LLM profile for Historian v2 episode capture (presence enables it)",
              reader str,
              option,
              long "memory-extract-profile",
              env "MAX_MEMORY_EXTRACT_PROFILE",
              conf "extract_profile",
              metavar "PROFILE"
            ]
    historianTimeoutSeconds <-
      subConfig "memory" $
        setting
          [ help "Wall-clock timeout seconds for one Historian completion",
            reader auto,
            option,
            long "historian-timeout-seconds",
            env "MAX_HISTORIAN_TIMEOUT_SECONDS",
            conf "timeout_seconds",
            metavar "SECONDS",
            value 600
          ]
    stickerCaptionProfile <-
      subConfig "stickers" $
        optional $
          setting
            [ help "Vision-capable LLM profile for sticker/chat-media captioning (presence enables it)",
              reader str,
              option,
              long "sticker-caption-profile",
              env "MAX_STICKER_CAPTION_PROFILE",
              conf "caption_profile",
              metavar "PROFILE"
            ]
    stickersEnabled <-
      subConfig "stickers" $
        yesNoSwitch
          [ help "Default for whether the bot may post stickers (send_sticker tool); per-group override via !sticker on/off",
            long "stickers",
            env "MAX_STICKERS",
            conf "enabled",
            value True
          ]
    owners <-
      setting
        [ help "Bot owners' QQ ids (top permission tier: !model, !grant, …)",
          reader (commaSeparatedList auto),
          option,
          long "owners",
          env "MAX_OWNERS",
          conf "owners",
          metavar "QQ[,QQ..]",
          value []
        ]
    matrix <- subConfig "matrix" matrixParser
    imessage <- subConfig "imessage" iMessageParser
    wechathook <- subConfig "wechathook" wechatHookParser
    intent <- subConfig "intent" intentParser
    admin <- subConfig "admin" adminParser
    adminCallRetentionDays <-
      setting
        [ help "Days of full LLM request/response bodies to keep (token counters are kept forever)",
          reader auto,
          option,
          long "admin-call-retention-days",
          env "MAX_ADMIN_CALL_RETENTION_DAYS",
          conf "admin_call_retention_days",
          metavar "N",
          value 7
        ]
    embedding <- subConfig "embedding" embeddingParser
    debug <-
      yesNoSwitch
        [ help "Default debug mode: announce tool calls in the group (per-group override via !debug)",
          long "debug",
          env "MAX_DEBUG",
          conf "debug",
          value False
        ]
    logLevel <-
      setting
        [ help "Lowest log level printed: trace | info | warn",
          reader (maybeReader (parseLogLevel . T.pack)),
          option,
          long "log-level",
          env "MAX_LOG_LEVEL",
          confWith "log_level" logLevelCodec,
          metavar "LEVEL",
          valueWithShown (T.unpack . renderLogLevel) LogInfo
        ]
    logColor <-
      setting
        [ help "ANSI colour in log lines: auto (tty only) | always | never. journald isn't a tty, so a host read via journalctl wants 'always'",
          reader (maybeReader (parseColorMode . T.pack)),
          option,
          long "log-color",
          env "MAX_LOG_COLOR",
          confWith "log_color" colorModeCodec,
          metavar "auto|always|never",
          valueWithShown renderColorMode ColorAuto
        ]
    -- Filled by 'loadConfig' once the parser has run; the resolution
    -- happens outside this record and can't be threaded in.
    let configFileUsed = Nothing
    pure AppConfig {..}

-- | Which YAML file to read.
--
-- An explicitly named file must exist.  The library's own
-- 'withFirstYamlConfig' treats @--config-file@ as merely the first
-- /candidate/, so a typo'd path silently fell through to @./max.yaml@
-- and then to the built-in defaults — the run looked completely
-- normal while reading a different file, or none.  Naming a file is a
-- statement that it is the one to use, so a missing one is an error
-- rather than a hint.
--
-- Without an explicit path the old search order stands, first hit
-- wins: @./max.yaml@ > @$XDG_CONFIG_HOME/max/config.yaml@.
--
-- @MAX_CONFIG@ is the env spelling of the same setting, which is what
-- this module's header always claimed; it used to be a separate
-- candidate while @--config-file@ answered to @CONFIG_FILE@.
resolveConfigFile :: IORef (Maybe FilePath) -> Parser (Maybe (Path Abs File))
resolveConfigFile usedRef =
  checkMapIO pick $
    (,)
      <$> optional
        ( filePathSetting
            [ option,
              long "config-file",
              env "MAX_CONFIG",
              help "Path to the configuration file (must exist when given)"
            ]
        )
      <*> fallbacks
  where
    fallbacks = do
      local <- mapIO resolveFile' (pure "max.yaml")
      xdg <- xdgYamlConfigFile "max"
      pure [local, xdg]

    pick (Just p, _) = do
      let fp = toFilePath p
      fileExists <- doesFileExist fp
      if fileExists
        then Right (Just p) <$ note fp
        else
          pure . Left $
            "config file not found: "
              <> fp
              <> "\n(--config-file / MAX_CONFIG names the file to use; \
                 \omit it to search ./max.yaml then XDG)"
    pick (Nothing, candidates) = Right <$> firstExisting candidates

    firstExisting [] = Nothing <$ writeIORef usedRef Nothing
    firstExisting (p : ps) = do
      fileExists <- doesFileExist (toFilePath p)
      if fileExists then Just p <$ note (toFilePath p) else firstExisting ps

    note fp = writeIORef usedRef (Just fp)

--------------------------------------------------------------------------------
-- Server / DB.

serverParser :: Parser ServerConfig
serverParser = do
  host <-
    setting
      [ help "Reverse-WebSocket bind host",
        reader str,
        option,
        long "ws-host",
        env "MAX_WS_HOST",
        conf "host",
        metavar "HOST",
        value "0.0.0.0"
      ]
  port <-
    setting
      [ help "Reverse-WebSocket bind port",
        reader auto,
        option,
        long "ws-port",
        env "MAX_WS_PORT",
        conf "port",
        metavar "PORT",
        value 8080
      ]
  path <-
    setting
      [ help "Reverse-WebSocket path",
        reader str,
        option,
        long "ws-path",
        env "MAX_WS_PATH",
        conf "path",
        metavar "PATH",
        value "/onebot"
      ]
  accessToken <-
    optional $
      setting
        [ help "OneBot access token (NapCat must send the same one)",
          reader str,
          option,
          long "access-token",
          env "MAX_ACCESS_TOKEN",
          conf "access_token",
          metavar "TOKEN"
        ]
  pure ServerConfig {..}

dbParser :: Parser DbConfig
dbParser = do
  url <-
    setting
      [ help "PostgreSQL connection URL",
        reader str,
        option,
        long "db-url",
        env "MAX_DB_URL",
        conf "url",
        metavar "URL",
        value "postgresql://127.0.0.1:5433/max"
      ]
  maxConns <-
    setting
      [ -- Sized against the connections that are held rather than the ones
        -- that are used.  Every 'Max.DB.Notify' waiter pins one for as long as
        -- it is asleep: dispatch, monitors and plans take one each, delivery
        -- takes one per lane — one per configured platform plus the unrouted
        -- lane — and each in-flight admin long-poll takes one more.
        -- At the old default of 8 that left four for every turn, worker and
        -- query in the process, and 'Data.Pool' blocks on acquire with no
        -- timeout: exhaustion does not error, it hangs the bot.
        help "Connection-pool size.  LISTEN waiters hold three plus one per delivery lane",
        reader auto,
        option,
        long "db-max-conns",
        env "MAX_DB_MAX_CONNS",
        conf "max_conns",
        metavar "N",
        value 24
      ]
  pure DbConfig {..}

--------------------------------------------------------------------------------
-- Search.

searchParser :: Parser (Maybe SearchConfig)
searchParser = do
  mKey <-
    optional $
      setting
        [ help "Tavily API key (enables the web_search tool)",
          reader str,
          option,
          long "tavily-api-key",
          env "MAX_TAVILY_API_KEY",
          conf "tavily_api_key",
          metavar "KEY"
        ]
  maxResults <-
    setting
      [ help "web_search: default result count",
        reader auto,
        option,
        long "search-max-results",
        env "MAX_SEARCH_MAX_RESULTS",
        conf "max_results",
        metavar "N",
        value 5
      ]
  timeoutSecs <-
    setting
      [ help "web_search: HTTP timeout seconds",
        reader auto,
        option,
        long "search-timeout-seconds",
        env "MAX_SEARCH_TIMEOUT_SECONDS",
        conf "timeout_seconds",
        metavar "N",
        value 30
      ]
  pure $ case mKey of
    Just key
      | not (T.null key) ->
          Just
            SearchConfig
              { scTavilyApiKey = key,
                scDefaultMaxResults = maxResults,
                scTimeoutSeconds = timeoutSecs
              }
    _ -> Nothing

--------------------------------------------------------------------------------
-- The credential pool in front of the subscription.

-- | @cliproxy@ block: presence of @management_key@ enables the
-- @\/api\/quota@ endpoint.  The base URL defaults to the loopback port
-- CLIProxyAPI ships with, since the common deployment runs it beside
-- the bot.
cliproxyParser :: Parser (Maybe CliProxyConfig)
cliproxyParser = do
  mKey <-
    optional $
      setting
        [ help "CLIProxyAPI management key (enables /api/quota)",
          reader str,
          option,
          long "cliproxy-management-key",
          env "MAX_CLIPROXY_MANAGEMENT_KEY",
          conf "management_key",
          metavar "KEY"
        ]
  baseUrl <-
    setting
      [ help "CLIProxyAPI root URL (a /v1 tail is tolerated)",
        reader str,
        option,
        long "cliproxy-base-url",
        env "MAX_CLIPROXY_BASE_URL",
        conf "base_url",
        metavar "URL",
        value "http://127.0.0.1:8317"
      ]
  pure $ case mKey of
    Just key
      | not (T.null key) ->
          Just CliProxyConfig {cpBaseUrl = baseUrl, cpManagementKey = key}
    _ -> Nothing

--------------------------------------------------------------------------------
-- Proactive-trigger intent classification.

-- | Presence of @homeserver@ enables the single-room Matrix adapter.  The
-- remaining identity/credential fields are then mandatory; partial config is
-- a startup error rather than a silently disabled mirror.
matrixParser :: Parser (Maybe MatrixConfig)
matrixParser = do
  mHomeserver <-
    optional $
      setting
        [ help "Matrix homeserver base URL (presence enables Matrix)",
          reader str,
          option,
          long "matrix-homeserver",
          env "MAX_MATRIX_HOMESERVER",
          conf "homeserver",
          metavar "URL"
        ]
  accessToken <-
    setting
      [ help "Matrix access token",
        reader str,
        option,
        long "matrix-access-token",
        env "MAX_MATRIX_ACCESS_TOKEN",
        conf "access_token",
        metavar "TOKEN",
        value ""
      ]
  userId <-
    setting
      [ help "Matrix user id for Max, e.g. @max:example.org",
        reader str,
        option,
        long "matrix-user-id",
        env "MAX_MATRIX_USER_ID",
        conf "user_id",
        metavar "MXID",
        value ""
      ]
  roomId <-
    setting
      [ help "Allowlisted Matrix room id",
        reader str,
        option,
        long "matrix-room-id",
        env "MAX_MATRIX_ROOM_ID",
        conf "room_id",
        metavar "ROOM",
        value ""
      ]
  mirrorQQGroup <-
    optional $
      setting
        [ help "Explicit QQ group to mirror; omit for standalone Matrix",
          reader auto,
          option,
          long "matrix-mirror-qq-group",
          env "MAX_MATRIX_MIRROR_QQ_GROUP",
          conf "mirror_qq_group",
          metavar "QQ_GROUP"
        ]
  syncTimeoutMs <-
    setting
      [ help "Matrix /sync long-poll timeout in milliseconds",
        reader auto,
        option,
        long "matrix-sync-timeout-ms",
        env "MAX_MATRIX_SYNC_TIMEOUT_MS",
        conf "sync_timeout_ms",
        metavar "MS",
        value 30000
      ]
  pure $ case mHomeserver of
    Nothing -> Nothing
    Just homeserver
      | any (T.null . T.strip) [homeserver, accessToken, userId, roomId] ->
          error "matrix: homeserver, access_token, user_id and room_id must all be non-empty"
      | syncTimeoutMs < 1000 -> error "matrix: sync_timeout_ms must be at least 1000"
      | otherwise -> Just MatrixConfig {..}

iMessageParser :: Parser (Maybe IMessageConfig)
iMessageParser = do
  mBridgeUrl <-
    optional $
      setting
        [ help "iMessage bridge URL on Tailscale (presence enables iMessage)",
          reader str,
          option,
          long "imessage-bridge-url",
          env "MAX_IMESSAGE_BRIDGE_URL",
          conf "bridge_url",
          metavar "URL"
        ]
  bridgeToken <-
    setting
      [ help "Bearer token shared with imsg-bridge",
        reader str,
        option,
        long "imessage-bridge-token",
        env "MAX_IMESSAGE_BRIDGE_TOKEN",
        conf "bridge_token",
        metavar "TOKEN",
        value ""
      ]
  accountKey <-
    setting
      [ help "Stable name for the Mac/Messages account",
        reader str,
        option,
        long "imessage-account-key",
        env "MAX_IMESSAGE_ACCOUNT_KEY",
        conf "account_key",
        metavar "NAME",
        value ""
      ]
  chatGuid <-
    setting
      [ help "Allowlisted portable iMessage chat GUID",
        reader str,
        option,
        long "imessage-chat-guid",
        env "MAX_IMESSAGE_CHAT_GUID",
        conf "chat_guid",
        metavar "GUID",
        value ""
      ]
  botName <-
    setting
      [ help "Literal @alias fallback for manually typed iMessage text",
        reader str,
        option,
        long "imessage-bot-name",
        env "MAX_IMESSAGE_BOT_NAME",
        conf "bot_name",
        metavar "NAME",
        value "Maxwell"
      ]
  mentionHandles <-
    setting
      [ help "Apple handles that identify confirmed mentions of Max",
        reader (commaSeparatedList str),
        option,
        long "imessage-mention-handles",
        env "MAX_IMESSAGE_MENTION_HANDLES",
        conf "mention_handles",
        metavar "HANDLE[,HANDLE..]",
        value []
      ]
  mirrorQQGroup <-
    optional $
      setting
        [ help "Explicit QQ group to mirror; omit for a standalone iMessage chat",
          reader auto,
          option,
          long "imessage-mirror-qq-group",
          env "MAX_IMESSAGE_MIRROR_QQ_GROUP",
          conf "mirror_qq_group",
          metavar "QQ_GROUP"
        ]
  pollIntervalMs <-
    setting
      [ help "Backoff between iMessage bridge reconnect attempts",
        reader auto,
        option,
        long "imessage-poll-interval-ms",
        env "MAX_IMESSAGE_POLL_INTERVAL_MS",
        conf "poll_interval_ms",
        metavar "MS",
        value 1000
      ]
  pure $ case mBridgeUrl of
    Nothing -> Nothing
    Just bridgeUrl
      | any (T.null . T.strip) [bridgeUrl, bridgeToken, accountKey, chatGuid, botName] ->
          error "imessage: bridge_url, bridge_token, account_key, chat_guid and bot_name must all be non-empty"
      | null mentionHandles || any (T.null . T.strip) mentionHandles ->
          error "imessage: mention_handles must contain at least one non-empty Apple handle"
      | pollIntervalMs < 100 -> error "imessage: poll_interval_ms must be at least 100"
      | otherwise -> Just IMessageConfig {..}

-- | Enabled iff @intent.profile@ names an LLM profile; the numeric
-- knobs have defaults so a one-line config turns the feature on.
-- | @wechathook@ block: presence of @api_url@ enables the WeChat backend over
-- a hooked Windows PC client.
--
-- Two settings are security-relevant rather than cosmetic.  The callback the
-- hook posts is unsigned and unauthenticated, so @listen_host@ must stay on a
-- private interface and @callback_path@ must carry an unguessable segment —
-- together they are the only thing keeping a forged @sender@ out of max's
-- authorization layer.
--
-- 已知风险：DLL 注入 + 内存偏移写死在特定微信版本，客户端升级即失效；封号自担（跑小号）。
wechatHookParser :: Parser (Maybe WechatHookConfig)
wechatHookParser = do
  mUrl <-
    optional $
      setting
        [ help "WeChat-Hook HTTP base URL (presence enables the WeChat hook backend)",
          reader str,
          option,
          long "wechathook-api-url",
          env "MAX_WECHATHOOK_API_URL",
          conf "api_url",
          metavar "URL"
        ]
  listenHost <-
    setting
      [ help "Bind address for the callback listener — keep it off any public interface",
        reader str,
        option,
        long "wechathook-listen-host",
        env "MAX_WECHATHOOK_LISTEN_HOST",
        conf "listen_host",
        metavar "ADDR",
        value "127.0.0.1"
      ]
  listenPort <-
    setting
      [ help "Port for the callback listener",
        reader auto,
        option,
        long "wechathook-listen-port",
        env "MAX_WECHATHOOK_LISTEN_PORT",
        conf "listen_port",
        metavar "PORT",
        value 8787
      ]
  callbackPath <-
    setting
      [ help "Path the callback listener answers on; include an unguessable segment",
        reader str,
        option,
        long "wechathook-callback-path",
        env "MAX_WECHATHOOK_CALLBACK_PATH",
        conf "callback_path",
        metavar "PATH",
        value "/wechat/callback"
      ]
  callbackUrl <-
    setting
      [ help "Callback URL as reachable from the Windows host; re-asserted every minute",
        reader str,
        option,
        long "wechathook-callback-url",
        env "MAX_WECHATHOOK_CALLBACK_URL",
        conf "callback_url",
        metavar "URL",
        value ""
      ]
  selfWxid <-
    setting
      [ help "The bot WeChat account's own wxid",
        reader str,
        option,
        long "wechathook-self-wxid",
        env "MAX_WECHATHOOK_SELF_WXID",
        conf "self_wxid",
        metavar "WXID",
        value ""
      ]
  botName <-
    setting
      [ help "Display name used for @-detection in chatroom texts",
        reader str,
        option,
        long "wechathook-bot-name",
        env "MAX_WECHATHOOK_BOT_NAME",
        conf "bot_name",
        metavar "NAME",
        value "Max"
      ]
  chatrooms <-
    setting
      [ help "Chatroom whitelist (xxx@chatroom ids, comma separated)",
        reader (commaSeparatedList str),
        option,
        long "wechathook-chatrooms",
        env "MAX_WECHATHOOK_CHATROOMS",
        conf "chatrooms",
        metavar "ID[,ID..]",
        value []
      ]
  nicknames <-
    setting
      [ help "wxid -> display name (config file only).  WeChat 4.x leaves the \
             \hook's contact database unreachable, so this table is the only \
             \source of names; an unlisted sender stays honestly nameless.",
        conf "nicknames",
        valueWithShown (const "{}") Map.empty
      ]
  bridgeUrl <-
    setting
      [ help "bridge/wechat base URL on the Windows host; absent means no image support",
        reader str,
        option,
        long "wechathook-bridge-url",
        env "MAX_WECHATHOOK_BRIDGE_URL",
        conf "bridge_url",
        metavar "URL",
        value ""
      ]
  bridgeToken <-
    setting
      [ help "Bearer token the bridge requires",
        reader str,
        option,
        long "wechathook-bridge-token",
        env "MAX_WECHATHOOK_BRIDGE_TOKEN",
        conf "bridge_token",
        metavar "TOKEN",
        value ""
      ]
  silenceSeconds <-
    setting
      [ help "Warn when no callback has arrived for this many seconds (0 disables)",
        reader auto,
        option,
        long "wechathook-silence-seconds",
        env "MAX_WECHATHOOK_SILENCE_SECONDS",
        conf "silence_seconds",
        metavar "SECONDS",
        value 21600
      ]
  pure $ do
    url <- mUrl
    pure
      WechatHookConfig
        { whApiUrl = url,
          whListenHost = listenHost,
          whListenPort = listenPort,
          whCallbackPath = callbackPath,
          whCallbackUrl = callbackUrl,
          whSelfWxid = selfWxid,
          whBotName = botName,
          whChatrooms = chatrooms,
          whNicknames = nicknames,
          whSilenceSeconds = silenceSeconds,
          whBridgeUrl = bridgeUrl,
          whBridgeToken = bridgeToken
        }

intentParser :: Parser (Maybe IntentConfig)
intentParser = do
  mProfile <-
    optional $
      setting
        [ help "LLM profile for proactive-trigger intent classification (presence enables it)",
          reader str,
          option,
          long "intent-profile",
          env "MAX_INTENT_PROFILE",
          conf "profile",
          metavar "PROFILE"
        ]
  cooldown <-
    setting
      [ help "Seconds between interested-topic barge-ins per group (name-calls/follow-ups exempt)",
        reader auto,
        option,
        long "intent-cooldown-seconds",
        env "MAX_INTENT_COOLDOWN_SECONDS",
        conf "cooldown_seconds",
        metavar "N",
        value 300
      ]
  perHour <-
    setting
      [ help "Max proactive replies per group per hour, all trigger kinds",
        reader auto,
        option,
        long "intent-max-per-hour",
        env "MAX_INTENT_MAX_PER_HOUR",
        conf "max_per_hour",
        metavar "N",
        value 8
      ]
  ctxLines <-
    setting
      [ help "Recent group messages the intent classifier sees",
        reader auto,
        option,
        long "intent-context-lines",
        env "MAX_INTENT_CONTEXT_LINES",
        conf "context_lines",
        metavar "N",
        value 15
      ]
  pure $ case mProfile of
    Just p
      | not (T.null p) ->
          Just
            IntentConfig
              { icProfile = p,
                icCooldownSeconds = cooldown,
                icMaxPerHour = perHour,
                icContextLines = ctxLines
              }
    _ -> Nothing

--------------------------------------------------------------------------------
-- Admin API.

-- | Enabled iff @port@ is present.  The default bind is loopback on
-- purpose: auth beyond the optional bearer token is the reverse
-- proxy's job.
adminParser :: Parser (Maybe AdminConfig)
adminParser = do
  mPort <-
    optional $
      setting
        [ help "Admin JSON API port (presence enables the server)",
          reader auto,
          option,
          long "admin-port",
          env "MAX_ADMIN_PORT",
          conf "port",
          metavar "PORT"
        ]
  host <-
    setting
      [ help "Admin API bind address",
        reader str,
        option,
        long "admin-host",
        env "MAX_ADMIN_HOST",
        conf "host",
        metavar "ADDR",
        value "127.0.0.1"
      ]
  token <-
    optional $
      setting
        [ help "Bearer token required on every admin request",
          reader str,
          option,
          long "admin-token",
          env "MAX_ADMIN_TOKEN",
          conf "token",
          metavar "TOKEN"
        ]
  pure $ case mPort of
    Just p -> Just AdminConfig {acHost = host, acPort = p, acToken = token}
    Nothing -> Nothing

--------------------------------------------------------------------------------
-- Embeddings.

-- | Enabled iff both @base_url@ and @model@ are present — an API key
-- alone means nothing, and local servers (Ollama) need no key at all.
embeddingParser :: Parser (Maybe EmbeddingConfig)
embeddingParser = do
  mUrl <-
    optional $
      setting
        [ help "OpenAI-compatible embeddings base URL, e.g. http://127.0.0.1:11434/v1 (enables vector search)",
          reader str,
          option,
          long "embedding-base-url",
          env "MAX_EMBEDDING_BASE_URL",
          conf "base_url",
          metavar "URL"
        ]
  mKey <-
    optional $
      setting
        [ help "Embeddings API key (omit for local servers)",
          reader str,
          option,
          long "embedding-api-key",
          env "MAX_EMBEDDING_API_KEY",
          conf "api_key",
          metavar "KEY"
        ]
  mModel <-
    optional $
      setting
        [ help "Embedding model name, e.g. bge-m3",
          reader str,
          option,
          long "embedding-model",
          env "MAX_EMBEDDING_MODEL",
          conf "model",
          metavar "MODEL"
        ]
  timeoutSecs <-
    setting
      [ help "Embeddings HTTP timeout seconds",
        reader auto,
        option,
        long "embedding-timeout-seconds",
        env "MAX_EMBEDDING_TIMEOUT_SECONDS",
        conf "timeout_seconds",
        metavar "N",
        value 60
      ]
  pure $ case (mUrl, mModel) of
    (Just u, Just m)
      | not (T.null u) ->
          Just
            EmbeddingConfig
              { ecBaseUrl = u,
                ecApiKey = mKey,
                ecModel = m,
                ecTimeoutSeconds = timeoutSecs
              }
    _ -> Nothing

--------------------------------------------------------------------------------
-- LLM profiles.

-- | One profile as it appears in YAML (all fields optional) — also
-- the shape of the env/CLI single-profile overlay.
data ProfileSpec = ProfileSpec
  { apiKey :: !(Maybe Text),
    baseUrl :: !(Maybe Text),
    model :: !(Maybe Text),
    maxInputTokens :: !(Maybe Int),
    maxTokens :: !(Maybe Int),
    attachmentReserve :: !(Maybe Int),
    toolRoundReserve :: !(Maybe Int),
    temperature :: !(Maybe Double),
    effort :: !(Maybe Text),
    timeoutSeconds :: !(Maybe Int),
    protocol :: !(Maybe Protocol),
    multimodal :: !(Maybe Bool),
    historyAsTurns :: !(Maybe Bool),
    stream :: !(Maybe Bool)
  }
  deriving stock (Show, Eq)

emptySpec :: ProfileSpec
emptySpec =
  ProfileSpec Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Per-field first-Just-wins overlay (left = higher priority).
mergeSpec :: ProfileSpec -> ProfileSpec -> ProfileSpec
mergeSpec a b =
  ProfileSpec
    { apiKey = a.apiKey <|> b.apiKey,
      baseUrl = a.baseUrl <|> b.baseUrl,
      model = a.model <|> b.model,
      maxInputTokens = a.maxInputTokens <|> b.maxInputTokens,
      maxTokens = a.maxTokens <|> b.maxTokens,
      attachmentReserve = a.attachmentReserve <|> b.attachmentReserve,
      toolRoundReserve = a.toolRoundReserve <|> b.toolRoundReserve,
      temperature = a.temperature <|> b.temperature,
      effort = a.effort <|> b.effort,
      timeoutSeconds = a.timeoutSeconds <|> b.timeoutSeconds,
      protocol = a.protocol <|> b.protocol,
      multimodal = a.multimodal <|> b.multimodal,
      historyAsTurns = a.historyAsTurns <|> b.historyAsTurns,
      stream = a.stream <|> b.stream
    }

instance HasCodec ProfileSpec where
  codec =
    object "LLMProfile" $
      ProfileSpec
        <$> optionalField "api_key" "API key" .= (.apiKey)
        <*> optionalField "base_url" "OpenAI: …/v1 base URL; Anthropic: bare host" .= (.baseUrl)
        <*> optionalField "model" "Model id" .= (.model)
        <*> optionalField "max_input_tokens" "Hard input-token ceiling for prompt planning" .= (.maxInputTokens)
        <*> optionalField "max_tokens" "Max tokens per completion" .= (.maxTokens)
        <*> optionalField "attachment_reserve" "Input tokens reserved when media is attached" .= (.attachmentReserve)
        <*> optionalField "tool_round_reserve" "Input tokens reserved for later agent tool rounds" .= (.toolRoundReserve)
        <*> optionalFieldWith "temperature" temperatureCodec "Sampling temperature; omit to not send the field (some providers reject explicit values)" .= (.temperature)
        <*> optionalField "effort" "Reasoning effort (low/medium/high/xhigh/max on Anthropic; reasoning_effort on OpenAI protocol); omit to not send the field" .= (.effort)
        <*> optionalField "timeout_seconds" "HTTP timeout for one completion" .= (.timeoutSeconds)
        <*> optionalFieldWith "protocol" protocolCodec "openai | anthropic | responses" .= (.protocol)
        <*> optionalField "multimodal" "Endpoint accepts image content blocks" .= (.multimodal)
        <*> optionalField "history_as_turns" "Render history as user/assistant turns instead of one flat transcript" .= (.historyAsTurns)
        <*> optionalField "stream" "Stream the completion over SSE, sending finished paragraphs as they arrive" .= (.stream)

-- | autodocodec has no @HasCodec Double@ on purpose (lossy floats);
-- bridge through Scientific, which is fine for temperature values.
temperatureCodec :: JSONCodec Double
temperatureCodec = dimapCodec realToFrac realToFrac scientificCodec

protocolCodec :: JSONCodec Protocol
protocolCodec = bimapCodec parse render codec
  where
    parse t = case parseProtocol t of
      Just p -> Right p
      Nothing -> Left ("expected 'openai', 'anthropic' or 'responses', got: " <> T.unpack t)
    render ProtocolOpenAI = "openai" :: Text
    render ProtocolAnthropic = "anthropic"
    render ProtocolResponses = "responses"

llmParser :: Parser ModelCatalog
llmParser =
  mapIO materializeLLM $ subConfig "llm" $ do
    defaultName <-
      optional $
        setting
          [ help "Which profile is the default",
            reader str,
            option,
            long "llm-default-profile",
            env "MAX_LLM_DEFAULT_PROFILE",
            conf "default",
            metavar "NAME"
          ]
    profiles <-
      setting
        [ help "LLM profiles (config file only): name -> profile settings",
          conf "profiles",
          valueWithShown (const "{}") Map.empty
        ]
    overlay <- overlayProfileParser
    pure (defaultName, profiles, overlay)

-- | The env/CLI single-profile flags.  No @conf@ — file profiles come
-- through the @llm.profiles@ map.
overlayProfileParser :: Parser ProfileSpec
overlayProfileParser = do
  apiKey <-
    optional $
      setting
        [ help "API key for the default profile",
          reader str,
          option,
          long "llm-api-key",
          env "MAX_LLM_API_KEY",
          metavar "KEY"
        ]
  baseUrl <-
    optional $
      setting
        [ help "Base URL for the default profile",
          reader str,
          option,
          long "llm-base-url",
          env "MAX_LLM_BASE_URL",
          metavar "URL"
        ]
  model <-
    optional $
      setting
        [ help "Model id for the default profile",
          reader str,
          option,
          long "llm-model",
          env "MAX_LLM_MODEL",
          metavar "NAME"
        ]
  maxInputTokens <-
    optional $
      setting
        [ help "Hard input-token ceiling for prompt planning",
          reader auto,
          option,
          long "llm-max-input-tokens",
          env "MAX_LLM_MAX_INPUT_TOKENS",
          metavar "N"
        ]
  maxTokens <-
    optional $
      setting
        [ help "Max tokens for the default profile",
          reader auto,
          option,
          long "llm-max-tokens",
          env "MAX_LLM_MAX_TOKENS",
          metavar "N"
        ]
  attachmentReserve <-
    optional $
      setting
        [ help "Input tokens reserved when media is attached",
          reader auto,
          option,
          long "llm-attachment-reserve",
          env "MAX_LLM_ATTACHMENT_RESERVE",
          metavar "N"
        ]
  toolRoundReserve <-
    optional $
      setting
        [ help "Input tokens reserved for later agent tool rounds",
          reader auto,
          option,
          long "llm-tool-round-reserve",
          env "MAX_LLM_TOOL_ROUND_RESERVE",
          metavar "N"
        ]
  temperature <-
    optional $
      setting
        [ help "Sampling temperature for the default profile (omit to not send the field)",
          reader auto,
          option,
          long "llm-temperature",
          env "MAX_LLM_TEMPERATURE",
          metavar "F"
        ]
  timeoutSeconds <-
    optional $
      setting
        [ help "HTTP timeout seconds for the default profile",
          reader auto,
          option,
          long "llm-timeout-seconds",
          env "MAX_LLM_TIMEOUT_SECONDS",
          metavar "N"
        ]
  protocol <-
    optional $
      setting
        [ help "Wire protocol for the default profile",
          reader protoReader,
          option,
          long "llm-protocol",
          env "MAX_LLM_PROTOCOL",
          metavar "openai|anthropic|responses"
        ]
  multimodal <-
    optional $
      setting
        [ help "Default profile accepts image content blocks",
          reader auto,
          option,
          long "llm-multimodal",
          env "MAX_LLM_MULTIMODAL",
          metavar "True|False"
        ]
  historyAsTurns <-
    optional $
      setting
        [ help "Default profile gets history as user/assistant turns, not a flat transcript",
          reader auto,
          option,
          long "llm-history-as-turns",
          env "MAX_LLM_HISTORY_AS_TURNS",
          metavar "True|False"
        ]
  stream <-
    optional $
      setting
        [ help "Default profile streams completions over SSE",
          reader auto,
          option,
          long "llm-stream",
          env "MAX_LLM_STREAM",
          metavar "True|False"
        ]
  effort <-
    optional $
      setting
        [ help "Reasoning effort for the default profile (omit to not send the field)",
          reader str,
          option,
          long "llm-effort",
          env "MAX_LLM_EFFORT",
          metavar "LEVEL"
        ]
  pure ProfileSpec {..}
  where
    protoReader = eitherReader $ \s -> case parseProtocol (T.pack s) of
      Just p -> Right p
      Nothing -> Left ("expected 'openai', 'anthropic' or 'responses', got: " <> s)

-- | Same resolution rules as the old hand-rolled config: pick the
-- default profile name, overlay env/CLI values onto it, apply
-- per-field defaults, insist on api_key.
materializeLLM :: (Maybe Text, Map Text ProfileSpec, ProfileSpec) -> IO ModelCatalog
materializeLLM (dn, fileProfiles, overlay) = do
  let resolvedDefault = case dn of
        Just n -> n
        Nothing -> case Map.keys fileProfiles of
          [single] -> single
          _ -> "default"
      -- Overlay env/CLI fields onto the default profile; if the
      -- overlay is all-empty don't create a spurious profile.
      withOverlay
        | overlay == emptySpec = fileProfiles
        | otherwise = Map.insertWith mergeSpec resolvedDefault overlay fileProfiles
      -- Ensure the default profile exists even if nothing declared
      -- it (so the error below names it).
      withDefaultProfile = Map.insertWith (\_ old -> old) resolvedDefault emptySpec withOverlay
  resolved <- Map.traverseWithKey (resolveProfile resolvedDefault) withDefaultProfile
  either (fail . show) pure (mkModelCatalogFromProfiles resolvedDefault resolved)
  where
    resolveProfile def profName spec = do
      key <- case spec.apiKey of
        Just k | not (T.null k) -> pure k
        _ ->
          fail $
            "llm profile '"
              <> T.unpack profName
              <> "' has no api_key"
              <> ( if profName == def
                     then "\n  set via --llm-api-key, MAX_LLM_API_KEY, or llm.profiles." <> T.unpack profName <> ".api_key"
                     else "\n  set via llm.profiles." <> T.unpack profName <> ".api_key"
                 )
      let resolvedMultimodal = fromMaybe False spec.multimodal
          resolvedMaxInput = fromMaybe defaultContextLimits.maxInputTokens spec.maxInputTokens
          resolvedMaxOutput = fromMaybe defaultContextLimits.reservedOutputTokens spec.maxTokens
          resolvedAttachmentReserve =
            fromMaybe
              (if resolvedMultimodal then defaultContextLimits.attachmentReserve else 0)
              spec.attachmentReserve
          resolvedToolRoundReserve = fromMaybe defaultContextLimits.toolRoundReserve spec.toolRoundReserve
      when (resolvedMaxInput <= 0) $
        fail $
          "llm profile '" <> T.unpack profName <> "' has non-positive max_input_tokens"
      when (resolvedMaxOutput <= 0) $
        fail $
          "llm profile '" <> T.unpack profName <> "' has non-positive max_tokens"
      when (resolvedAttachmentReserve < 0 || resolvedToolRoundReserve < 0) $
        fail $
          "llm profile '" <> T.unpack profName <> "' has a negative context reserve"
      when (resolvedAttachmentReserve + resolvedToolRoundReserve >= resolvedMaxInput) $
        fail $
          "llm profile '" <> T.unpack profName <> "' reserves its entire input window"
      pure
        LLMProfile
          { apiKey = key,
            baseUrl = fromMaybe "https://api.deepseek.com/v1" spec.baseUrl,
            model = fromMaybe "deepseek-v4-flash" spec.model,
            maxInputTokens = resolvedMaxInput,
            maxTokens = resolvedMaxOutput,
            attachmentReserve = resolvedAttachmentReserve,
            toolRoundReserve = resolvedToolRoundReserve,
            -- No default: omitted temperature means "don't send the
            -- field" — some providers (kimi via opencode zen) 400 on
            -- any explicit value other than 1.0.
            temperature = spec.temperature,
            effort = spec.effort,
            timeoutSeconds = fromMaybe 120 spec.timeoutSeconds,
            protocol = fromMaybe ProtocolOpenAI spec.protocol,
            multimodal = resolvedMultimodal,
            historyAsTurns = fromMaybe False spec.historyAsTurns,
            stream = fromMaybe True spec.stream
          }

-- | @auto@ / @always@ / @never@ — the spellings 'parseColorMode' takes.
renderColorMode :: ColorMode -> String
renderColorMode = \case
  ColorAuto -> "auto"
  ColorAlways -> "always"
  ColorNever -> "never"

-- | Same bimap-over-Text shape as 'protocolCodec': the YAML side is a
-- plain string, and an unknown one names the accepted spellings rather
-- than failing anonymously.
logLevelCodec :: JSONCodec LogLevel
logLevelCodec = bimapCodec parse (T.unpack . renderLogLevel) codec
  where
    parse t = case parseLogLevel (T.pack t) of
      Just l -> Right l
      Nothing -> Left ("expected 'trace', 'info' or 'warn', got: " <> t)

colorModeCodec :: JSONCodec ColorMode
colorModeCodec = bimapCodec parse renderColorMode codec
  where
    parse t = case parseColorMode (T.pack t) of
      Just m -> Right m
      Nothing -> Left ("expected 'auto', 'always' or 'never', got: " <> t)
