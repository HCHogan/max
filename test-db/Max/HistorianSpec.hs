module Max.HistorianSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (withAsync)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime, minutesToTimeZone)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (IOE, liftIO, (:>))
import Effectful.PostgreSQL (WithConnection, query)
import Helpers (insertMessageWithCanonicalId, insertRawMessageAtSeq, requireJust, testTime, truncateAll, withDb, withDbLog)
import Max.ContextAdmin (enqueueContextRebuildAdmin)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.ConversationCursor (historianCursor, loadCursor)
import Max.DB.History (LedgerItem (..), MessageCursor (..))
import Max.Effects.LLM
  ( ChatCtx (..),
    ChatMessage (..),
    ChatResponse (..),
    LLMInterpreter (..),
    runLLMWith,
  )
import Max.EpisodeScheduler (continueEpisodeAt, newEpisodeScheduler)
import Max.EpisodeStore
import Max.Historian
  ( historianPromptVersion,
    historianSchemaVersion,
    historianWorker,
    prepareOldestCoverageGap,
  )
import Max.ModelCatalog (ModelCapabilities (..), defaultContextLimits, mkModelCatalog)
import Max.Tasks (newTaskRegistry)
import Max.Util (tshow)
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Historian v2 worker core" $ do
  it "persists the raw structured response and atomically publishes its capture" $ do
    insertMessageWithCanonicalId pool 1001 groupId member botId testTime Nothing "Alice likes green tea"
    insertMessageWithCanonicalId pool 1002 groupId botId botId testTime Nothing "Max acknowledges"
    memberPrincipal <- principalFor pool member
    end <- latestCursor pool
    let scope = conversationScopeFor (GroupId groupId)
    tasks <- newTaskRegistry
    scheduler <- newEpisodeScheduler
    catalog <- either (fail . show) pure (mkModelCatalog "historian-test" (Map.singleton "historian-test" (ModelCapabilities False False Nothing defaultContextLimits)))
    now <- getCurrentTime
    continueEpisodeAt scheduler (GroupId groupId) now
    withAsync
      ( withDbLog pool . runLLMWith (fakeHistorian memberPrincipal (rawCapture memberPrincipal)) $
          historianWorker "historian-test" 600 catalog (minutesToTimeZone 480) tasks "historian-test" scheduler
      )
      $ \_ ->
        timeout 3_000_000 (waitUntil $ (== end) <$> withDb pool (loadCursor scope historianCursor)) `shouldReturn` Just ()

    rows <-
      withDb pool $
        query
          "SELECT status, raw_output, parsed_output->>'episode_kind' FROM episode_capture_runs"
          ()
    (rows :: [(Text, Maybe Text, Maybe Text)])
      `shouldBe` [("published", Just (rawCapture memberPrincipal), Just "max_interaction")]
    withDb pool (loadCursor scope historianCursor) `shouldReturn` end
    compartments <- withDb pool $ query "SELECT summary FROM conversation_compartments WHERE state = 'active'" ()
    (compartments :: [Only Text])
      `shouldBe` [Only "Alice said she likes green tea; Max acknowledged it."]

  it "heals a commit-order skip below the live cursor without rewinding it" $ do
    let scope = conversationScopeFor (GroupId groupId)
    -- Episode one: seqs 1-2 are captured and the cursor advances to 2.
    insertMessageWithCanonicalId pool 1001 groupId member botId testTime Nothing "seq one"
    insertMessageWithCanonicalId pool 1002 groupId member botId testTime Nothing "seq two"
    end2 <- latestCursor pool
    publishRange pool scope (MessageCursor 0) end2 [1001, 1002]
    -- A concurrent handler allocated seq 3 but has not committed when the
    -- next window is scanned: the scan sees only seq 4 and publishes it.
    _ <- withDb pool $ query "SELECT setval('canonical_message_id_seq', 1003, true)" () :: IO [Only Int64]
    _ <- insertRawMessageAtSeq pool 4 1004 groupId member botId testTime (Just "Bob") "seq four"
    publishRange pool scope end2 (MessageCursor 4) [1004]
    withDb pool (loadCursor scope historianCursor) `shouldReturn` MessageCursor 4
    -- The skipped insert commits only now: at/below the cursor, owned by no
    -- active compartment.  Restart used to be the first chance to see it.
    _ <- withDb pool $ query "SELECT setval('canonical_message_id_seq', 1002, true)" () :: IO [Only Int64]
    _ <- insertRawMessageAtSeq pool 3 1003 groupId member botId testTime (Just "Bob") "late seq three"
    _ <- withDb pool $ query "SELECT setval('canonical_message_id_seq', 1004, true)" () :: IO [Only Int64]
    withDb pool (findOldestBackfillGap scope)
      `shouldReturn` Just (BackfillGap end2 (MessageCursor 3))

    healed <-
      withDbLog pool (prepareOldestCoverageGap (minutesToTimeZone 480) "historian-test" 16_000 scope)
        >>= requireJust "coverage heal run"
    healed.crReason `shouldBe` "backfill"
    healed.crExpectedCursor `shouldBe` end2
    healed.crRange.srStart `shouldBe` MessageCursor 3
    healed.crRange.srEnd `shouldBe` MessageCursor 3
    -- Each attempt reads current sources; only completed captures become rows.

    source <- withDb pool $ loadCaptureSource healed
    validated <- requireValid healed source (rangeCapture [1003])
    _ <- withDb pool $ publishCaptureRun scope healed "fixture response" validated
    withDb pool (loadCursor scope historianCursor) `shouldReturn` MessageCursor 4
    withDb pool (findOldestBackfillGap scope) `shouldReturn` Nothing
    withDbLog pool (prepareOldestCoverageGap (minutesToTimeZone 480) "historian-test" 16_000 scope)
      `shouldReturn` Nothing
    ranges <- withDb pool $ query "SELECT start_ingest_seq, end_ingest_seq FROM conversation_compartments WHERE state = 'active' ORDER BY start_ingest_seq" ()
    (ranges :: [(Int64, Int64)]) `shouldBe` [(1, 2), (3, 3), (4, 4)]

  it "runs an admin rebuild locally while retaining the old summary during generation" $ do
    insertMessageWithCanonicalId pool 1001 groupId member botId testTime Nothing "Alice likes green tea"
    insertMessageWithCanonicalId pool 1002 groupId botId botId testTime Nothing "Max acknowledges"
    let scope = conversationScopeFor (GroupId groupId)
    end <- latestCursor pool
    publishRange pool scope (MessageCursor 0) end [1001, 1002]
    [old] <- map (.activeCompartmentId) <$> withDb pool (listActiveCompartments scope)
    scheduler <- newEpisodeScheduler
    withDb pool (enqueueContextRebuildAdmin scheduler groupId (Just old) "historian-test") `shouldReturn` Right [old]
    withDb pool (query "SELECT count(*) FROM episode_capture_runs" ()) `shouldReturn` [Only (1 :: Int)]
    tasks <- newTaskRegistry
    principal <- principalFor pool member
    catalog <- either (fail . show) pure (mkModelCatalog "historian-test" (Map.singleton "historian-test" (ModelCapabilities False False Nothing defaultContextLimits)))
    started <- newEmptyMVar
    release <- newEmptyMVar
    let model = fakeHistorian principal (rawCapture principal)
        gated = LLMInterpreter $ \ctx profile messages tools sink -> do
          liftIO (putMVar started ())
          liftIO (takeMVar release)
          model.liChat ctx profile messages tools sink
    withAsync
      ( withDbLog pool . runLLMWith gated $
          historianWorker "historian-test" 600 catalog (minutesToTimeZone 480) tasks "historian-test" scheduler
      )
      $ \_ -> do
        timeout 3_000_000 (takeMVar started) `shouldReturn` Just ()
        map (.activeCompartmentId) <$> withDb pool (listActiveCompartments scope) `shouldReturn` [old]
        putMVar release ()
        timeout 3_000_000 (waitUntil $ (/= [old]) . map (.activeCompartmentId) <$> withDb pool (listActiveCompartments scope)) `shouldReturn` Just ()
    withDb pool (loadCursor scope historianCursor) `shouldReturn` end

