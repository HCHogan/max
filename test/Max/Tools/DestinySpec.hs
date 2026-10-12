module Max.Tools.DestinySpec (spec) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Bungie.Shapes (describeEndpoint, describeType, shapesVersion)
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Destiny.Guides (parseGuideRequest)
import Max.Effects.Destiny
import Max.Effects.Tools
import Max.Skill.Load (resolveSkillLoads)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills (Skill (..), listAllSkills, newSkillRegistry)
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Catalog (catalogTools)
import Max.Tools.Destiny (destinyToolsFor)
import Max.Tools.Schema (integerParam, withKeys)
import Max.Toolset (inventoryDefinitions)
import Test.Hspec

-- Production only assembles these tools when a Bungie application is
-- configured, so nothing else in the unit suite builds their catalog.
spec :: Spec
spec = describe "Max.Tools.Destiny" $ do
  it "assembles against the production inventory and binds the skill's workflows" $ do
    registry <- either (fail . show) pure (buildToolRegistry destinyDefinitions (destinyToolsFor :: [Tool '[Destiny, IOE]]))
    skills <- listAllSkills =<< newSkillRegistry
    let snapshot = Map.fromList [(s.skillName, s) | s <- skills]
    Right loads <- resolveSkillLoads snapshot Map.empty (const (pure (Right Nothing))) "destiny"
    map (.slName) loads `shouldBe` ["codemode", "destiny"]
    bindWorkflowContracts javaScriptRuntimeVersion (catalogTools (registryCatalog registry)) loads `shouldSatisfy` isRight
    bindWorkflowContracts javaScriptRuntimeVersion [] loads `shouldSatisfy` isLeft

  it "lets schema decorations override the keys they decorate" $
    withKeys ["type" .= ("array" :: Text)] (integerParam "n") `shouldBe` object ["type" .= ("array" :: Text), "description" .= ("n" :: Text)]

  it "parses arguments against the published schemas" $ do
    lookupHashes <- run "destiny_lookup" (object ["kind" .= ("item" :: Text), "hashes" .= [3588934839 :: Int]])
    lookupHashes `shouldBe` Right (object ["lookup" .= ("item" :: Text), "hashes" .= [3588934839 :: Int]])
    search <- run "destiny_lookup" (object ["search" .= ("命运" :: Text)])
    search `shouldBe` Right (object ["search" .= ("命运" :: Text), "limit" .= (10 :: Int)])
    run "destiny_lookup" (object ["hashes" .= [1 :: Int]]) >>= (`shouldSatisfy` isLeft)
    run "destiny_lookup" (object ["kind" .= ("item" :: Text), "hashes" .= [1 :: Int], "search" .= ("x" :: Text)]) >>= (`shouldSatisfy` isLeft)
    run "destiny_write" (object ["path" .= ("/Destiny2/Actions/Items/EquipItem/" :: Text), "body" .= ("x" :: Text)]) >>= (`shouldSatisfy` isLeft)
    run "destiny_items" (object []) >>= (`shouldBe` Right (object ["kind" .= ("gear" :: Text), "items" .= ([] :: [Value])]))

  it "describes an oversized read instead of truncating it" $ do
    small <- run "destiny_read" (object ["path" .= ("/Destiny2/Milestones/" :: Text)])
    small `shouldBe` Right (object ["read" .= ("/Destiny2/Milestones/" :: Text)])
    large <- run "destiny_read" (object ["path" .= ("big" :: Text), "max_chars" .= (1000 :: Int)])
    case large of
      Right (Object o) -> fmap (== Bool True) (lookupKey "too_large" o) `shouldBe` Just True
      other -> expectationFailure (show other)

  it "serves response shapes from the embedded OpenAPI data, trimmed to the requested components" $ do
    shapesVersion `shouldNotBe` "unavailable"
    let shapeText = \case
          Right (Object o) | Just (String text) <- KeyMap.lookup "shape" o -> text
          other -> error (show other)
        profile = shapeText (describeEndpoint "https://www.bungie.net/Platform/Destiny2/6/Profile/4611686018534405083/" [102, 300] 12000)
    profile `shouldSatisfy` T.isInfixOf "profileInventory: Single<DestinyInventoryComponent> /*c102*/"
    profile `shouldSatisfy` T.isInfixOf "itemHash: number /*→item*/"
    profile `shouldSatisfy` T.isInfixOf "instances: Dict<DestinyItemInstanceComponent> /*c300*/"
    profile `shouldNotSatisfy` T.isInfixOf "characterEquipment"
    shapeText (describeEndpoint "/Destiny2/Actions/Items/TransferItem/" [] 12000) `shouldSatisfy` T.isInfixOf "transferToVault: boolean"
    shapeText (describeType "DestinyItemSocketState" 4000) `shouldSatisfy` T.isInfixOf "plugHash: number /*→item*/"
    describeEndpoint "/Destiny2/NoSuchThing/" [] 12000 `shouldSatisfy` isLeft
    T.length (shapeText (describeEndpoint "/Destiny2/6/Profile/1/" [] 3000)) `shouldSatisfy` (< 3500)

  it "keeps a refused write distinct from one whose outcome is unknown" $ do
    let write path = runOutcome "destiny_write" (object ["path" .= (path :: Text), "body" .= object []])
    write "refused" >>= (`shouldSatisfy` \case ToolFailedBeforeEffect _ -> True; _ -> False)
    write "unknown" >>= (`shouldSatisfy` \case ToolOutcomeUnknown _ -> True; _ -> False)
    write "applied" >>= (`shouldSatisfy` \case ToolCommitted _ -> True; _ -> False)

  describe "embedded guide tool (without a sandbox or linked account)" $ do
    it "discovers all four sources and all 106 CSVs with their schemas" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("index" :: Text), "limit" .= (200 :: Int), "max_chars" .= (3500000 :: Int)])
      at "total" result `shouldBe` Number 106
      length (arrayAt "sources" result) `shouldBe` 4
      length (arrayAt "tables" result) `shouldBe` 106
      at "next_offset" result `shouldBe` Null
      map (at "schema") (arrayAt "tables" result) `shouldSatisfy` notElem Null
      at "language" result `shouldBe` String "zh-chs"
      map (at "languages") (arrayAt "tables" result) `shouldSatisfy` all (== toJSON (["zh-chs", "en"] :: [Text]))
      map (at "title_en") (arrayAt "tables" result) `shouldSatisfy` notElem Null
      at "manifest_version" (at "translation" (at "snapshot" result)) `shouldNotBe` Null
      at "status" (at "translation" (at "snapshot" result)) `shouldBe` String "complete"
      at "pending_text_cells" (at "translation" (at "snapshot" result)) `shouldBe` Number 0

    it "keeps quoted multiline descriptions in their original spreadsheet row and column" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "offset" .= (24 :: Int), "limit" .= (1 :: Int), "columns" .= (["A", "C"] :: [Text])])
      case arrayAt "rows" result of
        [row] -> do
          at "row" row `shouldBe` Number 25
          at "A" (at "cells" row) `shouldBe` String "诱导推销"
          at "A" (at "original_cells" row) `shouldBe` String "Bait and Switch"
          at "C" (at "cells" row) `shouldSatisfy` \case String text -> "\n" `T.isInfixOf` text && "10" `T.isInfixOf` text; _ -> False
        other -> expectationFailure (show other)

    it "matches regex alternation and anchors, with optional case sensitivity" $ do
      let find query sensitive = run "destiny_guide" (object ["action" .= ("find" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "query" .= (query :: Text), "columns" .= (["A"] :: [Text]), "case_sensitive" .= sensitive, "language" .= ("en" :: Text)])
      Right alternatives <- find "^(Bait and Switch|Envious Arsenal)$" False
      at "total" alternatives `shouldBe` Number 2
      map (at "A" . at "cells") (arrayAt "rows" alternatives) `shouldMatchList` [String "Bait and Switch", String "Envious Arsenal"]
      Right folded <- find "^bait and switch$" False
      at "total" folded `shouldBe` Number 1
      Right sensitive <- find "^bait and switch$" True
      at "total" sensitive `shouldBe` Number 0

    it "finds Chinese names and mixed-language regexes without counting a row twice" $ do
      let find query language = run "destiny_guide" (object ["action" .= ("find" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "query" .= (query :: Text), "columns" .= (["A"] :: [Text]), "language" .= (language :: Text)])
      Right mixed <- find "^(诱导推销|Envious Arsenal)$" "zh-chs"
      at "total" mixed `shouldBe` Number 2
      map (at "A" . at "cells") (arrayAt "rows" mixed) `shouldMatchList` [String "诱导推销", String "嫉妒军械库"]
      Right same <- find "^(诱导推销|Bait and Switch)$" "zh-chs"
      at "total" same `shouldBe` Number 1
      case arrayAt "rows" same of
        [row] -> do
          at "row" row `shouldBe` Number 25
          at "matched_languages" row `shouldBe` toJSON (["zh-chs", "en"] :: [Text])
          at "A" (at "original_cells" row) `shouldBe` String "Bait and Switch"
        other -> expectationFailure (show other)
      Right english <- find "^诱导推销$" "en"
      map (at "A" . at "cells") (arrayAt "rows" english) `shouldBe` [String "Bait and Switch"]
      map (at "original_cells") (arrayAt "rows" english) `shouldBe` [Null]

    it "reads the preserved English CSV when explicitly requested" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "offset" .= (24 :: Int), "limit" .= (1 :: Int), "columns" .= (["A", "C"] :: [Text]), "language" .= ("en" :: Text)])
      at "language" result `shouldBe` String "en"
      map (at "A" . at "cells") (arrayAt "rows" result) `shouldBe` [String "Bait and Switch"]
      at "title" (at "sheet" result) `shouldBe` String "Weapon Perks"

    it "searches translated trigger conditions and retains the English condition for review" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("find" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "columns" .= (["C"] :: [Text]), "query" .= ("刷新" :: Text), "limit" .= (200 :: Int), "max_chars" .= (3500000 :: Int)])
      case filter ((== Number 25) . at "row") (arrayAt "rows" result) of
        [row] -> do
          at "matched_languages" row `shouldBe` toJSON (["zh-chs"] :: [Text])
          at "C" (at "cells" row) `shouldSatisfy` \case String text -> all (`T.isInfixOf` text) ["30%", "10", "11", "↑", "刷新"]; _ -> False
          at "C" (at "original_cells" row) `shouldSatisfy` \case String text -> "cannot be refreshed" `T.isInfixOf` text; _ -> False
        other -> expectationFailure (show other)

    it "searches Unicode and rejects invalid regexes and foreign file paths" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("find" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "query" .= ("↑" :: Text), "limit" .= (1 :: Int)])
      arrayAt "rows" result `shouldSatisfy` (not . null)
      run "destiny_guide" (object ["action" .= ("find" :: Text), "query" .= ("[" :: Text)]) >>= (`shouldSatisfy` isLeft)
      run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("../../.env" :: Text)]) >>= (`shouldSatisfy` isLeft)
      run "destiny_guide" (object ["action" .= ("index" :: Text), "source" .= ("missing" :: Text)]) >>= (`shouldSatisfy` isLeft)

    it "returns a merged description whose anchor lies before the requested page" $ do
      Right result <- run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1500097863" :: Text), "offset" .= (4 :: Int), "limit" .= (1 :: Int), "columns" .= (["C"] :: [Text])])
      let merges = arrayAt "merged_cells" (at "metadata" result)
      merges `shouldSatisfy` any (\merge -> at "anchor" merge == String "C4" && case at "value" merge of String text -> "充能近战" `T.isInfixOf` text; _ -> False)
      merges `shouldSatisfy` any (\merge -> case at "original_value" merge of String text -> "Powered Melee" `T.isInfixOf` text; _ -> False)
      at "original_details_language" (at "metadata" result) `shouldBe` String "en"

    it "pages complete records under the byte budget without skipping or duplicating rows" $ do
      let readPage offset = run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "offset" .= (offset :: Int), "limit" .= (200 :: Int), "columns" .= (["A", "C"] :: [Text]), "max_chars" .= (20000 :: Int)])
          collect offset = do
            Right result <- readPage offset
            let rows = arrayAt "rows" result
            at "too_large" result `shouldBe` Null
            LBS.length (encode result) `shouldSatisfy` (<= 20000)
            case fromJSON (at "next_offset" result) :: Result (Maybe Int) of
              Success (Just next) -> do
                next `shouldBe` offset + length rows
                (rows <>) <$> collect next
              Success Nothing -> pure rows
              Error err -> fail err
      rows <- collect 0
      map (at "row") rows `shouldBe` map (Number . fromIntegral) [1 .. 440 :: Int]

    it "reports an oversized complete record and exposes legacy pages when explicitly selected" $ do
      Right oversized <- run "destiny_guide" (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "offset" .= (24 :: Int), "limit" .= (1 :: Int), "max_chars" .= (1000 :: Int)])
      at "too_large" oversized `shouldBe` Bool True
      Right historical <- run "destiny_guide" (object ["action" .= ("find" :: Text), "sheet" .= ("compendium/70425171" :: Text), "query" .= ("." :: Text), "limit" .= (1 :: Int)])
      arrayAt "rows" historical `shouldSatisfy` (not . null)

    it "rejects missing selectors and invalid paging limits before reading data" $ do
      let decodeGuide = parseEither (withObject "guide arguments" parseGuideRequest)
      decodeGuide (object ["action" .= ("read" :: Text)]) `shouldSatisfy` isLeft
      decodeGuide (object ["action" .= ("find" :: Text)]) `shouldSatisfy` isLeft
      decodeGuide (object ["action" .= ("index" :: Text), "offset" .= (-1 :: Int)]) `shouldSatisfy` isLeft
      decodeGuide (object ["action" .= ("index" :: Text), "limit" .= (201 :: Int)]) `shouldSatisfy` isLeft
      decodeGuide (object ["action" .= ("index" :: Text), "language" .= ("zh-cht" :: Text)]) `shouldSatisfy` isLeft
      decodeGuide (object ["action" .= ("read" :: Text), "sheet" .= ("compendium/1662574278" :: Text), "columns" .= (["A1"] :: [Text])]) `shouldSatisfy` isLeft
  where
    at key (Object o) = fromMaybe Null (KeyMap.lookup (Key.fromText key) o)
    at _ _ = Null
    arrayAt key value = case fromJSON (at key value) :: Result [Value] of
      Success rows -> rows
      Error _ -> []
    destinyDefinitions = [d | d <- inventoryDefinitions, "destiny_" `T.isPrefixOf` d.tdRef.unToolRef]
    tool name = case filter ((== name) . (.toolName)) destinyToolsFor of
      [t] -> t
      _ -> error ("missing tool " <> T.unpack name)
    run name args = runEff (fake (toolRun (tool name) args))
    runOutcome name args = case (tool name).toolRunner of
      OutcomeRunner runner -> runEff (fake (runner args))
      LegacyRunner _ -> error "destiny tools report typed outcomes"
    lookupKey key o = case fromJSON (Object o) :: Result (Map.Map Text Value) of
      Success m -> Map.lookup key m
      Error _ -> Nothing
    fake :: Eff '[Destiny, IOE] a -> Eff '[IOE] a
    fake =
      runDestiny
        (pure (object ["linked" .= False]))
        ( \path _ _ _ ->
            pure . Right $
              if path == "big" then object ["blob" .= T.replicate 2000 "x"] else object ["read" .= path]
        )
        ( \path _ -> pure $ case path of
            "refused" -> WriteRefused "DestinyItemNotFound"
            "unknown" -> WriteUncertain "timeout"
            _ -> WriteApplied Null
        )
        (\kind hashes -> pure (Right (object ["lookup" .= kind, "hashes" .= hashes])))
        (\_ term limit -> pure (Right (object ["search" .= term, "limit" .= limit])))
        (\kind -> pure (Right (object ["kind" .= kind, "items" .= ([] :: [Value])])))
