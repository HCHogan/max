module Max.EpisodeSchedulerSpec (spec) where

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
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec =
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
