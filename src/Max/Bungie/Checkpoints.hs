-- | Checkpoint bots listed by d2checkpoint.com: which raid or dungeon
-- encounter each bot holds and how full its fireteam is. A bot counts only
-- when its public Bungie profile shows it in that activity with a fireteam,
-- the same check the site makes before it shows a bot.
module Max.Bungie.Checkpoints
  ( CheckpointActivity (..),
    CheckpointBot (..),
    ActivityTable,
    Checkpoints (..),
    CheckpointCache,
    newCheckpointCache,
    fetchCheckpoints,
    checkpointActivities,
    checkpointReport,
    decodeDevalue,
    parseBots,
    appBundlePath,
    parseActivityTable,
    partySize,
  )
where

import Control.Concurrent.Async (concurrently, mapConcurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Monad (guard)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (chr, isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isHexDigit)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as V
import Data.Void (Void)
import Max.Bungie.Api (ApiHost (..), ApiTarget (..))
import Max.Bungie.Client (callBungie, renderBungieFailure)
import Max.Bungie.Types (BungieConfig)
import Max.Http.Failure (renderTransportFailure)
import Max.HttpRuntime (BufferedResponse (..), HttpPool (StandardPool), HttpRuntime, ResponseMetadata (..), parseRequestEither, runBuffered)
import Network.HTTP.Client (Request (..), RequestBody (..), responseTimeoutMicro)
import Network.HTTP.Types (hAccept, hContentType, hUserAgent)
import Text.Megaparsec
import Text.Megaparsec.Char (char, space, string)
import Text.Megaparsec.Char.Lexer qualified as L

-- | One entry of the site's activity table.
data CheckpointActivity = CheckpointActivity
  { caName :: !Text,
    -- | 0 when the activity has one difficulty, 1 Standard, 2 Master.
    caDifficultyTier :: !Int,
    caEncounters :: ![Text],
    caFireteamSize :: !Int,
    caOrder :: !Int
  }
  deriving stock (Show, Eq)

type ActivityTable = Map Int64 CheckpointActivity

data CheckpointBot = CheckpointBot
  { -- | Bungie name, which is also what players /join.
    cbName :: !Text,
    cbMembershipId :: !Text,
    -- | 0 while the bot holds nothing.
    cbActivity :: !Int64,
    -- | Index into the activity's encounter list.
    cbEncounter :: !Int,
    cbPremium :: !Bool
  }
  deriving stock (Show, Eq)

data Checkpoints = Checkpoints
  { cpTable :: !(Either Text ActivityTable),
    cpBots :: ![CheckpointBot],
    -- | Keyed by membership id, for bots that claim an activity: the
    -- fireteam size when Bungie shows the bot there, Nothing when it does
    -- not, or why Bungie could not be asked.
    cpParties :: !(Map Text (Either Text (Maybe Int)))
  }
  deriving stock (Show, Eq)

-- | The activity table changes only when the site ships new code, and its
-- page is slow to fetch from tank; the bot list is read on every call.
newtype CheckpointCache = CheckpointCache (MVar (Maybe (UTCTime, ActivityTable)))

newCheckpointCache :: IO CheckpointCache
newCheckpointCache = CheckpointCache <$> newMVar Nothing

site :: Text
site = "https://d2checkpoint.com"

fetchCheckpoints :: HttpRuntime -> BungieConfig -> CheckpointCache -> IO (Either Text Checkpoints)
fetchCheckpoints http config cache = do
  (table, listed) <- concurrently (cachedTable http cache) (fetchBots http)
  case listed of
    Left err -> pure (Left err)
    Right bots -> do
      let claimed = filter ((/= 0) . (.cbActivity)) bots
      parties <- mapConcurrently (\bot -> (bot.cbMembershipId,) <$> presence bot) claimed
      pure (Right (Checkpoints table bots (Map.fromList parties)))
  where
    -- The bots are Steam accounts; the site reads them as membership type 3.
    presence bot =
      either (Left . renderBungieFailure) (Right . partySize bot.cbActivity)
        <$> callBungie http config 4_000_000 Nothing (ApiTarget MainHost ["Destiny2", "3", "Profile", bot.cbMembershipId] [("components", "204,1000")]) Nothing

cachedTable :: HttpRuntime -> CheckpointCache -> IO (Either Text ActivityTable)
cachedTable http (CheckpointCache var) = modifyMVar var $ \cached -> do
  now <- getCurrentTime
  case cached of
    Just (fetched, table) | diffUTCTime now fetched < 3 * 3600 -> pure (cached, Right table)
    _ ->
      fetchTable >>= \case
        Right table -> pure (Just (now, table), Right table)
        -- A stale table still names the encounters of every older activity.
        Left err -> pure (cached, maybe (Left err) (Right . snd) cached)
  where
    fetchTable = do
      page <- siteRequest http "/" Nothing 2_000_000
      case appBundlePath . TE.decodeUtf8Lenient . (.body) =<< page of
        Left err -> pure (Left err)
        Right path -> (parseActivityTable . TE.decodeUtf8Lenient . (.body) =<<) <$> siteRequest http path Nothing 8_000_000

fetchBots :: HttpRuntime -> IO (Either Text [CheckpointBot])
fetchBots http = do
  response <- siteRequest http "/_actions/bots.getBotsFromDb" (Just "{}") 1_000_000
  pure $ do
    r <- response
    value <- first (("机器人列表不是 JSON：" <>) . T.pack) (eitherDecodeStrict' r.body)
    -- Astro actions answer in devalue's flat form unless they say plain JSON.
    let devalue = maybe True ("devalue" `BS.isInfixOf`) (lookup hContentType r.metadata.headers)
    parseBots =<< if devalue then decodeDevalue value else Right value

siteRequest :: HttpRuntime -> Text -> Maybe ByteString -> Int -> IO (Either Text BufferedResponse)
siteRequest http path body limit =
  parseRequestEither (T.unpack (site <> path)) >>= \case
    Left problem -> pure (Left (unreachable (renderTransportFailure problem)))
    Right request0 -> do
      let request =
            request0
              { method = maybe "GET" (const "POST") body,
                requestHeaders =
                  (hUserAgent, "max/1.0 (+https://github.com/HCHogan/max)")
                    : concat [[(hAccept, "application/json"), (hContentType, "application/json")] | isJust body],
                requestBody = maybe mempty RequestBodyBS body,
                responseTimeout = responseTimeoutMicro 30_000_000
              }
      first (unreachable . renderTransportFailure) <$> runBuffered http StandardPool limit 2048 request
  where
    unreachable detail = "d2checkpoint.com 不可达：" <> detail

-- | devalue's flat form: a JSON array whose first element is the root and
-- whose containers hold indices into the array. Negative indices stand for
-- undefined and non-finite numbers, and tagged arrays for Dates, Maps and
-- the like; none of them carry anything the bot list needs.
decodeDevalue :: Value -> Either Text Value
decodeDevalue = \case
  Array values | not (V.null values) -> hydrate values (0 :: Int) 0
  _ -> Left "机器人列表不是 devalue 数组"
  where
    hydrate values depth index
      | depth > 32 = Left "机器人列表嵌套过深"
      | index < 0 = Right Null
      | otherwise = case values V.!? index of
          Nothing -> Left "机器人列表的引用越界"
          Just (Array items)
            | Just (String _) <- items V.!? 0 -> Right Null
            | otherwise -> Array <$> traverse (reference values depth) items
          Just (Object fields) -> Object <$> traverse (reference values depth) fields
          Just primitive -> Right primitive
    reference values depth = \case
      Number n | Just index <- toBoundedInteger n -> hydrate values (depth + 1) index
      _ -> Left "机器人列表的引用不是整数"

parseBots :: Value -> Either Text [CheckpointBot]
parseBots = first (("机器人列表格式变了：" <>) . T.pack) . parseEither (withArray "bots" (fmap (mapMaybe id) . traverse bot . toList))
  where
    bot :: Value -> Parser (Maybe CheckpointBot)
    bot = withObject "bot" $ \o -> do
      name <- o .: "name"
      membership <- o .: "membershipId"
      parsed <-
        CheckpointBot name membership
          <$> (fromMaybe 0 <$> o .:? "activityHash")
          <*> (fromMaybe 0 <$> o .:? "encounter")
          <*> (fromMaybe False <$> o .:? "premium")
      -- The id becomes a Bungie path segment and the name a chat command.
      pure (parsed <$ guard (validId membership && T.length name <= 40 && T.all (\c -> c /= '\n' && c /= '\r') name))
    validId t = not (T.null t) && T.length t <= 20 && T.all isDigit t

-- | The client bundle that renders the bot grid, named in the home page's
-- island markup with a content hash that changes on every deploy.
appBundlePath :: Text -> Either Text Text
appBundlePath page = case T.breakOn marker page of
  (_, rest)
    | not (T.null rest) -> Right (T.takeWhile (/= '"') (T.drop (T.length "component-url=\"") rest))
  _ -> Left "d2checkpoint.com 首页里找不到活动表所在的脚本"
  where
    marker = "component-url=\"/_astro/app."

-- | The bundle's activity table, a minified object literal keyed by
-- activity hash that starts with the empty placeholder entry 0.
parseActivityTable :: Text -> Either Text ActivityTable
parseActivityTable bundle = case T.breakOn "{0:{name:\"\"," bundle of
  (_, rest)
    | not (T.null rest) -> case parse jsValue "activities" rest of
        Left err -> Left ("d2checkpoint.com 的活动表解析失败：" <> T.pack (take 200 (errorBundlePretty err)))
        Right (Object entries) ->
          Right . Map.fromList $
            [ (hash, activity)
            | (key, value) <- KeyMap.toList entries,
              Right (hash, "") <- [TR.decimal (Key.toText key)],
              hash /= 0,
              Right activity <- [parseEither entry value]
            ]
        Right _ -> Left "d2checkpoint.com 的活动表不是对象"
  _ -> Left "d2checkpoint.com 的脚本里找不到活动表"
  where
    entry = withObject "activity" $ \o ->
      CheckpointActivity
        <$> o .: "name"
        <*> (fromMaybe 0 <$> o .:? "difficultyTier")
        <*> (fromMaybe [] <$> o .:? "encounterList")
        <*> (fromMaybe 0 <$> o .:? "fireteamSize")
        <*> (fromMaybe 0 <$> o .:? "displayOrder")

type JsParser = Parsec Void Text

-- The literal subset a minifier emits for static data: objects with bare,
-- numeric or quoted keys, arrays, strings, numbers and !0/!1 booleans.
jsValue :: JsParser Value
jsValue =
  lexeme $
    choice
      [ Object . KeyMap.fromList <$> container '{' '}' field,
        Array . V.fromList <$> container '[' ']' jsValue,
        String <$> jsString,
        Bool True <$ (string "!0" <|> string "true"),
        Bool False <$ (string "!1" <|> string "false"),
        Null <$ string "null",
        Number <$> L.signed (pure ()) L.scientific
      ]
  where
    lexeme p = p <* space
    container open close item = between (lexeme (char open)) (char close) (item `sepEndBy` lexeme (char ','))
    field = (,) <$> lexeme (Key.fromText <$> key) <* lexeme (char ':') <*> jsValue
    key = jsString <|> identifier <|> takeWhile1P (Just "digit") isDigit
    identifier = T.cons <$> satisfy start <*> takeWhileP Nothing (\c -> start c || isAlphaNum c)
    start c = isAsciiLower c || isAsciiUpper c || c == '_' || c == '$'

jsString :: JsParser Text
jsString = choice [quoted '"', quoted '\'']
  where
    quoted q = T.pack <$> (char q *> manyTill character (char q))
    character = (char '\\' *> escape) <|> anySingle
    escape =
      choice
        [ '\n' <$ char 'n',
          '\t' <$ char 't',
          '\r' <$ char 'r',
          char 'u' *> hex 4,
          char 'x' *> hex 2,
          anySingle
        ]
    hex n = chr . foldl (\acc d -> acc * 16 + hexValue d) 0 <$> count n (satisfy isHexDigit)
    hexValue d
      | isDigit d = fromEnum d - fromEnum '0'
      | otherwise = fromEnum d - fromEnum (if d >= 'a' then 'a' else 'A') + 10

-- | The bot's fireteam size while Bungie shows it in the given activity with
-- a fireteam, which is when the site shows it as available.
partySize :: Int64 -> Value -> Maybe Int
partySize activity profile = do
  Array members <- at ["profileTransitoryData", "data", "partyMembers"] profile
  guard (not (null members))
  guard (at ["profileTransitoryData", "data", "currentActivity", "numberOfPlayers"] profile /= Just (Number 0))
  Object characters <- at ["characterActivities", "data"] profile
  guard (any (\c -> hashAt "currentActivityHash" c == Just activity) (KeyMap.elems characters))
  pure (length members)
  where
    hashAt key value = case at [key] value of
      Just (Number n) -> toBoundedInteger n
      _ -> Nothing

-- | Activities whose names the report needs from the manifest.
checkpointActivities :: Checkpoints -> [Int64]
checkpointActivities found = Map.keys (Map.fromList [(bot.cbActivity, ()) | bot <- found.cpBots, Map.member bot.cbMembershipId found.cpParties])

-- | What players need to pick a bot: the activity under its official name,
-- the encounter, the fireteam's room and the join command.
checkpointReport :: Map Int64 Text -> Checkpoints -> Value
checkpointReport names found =
  object $
    [ "source" .= site,
      "bots" .= length found.cpBots,
      "idle_bots" .= (length found.cpBots - length available - length failed),
      "checkpoints" .= map (uncurry row) (sortOn (order . fst) available)
    ]
      <> ["unverified" .= [object (describe bot <> ["error" .= err]) | (bot, err) <- failed] | not (null failed)]
      <> ["note" .= ("没读到网站的活动表，关卡名和队伍上限缺失（" <> err <> "）") | Left err <- [found.cpTable]]
  where
    table = either (const Map.empty) id found.cpTable
    available = [(bot, n) | bot <- found.cpBots, Just (Right (Just n)) <- [Map.lookup bot.cbMembershipId found.cpParties]]
    failed = [(bot, err) | bot <- found.cpBots, Just (Left err) <- [Map.lookup bot.cbMembershipId found.cpParties]]
    order bot = maybe (maxBound, 0) (\a -> (a.caOrder, bot.cbEncounter)) (Map.lookup bot.cbActivity table)
    row bot party =
      object $
        describe bot
          <> ["in_fireteam" .= party]
          <> concat [["fireteam_size" .= a.caFireteamSize, "open_slots" .= max 0 (a.caFireteamSize - party)] | Just a <- [Map.lookup bot.cbActivity table], a.caFireteamSize > 0]
          <> ["join" .= ("/加入 " <> bot.cbName), "join_en" .= ("/join " <> bot.cbName)]
          <> ["premium" .= True | bot.cbPremium]
    describe bot =
      let activity = Map.lookup bot.cbActivity table
          encounters = maybe [] (.caEncounters) activity
       in ["activity" .= fromMaybe (maybe (T.pack (show bot.cbActivity)) english activity) (Map.lookup bot.cbActivity names)]
            <> ["activity_en" .= english a | Just a <- [activity]]
            <> ["encounter" .= e | Just e <- [lookupIndex bot.cbEncounter encounters], not (T.null e)]
            <> ["encounter_number" .= (bot.cbEncounter + 1)]
            <> ["encounters" .= length encounters | not (null encounters)]
            <> ["bot" .= bot.cbName]
    english a = a.caName <> case a.caDifficultyTier of
      1 -> ": Standard"
      2 -> ": Master"
      _ -> ""
    lookupIndex i xs = if i >= 0 && i < length xs then Just (xs !! i) else Nothing

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object o) = KeyMap.lookup (Key.fromText key) o >>= at rest
at _ _ = Nothing
