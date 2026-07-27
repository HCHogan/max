module Max.AdminSpec (spec) where

import Max.Admin (Route (..), authOk, route)
import Test.Hspec

spec :: Spec
spec = describe "Max.Admin" $ do
  describe "route" $ do
    it "maps the read endpoints" $ do
      route "GET" ["api", "overview"] `shouldBe` Just ROverview
      route "GET" ["api", "groups"] `shouldBe` Just RGroups
      route "GET" ["api", "memories"] `shouldBe` Just RMemoriesList
      route "GET" ["api", "permissions"] `shouldBe` Just RGrantsList
      route "GET" ["api", "tasks"] `shouldBe` Just RTasksList
      route "GET" ["api", "usage"] `shouldBe` Just RUsage
      route "GET" ["api", "stats", "messages"] `shouldBe` Just RMessageStats

    it "maps the mutations with their ids" $ do
      route "PATCH" ["api", "groups", "123", "session"] `shouldBe` Just (RSessionPatch 123)
      route "PATCH" ["api", "groups", "-42", "session"] `shouldBe` Just (RSessionPatch (-42))
      route "DELETE" ["api", "memories", "7"] `shouldBe` Just (RMemoryDelete 7)
      route "DELETE" ["api", "permissions", "3"] `shouldBe` Just (RGrantDelete 3)
      route "DELETE" ["api", "tasks", "t17"] `shouldBe` Just (RTaskKill "t17")
      route "POST" ["api", "permissions"] `shouldBe` Just RGrantCreate

    it "rejects junk ids, wrong methods and unknown paths" $ do
      route "PATCH" ["api", "groups", "abc", "session"] `shouldBe` Nothing
      route "DELETE" ["api", "memories", "1x"] `shouldBe` Nothing
      route "POST" ["api", "overview"] `shouldBe` Nothing
      route "GET" ["api", "nope"] `shouldBe` Nothing
      route "PUT" ["api", "permissions"] `shouldBe` Nothing

  describe "authOk" $ do
    it "is open when no token is configured (loopback is the guard)" $
      authOk Nothing Nothing `shouldBe` True

    it "requires the exact bearer token when configured" $ do
      authOk (Just "s3cret") (Just "Bearer s3cret") `shouldBe` True
      authOk (Just "s3cret") (Just "Bearer wrong") `shouldBe` False
      authOk (Just "s3cret") (Just "s3cret") `shouldBe` False
      authOk (Just "s3cret") Nothing `shouldBe` False
