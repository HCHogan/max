module Max.Node.RouterSpec (spec) where

import Control.Concurrent.Async (concurrently, wait, withAsync)
import Control.Concurrent.STM
import Control.Monad (forM_, replicateM_)
import Data.Aeson (Value (String))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Max.Node.Events qualified as Events
import Max.Node.Render (renderEvents)
import Max.Node.Router
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Task.Types (JobRun (..))
import Max.Tool.Media (InlineMedia (..), inlineMediaMessages)
import Max.ToolContext
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

spec :: Spec
spec = describe "node result routing" $ do
  it "keeps result attachments with their event or relay across the observation boundary" $ do
    (router, origin, _) <- fixture
    let media = [InlineMedia "result video" "data:video/mp4;base64,AA==" (Just 128)]
    atomically (deliverResult router origin "r1" (String "done") media)
    events <- atomically $ do
      observed <- Events.observe origin.target
      observeResults router origin.target observed
      pure observed
    map show (drop 1 (renderEvents events)) `shouldBe` map show (inlineMediaMessages media)
    atomically (deliverResult router origin "r2" (String "late") media >> closeTask router origin.target)
    relay <- atomically (takeRelay router)
    relay.reference `shouldBe` "r2"
    relay.media `shouldBe` media
    atomically (releaseRelay router relay)
    timeout 20000 (atomically (takeRelay router)) `shouldReturn` Nothing

  it "acknowledges event receipts rather than deleting later outcomes with the same reference" $ do
    (router, origin, _) <- fixture
    atomically (replicateM_ 201 (deliverResult router origin "same-reference" (String "done") []))
    events <- atomically (observeEvents router origin.target)
    length events `shouldBe` 200
    atomically (closeTask router origin.target)
    Just relay <- timeout 1000000 (atomically (takeRelay router))
    relay.reference `shouldBe` "same-reference"
    atomically (releaseRelay router relay)
    timeout 20000 (atomically (takeRelay router)) `shouldReturn` Nothing

  it "delivers to a live task once and does not relay an observed result" $ do
    (router, origin, _) <- fixture
    atomically (deliverResult router origin "t#1:r1" (String "done") [])
    events <- atomically $ do
      observed <- Events.observe origin.target
      observeResults router origin.target observed
      closeTask router origin.target
      pure observed
    map (.body) events `shouldBe` [Events.Settled "t#1:r1" (String "done") []]
    timeout 20000 (atomically (takeRelay router)) `shouldReturn` Nothing
    atomically (referencedOwners router) `shouldReturn` Set.empty

  it "relays an unobserved result when its task closes, regardless of arrival order" $ do
    replicateM_ 100 $ do
      (router, origin, _) <- fixture
      _ <- concurrently (atomically (deliverResult router origin "r1" (String "done") [])) (atomically (closeTask router origin.target))
      Just relay <- timeout 1000000 (atomically (takeRelay router))
      relay.value `shouldBe` String "done"
      atomically (referencedOwners router) `shouldReturn` Set.singleton (JobRun 1 1)
      atomically (releaseRelay router relay)
      atomically (referencedOwners router) `shouldReturn` Set.empty
      timeout 1000 (atomically (takeRelay router)) `shouldReturn` Nothing

  it "rechecks revocation before relay publication and frees stale capacity" $ do
    (router, origin, allowed) <- fixture
    atomically (closeTask router origin.target >> deliverResult router origin "r1" (String "done") [])
    relay <- atomically (takeRelay router)
    atomically (writeTVar allowed False)
    atomically (relayIsCurrent relay) `shouldReturn` False
    atomically (referencedOwners router) `shouldReturn` Set.empty
    atomically (releaseRelay router relay)
    atomically (deliverResult router origin "r2" (String "cancelled") [])
    timeout 20000 (atomically (takeRelay router)) `shouldReturn` Nothing

  it "retains a result under event-buffer pressure and reroutes it on closure" $ do
    (router, origin, _) <- fixture
    atomically (replicateM_ 255 (Events.deliver origin.target (Events.Steered (String "full"))))
    withAsync (atomically (deliverResult router origin "r1" (String "retained") [])) $ \producer -> do
      timeout 20000 (wait producer) `shouldReturn` Nothing
      atomically (closeTask router origin.target)
      timeout 1000000 (wait producer) `shouldReturn` Just ()
      relay <- atomically (takeRelay router)
      relay.value `shouldBe` String "retained"

  it "bounds retained results, unblocks after consumption and requeues admission races" $ do
    (router, origin, _) <- fixture
    atomically (closeTask router origin.target)
    forM_ [1 .. 1024 :: Int] $ \n -> atomically (deliverResult router origin (T.pack (show n)) (String "result") [])
    withAsync (atomically (deliverResult router origin "overflow" (String "result") [])) $ \producer -> do
      timeout 20000 (wait producer) `shouldReturn` Nothing
      relay <- atomically (takeRelay router)
      atomically (requeueRelay router relay >> releaseRelay router relay)
      retried <- atomically (takeRelay router)
      retried.identifier `shouldBe` relay.identifier
      retried.attempt `shouldBe` relay.attempt + 1
      -- An older dispatch may finish cleanup after the retry was claimed.
      atomically (releaseRelay router relay >> requeueRelay router relay)
      atomically (referencedOwners router) `shouldReturn` Set.singleton (JobRun 1 1)
      timeout 20000 (wait producer) `shouldReturn` Nothing
      atomically (releaseRelay router retried)
      timeout 1000000 (wait producer) `shouldReturn` Just ()

fixture :: IO (Router, Origin, TVar Bool)
fixture = do
  router <- newRouter
  target <- atomically (Events.newNode >>= Events.newTask)
  allowed <- newTVarIO True
  let context =
        mkToolContext
          (TurnIdentity (GroupId 1) (CanonicalMessageId 1) (UserId 1) (UserId 99) (PrincipalId 1) Nothing Nothing)
          (TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing False)
      origin = Origin (AgentTurnId 1) (Just (JobRun 1 1)) context target (readTVar allowed)
  pure (router, origin, allowed)
