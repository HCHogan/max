module Max.EpisodeSchedulerSpec (spec) where

import Data.Time (addUTCTime, getCurrentTime)
import Max.Episode.Types (CompartmentId (..))
import Max.EpisodeScheduler
  ( EpisodeRequest (..),
    EpisodeWork (..),
    awaitDueEpisode,
    bumpEpisode,
    continueEpisodeAt,
    episodePendingDeadline,
    episodeRetryCount,
    episodeRetryDelaySeconds,
    newEpisodeScheduler,
    queueCompact,
    queueEpisodeRebuilds,
    releaseEpisodeClaim,
    retryEpisodeAt,
  )
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec =
  describe "failure scheduling" $ do
    it "starts manual compact immediately, coalesces cutoffs, and ignores traffic postponement" $ do
      sched <- newEpisodeScheduler
      queueCompact sched (GroupId 42) 50
      queueCompact sched (GroupId 42) 100
      bumpEpisode sched (GroupId 42)
      work <- timeout 1_000_000 (awaitDueEpisode sched)
      work `shouldBe` Just (EpisodeWork (CompactConversation (GroupId 42) 100) 0)
      releaseEpisodeClaim sched (EpisodeWork (CompactConversation (GroupId 42) 100) 0)
      timeout 20_000 (awaitDueEpisode sched) `shouldReturn` Nothing

    it "re-arms a failed group after one minute" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      retryEpisodeAt sched (EpisodeWork (SettledConversation (GroupId 42)) 0) now
      episodePendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)
      episodeRetryCount sched `shouldReturn` 1
      bumpEpisode sched (GroupId 42)
      episodeRetryCount sched `shouldReturn` 0

    it "does not overwrite a newer schedule installed meanwhile" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      retryEpisodeAt sched (EpisodeWork (SettledConversation (GroupId 42)) 0) now
      retryEpisodeAt sched (EpisodeWork (SettledConversation (GroupId 42)) 0) (addUTCTime 300 now)
      episodePendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)

    it "re-arms traffic that arrives while the due episode is claimed" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      continueEpisodeAt sched (GroupId 42) now
      awaitDueEpisode sched `shouldReturn` EpisodeWork (SettledConversation (GroupId 42)) 0
      bumpEpisode sched (GroupId 42)
      deadline <- episodePendingDeadline sched (GroupId 42)
      deadline `shouldSatisfy` maybe False (> now)
      releaseEpisodeClaim sched (EpisodeWork (SettledConversation (GroupId 42)) 0)

    it "bounds provider retry frequency within this process" $
      map episodeRetryDelaySeconds [1 .. 8] `shouldBe` [60, 300, 900, 3600, 21600, 21600, 21600, 21600]

    it "keeps delayed retries from blocking another conversation" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      retryEpisodeAt sched (EpisodeWork (SettledConversation (GroupId 42)) 2) now
      continueEpisodeAt sched (GroupId 43) now
      timeout 1_000_000 (awaitDueEpisode sched) `shouldReturn` Just (EpisodeWork (SettledConversation (GroupId 43)) 0)
      episodePendingDeadline sched (GroupId 42) `shouldReturn` Just (addUTCTime 900 now)

    it "deduplicates rebuilds and keeps ownership within each conversation" $ do
      sched <- newEpisodeScheduler
      now <- getCurrentTime
      continueEpisodeAt sched (GroupId 42) now
      work <- awaitDueEpisode sched
      queueEpisodeRebuilds sched (GroupId 42) [CompartmentId 1, CompartmentId 1] "memory" `shouldReturn` True
      queueEpisodeRebuilds sched (GroupId 43) [CompartmentId 2] "memory" `shouldReturn` True
      timeout 1_000_000 (awaitDueEpisode sched) `shouldReturn` Just (EpisodeWork (RebuildEpisode (GroupId 43) (CompartmentId 2) "memory") 0)
      releaseEpisodeClaim sched work
      rebuilt <- awaitDueEpisode sched
      rebuilt `shouldBe` EpisodeWork (RebuildEpisode (GroupId 42) (CompartmentId 1) "memory") 0
      releaseEpisodeClaim sched rebuilt
      timeout 20_000 (awaitDueEpisode sched) `shouldReturn` Nothing

    it "rejects oversized rebuild batches atomically and loses requests on restart" $ do
      sched <- newEpisodeScheduler
      queueEpisodeRebuilds sched (GroupId 42) (map CompartmentId [1 .. 1025]) "memory" `shouldReturn` False
      timeout 20_000 (awaitDueEpisode sched) `shouldReturn` Nothing
      queueEpisodeRebuilds sched (GroupId 42) [CompartmentId 1] "memory" `shouldReturn` True
      fresh <- newEpisodeScheduler
      timeout 20_000 (awaitDueEpisode fresh) `shouldReturn` Nothing
