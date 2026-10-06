-- | The Bungie.net Platform surface Max exposes, as data. Pure: which paths a
-- model may read or act on, how they become URLs, and how Bungie's response
-- envelope separates data from errors.
--
-- Reads cover profiles, characters, items, vendors, stats, activity history,
-- clans and the manifest; the two player searches are POST reads. Writes are
-- the item and loadout actions DIM performs: transfer, equip, lock, track,
-- postmaster, free socket plugs and loadouts. Everything else (clan admin,
-- fireteams, forums, paid socket changes) is refused before any request.
module Max.Bungie.Api
  ( ApiHost (..),
    ApiTarget (..),
    BungieError (..),
    readTarget,
    writeTarget,
    targetUrl,
    queryPairs,
    decodeEnvelope,
    renderBungieError,
    authExpired,
    throttled,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isControl, isDigit)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Max.HttpRuntime (pathPiece, queryText)

data ApiHost
  = -- | www.bungie.net
    MainHost
  | -- | stats.bungie.net, which serves post-game carnage reports.
    StatsHost
  deriving stock (Show, Eq)

-- | A validated request target: normalized path segments and query.
data ApiTarget = ApiTarget
  { atHost :: !ApiHost,
    atSegments :: ![Text],
    atQuery :: ![(Text, Text)]
  }
  deriving stock (Show, Eq)

data BungieError = BungieError
  { beCode :: !Int,
    beStatus :: !Text,
    beMessage :: !Text,
    beThrottleSeconds :: !Int
  }
  deriving stock (Show, Eq)

-- One pattern segment: a literal (compared case-insensitively, as Bungie
-- does), a numeric id (membership types may be -1), or any single segment.
data Seg = Lit Text | Num | Any

readPatterns :: [[Seg]]
readPatterns =
  [ lits ["User", "GetMembershipsForCurrentUser"],
    lits ["User", "GetMembershipsById"] <> [Num, Num],
    lits ["User", "GetBungieNetUserById"] <> [Num],
    lits ["Destiny2", "Manifest"],
    lits ["Destiny2", "Manifest"] <> [Any, Num],
    [Lit "Destiny2", Num, Lit "Profile", Num],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "LinkedProfiles"],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "Character", Num],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "Character", Num, Lit "Vendors"],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "Character", Num, Lit "Vendors", Num],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "Character", Num, Lit "Collectibles", Num],
    [Lit "Destiny2", Num, Lit "Profile", Num, Lit "Item", Num],
    [Lit "Destiny2", Num, Lit "Account", Num, Lit "Stats"],
    [Lit "Destiny2", Num, Lit "Account", Num, Lit "Character", Num, Lit "Stats"],
    [Lit "Destiny2", Num, Lit "Account", Num, Lit "Character", Num, Lit "Stats", Lit "Activities"],
    [Lit "Destiny2", Num, Lit "Account", Num, Lit "Character", Num, Lit "Stats", Lit "UniqueWeapons"],
    [Lit "Destiny2", Num, Lit "Account", Num, Lit "Character", Num, Lit "Stats", Lit "AggregateActivityStats"],
    lits ["Destiny2", "Stats", "PostGameCarnageReport"] <> [Num],
    lits ["Destiny2", "Stats", "Definition"],
    lits ["Destiny2", "Milestones"],
    lits ["Destiny2", "Milestones"] <> [Num, Lit "Content"],
    lits ["Destiny2", "Vendors"],
    lits ["Destiny2", "Armory", "Search"] <> [Any, Any],
    lits ["Destiny2", "Clan"] <> [Num, Lit "WeeklyRewardState"],
    lits ["GroupV2", "User"] <> [Num, Num, Num, Num],
    [Lit "GroupV2", Num],
    [Lit "GroupV2", Num, Lit "Members"],
    lits ["Content", "Rss", "NewsArticles"] <> [Num],
    lits ["GlobalAlerts"]
  ]

-- | Player searches are reads that Bungie only accepts as POST.
searchPatterns :: [[Seg]]
searchPatterns =
  [ lits ["Destiny2", "SearchDestinyPlayerByBungieName"] <> [Num],
    lits ["User", "Search", "GlobalName"] <> [Num]
  ]

writePatterns :: [[Seg]]
writePatterns =
  [lits ["Destiny2", "Actions", "Items", action] | action <- ["TransferItem", "PullFromPostmaster", "EquipItem", "EquipItems", "SetLockState", "SetTrackedState", "InsertSocketPlugFree"]]
    <> [lits ["Destiny2", "Actions", "Loadouts", action] | action <- ["EquipLoadout", "SnapshotLoadout", "UpdateLoadoutIdentifiers", "ClearLoadout"]]

lits :: [Text] -> [Seg]
lits = map Lit

-- | A read: GET, or POST with a body for the player searches.
readTarget :: Bool -> Text -> Value -> Either Text ApiTarget
readTarget hasBody path query = do
  segments <- normalizePath path
  let patterns = if hasBody then searchPatterns else readPatterns
  if any (`matches` segments) patterns
    then ApiTarget (hostFor segments) segments <$> queryPairs query
    else
      Left $
        if hasBody
          then "带 body 的读取只支持 SearchDestinyPlayerByBungieName 和 User/Search/GlobalName：" <> path
          else "不在可读接口白名单里：" <> path
  where
    hostFor segments = case map T.toCaseFold segments of
      _ : "stats" : "postgamecarnagereport" : _ -> StatsHost
      _ -> MainHost

