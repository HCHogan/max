module Max.Tools.DestinySpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.Effects.Destiny
import Max.Effects.Tools
import Max.Skill.Load (resolveSkillLoads)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills (Skill (..), listAllSkills, newSkillRegistry)
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Catalog (catalogTools)
import Max.Bungie.Shapes (describeEndpoint, describeType, shapesVersion)
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
  where
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
        ( \path _ _ ->
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
