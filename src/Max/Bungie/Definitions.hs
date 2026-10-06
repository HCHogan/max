-- | Which manifest tables Max keeps and what it keeps of each definition.
-- Pure: the projection turns Bungie's full definitions (the zh-chs item table
-- alone is ~200 MB) into the fields a chat answer needs.
module Max.Bungie.Definitions
  ( syncedKinds,
    resolveKind,
    kindAliases,
    projectDefinition,
    englishName,
    unsignedHash,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (guard)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (nubBy)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

-- | Short names the tool accepts, and the tables synced locally. Other
-- @Destiny…Definition@ tables are still readable one hash at a time.
kindAliases :: [(Text, Text)]
kindAliases =
  [ ("item", "DestinyInventoryItemDefinition"),
    ("plugset", "DestinyPlugSetDefinition"),
    ("stat", "DestinyStatDefinition"),
    ("bucket", "DestinyInventoryBucketDefinition"),
    ("class", "DestinyClassDefinition"),
    ("race", "DestinyRaceDefinition"),
    ("gender", "DestinyGenderDefinition"),
    ("damage", "DestinyDamageTypeDefinition"),
    ("breaker", "DestinyBreakerTypeDefinition"),
    ("activity", "DestinyActivityDefinition"),
    ("activitytype", "DestinyActivityTypeDefinition"),
    ("mode", "DestinyActivityModeDefinition"),
    ("destination", "DestinyDestinationDefinition"),
    ("place", "DestinyPlaceDefinition"),
    ("vendor", "DestinyVendorDefinition"),
    ("perk", "DestinySandboxPerkDefinition"),
    ("socketcategory", "DestinySocketCategoryDefinition"),
    ("category", "DestinyItemCategoryDefinition"),
    ("objective", "DestinyObjectiveDefinition"),
    ("milestone", "DestinyMilestoneDefinition"),
    ("season", "DestinySeasonDefinition"),
    ("collectible", "DestinyCollectibleDefinition"),
    ("record", "DestinyRecordDefinition"),
    ("node", "DestinyPresentationNodeDefinition"),
    ("progression", "DestinyProgressionDefinition"),
    ("set", "DestinyEquipableItemSetDefinition"),
    ("loadoutname", "DestinyLoadoutNameDefinition")
  ]

syncedKinds :: [Text]
syncedKinds = map snd kindAliases

-- | Accept an alias or a full table name.
resolveKind :: Text -> Either Text Text
resolveKind raw
  | Just kind <- lookup (T.toLower stripped) kindAliases = Right kind
  | "Destiny" `T.isPrefixOf` stripped,
    "Definition" `T.isSuffixOf` stripped,
    T.all (\c -> c `elem` ['A' .. 'Z'] || c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9']) stripped =
      Right stripped
  | otherwise = Left ("未知的定义表：" <> raw <> "；可用简称：" <> T.intercalate ", " (map fst kindAliases))
  where
    stripped = T.strip raw

-- | Manifest keys and some API fields are unsigned 32-bit; others arrive
-- signed. Normalize to the unsigned value the tables are keyed by.
unsignedHash :: Int64 -> Maybe Int64
unsignedHash h
  | h >= 0 && h <= 4294967295 = Just h
  | h < 0 && h >= -2147483648 = Just (h + 4294967296)
  | otherwise = Nothing

-- | The name searched in English, alongside the localized one.
englishName :: Text -> Value -> Maybe Text
englishName kind value
  | boolAt ["redacted"] value = Nothing
  | otherwise = nonEmpty =<< case kind of
      "DestinyObjectiveDefinition" -> textAt ["progressDescription"] value
      "DestinyLoadoutNameDefinition" -> textAt ["name"] value
      _ -> textAt ["displayProperties", "name"] value <|> textAt ["title"] value

-- | (searchable name, projected data); 'Nothing' drops the row.
projectDefinition :: Text -> Value -> Maybe (Text, Value)
projectDefinition kind value
  | boolAt ["redacted"] value = Nothing
  | otherwise = case kind of
      "DestinyInventoryItemDefinition" -> projectItem value
      "DestinyPlugSetDefinition" -> projectPlugSet value
      "DestinyObjectiveDefinition" ->
        let name = fromMaybe "" (textAt ["progressDescription"] value)
         in Just (name, compact [("name", text name), ("completionValue", at ["completionValue"] value)])
      "DestinyLoadoutNameDefinition" -> do
        name <- nonEmpty =<< textAt ["name"] value
        pure (name, compact [("name", text name)])
      _ -> named (fromMaybe [] (lookup kind extraFields)) value

extraFields :: [(Text, [(Key, [Text])])]
extraFields =
  [ ("DestinyInventoryBucketDefinition", [("category", ["category"]), ("location", ["location"])]),
    ("DestinyClassDefinition", [("classType", ["classType"])]),
    ("DestinyDamageTypeDefinition", [("enumValue", ["enumValue"])]),
    ("DestinyBreakerTypeDefinition", [("enumValue", ["enumValue"])]),
    ("DestinyActivityDefinition", [("activityTypeHash", ["activityTypeHash"]), ("destinationHash", ["destinationHash"]), ("placeHash", ["placeHash"]), ("modeTypes", ["activityModeTypes"]), ("isPvP", ["isPvP"]), ("tier", ["tier"]), ("lightLevel", ["activityLightLevel"])]),
    ("DestinyActivityModeDefinition", [("modeType", ["modeType"]), ("isTeamBased", ["isTeamBased"])]),
    ("DestinyVendorDefinition", [("subtitle", ["displayProperties", "subtitle"])]),
    ("DestinyMilestoneDefinition", [("milestoneType", ["milestoneType"])]),
    ("DestinySeasonDefinition", [("seasonNumber", ["seasonNumber"])]),
    ("DestinyCollectibleDefinition", [("source", ["sourceString"]), ("itemHash", ["itemHash"])]),
    ("DestinyRecordDefinition", [("title", ["titleInfo", "titlesByGender", "Male"]), ("objectiveHashes", ["objectiveHashes"])]),
    ("DestinyPresentationNodeDefinition", [("objectiveHash", ["objectiveHash"]), ("completionRecordHash", ["completionRecordHash"])]),
    ("DestinyItemCategoryDefinition", [("shortTitle", ["shortTitle"])]),
    ("DestinyEquipableItemSetDefinition", [("setPerks", ["setPerks"])])
  ]

named :: [(Key, [Text])] -> Value -> Maybe (Text, Value)
named extras value = do
  name <- nonEmpty =<< (textAt ["displayProperties", "name"] value <|> textAt ["title"] value)
  pure
    ( name,
      compact $
        [("name", text name), ("description", String <$> (nonEmpty =<< textAt ["displayProperties", "description"] value))]
          <> [(key, at path value) | (key, path) <- extras]
    )

projectItem :: Value -> Maybe (Text, Value)
projectItem value = do
  name <- nonEmpty =<< textAt ["displayProperties", "name"] value
  let itemType = intAt ["itemType"] value
      gear = itemType `elem` [Just 2, Just 3]
  pure
    ( name,
      compact
        [ ("name", text name),
          ("description", String <$> (nonEmpty =<< textAt ["displayProperties", "description"] value)),
          ("type", String <$> (nonEmpty =<< textAt ["itemTypeDisplayName"] value)),
          ("tier", String <$> (nonEmpty =<< textAt ["inventory", "tierTypeName"] value)),
          ("tierType", at ["inventory", "tierType"] value),
          ("itemType", at ["itemType"] value),
          ("itemSubType", at ["itemSubType"] value),
          ("classType", at ["classType"] value),
          ("bucketTypeHash", at ["inventory", "bucketTypeHash"] value),
          ("damageType", at ["defaultDamageType"] value),
          ("ammoType", at ["equippingBlock", "ammoType"] value),
          ("plugCategory", String <$> (nonEmpty =<< textAt ["plug", "plugCategoryIdentifier"] value)),
          ("itemCategoryHashes", at ["itemCategoryHashes"] value),
          ("collectibleHash", at ["collectibleHash"] value),
          ("stats", if gear then itemStats value else Nothing),
          -- Gear carries the same numbers in stats; plugs and mods only here.
          ("investmentStats", if gear then Nothing else investmentStats value),
          ("sockets", sockets value),
          ("perks", perks value),
          ("flavor", String <$> (nonEmpty =<< textAt ["flavorText"] value))
        ]
    )

-- {statHash: value} without zeroes.
itemStats :: Value -> Maybe Value
itemStats value = do
  Object stats <- at ["stats", "stats"] value
  let pairs = [(key, Number n) | (key, entry) <- KeyMap.toList stats, Just (Number n) <- [at ["value"] entry], n /= 0]
  guard (not (null pairs))
  pure (Object (KeyMap.fromList pairs))

-- [[statHash, value]] for plugs that change stats (mods, masterworks, perks).
investmentStats :: Value -> Maybe Value
investmentStats value = do
  Array entries <- at ["investmentStats"] value
  let rows = [toJSON [h, n] | entry <- toList entries, Just h@(Number _) <- [at ["statTypeHash"] entry], Just n@(Number v) <- [at ["value"] entry], v /= 0]
  guard (not (null rows))
  pure (toJSON rows)

-- One entry per socket that can hold something, tagged with its category.
sockets :: Value -> Maybe Value
sockets value = do
  Array entries <- at ["sockets", "socketEntries"] value
  let categories =
        [ (index, category)
        | Just (Array cats) <- [at ["sockets", "socketCategories"] value],
          cat <- toList cats,
          Just category <- [at ["socketCategoryHash"] cat],
          Just (Array indexes) <- [at ["socketIndexes"] cat],
          Just index <- map intOf (toList indexes)
        ]
      socket (index, entry) =
        let plugs = [h | Just (Array reusable) <- [at ["reusablePlugItems"] entry], plug <- toList reusable, Just h <- [at ["plugItemHash"] plug]]
            fields =
              [ ("index", Just (toJSON index)),
                ("category", lookup index categories),
                ("initial", nonZero =<< at ["singleInitialItemHash"] entry),
                ("plugSet", nonZero =<< at ["reusablePlugSetHash"] entry),
                ("randomPlugSet", nonZero =<< at ["randomizedPlugSetHash"] entry),
                ("plugs", if null plugs then Nothing else Just (toJSON plugs))
              ]
         in if all (\(key, v) -> key `elem` ["index", "category"] || null v) fields then Nothing else Just (compact fields)
      projected = mapMaybe socket (zip [0 :: Int ..] (toList entries))
  guard (not (null projected))
  pure (toJSON projected)

perks :: Value -> Maybe Value
perks value = do
  Array entries <- at ["perks"] value
  let hashes = [h | entry <- toList entries, intAt ["perkVisibility"] entry `elem` [Nothing, Just 0], Just h <- [at ["perkHash"] entry]]
  guard (not (null hashes))
  pure (toJSON hashes)

projectPlugSet :: Value -> Maybe (Text, Value)
projectPlugSet value = do
  Array entries <- at ["reusablePlugItems"] value
  let plugs = [(h :: Int64, boolAt ["currentlyCanRoll"] entry) | entry <- toList entries, Just h <- [intOf =<< at ["plugItemHash"] entry]]
      merged = [(h, or [r | (h', r) <- plugs, h' == h]) | (h, _) <- nubBy (\a b -> fst a == fst b) plugs]
  pure ("", object ["plugs" .= [toJSON [toJSON h, toJSON canRoll] | (h, canRoll) <- merged]])

-- Drop absent and empty fields; keeps rows small and lookups readable.
compact :: [(Key, Maybe Value)] -> Value
compact fields = Object (KeyMap.fromList [(key, v) | (key, Just v) <- fields, meaningful v])
  where
    meaningful = \case
      Null -> False
      String t -> not (T.null t)
      Array a -> not (V.null a)
      Object o -> not (KeyMap.null o)
      _ -> True

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object o) = KeyMap.lookup (Key.fromText key) o >>= at rest
at _ _ = Nothing

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case at path value of
  Just (String t) -> Just t
  _ -> Nothing

intAt :: [Text] -> Value -> Maybe Int
intAt path value = intOf =<< at path value

intOf :: (Integral a) => Value -> Maybe a
intOf = \case
  Number n -> either (const Nothing) (Just . fromInteger) (floatingOrInteger n :: Either Double Integer)
  _ -> Nothing

boolAt :: [Text] -> Value -> Bool
boolAt path value = at path value == Just (Bool True)

nonZero :: Value -> Maybe Value
nonZero = \case
  Number 0 -> Nothing
  v -> Just v

nonEmpty :: Text -> Maybe Text
nonEmpty t = if T.null (T.strip t) then Nothing else Just t

text :: Text -> Maybe Value
text = Just . String
