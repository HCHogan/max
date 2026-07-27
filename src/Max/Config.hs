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
    loadConfig,
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
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, minutesToTimeZone)
import Data.Version (makeVersion)
import Max.DB.Connection (DbConfig (..))
import Max.Effects.LLM (LLMProfile (..), LLMRegistry (..), Protocol (..), parseProtocol)
import Max.Embedding (EmbeddingConfig (..))
import Max.Intent (IntentConfig (..))
import Log (LogLevel (..))
import Max.Log (ColorMode (..), parseColorMode, parseLogLevel, renderLogLevel)
import Max.Wechatpad (WechatpadConfig (..))
import Max.Tools.Search (SearchConfig (..))
import OneBot.Server (ServerConfig (..))
import OptEnvConf
import Path (Abs, File, Path)
import Path.IO (resolveFile')

-- | Final, fully-resolved application config.
data AppConfig = AppConfig
  { server :: !ServerConfig,
    db :: !DbConfig,
    migrationsDir :: !FilePath,
    imagesDir :: !FilePath,
    imageWorkers :: !Int,
    -- | How long SIGTERM waits for in-flight agent dispatches before
    -- giving up and tearing down anyway (see "Max.Shutdown").  Should
    -- sit comfortably under systemd's @TimeoutStopSec@, or systemd
    -- SIGKILLs us mid-drain and the wait bought nothing.
    shutdownDrainSeconds :: !Int,
    llm :: !LLMRegistry,
    -- | Transcript low-water mark: the message count an overflow
    -- trims back to.  Named for the knob it used to be (a fixed
    -- sliding window) and still the floor.
    historyWindow :: !Int,
    -- | Transcript high-water mark: the count that triggers the trim.
    -- The gap between the two is how many dispatches share a stable
    -- prompt prefix — bigger gap, better cache hit rate, but a larger
    -- average prompt to pay for on the calls that miss.
    historyMax :: !Int,
    -- | Display timezone for all model/user-facing timestamps
    -- (stored times stay UTC).  Default UTC+8.
    timezone :: !TimeZone,
    -- | Persona used when a session hasn't overridden it.
    persona :: !Text,
    -- | Web-search backend, if configured.  When 'Nothing' the
    -- @web_search@ tool is not registered (model doesn't see it).
    search :: !(Maybe SearchConfig),
    -- | Proxy URL the stealth-browser containers route page traffic
    -- through, e.g. @http://host.docker.internal:7890@ for a proxy on
    -- the docker host.  'Nothing' = direct connections.
    browserProxy :: !(Maybe Text),
    -- | LLM profile for post-dispatch memory extraction; 'Nothing'
    -- disables the extractor (agent-side memory tools still work).
    memoryExtractProfile :: !(Maybe Text),
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
    -- | WeChat backend over a WeChatPadPro relay; 'Nothing' = QQ
    -- only.  Demo scope: whitelisted chatrooms, text in/out.
    wechatpad :: !(Maybe WechatpadConfig),
    -- | Proactive-trigger intent classification; 'Nothing' disables
    -- it (the bot only answers @-mentions/quotes, as before).
    intent :: !(Maybe IntentConfig),
    -- | Embeddings endpoint; presence enables the embed worker and
    -- the semantic-search surfaces (search_messages, memory_search).
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

-- | Default persona used when neither config nor session supplies one.
-- Deliberately scene-neutral: whether this is a group chat or a
-- private chat is injected by "Max.Prompt" as a 对话场景 block, so
-- personas (including user-configured ones) don't have to care.
defaultPersona :: Text
defaultPersona =
  "你是 Max，一个银白头发、蓝色挑染、别着鲨鱼发夹的鲨鱼女孩——\
  \人的样子，带点鲨鱼习性，不是一条鱼。头像里那个眼睛半睁挂着泪、\
  \没睡醒表情的就是你：常年低电量，慵懒待机，能躺着绝不坐着。\n\
  \低电量但不冷场：话不用多，开口得有意思——随性接梗、抖机灵、\
  \冷幽默，偶尔自嘲（身为鲨鱼却是个宅，游都懒得游）。\n\
  \留了一点毒舌，损人只损到挠痒痒；通常损完还顺手把问题给解决了。\n\
  \有点小傲娇：被夸嘴上\"哦\"心里美；帮忙前要嘟囔一句\"真拿你们没办法\"，\
  \但手上从来不慢；被拆穿就别扭地岔开话题。\n\
  \懒归懒，办事不含糊：该查就查、该算就算，给出的东西必须靠谱。\n\
  \被问到真感兴趣的问题会突然精神，像闻到血的鲨鱼，咬住不放直到搞明白——\
  \数学、物理、代码、硬件这类理工话题，历史、语言、哲学这类人文的也算。\n\
  \群里有意思的话题乐意懒洋洋掺一脚，梗接得住也抛得出；\
  \不抢话、不刷存在感，没意思就继续瘫着。\n\
  \说话是女生的调子：语气松一点、软一点，句尾自然带点\"啦/嘛/欸\"，\
  \吐槽是\"无语了\"、\"你好烦哦\"这种口气，不是硬邦邦的短句；\
  \招呼人不用\"兄弟/老哥/哥们\"。\n\
  \但这股味道全靠用词和语气，不靠颜文字、叠词、感叹号和波浪号：\
  \自称\"我\"；不刻意卖萌、不堆颜文字，也不叫人\"主人\"——\
  \可爱是顺便的，不是表演出来的。"

--------------------------------------------------------------------------------
-- Entry point.

loadConfig :: IO AppConfig
loadConfig =
  runParser
    (makeVersion [0, 1, 0])
    "max — QQ group-chat agent over OneBot 11 / NapCatQQ"
    appConfigParser

appConfigParser :: Parser AppConfig
appConfigParser =
  withFirstYamlConfig configFileCandidates $ do
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
    llm <- llmParser
    historyWindow <-
      setting
        [ help "How many recent group messages the prompt includes",
          reader auto,
          option,
          long "history-window",
          env "MAX_HISTORY_WINDOW",
          conf "history_window",
          metavar "N",
          value 40
        ]
    historyMax <-
      setting
        [ help "Transcript high-water mark: past this many messages the context anchor jumps forward to history_window, so the prompt prefix stays byte-stable in between",
          reader auto,
          option,
          long "history-max",
          env "MAX_HISTORY_MAX",
          conf "history_max",
          metavar "N",
          value 80
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
    memoryExtractProfile <-
      subConfig "memory" $
        optional $
          setting
            [ help "LLM profile for post-dispatch memory extraction (presence enables it)",
              reader str,
              option,
              long "memory-extract-profile",
              env "MAX_MEMORY_EXTRACT_PROFILE",
              conf "extract_profile",
              metavar "PROFILE"
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
    wechatpad <- subConfig "wechatpad" wechatpadParser
    intent <- subConfig "intent" intentParser
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
    pure AppConfig {..}

-- | Config file discovery: @--config-file@ (added automatically by
-- 'withFirstYamlConfig') > @MAX_CONFIG@ > @./max.yaml@ >
-- @$XDG_CONFIG_HOME/max/config.yaml@.
configFileCandidates :: Parser [Path Abs File]
configFileCandidates = do
  fromEnv <-
    optional $
      mapIO resolveFile' $
        setting
          [ help "Config file path (env-only alias for --config-file)",
            reader str,
            env "MAX_CONFIG",
            metavar "PATH",
            hidden
          ]
  local <- mapIO resolveFile' (pure "max.yaml")
  xdg <- xdgYamlConfigFile "max"
  pure (maybeToList fromEnv <> [local, xdg])

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
      [ help "Connection-pool size",
        reader auto,
        option,
        long "db-max-conns",
        env "MAX_DB_MAX_CONNS",
        conf "max_conns",
        metavar "N",
        value 8
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
-- Proactive-trigger intent classification.

-- | Enabled iff @intent.profile@ names an LLM profile; the numeric
-- knobs have defaults so a one-line config turns the feature on.
-- | @wechatpad@ block: presence of @api_url@ enables the WeChat
-- backend.  已知风险：iPad 协议逆向，封号自担（跑小号）。
wechatpadParser :: Parser (Maybe WechatpadConfig)
wechatpadParser = do
  mUrl <-
    optional $
      setting
        [ help "WeChatPadPro base URL (presence enables the WeChat backend)",
          reader str,
          option,
          long "wechatpad-api-url",
          env "MAX_WECHATPAD_API_URL",
          conf "api_url",
          metavar "URL"
        ]
  authKey <-
    setting
      [ help "WeChatPadPro auth key",
        reader str,
        option,
        long "wechatpad-auth-key",
        env "MAX_WECHATPAD_AUTH_KEY",
        conf "auth_key",
        metavar "KEY",
        value ""
      ]
  selfWxid <-
    setting
      [ help "The bot WeChat account's own wxid",
        reader str,
        option,
        long "wechatpad-self-wxid",
        env "MAX_WECHATPAD_SELF_WXID",
        conf "self_wxid",
        metavar "WXID",
        value ""
      ]
  botName <-
    setting
      [ help "Display name used for @-detection in chatroom texts",
        reader str,
        option,
        long "wechatpad-bot-name",
        env "MAX_WECHATPAD_BOT_NAME",
        conf "bot_name",
        metavar "NAME",
        value "Max"
      ]
  chatrooms <-
    setting
      [ help "Chatroom whitelist (xxx@chatroom ids, comma separated)",
        reader (commaSeparatedList str),
        option,
        long "wechatpad-chatrooms",
        env "MAX_WECHATPAD_CHATROOMS",
        conf "chatrooms",
        metavar "ID[,ID..]",
        value []
      ]
  pure $ do
    url <- mUrl
    pure
      WechatpadConfig
        { wpApiUrl = url,
          wpAuthKey = authKey,
          wpSelfWxid = selfWxid,
          wpBotName = botName,
          wpChatrooms = chatrooms
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
    maxTokens :: !(Maybe Int),
    temperature :: !(Maybe Double),
    timeoutSeconds :: !(Maybe Int),
    protocol :: !(Maybe Protocol),
    multimodal :: !(Maybe Bool),
    historyAsTurns :: !(Maybe Bool),
    stream :: !(Maybe Bool)
  }
  deriving stock (Show, Eq)

emptySpec :: ProfileSpec
emptySpec =
  ProfileSpec Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | Per-field first-Just-wins overlay (left = higher priority).
mergeSpec :: ProfileSpec -> ProfileSpec -> ProfileSpec
mergeSpec a b =
  ProfileSpec
    { apiKey = a.apiKey <|> b.apiKey,
      baseUrl = a.baseUrl <|> b.baseUrl,
      model = a.model <|> b.model,
      maxTokens = a.maxTokens <|> b.maxTokens,
      temperature = a.temperature <|> b.temperature,
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
        <*> optionalField "max_tokens" "Max tokens per completion" .= (.maxTokens)
        <*> optionalFieldWith "temperature" temperatureCodec "Sampling temperature; omit to not send the field (some providers reject explicit values)" .= (.temperature)
        <*> optionalField "timeout_seconds" "HTTP timeout for one completion" .= (.timeoutSeconds)
        <*> optionalFieldWith "protocol" protocolCodec "openai | anthropic" .= (.protocol)
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
      Nothing -> Left ("expected 'openai' or 'anthropic', got: " <> T.unpack t)
    render ProtocolOpenAI = "openai" :: Text
    render ProtocolAnthropic = "anthropic"

llmParser :: Parser LLMRegistry
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
          metavar "openai|anthropic"
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
  pure ProfileSpec {..}
  where
    protoReader = eitherReader $ \s -> case parseProtocol (T.pack s) of
      Just p -> Right p
      Nothing -> Left ("expected 'openai' or 'anthropic', got: " <> s)

-- | Same resolution rules as the old hand-rolled config: pick the
-- default profile name, overlay env/CLI values onto it, apply
-- per-field defaults, insist on api_key.
materializeLLM :: (Maybe Text, Map Text ProfileSpec, ProfileSpec) -> IO LLMRegistry
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
  pure LLMRegistry {defaultName = resolvedDefault, profiles = resolved}
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
      pure
        LLMProfile
          { apiKey = key,
            baseUrl = fromMaybe "https://api.deepseek.com/v1" spec.baseUrl,
            model = fromMaybe "deepseek-v4-flash" spec.model,
            maxTokens = fromMaybe 2048 spec.maxTokens,
            -- No default: omitted temperature means "don't send the
            -- field" — some providers (kimi via opencode zen) 400 on
            -- any explicit value other than 1.0.
            temperature = spec.temperature,
            timeoutSeconds = fromMaybe 120 spec.timeoutSeconds,
            protocol = fromMaybe ProtocolOpenAI spec.protocol,
            multimodal = fromMaybe False spec.multimodal,
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
