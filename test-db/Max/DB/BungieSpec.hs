module Max.DB.BungieSpec (spec) where

import Control.Monad (void)
import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import Max.Browser.Vault (newBrowserVault)
import Max.Bungie.Account
import Max.Bungie.Manifest (SearchHit (..), lookupDefinitions, searchDefinitions)
import Max.Bungie.Runtime (BungieRuntime, newBungieRuntime)
import Max.Bungie.Types
import Max.DB.Bungie
import Max.DB.Connection (DbPool)
import Max.HttpRuntime (newHttpRuntime)
import Max.Platform.Types (PrincipalId (..))
import Max.Skills (Skill (..), loadSkills, newSkillRegistry, setOptInAvailable, setSkillEnabled, skillsForGroup)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Bungie storage" $ do
  it "consumes a login state once and never after it expires" $ do
    principal <- newPrincipal pool "Hank"
    now <- getCurrentTime
    withDb pool $ do
      insertLoginState "fresh" principal "Hank" (addUTCTime 600 now)
      insertLoginState "stale" principal "Hank" (addUTCTime (-1) now)
    withDb pool (takeLoginState "fresh") `shouldReturn` Just (principal, "Hank")
    withDb pool (takeLoginState "fresh") `shouldReturn` Nothing
    withDb pool (takeLoginState "stale") `shouldReturn` Nothing
    withDb pool (query "SELECT count(*) FROM bungie_oauth_states" ()) `shouldReturn` [Only (0 :: Int64)]

  it "hands out a stored token only to the person it was sealed for" $ do
    runtime <- newRuntime
    owner <- newPrincipal pool "Hank"
    other <- newPrincipal pool "Mallory"
    withDb pool (accessTokenFor runtime owner) >>= (`shouldSatisfy` either (const False) null)
    link pool runtime owner 3600 7776000
    withDb pool (accessTokenFor runtime owner) >>= \case
      Right (Just (token, account)) -> do
        token `shouldBe` "access-token"
        account.laBungieName `shouldBe` "Guardian#0042"
        account.laMembership `shouldBe` Just (DestinyMembership 3 4611686018400000001)
      other' -> expectationFailure ("expected a linked token, got " <> show (fmap (fmap snd) other'))
    -- A sealed row copied onto someone else does not authenticate.
    withDb pool $ void (execute "INSERT INTO bungie_links SELECT ?, bungie_membership_id, bungie_name, destiny_membership_type, destiny_membership_id, sealed_tokens, access_expires_at, refresh_expires_at FROM bungie_links WHERE principal_id = ?" (other.unPrincipalId, owner.unPrincipalId))
    withDb pool (accessTokenFor runtime other) >>= (`shouldSatisfy` isLeft)
    withDb pool (unlinkAccount owner) `shouldReturn` True
    withDb pool (accessTokenFor runtime owner) >>= (`shouldSatisfy` either (const False) null)

  it "drops a link whose refresh window has closed instead of calling Bungie" $ do
    runtime <- newRuntime
    owner <- newPrincipal pool "Hank"
    link pool runtime owner (-10) (-1)
    withDb pool (accessTokenFor runtime owner) >>= (`shouldSatisfy` isLeft)
    withDb pool (linkedAccount owner) `shouldReturn` Nothing

  it "persists per-conversation opt-in and restores it on load" $ do
    owner <- newPrincipal pool "Hank"
    registry <- newSkillRegistry
    setOptInAvailable registry ["destiny"]
    withDb pool (setSkillEnabled registry (GroupId 1) "destiny" (Just owner) True)
    names registry 1 >>= (`shouldContain` ["destiny"])
    names registry 2 >>= (`shouldNotContain` ["destiny"])
    restarted <- newSkillRegistry
    setOptInAvailable restarted ["destiny"]
    _ <- withDb pool (loadSkills restarted)
    names restarted 1 >>= (`shouldContain` ["destiny"])
    unavailable <- newSkillRegistry
    _ <- withDb pool (loadSkills unavailable)
    names unavailable 1 >>= (`shouldNotContain` ["destiny"])
    withDb pool (setSkillEnabled restarted (GroupId 1) "destiny" (Just owner) False)
    names restarted 1 >>= (`shouldNotContain` ["destiny"])

  it "searches the local manifest by either name, exact matches first" $ do
    withDb pool (searchDefinitions Nothing "命运" 5) >>= (`shouldSatisfy` null)
    withDb pool $ do
      let item = "DestinyInventoryItemDefinition" :: Text
      void (execute "INSERT INTO destiny_manifest_kinds (kind, version, row_count) VALUES (?, 'v1', 3)" (Only item))
      void $
        execute
          "INSERT INTO destiny_definitions (kind, hash, name, name_en, data) VALUES (?,1,'命运使者','Fatebringer',?), (?,2,'命运使者（调整版）','Fatebringer (Timelost)',?), (?,3,'100% 宿命','Fate',?)"
          (item, object ["type" .= ("手炮" :: Text)], item, object [], item, object [])
    Just hits <- withDb pool (searchDefinitions Nothing "fatebringer" 5)
    map (.shHash) hits `shouldBe` [1, 2]
    Just escaped <- withDb pool (searchDefinitions (Just "DestinyInventoryItemDefinition") "%" 5)
    map (.shHash) escaped `shouldBe` [3]
    runtime <- newRuntime
    (found, missing) <- withDb pool (lookupDefinitions runtime "DestinyInventoryItemDefinition" [1, 2])
    (length found, missing) `shouldBe` (2, [])
  where
    names registry gid = map (.skillName) <$> skillsForGroup registry (GroupId gid)

newRuntime :: IO BungieRuntime
newRuntime = do
  http <- newHttpRuntime
  vault <- newBrowserVault
  newBungieRuntime (BungieConfig "key" "1" "secret") http vault "https://max.example"

newPrincipal :: DbPool -> Text -> IO PrincipalId
newPrincipal pool name = do
  [Only principal] <- withDb pool (query "INSERT INTO principals (display_name) VALUES (?) RETURNING principal_id" (Only name))
  pure (PrincipalId principal)

link :: DbPool -> BungieRuntime -> PrincipalId -> Int -> Int -> IO ()
link pool runtime principal accessSeconds refreshSeconds = do
  now <- getCurrentTime
  sealed <- sealTokens runtime principal (TokenGrant "access-token" accessSeconds "refresh-token" refreshSeconds 77)
  withDb pool . upsertLink principal $
    LinkRow
      { lrBungieMembershipId = 77,
        lrBungieName = "Guardian#0042",
        lrMembershipType = Just 3,
        lrMembershipId = Just 4611686018400000001,
        lrSealedTokens = sealed,
        lrAccessExpiresAt = addUTCTime (fromIntegral accessSeconds) now,
        lrRefreshExpiresAt = addUTCTime (fromIntegral refreshSeconds) now,
        lrLinkedAt = now
      }
