-- | Closed, bounded message-hook contracts. Identity and scope come from host
-- assembly; the code can only recommend pass/ignore, never grant authority.
module Max.Hook.Types
  ( HookDefinition (..),
    HookPatch (..),
    HookQuery (..),
    HookResult (..),
    parseHookPatch,
    parseHookQuery,
    applyHookPatch,
    validateDefinition,
    parseDecision,
    resultValue,
    hookIgnored,
    maxHooks,
  )
where

import Control.Monad (unless, when)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isDigit)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

data HookDefinition = HookDefinition
  {name :: !Text, revision :: !Int, source :: !Text, config :: !Value, enabled :: !Bool}
  deriving stock (Eq, Show)

data HookPatch = HookPatch
  {hpName :: !Text, hpExpected :: !Int, hpEvent :: !(Maybe Text), hpSource :: !(Maybe Text), hpConfig :: !(Maybe Value), hpEnabled :: !(Maybe Bool)}
  deriving stock (Eq, Show)

data HookQuery
  = HookList
  | HookGet !Text !(Maybe Int)
  | HookTest !(Maybe Text) !(Maybe Int) !(Maybe Text) !(Maybe Value) !(Either Int64 Value)
  | HookRuns !(Maybe Text) !(Maybe Text) !(Maybe Int64) !(Maybe Int64) !Int
  | HookProjection !Int64
  deriving stock (Eq, Show)

data HookResult = HookResult {outcome :: !Text, reason :: !(Maybe Text), elapsedMs :: !Double}
  deriving stock (Eq, Show)

maxHooks :: Int
maxHooks = 8

parseHookPatch :: Value -> Either Text HookPatch
parseHookPatch = decodeWith $ withObject "set_hook" $ \o -> do
  closed ["name", "event", "expected_revision", "source", "config", "enabled"] o
  p <- HookPatch <$> o .: "name" <*> o .: "expected_revision" <*> o .:? "event" <*> o .:? "source" <*> pure (KM.lookup "config" o) <*> o .:? "enabled"
  either (fail . T.unpack) pure (validName p.hpName)
  when (p.hpExpected < 0 || p.hpExpected == maxBound) (fail "expected_revision must be nonnegative and incrementable")
  unless (maybe True (== "message.inbound") p.hpEvent) (fail "only message.inbound is supported")
  unless (any (`KM.member` o) ["source", "config", "enabled"]) (fail "provide source, config or enabled")
  pure p

applyHookPatch :: HookPatch -> Maybe HookDefinition -> Either Text HookDefinition
applyHookPatch p previous = do
  unless (maybe 0 (.revision) previous == p.hpExpected) (Left "revision_conflict: query the current definition before updating")
  code <- maybe (maybe (Left "creating a hook requires source") (Right . (.source)) previous) Right p.hpSource
  when (isNothing previous && p.hpEvent /= Just "message.inbound") (Left "creating a hook requires event=message.inbound")
  let next = HookDefinition p.hpName (p.hpExpected + 1) code (fromMaybe (maybe (object []) (.config) previous) p.hpConfig) (fromMaybe (maybe True (.enabled) previous) p.hpEnabled)
  validateDefinition next
  pure next

validateDefinition :: HookDefinition -> Either Text ()
validateDefinition d = do
  validName d.name
  when (T.null (T.strip d.source) || LBS.length (LBS.fromStrict (TE.encodeUtf8 d.source)) > 32768) (Left "source must contain 1..32768 UTF-8 bytes")
  when (LBS.length (encode d.config) > 16384) (Left "config exceeds 16 KiB")
  when (hasNul (toJSON [String d.source, d.config])) (Left "source/config cannot contain NUL")

validName :: Text -> Either Text ()
validName n = unless (not (T.null n) && T.length n <= 64 && T.all (\c -> isAsciiLower c || isDigit c || c `elem` ['-', '_']) n) (Left "name requires 1..64 lowercase ASCII letters, digits, - or _")

parseHookQuery :: Value -> Either Text HookQuery
parseHookQuery = decodeWith $ withObject "query_hooks" $ \o -> do
  view <- o .:? "view" .!= ("list" :: Text)
  case view of
    "list" -> closed ["view"] o >> pure HookList
    "get" -> do
      closed ["view", "name", "revision"] o
      HookGet <$> o .: "name" <*> positiveRevision o
    "test" -> do
      closed ["view", "name", "revision", "source", "config", "message_id", "sample"] o
      input <- case (KM.lookup "message_id" o, KM.lookup "sample" o) of
        (Just mid, Nothing) -> do
          n <- parseJSON mid
          when (n <= 0) (fail "message_id must be positive")
          pure (Left n)
        (Nothing, Just event@(Object _)) -> do
          when (LBS.length (encode event) > 65536) (fail "sample exceeds 64 KiB")
          pure (Right event)
        _ -> fail "provide exactly one of message_id or sample (event object)"
      n <- o .:? "name"
      r <- positiveRevision o
      s <- o .:? "source"
      when (isNothing n && isNothing s) (fail "test requires name or source")
      when (isNothing n && isJust r) (fail "revision requires name")
      pure (HookTest n r s (KM.lookup "config" o) input)
    "runs" -> do
      closed ["view", "name", "outcome", "message_id", "before", "limit"] o
      result <- o .:? "outcome"
      unless (maybe True (`elem` ["pass", "ignore", "error"]) result) (fail "invalid outcome")
      count <- o .:? "limit" .!= 20
      when (count < 1 || count > 100) (fail "limit must be 1..100")
      HookRuns <$> o .:? "name" <*> pure result <*> o .:? "message_id" <*> o .:? "before" <*> pure count
    "projection" -> do
      closed ["view", "message_id"] o
      mid <- o .: "message_id"
      when (mid <= 0) (fail "message_id must be positive")
      pure (HookProjection mid)
    _ -> fail "view must be list, get, test, runs or projection"
  where
    positiveRevision o = do
      r <- o .:? "revision"
      when (maybe False (<= 0) r) (fail "revision must be positive")
      pure r

parseDecision :: Value -> Either Text HookResult
parseDecision = decodeWith $ withObject "hook decision" $ \o -> do
  closed ["action", "reason"] o
  action <- o .: "action"
  unless (action `elem` ["pass", "ignore"]) (fail "action must be pass or ignore")
  why <- o .:? "reason"
  when (maybe False (\t -> T.length t > 512 || T.any (== '\0') t) why) (fail "reason must be at most 512 characters without NUL")
  pure (HookResult action why 0)

hookIgnored :: HookResult -> Bool
hookIgnored r = r.outcome /= "pass"

resultValue :: HookResult -> Value
resultValue r = object ["outcome" .= r.outcome, "reason" .= r.reason, "elapsed_ms" .= r.elapsedMs, "effective_action" .= (if hookIgnored r then "ignore" else "pass" :: Text)]

decodeWith :: (Value -> Parser a) -> Value -> Either Text a
decodeWith p = either (Left . T.pack) Right . parseEither p

closed :: [Key] -> Object -> Parser ()
closed keys o = unless (all (`elem` keys) (KM.keys o)) (fail "unknown argument field")

hasNul :: Value -> Bool
hasNul (String t) = T.any (== '\0') t
hasNul (Object o) = any (hasNul . String . toText) (KM.keys o) || any hasNul o
  where
    toText = Key.toText
hasNul (Array xs) = any hasNul xs
hasNul _ = False
