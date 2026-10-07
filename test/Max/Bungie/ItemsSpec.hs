module Max.Bungie.ItemsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Bungie.Items
import Test.Hspec

spec :: Spec
spec = describe "Max.Bungie.Items" $ do
  it "flattens every location into translated rows with perk columns, slotted first" $ do
    let rows = normalizeItems Everything lookups profile
        byName name = [o | Object o <- rows, KeyMap.lookup "name" o == Just (String name)]
    case byName "测试脉冲" of
      [weapon] -> do
        KeyMap.lookup "location" weapon `shouldBe` Just (String "vault")
        KeyMap.lookup "perks" weapon `shouldBe` Just (toJSON [["微型导弹框架"], ["混响", "肾上腺素成瘾"] :: [Text]])
        KeyMap.lookup "mods" weapon `shouldBe` Just (object ["武器模组" .= ["备用弹匣" :: Text]])
        KeyMap.lookup "power" weapon `shouldBe` Just (Number 550)
        KeyMap.lookup "damage" weapon `shouldBe` Just (String "电弧")
        (KeyMap.lookup "locked" weapon, KeyMap.lookup "masterwork" weapon, KeyMap.lookup "crafted" weapon) `shouldBe` (Just (Bool True), Just (Bool True), Nothing)
      other -> expectationFailure (show other)
    map (KeyMap.lookup "location") (byName "邮政官里的枪") `shouldBe` [Just (String "postmaster")]
    map (KeyMap.lookup "character") (byName "邮政官里的枪") `shouldBe` [Just (String "猎人")]
    map (\o -> (KeyMap.lookup "location" o, KeyMap.lookup "class" o)) (byName "测试头盔") `shouldBe` [(Just (String "equipped"), Just (String "猎人"))]
    map (\o -> (KeyMap.lookup "location" o, KeyMap.lookup "quantity" o)) (byName "强化棱镜") `shouldBe` [(Just (String "account"), Just (Number 7))]

  it "selects by kind and names only the plugs its rows use" $ do
    length (normalizeItems Weapons lookups profile) `shouldBe` 2
    length (normalizeItems Armor lookups profile) `shouldBe` 1
    length (normalizeItems Gear lookups profile) `shouldBe` 3
    itemHashes profile `shouldMatchList` [1, 2, 3, 4]
    socketPlugHashes Weapons definitions profile `shouldMatchList` [10, 20, 21, 30, 99, 98]
    parseItemKind "gear" `shouldBe` Right Gear
  where
    lookups = Lookups definitions Map.empty (Map.fromList [(2685412949, "武器模组")]) Map.empty Map.empty

definitions :: Map.Map Int64 Value
definitions =
  Map.fromList
    [ (1, object ["name" .= ("测试脉冲" :: Text), "type" .= ("脉冲步枪" :: Text), "itemType" .= (3 :: Int), "sockets" .= [socket 0 3956125808, socket 1 4241085061, socket 2 2685412949, socket 3 4241085061]]),
      (2, object ["name" .= ("邮政官里的枪" :: Text), "itemType" .= (3 :: Int)]),
      (3, object ["name" .= ("测试头盔" :: Text), "itemType" .= (2 :: Int), "classType" .= (1 :: Int)]),
      (4, object ["name" .= ("强化棱镜" :: Text), "itemType" .= (0 :: Int)]),
      (10, plug "微型导弹框架"),
      (20, plug "混响"),
      (21, plug "肾上腺素成瘾"),
      (30, plug "备用弹匣"),
      (98, plug "有名字的备选")
    ]
  where
    socket :: Int -> Int64 -> Value
    socket index category = object ["index" .= index, "category" .= category]
    plug :: Text -> Value
    plug name = object ["name" .= name]

profile :: Value
profile =
  object
    [ "characters" .= object ["data" .= object ["c1" .= object ["classType" .= (1 :: Int)]]],
      "profileInventory" .= object ["data" .= object ["items" .= [item 1 "a1" 138197802 5 1, item 4 "" 3313201758 0 7]]],
      "characterInventories" .= object ["data" .= object ["c1" .= object ["items" .= [item 2 "b1" 215593132 0 1]]]],
      "characterEquipment" .= object ["data" .= object ["c1" .= object ["items" .= [item 3 "h1" 3448274439 0 1]]]],
      "itemComponents"
        .= object
          [ "instances" .= object ["data" .= object ["a1" .= object ["primaryStat" .= object ["value" .= (550 :: Int)], "damageType" .= (2 :: Int)]]],
            -- Socket 3's slotted plug has no name: that column is left out.
            "sockets" .= object ["data" .= object ["a1" .= object ["sockets" .= [slotted 10, slotted 20, slotted 30, slotted 99]]]],
            "reusablePlugs" .= object ["data" .= object ["a1" .= object ["plugs" .= object ["1" .= [option 20, option 21], "3" .= [option 99, option 98]]]]]
          ]
    ]
  where
    item :: Int -> Text -> Int64 -> Int -> Int -> Value
    item hash instanceId bucket state quantity =
      object (["itemHash" .= hash, "bucketHash" .= bucket, "state" .= state, "quantity" .= quantity] <> ["itemInstanceId" .= instanceId | instanceId /= ""])
    slotted :: Int64 -> Value
    slotted h = object ["plugHash" .= h, "isVisible" .= True]
    option :: Int64 -> Value
    option h = object ["plugItemHash" .= h]
