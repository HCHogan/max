{-# LANGUAGE TemplateHaskell #-}

-- | Immutable guide snapshots embedded in Max. CSV records preserve spreadsheet
-- coordinates; discovery, reads and regex search need no filesystem or network.
module Max.Destiny.Guides
  ( GuideRequest (..),
    parseGuideRequest,
    queryGuides,
  )
where

import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Pair, Parser, parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiUpper, isDigit)
import Data.Csv qualified as CSV
import Data.FileEmbed (embedDir)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Text.Read (readMaybe)
import Text.Regex.TDFA (CompOption (..), Regex, defaultCompOpt, defaultExecOpt, matchTest)
import Text.Regex.TDFA.String qualified as Regex

data GuideRequest = GuideRequest
  { grAction :: !Text,
    grSheet :: !(Maybe Text),
    grSource :: !(Maybe Text),
    grQuery :: !(Maybe Text),
    grColumns :: ![Text],
    grOffset :: !Int,
    grLimit :: !Int,
    grMaxChars :: !Int,
    grLanguage :: !Text,
    grCaseSensitive :: !Bool,
    grIncludeLegacy :: !Bool
  }
  deriving stock (Show)

parseGuideRequest :: Object -> Parser GuideRequest
parseGuideRequest o = do
  request <-
    GuideRequest
      <$> o .: "action"
      <*> o .:? "sheet"
      <*> o .:? "source"
      <*> o .:? "query"
      <*> (map T.toUpper <$> o .:? "columns" .!= [])
      <*> o .:? "offset" .!= 0
      <*> o .:? "limit" .!= 20
      <*> o .:? "max_chars" .!= 60000
      <*> o .:? "language" .!= "zh-chs"
      <*> o .:? "case_sensitive" .!= False
      <*> o .:? "include_legacy" .!= False
  unless (request.grAction `elem` ["index", "read", "find"]) (fail "action must be index, read, or find")
  when (request.grOffset < 0) (fail "offset must be nonnegative")
  unless (request.grLimit >= 1 && request.grLimit <= 200) (fail "limit must be between 1 and 200")
  unless (request.grMaxChars >= 1000 && request.grMaxChars <= 3500000) (fail "max_chars must be between 1000 and 3500000")
  unless (request.grLanguage `elem` ["zh-chs", "en"]) (fail "language must be zh-chs or en (output language; find searches both)")
  unless (all validColumn request.grColumns && length request.grColumns <= 100) (fail "columns must be spreadsheet letters, e.g. A, C, AA")
  when (request.grAction == "read" && isNothing request.grSheet) (fail "read requires sheet from index")
  when (request.grAction == "find" && maybe True T.null request.grQuery) (fail "find requires a nonempty regex query")
  when (maybe False ((> 512) . T.length) request.grQuery) (fail "query exceeds 512 characters")
  pure request
  where
    validColumn value = not (T.null value) && T.length value <= 3 && T.all isAsciiUpper value

data GuideSheet = GuideSheet
  { gsId :: !Text,
    gsSource :: !Text,
    gsInfo :: !Value,
    gsColumns :: ![Text],
    gsRows :: !(V.Vector (V.Vector Text)),
    gsChineseRows :: !(V.Vector (V.Vector Text)),
    gsTranslation :: !Value,
    gsMetadata :: !Value,
    gsMerges :: ![Merge]
  }

data Merge = Merge
  { gmRange :: !Text,
    gmColumn :: !Text,
    gmStartRow :: !Int,
    gmEndRow :: !Int,
    gmStartColumn :: !Int,
    gmEndColumn :: !Int
  }

-- The index changes whenever the importer changes directory membership, so
-- file-embed and Cabal both track additions as well as existing file contents.
guideFiles :: Map.Map FilePath BS.ByteString
guideFiles = Map.fromList $(embedDir "data/destiny-guides")