-- | Publish a validated fixture without a model call.
publishRange :: DbPool -> ConversationScope -> MessageCursor -> MessageCursor -> [Int64] -> IO ()
publishRange pool scope expected end evidence = do
  let request =
        CaptureRequest
          { requestReason = CaptureIdle,
            requestHistorianProfile = "historian-test",
            requestPromptVersion = historianPromptVersion,
            requestSchemaVersion = historianSchemaVersion
          }
  run <- withDb pool (prepareCaptureRun scope expected end request) >>= requireJust "capture run"

  source <- withDb pool $ loadCaptureSource run
  validated <- requireValid run source (rangeCapture evidence)
  _ <- withDb pool $ publishCaptureRun scope run "fixture response" validated
  pure ()

rangeCapture :: [Int64] -> EpisodeCapture
rangeCapture ids =
  EpisodeCapture
    { captureSummary = CitedSummary "full summary" ids,
      captureImportance = 0.5,
      captureConfidence = 0.9,
      captureEpisodeKind = Ambient,
      captureMemoryProposals = []
    }

requireValid :: CaptureRun -> [LedgerItem] -> EpisodeCapture -> IO ValidatedEpisodeCapture
requireValid run source capture = case validateEpisodeCapture run source capture of
  Right validated -> pure validated
  Left errors -> expectationFailure (show errors) >> error "invalid capture"

