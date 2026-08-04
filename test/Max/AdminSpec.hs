module Max.AdminSpec (spec) where

import Max.Admin (Route (..), authOk, needsAuth, route)
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
      route "GET" ["api", "platforms", "status"] `shouldBe` Just RPlatformStatus
      route "GET" ["api", "platforms", "timeline", "42"] `shouldBe` Just (RPlatformTimeline 42)
      route "GET" ["api", "platforms", "timeline", "42", "wait"] `shouldBe` Just (RPlatformTimelineWait 42)
      route "GET" ["api", "blobs", "abc"] `shouldBe` Just (RBlob "abc")
      route "GET" ["api", "context", "status"] `shouldBe` Just RContextStatus
      route "GET" ["api", "context", "captures"] `shouldBe` Just RContextCaptures
      route "GET" ["api", "context", "compartments"] `shouldBe` Just RContextCompartments
      route "GET" ["api", "context", "plans"] `shouldBe` Just RContextPlans
      route "GET" ["api", "context", "memories", "77"] `shouldBe` Just (RContextMemory 77)
      route "GET" ["api", "context", "embeddings"] `shouldBe` Just RContextEmbeddings
      route "GET" ["api", "context", "recall"] `shouldBe` Just RContextRecall
      route "GET" ["api", "context", "integrity"] `shouldBe` Just RContextIntegrity

    it "maps the mutations with their ids" $ do
      route "PATCH" ["api", "groups", "123", "session"] `shouldBe` Just (RSessionPatch 123)
      route "PATCH" ["api", "groups", "-42", "session"] `shouldBe` Just (RSessionPatch (-42))
      route "DELETE" ["api", "memories", "7"] `shouldBe` Just (RMemoryDelete 7)
      route "DELETE" ["api", "permissions", "3"] `shouldBe` Just (RGrantDelete 3)
      route "DELETE" ["api", "tasks", "t17"] `shouldBe` Just (RTaskKill "t17")
      route "POST" ["api", "permissions"] `shouldBe` Just RGrantCreate
      route "GET" ["api", "skills"] `shouldBe` Just RSkillsList
      route "POST" ["api", "skills"] `shouldBe` Just RSkillCreate
      route "POST" ["api", "context", "rebuild"] `shouldBe` Just RContextRebuild
      route "POST" ["api", "context", "reindex"] `shouldBe` Just RContextReindex
      route "PATCH" ["api", "skills", "9"] `shouldBe` Just (RSkillPatch 9)
      route "DELETE" ["api", "skills", "9"] `shouldBe` Just (RSkillDelete 9)

    it "rejects junk ids, wrong methods and unknown paths" $ do
      route "PATCH" ["api", "groups", "abc", "session"] `shouldBe` Nothing
      route "DELETE" ["api", "memories", "1x"] `shouldBe` Nothing
      route "POST" ["api", "overview"] `shouldBe` Nothing
      route "GET" ["api", "nope"] `shouldBe` Nothing
      route "PUT" ["api", "permissions"] `shouldBe` Nothing

  describe "static asset routes" $ do
    it "serves the panel at the root" $ do
      route "GET" [] `shouldBe` Just (RStatic ["index.html"])
      route "GET" [""] `shouldBe` Just (RStatic ["index.html"])

    it "serves nested assets under /static" $ do
      route "GET" ["static", "app.js"] `shouldBe` Just (RStatic ["app.js"])
      route "GET" ["static", "vendor", "uplot.iife.min.js"]
        `shouldBe` Just (RStatic ["vendor", "uplot.iife.min.js"])

    it "refuses traversal and empty segments" $ do
      route "GET" ["static", "..", "etc", "passwd"] `shouldBe` Nothing
      route "GET" ["static", ""] `shouldBe` Nothing
      route "GET" ["static"] `shouldBe` Nothing

  -- A <script> tag can't send an Authorization header, so gating the
  -- panel's own files would make the token unusable from a browser.
  -- They carry no data; every byte of state comes from /api.
  describe "needsAuth" $ do
    it "exempts the panel's own assets" $ do
      needsAuth (RStatic ["index.html"]) `shouldBe` False
      needsAuth (RStatic ["vendor", "alpine.min.js"]) `shouldBe` False

    it "gates every data route" $ do
      needsAuth ROverview `shouldBe` True
      needsAuth RGroups `shouldBe` True
      needsAuth (RSessionPatch 1) `shouldBe` True
      needsAuth RMemoriesList `shouldBe` True
      needsAuth (RMemoryDelete 1) `shouldBe` True
      needsAuth RGrantsList `shouldBe` True
      needsAuth RGrantCreate `shouldBe` True
      needsAuth (RGrantDelete 1) `shouldBe` True
      needsAuth RTasksList `shouldBe` True
      needsAuth (RTaskKill "t1") `shouldBe` True
      needsAuth RUsage `shouldBe` True
      needsAuth RMessageStats `shouldBe` True
      needsAuth RPlatformStatus `shouldBe` True
      needsAuth (RPlatformTimeline 42) `shouldBe` True
      needsAuth (RPlatformTimelineWait 42) `shouldBe` True
      needsAuth (RBlob "abc") `shouldBe` True
      needsAuth RSkillsList `shouldBe` True
      needsAuth RSkillCreate `shouldBe` True
      needsAuth (RSkillPatch 1) `shouldBe` True
      needsAuth (RSkillDelete 1) `shouldBe` True

  describe "authOk" $ do
    it "is open when no token is configured (loopback is the guard)" $
      authOk Nothing Nothing `shouldBe` True

    it "requires the exact bearer token when configured" $ do
      authOk (Just "s3cret") (Just "Bearer s3cret") `shouldBe` True
      authOk (Just "s3cret") (Just "Bearer wrong") `shouldBe` False
      authOk (Just "s3cret") (Just "s3cret") `shouldBe` False
      authOk (Just "s3cret") Nothing `shouldBe` False