guideCatalog :: Either Text (Value, [Value], [GuideSheet])
guideCatalog = do
  index <- decodeFile "index.json"
  translation <- decodeFile "zh-chs/index.json"
  localized <- first T.pack (parseEither (withObject "translation index" (.: "sheets")) translation)
  (generated, sources) <- first T.pack (parseEither indexP index)
  parsed <- traverse (sourceP localized) sources
  let snapshot = object ["generated_at" .= generated, "bundle_hash" .= bundleHash, "translation" .= translationSummary translation]
  pure (snapshot, map fst parsed, concatMap snd parsed)
  where
    indexP = withObject "guide index" $ \o -> (,) <$> (o .: "generated_at" :: Parser Text) <*> o .: "sources"
    sourceP localized source =
      first T.pack (parseEither sourceInfoP source) >>= \(sid, sourceInfo, sheets) -> do
        tables <- traverse (loadSheet localized sid) sheets
        pure (sourceInfo, tables)
    sourceInfoP = withObject "guide source" $ \o -> do
      sid <- o .: "id"
      title <- o .: "title" :: Parser Text
      url <- o .: "source_url" :: Parser Text
      fetched <- o .: "fetched_at" :: Parser Text
      sheets <- o .: "sheets"
      pure (sid, object ["id" .= sid, "title" .= title, "source_url" .= url, "fetched_at" .= fetched, "description" .= sourceDescription sid], sheets)

bundleHash :: Text
bundleHash = TE.decodeUtf8 . B16.encode . SHA256.hash . BS.concat $ [TE.encodeUtf8 (T.pack path) <> "\0" <> bytes <> "\0" | (path, bytes) <- Map.toAscList guideFiles]

sourceDescription :: Text -> Text
sourceDescription = \case
  "court" -> "增伤/减益分类与叠加规则、勇士应对、催化、Banes 和 Micro-Missiles。"
  "compendium" -> "武器 perk、异域武器/护甲、模组、子职业技能与游戏机制的具体数值、触发条件和例外。"
  "endgame-analysis" -> "终局武器评价、推荐 perk、用途、护甲套装效果及技能/神器评价；Status 页记录更新状态。"
  "boss-damage" -> "武器/技能伤害测试、持续输出 Sustained、切枪组件 Swap、队伍方案和 Boss 条件。"
  _ -> ""

fileBytes :: FilePath -> Either Text BS.ByteString
fileBytes path = maybe (Left ("攻略快照缺少文件：" <> T.pack path)) Right (Map.lookup path guideFiles)

decodeFile :: FilePath -> Either Text Value
decodeFile path = fileBytes path >>= first T.pack . eitherDecodeStrict'

loadSheet :: [Value] -> Text -> Value -> Either Text GuideSheet
loadSheet localized source info = do
  (sid, path, metadataPath, expectedHash, expectedRows, columns) <- first T.pack (parseEither infoP info)
  bytes <- fileBytes path
  unless (TE.decodeUtf8 (B16.encode (SHA256.hash bytes)) == expectedHash) (Left ("攻略 CSV 校验失败：" <> sid))
  rows <- first T.pack (CSV.decode CSV.NoHeader (LBS.fromStrict bytes))
  unless (V.length rows == expectedRows && V.all ((== length columns) . V.length) rows) (Left ("攻略 CSV 行列不匹配：" <> sid))
  translation <- case filter ((== String sid) . field "id") localized of
    [value] -> Right value
    _ -> Left ("攻略中文索引缺失或重复：" <> sid)
  (chinesePath, chineseHash, originalHash) <- first T.pack (parseEither translationP translation)
  unless (originalHash == expectedHash) (Left ("攻略中文版本与英文快照不匹配：" <> sid))
  chineseBytes <- fileBytes chinesePath
  unless (TE.decodeUtf8 (B16.encode (SHA256.hash chineseBytes)) == chineseHash) (Left ("攻略中文 CSV 校验失败：" <> sid))
  chineseRows <- first T.pack (CSV.decode CSV.NoHeader (LBS.fromStrict chineseBytes))
  unless (V.length chineseRows == expectedRows && V.all ((== length columns) . V.length) chineseRows) (Left ("攻略中文 CSV 行列不匹配：" <> sid))
  metadata <- decodeFile metadataPath
  ranges <- first T.pack (parseEither (withObject "sheet metadata" (\o -> o .:? "merged_ranges" .!= [])) metadata)
  merges <- traverse parseMerge ranges
  pure (GuideSheet sid source info columns rows chineseRows translation metadata merges)
  where
    infoP = withObject "guide sheet" $ \o -> do
      schema <- o .: "schema"
      columns <- withObject "guide schema" (.: "column_ids") schema
      (,,,,,) <$> o .: "id" <*> o .: "path" <*> o .: "metadata_path" <*> o .: "sha256" <*> o .: "rows" <*> pure columns
    translationP = withObject "guide translation" $ \o -> (,,) <$> o .: "path" <*> o .: "sha256" <*> o .: "original_sha256"

