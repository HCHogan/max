-- |
-- One log line per event, meant to be read by a person.
--
-- The default @log-base@ stdout backend emits pretty-printed JSON, so
-- a single dispatch spans a dozen lines and a field's value sits
-- nowhere near its event.  That is fine for a machine and miserable at
-- a terminal — and it also breaks the obvious @grep -A@ / @grep -B@
-- reflexes, because "the next line" is a brace rather than the next
-- event.
--
-- This renders instead:
--
-- > 14:32:07 INFO  llm      llm dispatch  group_id=7777 user_id=2001 origin=OriginDirect
-- > 14:32:09 WARN  llm      tool failed  name=web_search error="timeout after 15s"
--
-- Fixed-width time and level so the eye can track a column; the domain
-- next, dim, because it is the usual filter; then the message; then the
-- structured data as @key=value@.  Everything on one line, always —
-- newlines inside a value collapse to @⏎@, the same marker the prompt
-- renderer uses for the same reason.
--
-- == Levels
--
-- @log-base@ has exactly three ('LogTrace', 'LogInfo', 'LogAttention')
-- and this maps them one-to-one onto @TRACE@ \/ @INFO@ \/ @WARN@.
-- There is no fourth to give: the codebase uses 'logAttention' for both
-- recoverable warnings and outright failures, and splitting them would
-- mean auditing every call site rather than guessing here.  A heuristic
-- (say, "has an @error@ field") looks principled and isn't — half the
-- real failures, @llm dispatch failed@ among them, carry no such field.
module Max.Log
  ( ColorMode (..),
    withCompactLogger,
    formatLogMessage,
    parseColorMode,
    parseLogLevel,
    renderLogLevel,
  )
where

import Control.Exception (bracket)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Text (encodeToLazyText)
import Data.List (sortOn)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Log (LogLevel (..), LogMessage (..), Logger, mkLogger, waitForLogger)
import System.Environment (lookupEnv)
import System.IO (hFlush, hIsTerminalDevice, stdout)

-- | When to emit ANSI escapes.
--
-- 'ColorAuto' means "stdout is a terminal, and @NO_COLOR@ is unset".
-- Under systemd stdout is a pipe to journald, so auto resolves to off —
-- which is usually wrong, because @journalctl@ renders escapes happily
-- and that is where production logs are read.  Hence 'ColorAlways' as
-- an explicit setting rather than a cleverer guess.
data ColorMode
  = ColorAuto
  | ColorAlways
  | ColorNever
  deriving stock (Show, Eq)

parseColorMode :: Text -> Maybe ColorMode
parseColorMode t = case T.toLower (T.strip t) of
  "auto" -> Just ColorAuto
  "always" -> Just ColorAlways
  "never" -> Just ColorNever
  _ -> Nothing

-- | Accepts the names this module prints, plus @log-base@'s own
-- spellings so a value copied out of a config still works.
parseLogLevel :: Text -> Maybe LogLevel
parseLogLevel t = case T.toLower (T.strip t) of
  "trace" -> Just LogTrace
  "debug" -> Just LogTrace
  "info" -> Just LogInfo
  "warn" -> Just LogAttention
  "warning" -> Just LogAttention
  "attention" -> Just LogAttention
  "error" -> Just LogAttention
  _ -> Nothing

renderLogLevel :: LogLevel -> Text
renderLogLevel = \case
  LogTrace -> "trace"
  LogInfo -> "info"
  LogAttention -> "warn"

-- | Run an action with a logger writing compact lines to stdout.
--
-- Mirrors @Log.Backend.StandardOutput.withStdOutLogger@'s contract:
-- the logger is flushed and shut down on the way out, so nothing
-- buffered is lost when the process exits.
withCompactLogger :: ColorMode -> (Logger -> IO a) -> IO a
withCompactLogger mode act = do
  colored <- resolveColor mode
  bracket (mkLogger "compact" (emit colored)) waitForLogger act
  where
    emit colored msg = TIO.putStrLn (formatLogMessage colored msg) >> hFlush stdout

resolveColor :: ColorMode -> IO Bool
resolveColor = \case
  ColorAlways -> pure True
  ColorNever -> pure False
  ColorAuto -> do
    noColor <- lookupEnv "NO_COLOR"
    case noColor of
      -- Any value, including empty, disables colour — that is what the
      -- NO_COLOR convention specifies.
      Just _ -> pure False
      Nothing -> hIsTerminalDevice stdout

