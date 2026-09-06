-- |
-- The claim query is the part of the media pipeline with no cheap way
-- to notice breakage: leases, @SKIP LOCKED@ and the parking arithmetic
-- all live in one SQL string, and getting any of them subtly wrong
-- shows up as \"images stopped arriving\" days later.  So it gets a
-- real database.
module Max.DB.FetchQueueSpec (spec) where

import Data.Text (Text)
import Helpers (truncateAll, withDbLog)
import Max.DB.Connection (DbPool)
import Max.DB.FetchQueue
  ( ClaimedJob (..),
    JobKind (..),
    claimJobs,
    completeJob,
    enqueueJob,
    failJob,
    jobClaim,
    maxAttempts,
  )
import Test.Hspec

-- | Claim with an explicit lease, so the expiry path is reachable.
-- Fixes the payload to 'Text': these cases are about queue mechanics,
-- not about what rides in the row.
claimWithLease :: DbPool -> JobKind -> Int -> Int -> IO [ClaimedJob Text]
claimWithLease pool kind lease n = withDbLog pool (claimJobs kind lease n)

-- | Claim with a lease long enough that nothing expires mid-test.
claim :: DbPool -> JobKind -> Int -> IO [ClaimedJob Text]
claim pool kind = claimWithLease pool kind 300

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.DB.FetchQueue" $ do
  it "hands back what was queued, on its first attempt" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    [j] <- claim pool JobImage 10
    (j.cjPayload, j.cjAttempt) `shouldBe` ("payload-a", 1)

  it "dedupes on the natural key, so a redelivered message queues once" $ do
    withDbLog pool $ do
      enqueueJob JobImage "m1:0" ("first" :: Text)
      enqueueJob JobImage "m1:0" ("second" :: Text)
    js <- claim pool JobImage 10
    map (.cjPayload) js `shouldBe` ["first"]

  it "scopes claims to one kind — a file worker never sees an image job" $ do
    withDbLog pool $ do
      enqueueJob JobImage "m1:0" ("img" :: Text)
      enqueueJob JobFile "f1" ("file" :: Text)
    imgs <- claim pool JobImage 10
    files <- claim pool JobFile 10
    (map (.cjPayload) imgs, map (.cjPayload) files) `shouldBe` (["img"], ["file"])

  it "holds a claimed job under its lease, so a pool can't double-fetch" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    _ <- claim pool JobImage 10
    again <- claim pool JobImage 10
    again `shouldSatisfy` (null :: [ClaimedJob Text] -> Bool)

  it "re-offers a job whose lease has expired — this is the crash path" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    -- A zero-second lease is a process that died the instant it claimed.
    _ <- claimWithLease pool JobImage 0 10
    [j] <- claim pool JobImage 10
    j.cjAttempt `shouldBe` 2

  it "returns a failed job to the pool, counting the attempt" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    [j1] <- claim pool JobImage 10
    withDbLog pool (failJob (jobClaim j1) "boom")
    [j2] <- claim pool JobImage 10
    (j1.cjAttempt, j2.cjAttempt) `shouldBe` (1, 2)

  it "parks a job once its attempts run out, and stops offering it" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    let burn 0 = pure ()
        burn n = do
          [j] <- claim pool JobImage 10
          withDbLog pool (failJob (jobClaim j) "boom")
          burn (n - 1 :: Int)
    burn maxAttempts
    parked <- claim pool JobImage 10
    parked `shouldSatisfy` (null :: [ClaimedJob Text] -> Bool)

  it "drops a completed job so the table only ever holds live work" $ do
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-a" :: Text))
    [j] <- claim pool JobImage 10
    withDbLog pool (completeJob (jobClaim j))
    -- Re-enqueueing the same key must work again: the row is gone, not
    -- lingering to block it via the UNIQUE constraint.
    withDbLog pool (enqueueJob JobImage "m1:0" ("payload-b" :: Text))
    [j'] <- claim pool JobImage 10
    (j'.cjPayload, j'.cjAttempt) `shouldBe` ("payload-b", 1)

  it "fences late completion and failure from an expired attempt" $ do
    withDbLog pool (enqueueJob JobImage "stale" ("payload" :: Text))
    [old] <- claimWithLease pool JobImage 0 1
    [current] <- claim pool JobImage 1
    withDbLog pool (failJob (jobClaim old) "late failure")
    again <- claim pool JobImage 1
    length again `shouldBe` 0
    withDbLog pool (completeJob (jobClaim old))
    withDbLog pool (failJob (jobClaim current) "current failure")
    [next] <- claim pool JobImage 1
    next.cjAttempt `shouldBe` 3

  it "respects the batch limit" $ do
    withDbLog pool $
      mapM_
        (\i -> enqueueJob JobImage ("m1:" <> i) ("p" <> i :: Text))
        ["0", "1", "2", "3"]
    js <- claim pool JobImage 2
    length js `shouldBe` 2