translationSummary :: Value -> Value
translationSummary (Object info) = Object (KM.filterWithKey (\key _ -> Key.toText key `elem` ["language", "status", "pending_text_cells", "generated_at", "manifest_version", "method", "validation"]) info)
translationSummary _ = Null

parseCell :: Text -> Maybe (Text, Int, Int)
parseCell value = do
  let (column, digits) = T.span isAsciiUpper value
  unless (not (T.null column) && not (T.null digits) && T.all isDigit digits) Nothing
  row <- readMaybe (T.unpack digits)
  unless (row > 0) Nothing
  let number = T.foldl' (\n c -> n * 26 + fromEnum c - fromEnum 'A' + 1) 0 column
  pure (column, row, number)

parseMerge :: Text -> Either Text Merge
parseMerge range = case T.splitOn ":" range of
  [start, end]
    | Just (column, firstRow, firstColumn) <- parseCell start,
      Just (_, lastRow, lastColumn) <- parseCell end ->
        Right (Merge range column firstRow lastRow firstColumn lastColumn)
  _ -> Left ("攻略合并范围无效：" <> range)

sheetInfo :: GuideRequest -> GuideSheet -> Value
sheetInfo request sheet = case sheet.gsInfo of
  Object info -> Object (KM.fromList [("source", String sheet.gsSource), ("title_en", field "title" sheet.gsInfo), ("languages", toJSON (["zh-chs", "en"] :: [Text])), ("title", sheetTitle request sheet), ("schema", schema), ("preview", preview)] <> KM.filterWithKey (\key _ -> Key.toText key `elem` keys) info)
  other -> other
  where
    keys = ["id", "visibility", "source_status", "source_url", "fetched_at", "rows", "columns"]
    schema = case field "schema" sheet.gsInfo of
      Object original -> Object (KM.insert "header_rows" headers original)
      other -> other
    headers = case field "header_rows" (field "schema" sheet.gsInfo) of
      Array original -> Array (V.map localHeader original)
      other -> other
    localHeader header = case fromJSON (field "row" header) of
      Success row -> summaryRow row (fromMaybe V.empty (sheetRows request sheet V.!? (row - 1)))
      Error _ -> header
    preview = toJSON [summaryRow row (V.map (T.take 240) cells) | (row, cells) <- take 5 (zip [1 ..] (V.toList (sheetRows request sheet))), V.any (not . T.null) cells]
    summaryRow row cells = object ["row" .= (row :: Int), "cells" .= cellsJson (request {grColumns = []}) sheet cells]

sheetTitle :: GuideRequest -> GuideSheet -> Value
sheetTitle request sheet = field "title" (if request.grLanguage == "en" then sheet.gsInfo else sheet.gsTranslation)