--------------------------------------------------------------------------------
-- Rendering

formatLogMessage :: Bool -> LogMessage -> Text
formatLogMessage colored msg =
  T.intercalate
    " "
    [ dim (fmtClock msg.lmTime),
      levelTag colored msg.lmLevel,
      pad domainWidth (dim (domainOf msg)),
      body
    ]
  where
    dim = ansi colored "2"
    fields = renderData colored msg.lmData
    -- Two spaces between the message and its fields.  One is not
    -- enough: the dim key colour separates them on a terminal, but the
    -- line most often gets read through grep or a redirect, where every
    -- escape is gone and "llm dispatch group_id=7777" reads as one run.
    body
      | null fields = msg.lmMessage
      | T.null msg.lmMessage = T.unwords fields
      | otherwise = msg.lmMessage <> "  " <> T.unwords fields

-- | Wall-clock only.  The date is in journald's own stamp in
-- production, and a local run rarely spans midnight.
fmtClock :: UTCTime -> Text
fmtClock = T.pack . formatTime defaultTimeLocale "%H:%M:%S"

domainOf :: LogMessage -> Text
domainOf msg = T.intercalate "/" msg.lmDomain

-- | Wide enough for the domains this bot actually uses ("llm",
-- "image-worker", "shutdown"); a longer one pushes the line rather
-- than being truncated, since a clipped domain is a useless one.
domainWidth :: Int
domainWidth = 8

levelTag :: Bool -> LogLevel -> Text
levelTag colored = \case
  LogTrace -> ansi colored "2" (pad 5 "TRACE")
  LogInfo -> ansi colored "36" (pad 5 "INFO")
  LogAttention -> ansi colored "1;33" (pad 5 "WARN")

-- | Structured data as @key=value@, keys sorted so the same event
-- always renders its fields in the same order (aeson objects are
-- unordered, and a line that shuffles between occurrences can't be
-- diffed or eyeballed).
renderData :: Bool -> Value -> [Text]
renderData colored = \case
  Object o ->
    [ ansi colored "2" (Key.toText k <> "=") <> renderValue v
    | (k, v) <- sortOn fst (KM.toList o)
    ]
  Null -> []
  v -> [renderValue v]

renderValue :: Value -> Text
renderValue = \case
  -- Unquoted unless the value could be mistaken for more fields: a log
  -- line is prose, not JSON, and quotes on every string is most of what
  -- makes the JSON backend hard to read.
  String s
    | T.any (\c -> c == ' ' || c == '=' || c == '"') s' -> quote s'
    | T.null s' -> "\"\""
    | otherwise -> s'
    where
      s' = oneLine s
  Number n -> case floatingOrInteger n :: Either Double Integer of
    -- Aeson holds every number as Scientific, so an id would otherwise
    -- print as 7777.0.
    Right i -> T.pack (show i)
    Left d -> T.pack (show d)
  Bool b -> if b then "true" else "false"
  Null -> "null"
  v -> oneLine (TL.toStrict (encodeToLazyText v))

quote :: Text -> Text
quote s = "\"" <> T.replace "\"" "\\\"" s <> "\""

-- | Collapse to a single line.  @⏎@ rather than @\\n@ because it stays
-- one visible character wide and is the marker "Max.Prompt" already
-- uses when flattening a multi-line message.
oneLine :: Text -> Text
oneLine = T.intercalate "⏎" . T.lines . T.replace "\r\n" "\n"

pad :: Int -> Text -> Text
pad n t
  | visible >= n = t
  | otherwise = t <> T.replicate (n - visible) " "
  where
    -- Escapes take no columns, so pad on the text the terminal shows.
    visible = T.length (stripAnsi t)

stripAnsi :: Text -> Text
stripAnsi t = case T.breakOn "\ESC[" t of
  (before, rest)
    | T.null rest -> before
    | otherwise -> before <> stripAnsi (T.drop 1 (T.dropWhile (/= 'm') rest))

ansi :: Bool -> Text -> Text -> Text
ansi False _ t = t
ansi True code t = "\ESC[" <> code <> "m" <> t <> "\ESC[0m"
