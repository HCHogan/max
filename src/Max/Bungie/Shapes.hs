{-# LANGUAGE TemplateHaskell #-}

-- | Response structures from Bungie's OpenAPI specification, generated into
-- data/bungie-shapes.json by scripts/bungie-shapes.py and embedded at build
-- time. A model about to read a Platform response asks for its shape instead
-- of probing the payload with Object.keys round after round.
module Max.Bungie.Shapes
  ( describeEndpoint,
    describeType,
    shapesVersion,
  )
where

import Data.Aeson
import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.List (find, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

data Field = Field
  { fLine :: !Text,
    fRefs :: ![Text],
    fComponent :: !(Maybe Int)
  }

data TypeShape = TypeShape
  { tLine :: !Text,
    tFields :: ![Field],
    tRefs :: ![Text]
  }

data Endpoint = Endpoint
  { eMethod :: !Text,
    ePath :: !Text,
    eSummary :: !Text,
    eResponse :: !Text,
    eResponseRefs :: ![Text],
    eRequest :: !(Maybe Text),
    eRequestRefs :: ![Text]
  }

data Shapes = Shapes
  { sVersion :: !Text,
    sLegend :: !Text,
    sComponents :: !(Map Text Text),
    sNames :: !(Map Text Text),
    sEndpoints :: ![Endpoint],
    sTypes :: !(Map Text TypeShape)
  }

instance FromJSON Field where
  parseJSON = withObject "field" $ \o -> Field <$> o .: "line" <*> o .: "refs" <*> o .:? "component"

instance FromJSON TypeShape where
  parseJSON = withObject "type" $ \o -> TypeShape <$> o .: "line" <*> o .: "fields" <*> o .: "refs"

instance FromJSON Endpoint where
  parseJSON = withObject "endpoint" $ \o ->
    Endpoint <$> o .: "method" <*> o .: "path" <*> o .: "summary" <*> o .: "response" <*> o .: "response_refs" <*> o .:? "request" <*> o .: "request_refs"

instance FromJSON Shapes where
  parseJSON = withObject "shapes" $ \o ->
    Shapes <$> o .: "version" <*> o .: "legend" <*> o .: "components" <*> o .: "names" <*> o .: "endpoints" <*> o .: "types"

shapesFile :: ByteString
shapesFile = $(embedFile "data/bungie-shapes.json")

-- A malformed file is a build artifact error; the spec suite decodes it.
shapes :: Either String Shapes
shapes = eitherDecodeStrict' shapesFile

shapesVersion :: Text
shapesVersion = either (const "unavailable") (.sVersion) shapes

-- | The structure of one Platform response, trimmed to the requested
-- components (none requested = every field, tagged with its component).
describeEndpoint :: Text -> [Int] -> Int -> Either Text Value
describeEndpoint rawPath components budget = do
  table <- either (const (Left "接口结构数据不可用")) Right shapes
  segments <- pathSegments rawPath
  endpoint <- maybe (Left ("规范里没有这个接口：" <> rawPath)) Right (matchEndpoint table segments)
  let wanted = if null components then Nothing else Just (Set.fromList components)
      (text, unexpanded) = expand table wanted budget (requestLines endpoint <> [eLine endpoint]) (endpoint.eRequestRefs <> endpoint.eResponseRefs)
  pure $
    object
      [ "endpoint" .= (endpoint.eMethod <> " " <> endpoint.ePath),
        "summary" .= endpoint.eSummary,
        "components" .= [c <> " " <> fromMaybe "?" (Map.lookup c table.sComponents) | c <- map (T.pack . show) components],
        "legend" .= table.sLegend,
        "shape" .= text,
        "unexpanded" .= unexpanded,
        "spec_version" .= table.sVersion
      ]
  where
    eLine endpoint = "→ Response: " <> endpoint.eResponse
    requestLines endpoint = ["→ body: " <> request | Just request <- [endpoint.eRequest]]

-- | One named type and what it references, for following an unexpanded name.
describeType :: Text -> Int -> Either Text Value
describeType name budget = do
  table <- either (const (Left "接口结构数据不可用")) Right shapes
  full <- maybe (Left ("规范里没有这个类型：" <> name)) Right (Map.lookup (T.strip name) table.sNames)
  let (text, unexpanded) = expand table Nothing budget [] [full]
  pure (object ["type" .= name, "legend" .= table.sLegend, "shape" .= text, "unexpanded" .= unexpanded, "spec_version" .= table.sVersion])

-- Breadth-first: the response's own fields first, then what they reference,
-- until the budget runs out; the rest are listed by name.
expand :: Shapes -> Maybe (Set Int) -> Int -> [Text] -> [Text] -> (Text, [Text])
expand table wanted budget header roots = go header (T.length (T.unlines header)) Set.empty roots
  where
    go out _ _ [] = (T.unlines (reverse out), [])
    go out used seen (name : rest)
      | name `Set.member` seen = go out used seen rest
      | otherwise = case Map.lookup name table.sTypes of
          Nothing -> go out used (Set.insert name seen) rest
          Just shape ->
            let kept = filter keep shape.tFields
                rendered = render shape kept
                size = T.length rendered + 1
                refs = if null shape.tFields then shape.tRefs else concatMap (.fRefs) kept
             in if not (null shape.tFields) && null kept
                  then go out used (Set.insert name seen) rest
                  else
                    if used + size > budget && not (null out)
                      then (T.unlines (reverse out), dedupe [n | n <- name : rest, n `Set.notMember` seen, Map.member n table.sTypes])
                      else go (rendered : out) (used + size) (Set.insert name seen) (rest <> refs)
    keep field = case (wanted, field.fComponent) of
      (Just set, Just component) -> component `Set.member` set
      _ -> True
    render shape kept
      | null shape.tFields = shape.tLine
      | otherwise = shape.tLine <> " {\n" <> T.intercalate "\n" ["  " <> f.fLine <> maybe "" (\c -> " /*c" <> T.pack (show c) <> "*/") f.fComponent | f <- kept] <> "\n}"
    dedupe = map (displayName table) . Set.toList . Set.fromList

displayName :: Shapes -> Text -> Text
displayName table full = maybe full fst (find ((== full) . snd) (Map.toList table.sNames))

pathSegments :: Text -> Either Text [Text]
pathSegments raw
  | T.null stripped = Left "path 为空"
  | otherwise = Right (dropPlatform (filter (not . T.null) (T.splitOn "/" (T.takeWhile (/= '?') stripped))))
  where
    stripped = foldr (\prefix t -> fromMaybe t (T.stripPrefix prefix t)) (T.strip raw) ["https://www.bungie.net", "https://stats.bungie.net"]
    dropPlatform = \case
      first : rest | T.toCaseFold first == "platform" -> rest
      other -> other

-- Template segments in braces match any value; literals compare like Bungie,
-- ignoring case. Among matches, the one with the most literals wins.
matchEndpoint :: Shapes -> [Text] -> Maybe Endpoint
matchEndpoint table segments =
  case sortOn (negate . literals) (filter matches table.sEndpoints) of
    best : _ -> Just best
    [] -> Nothing
  where
    template endpoint = filter (not . T.null) (T.splitOn "/" endpoint.ePath)
    matches endpoint = length (template endpoint) == length segments && and (zipWith one (template endpoint) segments)
    one pattern actual
      | "{" `T.isPrefixOf` pattern = not (T.null actual)
      | otherwise = T.toCaseFold pattern == T.toCaseFold actual
    literals endpoint = length (filter (not . ("{" `T.isPrefixOf`)) (template endpoint))