sheetRows :: GuideRequest -> GuideSheet -> V.Vector (V.Vector Text)
sheetRows request sheet = if request.grLanguage == "en" then sheet.gsRows else sheet.gsChineseRows

field :: Text -> Value -> Value
field key (Object o) = fromMaybe Null (KM.lookup (Key.fromText key) o)
field _ _ = Null

queryGuides :: GuideRequest -> Either Text Value
queryGuides request = do
  (snapshot, sources, catalog) <- guideCatalog
  case request.grSource of
    Just source -> unless (any ((== String source) . field "id") sources) (Left "未知 source；请先 index 获取来源 ID")
    Nothing -> pure ()
  case request.grSheet of
    Just sid -> unless (any ((== sid) . (.gsId)) catalog) (Left "未知 sheet；必须使用 index 返回的分页 ID")
    Nothing -> pure ()
  let selected = filter (\sheet -> maybe True (== sheet.gsSource) request.grSource && maybe True (== sheet.gsId) request.grSheet) catalog
      base = ["action" .= request.grAction, "snapshot" .= snapshot, "language" .= request.grLanguage]
  when (null selected) (Left "source 与 sheet 不属于同一来源")
  case request.grAction of
    "index" -> page request (base <> ["sources" .= sources]) selected (\sheets -> ["tables" .= map (sheetInfo request) sheets])
    "read" -> case selected of
      [sheet] -> do
        unless (all (`elem` sheet.gsColumns) request.grColumns) (Left "columns 不在此分页 schema 中")
        page request (base <> ["sheet" .= sheetInfo request sheet]) (zip [1 ..] (V.toList (sheetRows request sheet))) $ \rows ->
          ["rows" .= [rowJson request sheet row cells | (row, cells) <- rows], "metadata" .= readMetadata request sheet (map fst rows)]
      _ -> Left "read requires one sheet"
    "find" -> do
      regex <- compileQuery request
      let eligible sheet = request.grIncludeLegacy || isJust request.grSheet || (field "source_status" sheet.gsInfo == String "unspecified" && field "visibility" sheet.gsInfo /= String "hidden")
          matches =
            [ (sheet, row, cells, matched, languages)
            | sheet <- filter eligible selected,
              (row, cells) <- zip [1 ..] (V.toList (sheetRows request sheet)) :: [(Int, V.Vector Text)],
              let hits = [(language, column) | (language, grid) <- [("en" :: Text, sheet.gsRows), ("zh-chs", sheet.gsChineseRows)], (column, value) <- selectedCells request sheet (grid V.! (row - 1)), not (T.null value), matchTest regex (T.unpack value)]
                  matched = [column | column <- sheet.gsColumns, any ((== column) . snd) hits]
                  languages = [language | language <- ["zh-chs", "en"], any ((== language) . fst) hits],
              not (null matched)
            ]
      page request (base <> ["query" .= request.grQuery, "case_sensitive" .= request.grCaseSensitive]) matches $ \rows ->
        [ "rows" .= [object (["sheet" .= sheet.gsId, "title" .= sheetTitle request sheet, "row" .= row, "source_url" .= field "source_url" sheet.gsInfo, "cells" .= cellsJson request sheet cells, "matched_columns" .= matched, "matched_languages" .= languages] <> originalCells request sheet row) | (sheet, row, cells, matched, languages) <- rows]
        ]
    _ -> Left "action must be index, read, or find"

compileQuery :: GuideRequest -> Either Text Regex
compileQuery request = case request.grQuery of
  Nothing -> Left "find requires query"
  Just query -> first (\error' -> "无效的 POSIX 扩展正则：" <> T.pack error') (Regex.compile (defaultCompOpt {caseSensitive = request.grCaseSensitive}) defaultExecOpt (T.unpack query))

selectedCells :: GuideRequest -> GuideSheet -> V.Vector Text -> [(Text, Text)]
selectedCells request sheet cells = [(column, value) | (column, value) <- zip sheet.gsColumns (V.toList cells), null request.grColumns || column `elem` request.grColumns]

