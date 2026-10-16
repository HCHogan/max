module Max.Bungie.CheckpointsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Max.Bungie.Checkpoints
import Test.Hspec

spec :: Spec
spec = describe "Max.Bungie.Checkpoints" $ do
  it "decodes the site's devalue bot list" $ do
    -- Two bots from a real response: one holding Rhulk, one idle.
    let raw = "[[1,8,13],{\"name\":2,\"steam\":3,\"membershipId\":4,\"activityHash\":5,\"encounter\":6,\"premium\":7},\"CheckpointBot#4108\",\"d2checkpoint01\",\"4611686018526359012\",1441982566,3,false,{\"name\":9,\"steam\":10,\"membershipId\":11,\"activityHash\":12,\"encounter\":12,\"premium\":7},\"CheckpointBot#1883\",\"d2checkpoint04\",\"4611686018526359234\",0,{\"name\":14,\"membershipId\":15,\"activityHash\":-1},\"Mallory\",\"../Destiny2\"]"
    (parseBots =<< decodeDevalue (json raw))
      `shouldBe` Right
        [ CheckpointBot "CheckpointBot#4108" "4611686018526359012" 1441982566 3 False,
          CheckpointBot "CheckpointBot#1883" "4611686018526359234" 0 0 False
        ]
    decodeDevalue (json "[[1],{\"a\":9}]") `shouldSatisfy` isLeft
    decodeDevalue (json "[[0]]") `shouldSatisfy` isLeft
    decodeDevalue (json "[[1],[\"Date\",\"2026-10-16T00:00:00Z\"]]") `shouldBe` Right (toJSON [Null])

  it "finds the activity table in the page's app bundle" $ do
    appBundlePath "<astro-island uid=\"Zc\" component-url=\"/_astro/app.DyCdqHRL.js\" component-export=\"default\">"
      `shouldBe` Right "/_astro/app.DyCdqHRL.js"
    appBundlePath "<html></html>" `shouldSatisfy` isLeft
    let bundle =
          "const Ue={0:{name:\"\",difficultyTier:0,encounterList:[\"\"],imgDir:\"x\",fireteamSize:0,displayOrder:0},\
          \1441982566:{name:\"Vow of the Disciple\",difficultyTier:1,encounterList:[\"Acquisition\",\"The Caretaker\",\"The Upended\",\"Rhulk\"],\
          \imgDir:\"https://d2checkpoint.com/assets/img/activity/raid/vow_of_the_disciple\",discordEmoji:\"<:VowOfTheDisciple:1184597546094563458>\",fireteamSize:6,displayOrder:1100},\
          \\"2296818662\":{name:\"Spire of the Watcher\",difficultyTier:2,encounterList:[\"Spire Ascent\",\"Akelous\",\"Persys\"],fireteamSize:3,displayOrder:1800,beta:!0},\
          \107319834:{name:\"Crota's End\",difficultyTier:1,encounterList:[\"Abyss\",\"Ir Y\\u00fbt\",'Crota, Son of Oryx'],fireteamSize:6,displayOrder:23e2}},Pr=e=>Ue[e];"
    parseActivityTable bundle
      `shouldBe` Right
        ( Map.fromList
            [ (1441982566, CheckpointActivity "Vow of the Disciple" 1 ["Acquisition", "The Caretaker", "The Upended", "Rhulk"] 6 1100),
              (2296818662, CheckpointActivity "Spire of the Watcher" 2 ["Spire Ascent", "Akelous", "Persys"] 3 1800),
              (107319834, CheckpointActivity "Crota's End" 1 ["Abyss", "Ir Yût", "Crota, Son of Oryx"] 6 2300)
            ]
        )
    parseActivityTable "const Ue={1:{name:\"x\"}}" `shouldSatisfy` isLeft

  it "counts a bot only while Bungie shows it in its activity with a fireteam" $ do
    let profile activity members players =
          object
            [ "profileTransitoryData" .= object ["data" .= object ["partyMembers" .= replicate members (object ["status" .= (3 :: Int)]), "currentActivity" .= object ["numberOfPlayers" .= (players :: Int)]], "privacy" .= (1 :: Int)],
              "characterActivities" .= object ["data" .= object ["2305843010154714234" .= object ["currentActivityHash" .= (activity :: Int)]]]
            ]
    partySize 1441982566 (profile 1441982566 3 3) `shouldBe` Just 3
    partySize 1441982566 (profile 2122313384 3 3) `shouldBe` Nothing
    partySize 1441982566 (profile 1441982566 0 0) `shouldBe` Nothing
    partySize 1441982566 (profile 1441982566 2 0) `shouldBe` Nothing
    partySize 1441982566 (object ["profileTransitoryData" .= object ["privacy" .= (1 :: Int)]]) `shouldBe` Nothing

  it "reports confirmed bots in the site's order and keeps unconfirmed ones apart" $ do
    let table =
          Map.fromList
            [ (1441982566, CheckpointActivity "Vow of the Disciple" 1 ["Acquisition", "The Caretaker", "The Upended", "Rhulk"] 6 1100),
              (2122313384, CheckpointActivity "Last Wish" 0 ["Kalli", "Shuro-Chi", "Morgeth", "Vault", "Riven", "Queen's Walk"] 6 100)
            ]
        vow = CheckpointBot "CheckpointBot#4108" "1" 1441982566 3 False
        wish = CheckpointBot "CheckpointBot#0422" "2" 2122313384 1 True
        idle = CheckpointBot "CheckpointBot#1883" "3" 0 0 False
        gone = CheckpointBot "CheckpointBot#8880" "4" 300092127 2 False
        broken = CheckpointBot "CheckpointBot#3036" "5" 3889634515 0 False
        found = Checkpoints (Right table) [vow, wish, idle, gone, broken] (Map.fromList [("1", Right (Just 3)), ("2", Right (Just 6)), ("4", Right Nothing), ("5", Left "Bungie.net 不可达：timeout")])
        names = Map.fromList [(1441982566, "门徒誓约: 标准"), (2122313384, "最后一愿: 标准")]
    checkpointActivities found `shouldBe` [300092127, 1441982566, 2122313384, 3889634515]
    checkpointReport names found
      `shouldBe` object
        [ "source" .= ("https://d2checkpoint.com" :: Text),
          "bots" .= (5 :: Int),
          "idle_bots" .= (2 :: Int),
          "checkpoints"
            .= [ object
                   [ "activity" .= ("最后一愿: 标准" :: Text),
                     "activity_en" .= ("Last Wish" :: Text),
                     "encounter" .= ("Shuro-Chi" :: Text),
                     "encounter_number" .= (2 :: Int),
                     "encounters" .= (6 :: Int),
                     "bot" .= ("CheckpointBot#0422" :: Text),
                     "in_fireteam" .= (6 :: Int),
                     "fireteam_size" .= (6 :: Int),
                     "open_slots" .= (0 :: Int),
                     "join" .= ("/加入 CheckpointBot#0422" :: Text),
                     "join_en" .= ("/join CheckpointBot#0422" :: Text),
                     "premium" .= True
                   ],
                 object
                   [ "activity" .= ("门徒誓约: 标准" :: Text),
                     "activity_en" .= ("Vow of the Disciple: Standard" :: Text),
                     "encounter" .= ("Rhulk" :: Text),
                     "encounter_number" .= (4 :: Int),
                     "encounters" .= (4 :: Int),
                     "bot" .= ("CheckpointBot#4108" :: Text),
                     "in_fireteam" .= (3 :: Int),
                     "fireteam_size" .= (6 :: Int),
                     "open_slots" .= (3 :: Int),
                     "join" .= ("/加入 CheckpointBot#4108" :: Text),
                     "join_en" .= ("/join CheckpointBot#4108" :: Text)
                   ]
               ],
          "unverified"
            .= [ object
                   [ "activity" .= ("3889634515" :: Text),
                     "encounter_number" .= (1 :: Int),
                     "bot" .= ("CheckpointBot#3036" :: Text),
                     "error" .= ("Bungie.net 不可达：timeout" :: Text)
                   ]
               ]
        ]
    -- Without the table the official name and encounter number remain.
    case checkpointReport names found {cpTable = Left "timeout"} of
      Object o -> do
        KeyMap.lookup "note" o `shouldSatisfy` (/= Nothing)
        fmap (map (KeyMap.lookup "encounter")) (rows o) `shouldBe` Just [Nothing, Nothing]
      other -> expectationFailure (show other)
  where
    json :: LBS.ByteString -> Value
    json raw = fromMaybe (error "invalid fixture") (decode raw)
    rows o = case KeyMap.lookup "checkpoints" o of
      Just (Array xs) -> Just [r | Object r <- foldr (:) [] xs]
      _ -> Nothing
