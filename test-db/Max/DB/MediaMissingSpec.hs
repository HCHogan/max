module Max.DB.MediaMissingSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Monad (forM_)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..), execute, query_)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Helpers (insertRawMessage, requireJust, testTime, truncateAll, withDb, withDbLog)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.MediaMissing
import Max.Effects.Http (runHttp)
import Max.Effects.PlatformQuery (runPlatformQuery)
import Max.FetchQueue
import Max.Forward (forwardWorker)
import Max.HttpRuntime (httpRuntimeFromManagers)
import Max.IR qualified as IR
import Max.Images (enqueueImages, imageWorker)
import Max.Platform (PlatformBackend (..))
import Max.Platform.Rpc (platformRouter)
import Max.Platform.Store (loadDispatchMessage)
import Max.Platform.Types (CanonicalMessageId (..))
import Network.HTTP.Client (defaultManagerSettings, newManager)
import Network.HTTP.Types (status200)
import Network.Wai (responseLBS)
import Network.Wai.Handler.Warp (testWithApplication)
import OneBot.Action (Response (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "missing media discovery" $ do
  it "checks each canonical attachment and requires explicit forward completion" $ do
    mid <- source pool 11 True [IR.NText "caption", media IR.MImage, media IR.MVideo, fileNode, forwardNode]
    let missing = snd <$> withDb pool (missingMediaMessages 0)
        job = ForwardJob mid "chain" 100 1000
    missing `shouldReturn` [(CanonicalMessageId mid, True)]
    withConn pool $ \c -> do
      _ <- execute c "INSERT INTO images(sha256,mime_type,bytes_size,local_path) VALUES ('image','image/png',1,'fixture')" ()
      _ <- execute c "INSERT INTO videos(sha256,mime_type,bytes_size,local_path) VALUES ('video','video/mp4',1,'fixture')" ()
      -- The image belongs at canonical node 1, not original segment 0.
      _ <- execute c "INSERT INTO message_images(canonical_message_id,seg_index,sha256) VALUES (?,0,'image')" (Only mid)
      _ <- execute c "INSERT INTO message_videos(canonical_message_id,seg_index,sha256) VALUES (?,2,'video')" (Only mid)
      _ <- execute c "INSERT INTO group_files(file_id,group_id,sender_user_id,file_name,sha256) VALUES ('file-id',100,3001,'fixture.txt','file')" ()
      pure ()
    withDb pool (recordForwardExpansion job 0)
    missing `shouldReturn` [(CanonicalMessageId mid, True)]
    _ <- withConn pool $ \c -> execute c "UPDATE message_images SET seg_index=1 WHERE canonical_message_id=?" (Only mid)
    missing `shouldReturn` []

  it "fetches media inside imported forwards without reopening nested forward chains" $ do
    mid <- source pool 12 False [forwardNode]
    withDb pool (missingMediaMessages 0) `shouldReturn` (mid, [])
    setBody pool mid [media IR.MImage, forwardNode]
    withDb pool (missingMediaMessages 0) `shouldReturn` (mid, [(CanonicalMessageId mid, False)])

  it "advances over text-only pages and rediscovers late commits on a fresh sweep" $ do
    late <- source pool 1 True [IR.NText "not yet visible as media"]
    forM_ [2 .. 130] $ \i -> insertRawMessage pool i 100 3001 1000 testTime Nothing "text"
    (first, missing) <- withDb pool (missingMediaMessages 0)
    missing `shouldBe` []
    first `shouldBe` 128
    (lastId, tailMissing) <- withDb pool (missingMediaMessages first)
    lastId `shouldBe` 130
    tailMissing `shouldBe` []
    setBody pool late [media IR.MImage]
    withDb pool (missingMediaMessages lastId) `shouldReturn` (lastId, [])
    snd <$> withDb pool (missingMediaMessages 0) `shouldReturn` [(CanonicalMessageId late, True)]

  it "downloads a discovered image at its canonical position without writing a SQL job" $
    testWithApplication (pure (\_ respond -> respond (responseLBS status200 [("Content-Type", "image/png")] "fixture image bytes"))) $ \port -> do
      let url = "http://127.0.0.1:" <> T.pack (show port) <> "/image"
      mid <- source pool 14 True [IR.NText "caption", IR.NMedia (IR.mediaRemoteRef url) (meta IR.MImage)]
      signal <- newFetchSignal
      message <- withDb pool (loadDispatchMessage (CanonicalMessageId mid)) >>= requireJust "media source"
      runEff (enqueueImages MissingFetch signal message)
      manager <- newManager defaultManagerSettings
      let runtime = httpRuntimeFromManagers manager manager manager
      withAsync (withDbLog pool . runConcurrent . runHttp runtime $ imageWorker 2 signal) $ \_ -> do
        timeout 3_000_000 (waitUntil $ isJust <$> withDb pool (storedMedia MediaImage mid 1)) `shouldReturn` Just ()
        withDb pool (storedMedia MediaImage mid 0) `shouldReturn` Nothing
        snd <$> withDb pool (missingMediaMessages 0) `shouldReturn` []
        withConn pool (\c -> query_ c "SELECT count(*) FROM fetch_jobs") `shouldReturn` [Only (0 :: Int)]

  it "records an empty forward response as complete, for later discovery" $ do
    mid <- source pool 15 True [forwardNode]
    let job = ForwardJob mid "chain" 100 1000
        backend = PlatformBackend "qq" "fixture" (\_ -> fail "unexpected send") (\_ _ -> pure (Right (Response "ok" 0 (object ["messages" .= ([] :: [Value])]) "test")))
    signal <- newFetchSignal
    runEff (enqueueFetch signal MissingFetch JobForward "chain" job)
    withAsync (withDbLog pool . runPlatformQuery (platformRouter backend (pure [])) $ forwardWorker signal) $ \_ ->
      timeout 3_000_000 (waitUntil $ withDb pool (forwardExpanded job)) `shouldReturn` Just ()
    snd <$> withDb pool (missingMediaMessages 0) `shouldReturn` []

source :: DbPool -> Int64 -> Bool -> [IR.Node 'IR.Canonical] -> IO Int64
source pool native topLevel nodes = do
  mid <- insertRawMessage pool native 100 3001 1000 testTime Nothing "media fixture"
  setBody pool mid nodes
  if topLevel
    then pure ()
    else withConn pool $ \c -> do
      _ <- execute c "UPDATE messages SET source_native_event_id='forward:parent:0' WHERE canonical_message_id=?" (Only mid)
      pure ()
  pure mid

setBody :: DbPool -> Int64 -> [IR.Node 'IR.Canonical] -> IO ()
setBody pool mid nodes = withConn pool $ \c -> do
  _ <- execute c "UPDATE messages SET canonical_content=? WHERE canonical_message_id=?" (toJSON (IR.Body nodes), mid)
  pure ()

meta :: IR.MediaKind -> IR.MediaMeta
meta kind = IR.MediaMeta kind Nothing Nothing Nothing Nothing Nothing

media :: IR.MediaKind -> IR.Node 'IR.Canonical
media kind = IR.NMedia (IR.mediaRemoteRef "https://example.test/media") (meta kind)

fileNode, forwardNode :: IR.Node 'IR.Canonical
fileNode = IR.NMedia Nothing (IR.MediaMeta IR.MFile Nothing Nothing Nothing Nothing (Just rawFile))
  where
    rawFile = object ["type" .= ("file" :: Text), "data" .= object ["file" .= ("file-id" :: Text), "name" .= ("fixture.txt" :: Text)]]
forwardNode = IR.NForward (IR.ForwardRef "chain" Nothing)

waitUntil :: IO Bool -> IO ()
waitUntil action = action >>= \done -> if done then pure () else threadDelay 10_000 >> waitUntil action