fakeHistorian :: (WithConnection :> es, IOE :> es) => Int64 -> Text -> LLMInterpreter es
fakeHistorian memberPrincipal raw =
  LLMInterpreter
    { liChat = \ctx profile messages tools sink -> do
        rows <- query "SELECT count(*) FROM episode_capture_runs WHERE status IN ('pending','leased','generated')" ()
        liftIO $ do
          (rows :: [Only Int]) `shouldBe` [Only 0]
          ctx.ccSource `shouldBe` "historian"
          ctx.ccGroup `shouldBe` Just groupId
          ctx.ccTimeoutSeconds `shouldBe` Just 600
          ctx.ccBufferedRetryDelaysSeconds `shouldBe` Just []
          profile `shouldBe` "historian-test"
          tools `shouldSatisfy` null
          case sink of
            Nothing -> pure ()
            Just _ -> expectationFailure "historian unexpectedly used streaming"
          messages `shouldSatisfy` \case
            [MsgSystem _, MsgUser input] ->
              all (`T.isInfixOf` input) ["principal_id=" <> tshow memberPrincipal, "message_id=1001", "message_id=1002"]
            _ -> False
        pure (Right (ContentResp raw))
    }

latestCursor :: DbPool -> IO MessageCursor
latestCursor pool = do
  rows <- withDb pool $ query "SELECT max(ingest_seq) FROM messages WHERE group_id = ?" (Only groupId)
  case rows :: [Only (Maybe Int64)] of
    Only (Just cursor) : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "expected a latest cursor" >> pure (MessageCursor 0)

-- A proposal's subject is a principal since ADR 004, and it has to be the
-- principal that spoke a cited message.
rawCapture :: Int64 -> Text
rawCapture memberPrincipal =
  "{\"summary\":{\"text\":\"Alice said she likes green tea; Max acknowledged it.\",\"evidence_message_ids\":[1001,1002]},\"importance\":0.7,\"confidence\":0.95,\"episode_kind\":\"max_interaction\",\"memory_proposals\":[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":"
    <> tshow memberPrincipal
    <> ",\"content\":\"Alice likes green tea.\",\"category\":\"preference\",\"evidence_message_ids\":[1001]}]}"

groupId, member, botId :: Int64
groupId = 100
member = 2001
botId = 1000

-- | The principal behind a fixture's native (QQ) user id.
principalFor :: DbPool -> Int64 -> IO Int64
principalFor pool native = do
  rows <-
    withDb pool $
      query "SELECT principal_id FROM principal_identities WHERE native_user_id = ?" (Only (show native))
  case rows :: [Only Int64] of
    Only principal : _ -> pure principal
    [] -> expectationFailure ("no principal for native " <> show native) >> pure 0

waitUntil :: IO Bool -> IO ()
waitUntil action = action >>= \done -> if done then pure () else threadDelay 10_000 >> waitUntil action
