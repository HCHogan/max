-- | Typed, bounded media work owned by this process. Canonical history supplies
-- missing work; no job payload, lease or restart attempt is stored in SQL. A
-- key that exhausts its retries is handed to the caller, which parks it so
-- discovery does not requeue it after every restart.
module Max.FetchQueue
  ( FetchSignal,
    FetchPriority (..),
    JobKind (..),
    ImageJob (..),
    MediaKind (..),
    FileJob (..),
    ForwardJob (..),
    newFetchSignal,
    enqueueFetch,
    notifyFetch,
    fetchCounts,
    fetchTick,
    waitFetch,
    runFetchLoop,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forever, unless)
import Data.Int (Int64)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Exception (bracket)
import Effectful.Log
import Max.DB.Stickers (StickerMeta)
import Max.Util (trySync)

data MediaKind = MediaImage | MediaVideo
  deriving stock (Show, Eq)

-- | Sticker metadata is recorded once the downloaded content hash is known.
data ImageJob = ImageJob
  { canonicalMessageId :: !Int64,
    segIndex :: !Int,
    url :: !Text,
    groupId :: !(Maybe Int64),
    sticker :: !(Maybe StickerMeta),
    kind :: !MediaKind
  }
  deriving stock (Show)

data FileJob = FileJob
  { fjFileId :: !Text,
    fjGroupId :: !Int64,
    fjMessageId :: !Int64,
    fjSenderUserId :: !Int64,
    fjFileName :: !Text,
    fjSizeHint :: !(Maybe Int64),
    fjUrlHint :: !(Maybe Text)
  }
  deriving stock (Show)

data ForwardJob = ForwardJob
  { containerMessageId :: !Int64,
    forwardId :: !Text,
    groupId :: !Int64,
    selfId :: !Int64
  }
  deriving stock (Show)

data JobKind a where
  JobImage :: JobKind ImageJob
  JobForward :: JobKind ForwardJob
  JobFile :: JobKind FileJob

data FetchPriority = LiveFetch | MissingFetch

data FetchSignal = FetchSignal
  { images :: !(FetchQueue ImageJob),
    forwards :: !(FetchQueue ForwardJob),
    files :: !(FetchQueue FileJob),
    tick :: !(TVar Int)
  }

data FetchQueue a = FetchQueue
  { pending :: !(TBQueue (Text, a)),
    missing :: !(TBQueue (Text, a)),
    active :: !(TVar (Set.Set Text)),
    recent :: !(TVar (Seq.Seq Text, Set.Set Text)),
    failures :: !(TVar Int)
  }

newFetchSignal :: IO FetchSignal
newFetchSignal = FetchSignal <$> newQueue <*> newQueue <*> newQueue <*> newTVarIO 0
  where
    newQueue = FetchQueue <$> newTBQueueIO 1024 <*> newTBQueueIO 128 <*> newTVarIO Set.empty <*> newTVarIO (Seq.empty, Set.empty) <*> newTVarIO 0

queueFor :: FetchSignal -> JobKind a -> FetchQueue a
queueFor signal = \case JobImage -> signal.images; JobForward -> signal.forwards; JobFile -> signal.files

kindName :: JobKind a -> Text
kindName = \case JobImage -> "image"; JobForward -> "forward"; JobFile -> "file"

enqueueFetch :: (IOE :> es) => FetchSignal -> FetchPriority -> JobKind a -> Text -> a -> Eff es ()
enqueueFetch signal priority kind key payload = liftIO $ atomically $ do
  let queue = queueFor signal kind
  active <- readTVar queue.active
  (_, recent) <- readTVar queue.recent
  unless (Set.member key active || Set.member key recent) $ do
    writeTBQueue (case priority of LiveFetch -> queue.pending; MissingFetch -> queue.missing) (key, payload)
    modifyTVar' queue.active (Set.insert key)

notifyFetch :: FetchSignal -> IO ()
notifyFetch signal = atomically (modifyTVar' signal.tick (+ 1))

fetchTick :: FetchSignal -> IO Int
fetchTick = readTVarIO . (.tick)

waitFetch :: FetchSignal -> Int -> IO ()
waitFetch signal observed = do
  timer <- registerDelay 60_000_000
  atomically $ (readTVar timer >>= check) `orElse` (readTVar signal.tick >>= check . (/= observed))

-- | @exhausted kind key error@ runs once a key has failed every attempt.
runFetchLoop :: (Log :> es, IOE :> es) => FetchSignal -> JobKind a -> (Text -> Text -> Text -> Eff es ()) -> (a -> Eff es (Either Text ())) -> Eff es ()
runFetchLoop signal kind exhausted process =
  forever $
    bracket
      (liftIO . atomically $ readTBQueue queue.pending `orElse` readTBQueue queue.missing)
      ( \(key, _) -> liftIO . atomically $ do
          modifyTVar' queue.active (Set.delete key)
          modifyTVar' queue.recent (remember key)
      )
      (\(key, payload) -> attempt key payload 1)
  where
    queue = queueFor signal kind
    attempt key payload count = do
      result <- trySync (process payload)
      case either (Left . T.pack . show) id result of
        Right () -> pure ()
        Left err
          | count < (5 :: Int) -> do
              logInfo "media fetch retrying" (object ["kind" .= kindName kind, "key" .= key, "attempt" .= count, "error" .= err])
              liftIO (threadDelay (250_000 * 2 ^ (count - 1)))
              attempt key payload (count + 1)
          | otherwise -> do
              logAttention "media fetch failed" (object ["kind" .= kindName kind, "key" .= key, "attempts" .= count, "error" .= err])
              liftIO . atomically $ modifyTVar' queue.failures (+ 1)
              trySync (exhausted (kindName kind) key err) >>= \case
                Left parkErr -> logAttention "media fetch could not be parked" (object ["kind" .= kindName kind, "key" .= key, "error" .= show parkErr])
                Right () -> pure ()

    remember key (order, keys) =
      let next = order Seq.|> key
       in case Seq.viewl next of
            oldest Seq.:< rest | Seq.length next > 1024 -> (rest, Set.insert key (Set.delete oldest keys))
            _ -> (next, Set.insert key keys)

fetchCounts :: FetchSignal -> IO (Int, Int)
fetchCounts signal = atomically $ do
  values <- sequence [counts signal.images, counts signal.forwards, counts signal.files]
  pure (sum (map fst values), sum (map snd values))
  where
    counts :: FetchQueue a -> STM (Int, Int)
    counts queue = do
      pending <- Set.size <$> readTVar queue.active
      failed <- readTVar queue.failures
      pure (pending, failed)