writeTarget :: Text -> Either Text ApiTarget
writeTarget path = do
  segments <- normalizePath path
  if any (`matches` segments) writePatterns
    then Right (ApiTarget MainHost segments [])
    else Left ("不在可写接口白名单里（只有 Destiny2/Actions/Items|Loadouts 的转移、装备、锁定、追踪、邮政官、免费插件和配装）：" <> path)

-- Accept "/Platform/Destiny2/…/", "Destiny2/…" or a full Bungie URL; keep the
-- literal casing of matched patterns so URLs are canonical.
normalizePath :: Text -> Either Text [Text]
normalizePath raw
  | T.any (\c -> isControl c || c `elem` ['?', '#', '\\']) stripped = Left "path 只写路径，查询参数放 query"
  | null segments = Left "path 为空"
  | any (`elem` [".", ".."]) segments = Left "path 不能含 . 或 .."
  | length segments > 12 || T.length stripped > 512 = Left "path 太长"
  | otherwise = Right segments
  where
    stripped = foldr (\prefix t -> fromMaybe t (T.stripPrefix prefix t)) (T.strip raw) ["https://www.bungie.net", "https://stats.bungie.net", "https://bungie.net"]
    segments = dropPlatform (filter (not . T.null) (T.splitOn "/" stripped))
    dropPlatform = \case
      first : rest | T.toCaseFold first == "platform" -> rest
      other -> other

matches :: [Seg] -> [Text] -> Bool
matches pattern segments = length pattern == length segments && and (zipWith one pattern segments)
  where
    one (Lit expected) actual = T.toCaseFold expected == T.toCaseFold actual
    one Num actual = case T.stripPrefix "-" actual of
      Just digits -> numeric digits
      Nothing -> numeric actual
    one Any actual = not (T.null actual)
    numeric t = not (T.null t) && T.length t <= 20 && T.all isDigit t

targetUrl :: ApiTarget -> Text
targetUrl target =
  base <> "/Platform/" <> T.concat [pathPiece segment <> "/" | segment <- target.atSegments] <> queryText target.atQuery
  where
    base = case target.atHost of
      MainHost -> "https://www.bungie.net"
      StatsHost -> "https://stats.bungie.net"

-- | Query parameters from a JSON object of scalars or scalar lists. Lists
-- become Bungie's comma form (@components=100,200@).
queryPairs :: Value -> Either Text [(Text, Text)]
queryPairs = \case
  Null -> Right []
  Object fields -> traverse pair (KeyMap.toList fields)
  _ -> Left "query 必须是对象，如 {\"components\": [100, 200]}"
  where
    pair (key, value) = (,) (Key.toText key) <$> scalarList value
    scalarList = \case
      Array values -> T.intercalate "," <$> traverse scalar (toList values)
      value -> scalar value
    scalar = \case
      String t -> Right t
      Number n -> Right (either (T.pack . show) (T.pack . show) (floatingOrInteger n :: Either Double Integer))
      Bool b -> Right (if b then "true" else "false")
      _ -> Left "query 的值只能是字符串、数字、布尔或它们的数组"

-- | Split Bungie's envelope. HTTP 200 responses can still carry an error
-- code; error responses carry the same envelope.
decodeEnvelope :: Value -> Either BungieError Value
decodeEnvelope = \case
  Object o ->
    let code = intField "ErrorCode" o
     in if code == Just 1
          then Right (fromMaybe Null (KeyMap.lookup "Response" o))
          else
            Left
              BungieError
                { beCode = fromMaybe 0 code,
                  beStatus = textField "ErrorStatus" o,
                  beMessage = textField "Message" o,
                  beThrottleSeconds = fromMaybe 0 (intField "ThrottleSeconds" o)
                }
  _ -> Left (BungieError 0 "MalformedResponse" "Bungie 返回的不是 JSON 对象" 0)
  where
    intField name o = case KeyMap.lookup name o of
      Just (Number n) -> either (const Nothing) Just (floatingOrInteger n :: Either Double Int)
      _ -> Nothing
    textField name o = case KeyMap.lookup name o of
      Just (String t) -> t
      _ -> ""

renderBungieError :: BungieError -> Text
renderBungieError e =
  T.concat
    [ "Bungie ",
      if T.null e.beStatus then "error" else e.beStatus,
      " (",
      T.pack (show e.beCode),
      ")",
      if T.null e.beMessage then "" else ": " <> e.beMessage
    ]

-- | Errors that a fresh access token can cure.
authExpired :: BungieError -> Bool
authExpired e = e.beCode `elem` [99, 2111] || e.beStatus `elem` ["WebAuthRequired", "AccessTokenHasExpired", "AuthorizationRecordExpired", "AuthorizationRecordRevoked"]

-- | Bungie asks clients to wait ThrottleSeconds before retrying these.
throttled :: BungieError -> Bool
throttled e = e.beThrottleSeconds > 0 || e.beStatus `elem` ["ThrottleLimitExceeded", "ThrottleLimitExceededMomentarily", "ThrottleLimitExceededMinutes", "ThrottleLimitExceededSeconds", "DestinyThrottledByGameServer", "PerApplicationThrottleExceeded", "PerEndpointRequestThrottleExceeded", "PerUserThrottleExceeded"]