cellsJson :: GuideRequest -> GuideSheet -> V.Vector Text -> Value
cellsJson request sheet cells = object [Key.fromText column .= value | (column, value) <- selectedCells request sheet cells, not (T.null value)]

rowJson :: GuideRequest -> GuideSheet -> Int -> V.Vector Text -> Value
rowJson request sheet row cells = object (["row" .= row, "cells" .= cellsJson request sheet cells] <> originalCells request sheet row)

originalCells :: GuideRequest -> GuideSheet -> Int -> [Pair]
originalCells request sheet row = ["original_cells" .= cellsJson request sheet cells | request.grLanguage /= "en", Just cells <- [sheet.gsRows V.!? (row - 1)]]

readMetadata :: GuideRequest -> GuideSheet -> [Int] -> Value
readMetadata request sheet rows =
  object
    [ "merged_cells" .= map mergeJson relevant,
      "original_details_language" .= ("en" :: Text),
      "cell_notes" .= selectDetails "cell_notes",
      "hyperlinks" .= selectDetails "hyperlinks",
      "images" .= selectDetails "images",
      "rich_text" .= selectDetails "rich_text"
    ]
  where
    columns = if null request.grColumns then sheet.gsColumns else request.grColumns
    columnNumbers = [number | column <- columns, Just (_, _, number) <- [parseCell (column <> "1")]]
    relevant = [merge | merge <- sheet.gsMerges, any (\row -> row >= merge.gmStartRow && row <= merge.gmEndRow) rows, any (\col -> col >= merge.gmStartColumn && col <= merge.gmEndColumn) columnNumbers]
    anchors = [merge.gmColumn <> T.pack (show merge.gmStartRow) | merge <- relevant]
    selectDetails key = case field key sheet.gsMetadata of
      Object details -> Object (KM.filterWithKey (\ref _ -> Key.toText ref `elem` anchors || maybe False (\(col, row, _) -> row `elem` rows && col `elem` columns) (parseCell (Key.toText ref))) details)
      _ -> object []
    mergeJson merge =
      object
        [ "range" .= merge.gmRange,
          "anchor" .= (merge.gmColumn <> T.pack (show merge.gmStartRow)),
          "value" .= fromMaybe "" (sheetRows request sheet V.!? (merge.gmStartRow - 1) >>= (V.!? (merge.gmStartColumn - 1))),
          "original_value" .= fromMaybe "" (sheet.gsRows V.!? (merge.gmStartRow - 1) >>= (V.!? (merge.gmStartColumn - 1)))
        ]

-- Bound whole records, never truncate a cell. Continuations advance only by
-- the records actually returned, even when the byte budget shortens a page.
page :: GuideRequest -> [Pair] -> [a] -> ([a] -> [Pair]) -> Either Text Value
page request base items render = fit [] (take request.grLimit (drop request.grOffset items))
  where
    total = length items
    result rows =
      let next = request.grOffset + length rows
          more = next < total
       in object (base <> ["offset" .= request.grOffset, "total" .= total, "next_offset" .= if more then Just next else Nothing, "has_more" .= more] <> render rows)
    size = LBS.length . encode
    fit rows [] = bounded rows (result rows)
    fit rows (next : rest)
      | size (result (rows <> [next])) > fromIntegral request.grMaxChars =
          if null rows then oversized (result [next]) else bounded rows (result rows)
      | otherwise = fit (rows <> [next]) rest
    bounded _ value
      | size value > fromIntegral request.grMaxChars = oversized value
      | otherwise = Right value
    oversized value = Right (object ["action" .= request.grAction, "too_large" .= True, "required_bytes" .= size value, "max_chars" .= request.grMaxChars, "hint" .= ("提高 max_chars（run_code 中最多 3500000），或减少 columns；完整单元格未被截断。" :: Text)])
