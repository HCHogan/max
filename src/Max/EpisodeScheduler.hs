-- |
-- In-process quiet-period scheduling for conversation episode capture.
-- Durable correctness lives in 'Max.EpisodeStore'; this scheduler only decides
-- when a conversation looks settled enough to enqueue work.  Losing it on a
-- restart is safe because the historian recovers conversations whose durable
-- cursor trails the raw ledger.
module Max.EpisodeScheduler
  ( EpisodeScheduler,
    newEpisodeScheduler,
    armEpisode,
    bumpEpisode,
    retryEpisodeAt,
    continueEpisodeAt,
    awaitDueEpisode,
    releaseEpisodeClaim,
    episodePendingDeadline,
    episodeIdleSeconds,
  )
where

import Control.Concurrent.STM
import Data.Int (Int64)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time
  ( UTCTime,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
  )
import OneBot.Types (GroupId (..))

-- | Conversation storage id → quiet deadline.  A version counter wakes an
-- awaiter when an earlier deadline replaces the one it was sleeping toward.
data EpisodeScheduler = EpisodeScheduler
  { esPending :: !(TVar (Map Int64 UTCTime)),
    esClaimed :: !(TVar (Set Int64)),
    esVersion :: !(TVar Int)
  }

newEpisodeScheduler :: IO EpisodeScheduler
newEpisodeScheduler =
  EpisodeScheduler <$> newTVarIO Map.empty <*> newTVarIO Set.empty <*> newTVarIO 0

-- | Recent and in-flight turns remain raw for ten quiet minutes before the
-- historian may project them into a compartment.
episodeIdleSeconds :: Int
episodeIdleSeconds = 600

retrySeconds :: Int
retrySeconds = 60

armEpisode :: EpisodeScheduler -> GroupId -> IO ()
armEpisode scheduler gid = do
  now <- getCurrentTime
  setDeadline scheduler gid (fromIntegral episodeIdleSeconds `addUTCTime` now)

-- | Any new group traffic restarts quiet settlement.  Unlike the legacy
-- extractor, message volume alone never folds an active conversation.
bumpEpisode :: EpisodeScheduler -> GroupId -> IO ()
bumpEpisode scheduler (GroupId gid) = do
  now <- getCurrentTime
  atomically $ do
    pending <- readTVar scheduler.esPending
    claimed <- readTVar scheduler.esClaimed
    whenArmed (Map.member gid pending || Set.member gid claimed) $ do
      writeTVar scheduler.esPending (Map.insert gid (fromIntegral episodeIdleSeconds `addUTCTime` now) pending)
      modifyTVar' scheduler.esVersion (+ 1)
  where
    whenArmed True action = action
    whenArmed False _ = pure ()

-- | Re-arm a failed attempt without overwriting a newer deadline installed by
-- traffic while the attempt was running.
retryEpisodeAt :: EpisodeScheduler -> GroupId -> UTCTime -> IO ()
retryEpisodeAt scheduler (GroupId gid) now = atomically $ do
  modifyTVar' scheduler.esPending $
    Map.insertWith
      (\_ newer -> newer)
      gid
      (fromIntegral retrySeconds `addUTCTime` now)
  modifyTVar' scheduler.esVersion (+ 1)

continueEpisodeAt :: EpisodeScheduler -> GroupId -> UTCTime -> IO ()
continueEpisodeAt scheduler (GroupId gid) now = atomically $ do
  modifyTVar' scheduler.esPending (Map.insertWith (\_ existing -> existing) gid now)
  modifyTVar' scheduler.esVersion (+ 1)

episodePendingDeadline :: EpisodeScheduler -> GroupId -> IO (Maybe UTCTime)
episodePendingDeadline scheduler (GroupId gid) =
  Map.lookup gid <$> readTVarIO scheduler.esPending

setDeadline :: EpisodeScheduler -> GroupId -> UTCTime -> IO ()
setDeadline scheduler (GroupId gid) deadline = atomically $ do
  modifyTVar' scheduler.esPending (Map.insert gid deadline)
  modifyTVar' scheduler.esVersion (+ 1)

-- | Wait for and atomically claim exactly one due conversation.  Claiming one
-- at a time means a worker failure cannot lose the unstarted tail of a batch.
awaitDueEpisode :: EpisodeScheduler -> IO GroupId
awaitDueEpisode scheduler = foreverUntilClaimed
  where
    foreverUntilClaimed = do
      now <- getCurrentTime
      (claimed, nextDeadline, version) <- atomically $ do
        pending <- readTVar scheduler.esPending
        let (due, waiting) = Map.partition (<= now) pending
        version <- readTVar scheduler.esVersion
        case Map.lookupMin due of
          Just (gid, _) -> do
            writeTVar scheduler.esPending (Map.delete gid pending)
            modifyTVar' scheduler.esClaimed (Set.insert gid)
            pure (Just (GroupId gid), Nothing, version)
          Nothing -> pure (Nothing, minimum <$> nonEmpty (Map.elems waiting), version)
      case claimed of
        Just gid -> pure gid
        Nothing -> do
          waitForDeadlineOrChange now nextDeadline version
          foreverUntilClaimed

    waitForDeadlineOrChange _ Nothing version =
      atomically $ readTVar scheduler.esVersion >>= \newVersion -> check (newVersion /= version)
    waitForDeadlineOrChange now (Just deadline) version = do
      let micros = max 0 (ceiling (diffUTCTime deadline now * 1_000_000)) :: Integer
      delay <- registerDelay (fromIntegral (min micros 3_600_000_000))
      atomically $
        (readTVar delay >>= check)
          `orElse` (readTVar scheduler.esVersion >>= \newVersion -> check (newVersion /= version))

-- | Release the transient claim after its durable enqueue/drain round.  New
-- traffic that arrived while claimed has already installed a fresh deadline.
releaseEpisodeClaim :: EpisodeScheduler -> GroupId -> IO ()
releaseEpisodeClaim scheduler (GroupId gid) =
  atomically (modifyTVar' scheduler.esClaimed (Set.delete gid))
