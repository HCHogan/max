-- | Process-local quiet periods, rebuild requests and retry delays.
module Max.EpisodeScheduler
  ( EpisodeScheduler,
    EpisodeRequest (..),
    EpisodeWork (..),
    episodeGroup,
    newEpisodeScheduler,
    queueEpisodeRebuilds,
    armEpisode,
    bumpEpisode,
    retryEpisodeAt,
    deferEpisodeAt,
    continueEpisodeAt,
    awaitDueEpisode,
    releaseEpisodeClaim,
    episodePendingDeadline,
    episodeRetryCount,
    episodeIdleSeconds,
    episodeRetryDelaySeconds,
  )
where

import Control.Concurrent.STM
import Control.Monad (when)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Max.Episode.Types (CompartmentId)
import OneBot.Types (GroupId (..))

data EpisodeRequest
  = SettledConversation !GroupId
  | RebuildEpisode !GroupId !CompartmentId !Text
  deriving stock (Eq, Ord, Show)

data EpisodeWork = EpisodeWork
  { request :: !EpisodeRequest,
    failures :: !Int
  }
  deriving stock (Eq, Show)

data EpisodeScheduler = EpisodeScheduler
  { pending :: !(TVar (Map EpisodeRequest (UTCTime, Int))),
    claimed :: !(TVar (Set Int64)),
    version :: !(TVar Int)
  }

newEpisodeScheduler :: IO EpisodeScheduler
newEpisodeScheduler = EpisodeScheduler <$> newTVarIO Map.empty <*> newTVarIO Set.empty <*> newTVarIO 0

episodeGroup :: EpisodeRequest -> GroupId
episodeGroup = \case SettledConversation gid -> gid; RebuildEpisode gid _ _ -> gid

episodeIdleSeconds :: Int
episodeIdleSeconds = 600

episodeRetryDelaySeconds :: Int -> Int
episodeRetryDelaySeconds attempt
  | attempt <= 1 = 60
  | attempt == 2 = 300
  | attempt == 3 = 900
  | attempt == 4 = 3600
  | otherwise = 21600

-- | Admit a whole admin request or leave the queue unchanged.
queueEpisodeRebuilds :: EpisodeScheduler -> GroupId -> [CompartmentId] -> Text -> IO Bool
queueEpisodeRebuilds scheduler gid compartments profile = do
  now <- getCurrentTime
  atomically $ do
    current <- readTVar scheduler.pending
    let additions = Map.fromList [(RebuildEpisode gid compartment profile, (now, 0)) | compartment <- compartments]
        next = Map.union current additions
        rebuildCount = Map.size (Map.filterWithKey (\key _ -> case key of RebuildEpisode {} -> True; _ -> False) next)
    if rebuildCount > 1024
      then pure False
      else do
        writeTVar scheduler.pending next
        modifyTVar' scheduler.version (+ 1)
        pure True

armEpisode :: EpisodeScheduler -> GroupId -> IO ()
armEpisode scheduler gid = do
  now <- getCurrentTime
  schedule scheduler (EpisodeWork (SettledConversation gid) 0) (addUTCTime (fromIntegral episodeIdleSeconds) now) False

-- | Traffic during generation starts a fresh quiet period for the next range.
bumpEpisode :: EpisodeScheduler -> GroupId -> IO ()
bumpEpisode scheduler gid@(GroupId raw) = do
  now <- getCurrentTime
  atomically $ do
    current <- readTVar scheduler.pending
    active <- readTVar scheduler.claimed
    let key = SettledConversation gid
    when (Map.member key current || Set.member raw active) $ do
      writeTVar scheduler.pending (Map.insert key (addUTCTime (fromIntegral episodeIdleSeconds) now, 0) current)
      modifyTVar' scheduler.version (+ 1)

retryEpisodeAt :: EpisodeScheduler -> EpisodeWork -> UTCTime -> IO ()
retryEpisodeAt scheduler work now =
  let failures = work.failures + 1
   in schedule scheduler (work {failures}) (addUTCTime (fromIntegral (episodeRetryDelaySeconds failures)) now) True

deferEpisodeAt :: EpisodeScheduler -> EpisodeWork -> UTCTime -> IO ()
deferEpisodeAt scheduler work now = schedule scheduler work (addUTCTime 60 now) True

continueEpisodeAt :: EpisodeScheduler -> GroupId -> UTCTime -> IO ()
continueEpisodeAt scheduler gid now = schedule scheduler (EpisodeWork (SettledConversation gid) 0) now True

schedule :: EpisodeScheduler -> EpisodeWork -> UTCTime -> Bool -> IO ()
schedule scheduler work deadline keepNewer = atomically $ do
  modifyTVar' scheduler.pending $
    Map.insertWith (\new old -> if keepNewer then old else new) work.request (deadline, work.failures)
  modifyTVar' scheduler.version (+ 1)

episodePendingDeadline :: EpisodeScheduler -> GroupId -> IO (Maybe UTCTime)
episodePendingDeadline scheduler gid = fmap fst . Map.lookup (SettledConversation gid) <$> readTVarIO scheduler.pending

episodeRetryCount :: EpisodeScheduler -> IO Int
episodeRetryCount scheduler = Map.size . Map.filter ((> 0) . snd) <$> readTVarIO scheduler.pending

awaitDueEpisode :: EpisodeScheduler -> IO EpisodeWork
awaitDueEpisode scheduler = do
  now <- getCurrentTime
  (ready, deadline, observed) <- atomically $ do
    current <- readTVar scheduler.pending
    active <- readTVar scheduler.claimed
    observed <- readTVar scheduler.version
    let available = [(key, scheduled) | (key, scheduled) <- Map.toList current, let GroupId gid = episodeGroup key, Set.notMember gid active]
    case sortOn (fst . snd) available of
      (key, (deadline, failures)) : _ | deadline <= now -> do
        let GroupId gid = episodeGroup key
        writeTVar scheduler.pending (Map.delete key current)
        modifyTVar' scheduler.claimed (Set.insert gid)
        pure (Just (EpisodeWork key failures), Nothing, observed)
      (_, (deadline, _)) : _ -> pure (Nothing, Just deadline, observed)
      [] -> pure (Nothing, Nothing, observed)
  case ready of
    Just work -> pure work
    Nothing -> do
      let changed = readTVar scheduler.version >>= check . (/= observed)
      case deadline of
        Nothing -> atomically changed
        Just at -> do
          let micros = max 0 (ceiling (diffUTCTime at now * 1_000_000)) :: Integer
          timer <- registerDelay (fromIntegral (min micros 3_600_000_000))
          atomically $ (readTVar timer >>= check) `orElse` changed
      awaitDueEpisode scheduler

releaseEpisodeClaim :: EpisodeScheduler -> EpisodeWork -> IO ()
releaseEpisodeClaim scheduler work = atomically $ do
  let GroupId gid = episodeGroup work.request
  modifyTVar' scheduler.claimed (Set.delete gid)
  modifyTVar' scheduler.version (+ 1)
