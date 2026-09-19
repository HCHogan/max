module Max.FetchQueueSpec (spec) where

import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM
import Control.Exception (throwIO)
import Control.Monad (forM_, replicateM)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Max.FetchQueue
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "process-local media queue" $ do
  it "prioritizes live media and deduplicates queued and completed work" $ do
    queue <- newFetchSignal
    seen <- newTQueueIO
    enqueue queue MissingFetch "old-a"
    enqueue queue MissingFetch "old-b"
    enqueue queue LiveFetch "new"
    enqueue queue LiveFetch "old-a"
    withAsync
      ( logged $ runFetchLoop queue JobForward $ \job -> do
          liftIO . atomically $ writeTQueue seen job.forwardId
          pure (Right ())
      )
      $ \_ -> do
        timeout 1_000_000 (replicateM 3 (atomically $ readTQueue seen)) `shouldReturn` Just ["new", "old-a", "old-b"]
        enqueue queue LiveFetch "old-a"
        enqueue queue LiveFetch "sentinel"
        timeout 1_000_000 (atomically $ readTQueue seen) `shouldReturn` Just "sentinel"

  it "bounds historical backlog without blocking live admission" $ do
    queue <- newFetchSignal
    forM_ [1 .. 128 :: Int] (enqueue queue MissingFetch . T.pack . show)
    timeout 20_000 (enqueue queue MissingFetch "overflow") `shouldReturn` Nothing
    timeout 1_000_000 (enqueue queue LiveFetch "new") `shouldReturn` Just ()
    fetchCounts queue `shouldReturn` (129, 0)

  it "retries synchronous failures five times then processes the next item" $ do
    queue <- newFetchSignal
    attempts <- newTVarIO (0 :: Int)
    done <- newEmptyTMVarIO
    enqueue queue LiveFetch "broken"
    enqueue queue LiveFetch "healthy"
    withAsync
      ( logged $ runFetchLoop queue JobForward $ \job ->
          if job.forwardId == "broken"
            then do
              liftIO . atomically $ modifyTVar' attempts (+ 1)
              liftIO (throwIO (userError "fixture download failure"))
            else liftIO (atomically $ putTMVar done ()) >> pure (Right ())
      )
      $ \_ -> do
        timeout 6_000_000 (atomically $ takeTMVar done) `shouldReturn` Just ()
        readTVarIO attempts `shouldReturn` 5
        (_, failed) <- fetchCounts queue
        failed `shouldBe` 1

  it "keeps one owner per key and cancels a blocked fetch without retry" $ do
    queue <- newFetchSignal
    started <- newTQueueIO
    gate <- newEmptyTMVarIO @()
    enqueue queue LiveFetch "blocked"
    let process job = do
          liftIO . atomically $ writeTQueue started job.forwardId
          liftIO . atomically $ takeTMVar gate
          pure (Right ())
        run = logged (runFetchLoop queue JobForward process)
    withAsync run $ \_ -> withAsync run $ \_ -> do
      timeout 1_000_000 (atomically $ readTQueue started) `shouldReturn` Just "blocked"
      enqueue queue LiveFetch "blocked"
      enqueue queue LiveFetch "second"
      timeout 1_000_000 (atomically $ readTQueue started) `shouldReturn` Just "second"
    fetchCounts queue `shouldReturn` (0, 0)
    atomically (tryReadTQueue started) `shouldReturn` Nothing

enqueue :: FetchSignal -> FetchPriority -> Text -> IO ()
enqueue queue priority key = runEff (enqueueFetch queue priority JobForward key (ForwardJob 1 key 100 1000))

logged :: Eff '[Log, IOE] a -> IO a
logged action = withCompactLogger ColorNever Nothing $ \logger -> runEff (runLog "media-test" logger LogAttention action)
