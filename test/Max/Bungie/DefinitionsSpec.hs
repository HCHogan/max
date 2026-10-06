module Max.Bungie.DefinitionsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Max.Bungie.Definitions
import Test.Hspec

spec :: Spec
spec = describe "Max.Bungie.Definitions" $ do
  it "resolves aliases and full table names" $ do
    resolveKind "item" `shouldBe` Right "DestinyInventoryItemDefinition"
    resolveKind " PlugSet " `shouldBe` Right "DestinyPlugSetDefinition"
    resolveKind "DestinyTraitDefinition" `shouldBe` Right "DestinyTraitDefinition"
    resolveKind "Destiny'; DROP" `shouldSatisfy` isLeft
  it "normalizes signed hashes to the unsigned manifest keys" $ do
    unsignedHash (-1) `shouldBe` Just 4294967295
    unsignedHash 3588934839 `shouldBe` Just 3588934839
    unsignedHash 4294967296 `shouldBe` Nothing
  it "keeps the fields a weapon answer needs and drops the rest" $ do
    let weapon =
          object
            [ "displayProperties" .= object ["name" .= ("命运使者" :: String), "description" .= ("" :: String), "icon" .= ("/x.png" :: String)],
              "itemTypeDisplayName" .= ("手炮" :: String),
              "inventory" .= object ["tierTypeName" .= ("传说" :: String), "tierType" .= (5 :: Int), "bucketTypeHash" .= (1498876634 :: Int)],
              "itemType" .= (3 :: Int),
              "defaultDamageType" .= (2 :: Int),
              "screenshot" .= ("/big.jpg" :: String),
              "stats" .= object ["stats" .= object ["4284893193" .= object ["value" .= (140 :: Int)], "1" .= object ["value" .= (0 :: Int)]]],
              "sockets"
                .= object
                  [ "socketEntries"
                      .= [ object ["singleInitialItemHash" .= (11 :: Int), "randomizedPlugSetHash" .= (0 :: Int)],
                           object ["singleInitialItemHash" .= (0 :: Int), "randomizedPlugSetHash" .= (99 :: Int)],
                           object ["singleInitialItemHash" .= (0 :: Int)]
                         ],
                    "socketCategories" .= [object ["socketCategoryHash" .= (4241085061 :: Int), "socketIndexes" .= [0, 1 :: Int]]]
                  ]
            ]
        Just (name, Object projected) = projectDefinition "DestinyInventoryItemDefinition" weapon
    name `shouldBe` "命运使者"
    KeyMap.lookup "type" projected `shouldBe` Just (String "手炮")
    KeyMap.member "description" projected `shouldBe` False
    KeyMap.member "screenshot" projected `shouldBe` False
    KeyMap.lookup "stats" projected `shouldBe` Just (object ["4284893193" .= (140 :: Int)])
    KeyMap.lookup "sockets" projected
      `shouldBe` Just (toJSON [object ["index" .= (0 :: Int), "category" .= (4241085061 :: Int), "initial" .= (11 :: Int)], object ["index" .= (1 :: Int), "category" .= (4241085061 :: Int), "randomPlugSet" .= (99 :: Int)]])
  it "drops unnamed and redacted items" $ do
    projectDefinition "DestinyInventoryItemDefinition" (object ["displayProperties" .= object ["name" .= ("" :: String)]]) `shouldBe` Nothing
    projectDefinition "DestinyInventoryItemDefinition" (object ["redacted" .= True, "displayProperties" .= object ["name" .= ("x" :: String)]]) `shouldBe` Nothing
  it "merges duplicate plug set entries" $
    projectDefinition "DestinyPlugSetDefinition" (object ["reusablePlugItems" .= [object ["plugItemHash" .= (5 :: Int), "currentlyCanRoll" .= False], object ["plugItemHash" .= (5 :: Int), "currentlyCanRoll" .= True], object ["plugItemHash" .= (6 :: Int)]]])
      `shouldBe` Just ("", object ["plugs" .= [[toJSON (5 :: Int), Bool True], [toJSON (6 :: Int), Bool False]]])
  it "reads English names for search without projecting" $
    englishName "DestinyObjectiveDefinition" (object ["progressDescription" .= ("Kills" :: String)]) `shouldBe` Just "Kills"
