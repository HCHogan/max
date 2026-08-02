module Max.MemoryExtractSpec (spec) where

import Data.Time (addUTCTime, getCurrentTime)
import Max.EpisodeScheduler
  ( awaitDueEpisode,
    bumpEpisode,
    continueEpisodeAt,
    episodePendingDeadline,
    newEpisodeScheduler,
    releaseEpisodeClaim,
    retryEpisodeAt,
  )
import Max.MemoryExtract
  ( ExtractOp (..),
    parseOps,
  )
import Max.MemoryStore (MemoryId (..), MemoryVersion (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "failure scheduling" $ do
    it "re-arms a failed group after one minute" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      retryEpisodeAt sched (GroupId 42) now
      episodePendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)

    it "does not overwrite a newer schedule installed meanwhile" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      retryEpisodeAt sched (GroupId 42) now
      retryEpisodeAt sched (GroupId 42) (addUTCTime 300 now)
      episodePendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)

    it "re-arms traffic that arrives while the due episode is claimed" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      continueEpisodeAt sched (GroupId 42) now
      awaitDueEpisode sched `shouldReturn` GroupId 42
      bumpEpisode sched (GroupId 42)
      deadline <- episodePendingDeadline sched (GroupId 42)
      deadline `shouldSatisfy` maybe False (> now)
      releaseEpisodeClaim sched (GroupId 42)

  describe "parseOps" $ do
    it "parses a plain JSON array" $
      parseOps "[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"喜欢 Haskell\"}]"
        `shouldBe` Right [OpAdd "user" (Just 123) "喜欢 Haskell"]

    it "parses update and delete" $
      parseOps "[{\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"新内容\"},{\"action\":\"delete\",\"id\":7,\"version\":4}]"
        `shouldBe` Right
          [ OpUpdate (MemoryId 5) (MemoryVersion 2) "新内容" "legacy maintenance update",
            OpArchive (MemoryId 7) (MemoryVersion 4) "legacy maintenance delete"
          ]

    it "parses evidence-reasoned supersede and archive operations" $
      parseOps
        "[{\"action\":\"supersede\",\"id\":7,\"version\":4,\"replacement_id\":5,\"reason\":\"newer message evidence\"},{\"action\":\"archive\",\"id\":8,\"version\":1,\"reason\":\"dated commitment expired\"}]"
        `shouldBe` Right
          [ OpSupersede (MemoryId 7) (MemoryVersion 4) (MemoryId 5) "newer message evidence",
            OpArchive (MemoryId 8) (MemoryVersion 1) "dated commitment expired"
          ]

    it "accepts an empty array" $
      parseOps "[]" `shouldBe` Right []

    it "strips markdown code fences" $
      parseOps "```json\n[{\"action\":\"delete\",\"id\":3,\"version\":1}]\n```"
        `shouldBe` Right [OpArchive (MemoryId 3) (MemoryVersion 1) "legacy maintenance delete"]

    it "tolerates prose around the array" $
      parseOps "好的，以下是操作：\n[{\"action\":\"delete\",\"id\":3,\"version\":1}] 完毕"
        `shouldBe` Right [OpArchive (MemoryId 3) (MemoryVersion 1) "legacy maintenance delete"]

    it "add without user_id defaults later (parses as Nothing)" $
      parseOps "[{\"action\":\"add\",\"scope\":\"group\",\"content\":\"c\"}]"
        `shouldBe` Right [OpAdd "group" Nothing "c"]

    it "rejects unknown actions" $
      parseOps "[{\"action\":\"merge\",\"id\":1}]" `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
