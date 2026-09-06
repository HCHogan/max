module Max.PlatformCapabilitiesSpec (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Effectful.Reader.Dynamic (ask, local, runReader)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.Effects.PlatformAccount
import Max.Effects.PlatformInteraction
import Max.Effects.PlatformQuery
import Max.IR.Lower (textOnlyCaps)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Failure (PlatformFailure (..))
import Max.Platform.Roster (GroupMember (..), GroupMeta (..))
import Max.Platform.Rpc (platformRouter)
import Max.Platform.Store (RegisteredEndpoint (..), ensureConfiguredEndpoint, ensureLegacyEndpoint)
import Max.Platform.Types
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "narrow platform capabilities" $ do
  it "routes typed roster queries by canonical ownership and decodes their data" $ do
    endpoint <- matrixEndpoint
    let group = GroupId endpoint.compatibilityConversationId
        backend =
          (forbiddenBackend "matrix")
            { pbCall = \action timeout -> do
                timeout `shouldBe` 10000
                case action of
                  GetGroupInfo actual | actual == group -> reply (object ["group_name" .= ("room" :: String), "member_count" .= (2 :: Int)])
                  GetGroupMemberList actual | actual == group -> reply (toMembers 7)
                  _ -> fail ("unexpected query: " <> show action)
            }
    (meta, members) <-
      withDb pool . runPlatformQuery (platformRouter (forbiddenBackend "qq") (pure [backend])) $
        (,) <$> queryGroupMeta group <*> queryGroupMembers group
    meta `shouldBe` Right (GroupMeta "room" (Just 2))
    members `shouldBe` Right [GroupMember (UserId 7) (Just "member") Nothing "member" Nothing]

  it "does not fall back to QQ when a foreign endpoint lacks its backend" $ do
    endpoint <- matrixEndpoint
    result <-
      withDb pool . runPlatformQuery (platformRouter (forbiddenBackend "qq") (pure [])) $
        queryGroupMeta (GroupId endpoint.compatibilityConversationId)
    result `shouldBe` Left (PlatformRouteUnavailable "matrix" ["qq"])

  it "does not issue an RPC without canonical ownership" $ do
    result <-
      withDb pool . runPlatformQuery (platformRouter (forbiddenBackend "qq") (pure [])) $
        queryGroupMembers (GroupId 123456)
    result `shouldBe` Left PlatformRouteMissing

  it "retains rejected and malformed query results as different typed failures" $ do
    group <- qqGroup
    let rejected = (forbiddenBackend "qq") {pbCall = \_ _ -> pure (Right (Response "failed" 1404 Null "test"))}
        malformed = (forbiddenBackend "qq") {pbCall = \_ _ -> reply (object [])}
    failure <- withDb pool . runPlatformQuery (platformRouter rejected (pure [])) $ queryGroupFileUrl group "file-1"
    invalid <- withDb pool . runPlatformQuery (platformRouter malformed (pure [])) $ queryGroupFileUrl group "file-1"
    failure `shouldBe` Left (PlatformRejected 1404)
    invalid `shouldSatisfy` \case Left PlatformInvalidResponse {} -> True; _ -> False

  it "resolves foreign resources from the current scope and restores the enclosing generation" $ do
    endpoint <- matrixEndpoint
    let group = GroupId endpoint.compatibilityConversationId
        backend name = (forbiddenBackend "matrix") {pbCall = \_ _ -> reply (object ["group_name" .= (name :: String)])}
    names <- withDb pool . runReader [backend "old"] . runPlatformQuery (platformRouter (forbiddenBackend "qq") (ask @[PlatformBackend])) $ do
      initial <- queryGroupMeta group
      inside <- local @[PlatformBackend] (const [backend "new"]) (queryGroupMeta group)
      restored <- queryGroupMeta group
      pure (initial, inside, restored)
    names `shouldBe` (Right (GroupMeta "old" Nothing), Right (GroupMeta "new" Nothing), Right (GroupMeta "old" Nothing))

  it "keeps poke and friend approval in their distinct interpreters" $ do
    group <- qqGroup
    calls <- newIORef ([] :: [Text])
    let backend =
          (forbiddenBackend "qq")
            { pbCall = \action timeout -> case action of
                SendPoke actual user | actual == group && user == UserId 7 && timeout == 10000 -> do
                  modifyIORef' calls (<> ["poke"])
                  reply (object [])
                _ -> fail ("unexpected interaction: " <> show action),
              pbSend = \case
                SetFriendAddRequest "event-flag" False -> Right () <$ modifyIORef' calls (<> ["reject friend"])
                action -> fail ("unexpected account operation: " <> show action)
            }
    withDb pool (runPlatformInteraction (platformRouter backend (pure [])) (pokeUser group (UserId 7))) `shouldReturn` Right ()
    withDb pool (runPlatformAccount (platformRouter backend (pure [])) (respondToFriendRequest "event-flag" RejectFriend)) `shouldReturn` Right ()
    readIORef calls `shouldReturn` ["poke", "reject friend"]

  it "does not present a rejected poke as success" $ do
    group <- qqGroup
    let backend = (forbiddenBackend "qq") {pbCall = \_ _ -> pure (Right (Response "failed" 100 Null "test"))}
    withDb pool (runPlatformInteraction (platformRouter backend (pure [])) (pokeUser group (UserId 7))) `shouldReturn` Left (PlatformRejected 100)
  where
    matrixEndpoint = withDb pool $ ensureConfiguredEndpoint PlatformMatrix (NativeAccountId "@max:test") (NativeConversationId "!room:test") ConversationGroup EndpointStandalone Nothing textOnlyCaps
    qqGroup = do
      _ <- withDb pool $ ensureLegacyEndpoint PlatformQQ (NativeAccountId "9") (NativeConversationId "42") ConversationGroup 42 textOnlyCaps
      pure (GroupId 42)
    toMembers uid = toJSON [object ["user_id" .= (uid :: Int), "nickname" .= ("member" :: String)]]

reply :: Value -> IO (Either a Response)
reply value = pure (Right (Response "ok" 0 value "test"))

forbiddenBackend :: Text -> PlatformBackend
forbiddenBackend name = PlatformBackend name name (\_ -> fail "unexpected platform send") (\_ _ -> fail "unexpected platform call")
