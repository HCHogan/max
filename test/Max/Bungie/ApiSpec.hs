module Max.Bungie.ApiSpec (spec) where

import Data.Aeson
import Data.Either (isLeft)
import Max.Bungie.Api
import Max.Bungie.Types
import Test.Hspec

spec :: Spec
spec = describe "Max.Bungie" $ do
  describe "readTarget" $ do
    it "accepts profile reads with any Platform spelling and comma components" $ do
      let Right target = readTarget False "https://www.bungie.net/Platform/Destiny2/3/Profile/4611686018400000000/" (object ["components" .= ([100, 200] :: [Int])])
      target.atSegments `shouldBe` ["Destiny2", "3", "Profile", "4611686018400000000"]
      targetUrl target `shouldBe` "https://www.bungie.net/Platform/Destiny2/3/Profile/4611686018400000000/?components=100%2C200"
      fmap (.atSegments) (readTarget False "destiny2/-1/profile/1/character/2/" Null) `shouldBe` Right ["destiny2", "-1", "profile", "1", "character", "2"]
    it "sends post-game carnage reports to the stats host" $
      fmap (.atHost) (readTarget False "/Destiny2/Stats/PostGameCarnageReport/123/" Null) `shouldBe` Right StatsHost
    it "percent-encodes free-text segments" $
      fmap targetUrl (readTarget False "/Destiny2/Armory/Search/DestinyInventoryItemDefinition/命运使者/" Null)
        `shouldBe` Right "https://www.bungie.net/Platform/Destiny2/Armory/Search/DestinyInventoryItemDefinition/%E5%91%BD%E8%BF%90%E4%BD%BF%E8%80%85/"
    it "refuses paths outside the read allowlist, traversal and smuggled queries" $ do
      readTarget False "/Destiny2/Actions/Items/TransferItem/" Null `shouldSatisfy` isLeft
      readTarget False "/GroupV2/123/Admins/" Null `shouldSatisfy` isLeft
      readTarget False "/Destiny2/3/Profile/abc/" Null `shouldSatisfy` isLeft
      readTarget False "/Destiny2/3/Profile/1/../../Actions/" Null `shouldSatisfy` isLeft
      readTarget False "/Destiny2/Milestones/?x=1" Null `shouldSatisfy` isLeft
      readTarget False "/Destiny2/Milestones/" (String "components=1") `shouldSatisfy` isLeft
    it "allows a body only for the player searches" $ do
      readTarget True "/Destiny2/SearchDestinyPlayerByBungieName/-1/" Null `shouldSatisfy` (not . isLeft)
      readTarget True "/Destiny2/Milestones/" Null `shouldSatisfy` isLeft
      readTarget False "/Destiny2/SearchDestinyPlayerByBungieName/-1/" Null `shouldSatisfy` isLeft
  describe "writeTarget" $ do
    it "covers item and loadout actions only" $ do
      fmap (.atSegments) (writeTarget "/Destiny2/Actions/Items/TransferItem/") `shouldBe` Right ["Destiny2", "Actions", "Items", "TransferItem"]
      writeTarget "/Destiny2/Actions/Loadouts/EquipLoadout/" `shouldSatisfy` (not . isLeft)
      writeTarget "/Destiny2/Actions/Items/InsertSocketPlug/" `shouldSatisfy` isLeft
      writeTarget "/GroupV2/1/Members/2/2/Kick/" `shouldSatisfy` isLeft
      writeTarget "/Destiny2/3/Profile/1/" `shouldSatisfy` isLeft
  describe "decodeEnvelope" $ do
    it "returns Response on success and a typed error otherwise" $ do
      decodeEnvelope (object ["ErrorCode" .= (1 :: Int), "ErrorStatus" .= ("Success" :: String), "Response" .= object ["x" .= True]])
        `shouldBe` Right (object ["x" .= True])
      let Left err = decodeEnvelope (object ["ErrorCode" .= (1665 :: Int), "ErrorStatus" .= ("DestinyPrivacyRestriction" :: String), "Message" .= ("private" :: String), "ThrottleSeconds" .= (0 :: Int)])
      err `shouldBe` BungieError 1665 "DestinyPrivacyRestriction" "private" 0
      renderBungieError err `shouldBe` "Bungie DestinyPrivacyRestriction (1665): private"
    it "classifies token and throttle failures" $ do
      authExpired (BungieError 99 "WebAuthRequired" "" 0) `shouldBe` True
      authExpired (BungieError 1665 "DestinyPrivacyRestriction" "" 0) `shouldBe` False
      throttled (BungieError 0 "Anything" "" 3) `shouldBe` True
      throttled (BungieError 0 "DestinyThrottledByGameServer" "" 0) `shouldBe` True
  describe "OAuth responses" $ do
    it "requires a refresh token, which only Confidential clients receive" $ do
      let grant = object ["access_token" .= ("a" :: String), "expires_in" .= (3600 :: Int), "refresh_token" .= ("r" :: String), "refresh_expires_in" .= (7776000 :: Int), "membership_id" .= ("123" :: String)]
      fmap (.tgMembershipId) (parseTokenGrant grant) `shouldBe` Right 123
      show (parseTokenGrant grant) `shouldNotContain` "\"a\""
      parseTokenGrant (object ["access_token" .= ("a" :: String), "expires_in" .= (3600 :: Int), "membership_id" .= ("123" :: String)]) `shouldSatisfy` isLeft
    it "picks the cross-save primary membership and renders the Bungie Name" $ do
      let memberships =
            object
              [ "bungieNetUser" .= object ["cachedBungieGlobalDisplayName" .= ("Guardian" :: String), "cachedBungieGlobalDisplayNameCode" .= (42 :: Int)],
                "destinyMemberships"
                  .= [ object ["membershipType" .= (2 :: Int), "membershipId" .= ("111" :: String), "crossSaveOverride" .= (3 :: Int)],
                       object ["membershipType" .= (3 :: Int), "membershipId" .= ("222" :: String), "crossSaveOverride" .= (3 :: Int)]
                     ]
              ]
      parseAccountIdentity memberships `shouldBe` Right (AccountIdentity "Guardian#0042" (Just (DestinyMembership 3 222)))
      parseAccountIdentity (object ["bungieNetUser" .= object ["uniqueName" .= ("old#1" :: String)], "primaryMembershipId" .= ("111" :: String), "destinyMemberships" .= [object ["membershipType" .= (2 :: Int), "membershipId" .= ("111" :: String)]]])
        `shouldBe` Right (AccountIdentity "old#1" (Just (DestinyMembership 2 111)))
