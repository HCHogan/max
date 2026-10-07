-- | The account's items as flat, translated rows: the composable base for any
-- inventory question. The host reads the whole profile in one request (no
-- code-mode size limit), translates every hash from the local manifest, and
-- code filters the rows with whatever predicate the question needs.
module Max.Bungie.Items
  ( ItemKind (..),
    parseItemKind,
    profileComponents,
    Lookups (..),
    itemHashes,
    socketPlugHashes,
    objectiveHashes,
    statHashes,
    normalizeItems,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits ((.&.))
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T

-- | Weapons, armor, both (the default), or every item including stacks.
data ItemKind = Weapons | Armor | Gear | Everything
  deriving stock (Show, Eq)

parseItemKind :: Text -> Either Text ItemKind
parseItemKind = \case
  "weapon" -> Right Weapons
  "armor" -> Right Armor
  "gear" -> Right Gear
  "all" -> Right Everything
  other -> Left ("kind 只能是 weapon、armor、gear 或 all：" <> other)

-- | Characters, inventories, equipment, and every item component the rows
-- report: instances, objectives, stats, sockets, plug objectives and
-- selectable plugs.
profileComponents :: [Int]
profileComponents = [102, 200, 201, 205, 300, 301, 304, 305, 309, 310]

-- | Translations, each keyed by hash.
data Lookups = Lookups
  { lItems :: !(Map Int64 Value),
    lBuckets :: !(Map Int64 Text),
    lCategories :: !(Map Int64 Text),
    lStats :: !(Map Int64 Text),
    lObjectives :: !(Map Int64 Text)
  }

-- Intrinsic traits, weapon perks, armor perks: what "带 X 的" asks about.
perkCategories :: [Int64]
perkCategories = [3956125808, 4241085061, 3154740035]

-- Weapon and armor cosmetics: shaders and ornaments.
cosmeticCategories :: [Int64]
cosmeticCategories = [2048875504, 1926152773]

data Entry = Entry
  { enItem :: !Object,
    enLocation :: !Text,
    enCharacter :: !(Maybe Text)
  }

entries :: Value -> [Entry]
entries profile =
  [Entry item (if bucket item == Just 138197802 then "vault" else "account") Nothing | item <- itemsAt ["profileInventory", "data", "items"]]
    <> [Entry item (if bucket item == Just 215593132 then "postmaster" else "inventory") (Just cid) | (cid, items) <- perCharacter "characterInventories", item <- items]
    <> [Entry item "equipped" (Just cid) | (cid, items) <- perCharacter "characterEquipment", item <- items]
  where
    bucket item = intField "bucketHash" (Object item)
    itemsAt path = case at path profile of
      Just (Array items) -> [o | Object o <- toList items]
      _ -> []
    perCharacter key = case at [key, "data"] profile of
      Just (Object characters) ->
        [ (Key.toText cid, [o | Object o <- toList items])
        | (cid, Object inventory) <- KeyMap.toList characters,
          Just (Array items) <- [KeyMap.lookup "items" inventory]
        ]
      _ -> []

itemHashes :: Value -> [Int64]
itemHashes profile = nub (mapMaybe (intField "itemHash" . Object . (.enItem)) (entries profile))

selected :: ItemKind -> Map Int64 Value -> Value -> [(Entry, Value)]
selected kind definitions profile =
  [ (entry, definition)
  | entry <- entries profile,
    Just hash <- [intField "itemHash" (Object entry.enItem)],
    Just definition <- [Map.lookup hash definitions],
    wanted (intField "itemType" definition)
  ]
  where
    wanted itemType = case kind of
      Weapons -> itemType == Just 3
      Armor -> itemType == Just 2
      Gear -> itemType `elem` [Just 2, Just 3]
      Everything -> True

-- Each socket the definition declares, with what is slotted (305) and what it
-- can switch to (310).
data Socket = Socket
  { soCategory :: !Int64,
    soSlotted :: !(Maybe Int64),
    soOptions :: ![Int64]
  }

socketsOf :: Value -> Text -> Value -> [Socket]
socketsOf profile instanceId definition =
  [ Socket category slotted [o | o <- options, Just o /= slotted]
  | Just (Array declared) <- [at ["sockets"] definition],
    Object socket <- toList declared,
    Just category <- [intField "category" (Object socket)],
    Just index <- [intField "index" (Object socket)],
    let slotted = live index
        options = reusable index,
    isJust slotted || not (null options)
  ]
  where
    live index = do
      Array states <- at ["itemComponents", "sockets", "data", instanceId, "sockets"] profile
      Object state <- listToMaybe (drop (fromIntegral index) (toList states))
      plug <- intField "plugHash" (Object state)
      if KeyMap.lookup "isVisible" state == Just (Bool False) then Nothing else Just plug
    reusable index = case at ["itemComponents", "reusablePlugs", "data", instanceId, "plugs", T.pack (show index)] profile of
      Just (Array plugs) -> nub (mapMaybe (intField "plugItemHash") (toList plugs))
      _ -> []

instanceOf :: Entry -> Maybe Text
instanceOf entry = case KeyMap.lookup "itemInstanceId" entry.enItem of
  Just (String i) -> Just i
  _ -> Nothing

-- | Every plug hash the rows will name.
socketPlugHashes :: ItemKind -> Map Int64 Value -> Value -> [Int64]
socketPlugHashes kind definitions profile =
  nub
    [ plug
    | (entry, definition) <- selected kind definitions profile,
      Just instanceId <- [instanceOf entry],
      socket <- socketsOf profile instanceId definition,
      plug <- maybe id (:) socket.soSlotted socket.soOptions
    ]

objectiveHashes :: Value -> [Int64]
objectiveHashes profile =
  nub
    [ h
    | Just (Object byItem) <- [at ["itemComponents", "plugObjectives", "data"] profile, at ["itemComponents", "objectives", "data"] profile],
      progress <- KeyMap.elems byItem,
      Object objective <- objectivesIn progress,
      Just h <- [intField "objectiveHash" (Object objective)]
    ]

statHashes :: Value -> [Int64]
statHashes profile =
  nub
    [ h
    | Just (Object byItem) <- [at ["itemComponents", "stats", "data"] profile],
      Object item <- KeyMap.elems byItem,
      Just (Object stats) <- [KeyMap.lookup "stats" item],
      stat <- KeyMap.elems stats,
      Just h <- [intField "statHash" stat]
    ]

-- 301 lists {objectives: [...]}; 309 lists {objectivesPerPlug: {plug: [...]}}.
objectivesIn :: Value -> [Value]
objectivesIn value =
  [o | Just (Array list) <- [at ["objectives"] value], o <- toList list]
    <> [o | Just (Object perPlug) <- [at ["objectivesPerPlug"] value], Array list <- KeyMap.elems perPlug, o <- toList list]

-- | Rows for code to filter. Perk columns list the slotted plug first, then
-- the others it can switch to; mods and cosmetics group slotted plugs by
-- socket category.
normalizeItems :: ItemKind -> Lookups -> Value -> [Value]
normalizeItems kind lookups profile = map row (selected kind lookups.lItems profile)
  where
    classes = case at ["characters", "data"] profile of
      Just (Object characters) -> Map.fromList [(Key.toText cid, name) | (cid, c) <- KeyMap.toList characters, Just name <- [intField "classType" c >>= (`lookup` classNames)]]
      _ -> Map.empty
    row (entry, definition) =
      let instanceId = instanceOf entry
          sockets = maybe [] (\i -> socketsOf profile i definition) instanceId
          instance' = instanceId >>= \i -> at ["itemComponents", "instances", "data", i] profile
          state = fromMaybe 0 (intField "state" (Object entry.enItem))
          quantity = fromMaybe 1 (intField "quantity" (Object entry.enItem))
          gear = intField "itemType" definition `elem` [Just 2, Just 3]
          -- Unnamed plugs are internal; a column whose slotted plug has no
          -- name is dropped so the first entry always means "slotted".
          perks =
            [ maybe [] pure slottedName <> mapMaybe plugName s.soOptions
            | s <- sockets,
              s.soCategory `elem` perkCategories,
              let slottedName = s.soSlotted >>= plugName,
              maybe True (const (isJust slottedName)) s.soSlotted,
              isJust slottedName || not (null (mapMaybe plugName s.soOptions))
            ]
          grouped wanted = groupByCategory [s | s <- sockets, wanted s.soCategory]
          mods = grouped (\c -> c `notElem` perkCategories && c `notElem` cosmeticCategories)
          cosmetics = grouped (`elem` cosmeticCategories)
          stats = do
            i <- instanceId
            Object values <- at ["itemComponents", "stats", "data", i, "stats"] profile
            pure $ object [Key.fromText (named lookups.lStats h) .= v | Object stat <- KeyMap.elems values, Just h <- [intField "statHash" (Object stat)], Just v <- [intField "value" (Object stat)], v /= 0]
          objectives = do
            i <- instanceId
            let found = concat [objectivesIn v | Just v <- [at ["itemComponents", "objectives", "data", i] profile, at ["itemComponents", "plugObjectives", "data", i] profile]]
            if null found then Nothing else Just (map objective found)
       in object $
            [ "id" .= instanceId,
              "hash" .= intField "itemHash" (Object entry.enItem),
              "name" .= textField "name" definition,
              "type" .= textField "type" definition,
              "tier" .= textField "tier" definition,
              "location" .= entry.enLocation
            ]
              <> ["slot" .= name | Just b <- [intField "bucketTypeHash" definition], Just name <- [Map.lookup b lookups.lBuckets]]
              <> ["character_id" .= cid | Just cid <- [entry.enCharacter]]
              <> ["character" .= name | Just cid <- [entry.enCharacter], Just name <- [Map.lookup cid classes]]
              <> ["class" .= name | intField "itemType" definition == Just 2, Just name <- [intField "classType" definition >>= (`lookup` classNames)]]
              <> ["quantity" .= quantity | quantity > 1]
              <> ["power" .= p | Just p <- [instance' >>= at ["primaryStat", "value"] >>= int], p > 0]
              <> ["damage" .= d | Just d <- [instance' >>= intField "damageType" >>= (`lookup` damageNames)]]
              <> [flag .= True | gear, (bit, flag) <- stateFlags, state .&. bit /= 0]
              <> ["perks" .= perks | not (null perks)]
              <> ["mods" .= mods | not (KeyMap.null mods)]
              <> ["cosmetics" .= cosmetics | not (KeyMap.null cosmetics)]
              <> ["stats" .= s | Just s <- [stats]]
              <> ["objectives" .= o | Just o <- [objectives]]
    groupByCategory sockets =
      KeyMap.fromListWith
        (\new old -> case (old, new) of (Array a, Array b) -> Array (a <> b); _ -> new)
        [(Key.fromText (named lookups.lCategories s.soCategory), toJSON [name]) | s <- sockets, Just name <- [s.soSlotted >>= plugName]]
    objective o =
      object
        [ "name" .= (intField "objectiveHash" o >>= (`Map.lookup` lookups.lObjectives)),
          "progress" .= intField "progress" o,
          "completion" .= intField "completionValue" o,
          "complete" .= (at ["complete"] o == Just (Bool True))
        ]
    plugName h = Map.lookup h lookups.lItems >>= textField "name"
    named table h = Map.findWithDefault (T.pack (show h)) h table
    stateFlags = [(1, "locked"), (2, "tracked"), (4, "masterwork"), (8, "crafted"), (32, "enhanced")] :: [(Int64, Key)]
    damageNames = [(1, "动能"), (2, "电弧"), (3, "烈日"), (4, "虚空"), (6, "冰影"), (7, "缚丝")] :: [(Int64, Text)]
    classNames = [(0, "泰坦"), (1, "猎人"), (2, "术士")] :: [(Int64, Text)]

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object o) = KeyMap.lookup (Key.fromText key) o >>= at rest
at _ _ = Nothing

intField :: Text -> Value -> Maybe Int64
intField key value = at [key] value >>= int

int :: Value -> Maybe Int64
int = \case
  Number n -> either (const Nothing) Just (floatingOrInteger n :: Either Double Int64)
  _ -> Nothing

textField :: Text -> Value -> Maybe Text
textField key value = case at [key] value of
  Just (String t) -> Just t
  _ -> Nothing
