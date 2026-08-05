module Max.HistorianSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (minutesToTimeZone)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (IOE, liftIO, runEff)
import Effectful.PostgreSQL (WithConnection, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertMessageWithCanonicalId, insertRawMessageAtSeq, requireJust, testTime, truncateAll, withDb, withDbLog)
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
import Max.EpisodeStore
import Max.Historian
  ( CaptureProcessResult (..),
    healOldestCoverageGap,
    historianPromptVersion,
    historianSchemaVersion,
    processCaptureLease,
  )
import Max.Tasks (newTaskRegistry)
import Max.Util (tshow)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Historian v2 worker core" $ do
  it "persists the raw structured response and atomically publishes its capture" $ do
    insertMessageWithCanonicalId pool 1001 groupId member botId testTime Nothing "Alice likes green tea"
    insertMessageWithCanonicalId pool 1002 groupId botId botId testTime Nothing "Max acknowledges"
    memberPrincipal <- principalFor pool member
    end <- latestCursor pool
    let scope = conversationScopeFor (GroupId groupId)
        request =
          CaptureRequest
            { requestReason = CaptureIdle,
              requestHistorianProfile = "historian-test",
              requestPromptVersion = historianPromptVersion,
              requestSchemaVersion = historianSchemaVersion
            }
    _ <- withDb pool $ enqueueCaptureRun scope (MessageCursor 0) end request
    lease <- withDb pool (claimCaptureRun "test-worker" 600) >>= requireJust "capture lease"
    tasks <- newTaskRegistry

    result <-
      runEff
        . runWithConnectionPool pool
        . runLLMWith (fakeHistorian memberPrincipal (rawCapture memberPrincipal))
        $ processCaptureLease 16_000 600 (minutesToTimeZone 480) tasks lease
    result `shouldSatisfy` \case CapturePublished _ -> True; _ -> False

    rows <-
      withDb pool $
        query
          "SELECT status, raw_output, parsed_output->>'episode_kind' FROM episode_capture_runs"
          ()
    (rows :: [(Text, Maybe Text, Maybe Text)])
      `shouldBe` [("published", Just (rawCapture memberPrincipal), Just "max_interaction")]
    withDb pool (loadCursor scope historianCursor) `shouldReturn` end
    compartments <- withDb pool $ query "SELECT summary_p1, summary_p3 FROM conversation_compartments WHERE state = 'active'" ()
    (compartments :: [(Text, Text)])
      `shouldBe` [("Alice said she likes green tea; Max acknowledged it.", "Alice's green-tea preference was acknowledged.")]

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
      withDbLog pool (healOldestCoverageGap (minutesToTimeZone 480) "historian-test" 16_000 scope)
        >>= requireJust "coverage heal run"
    healed.crReason `shouldBe` "backfill"
    healed.crExpectedCursor `shouldBe` end2
    healed.crRange.srStart `shouldBe` MessageCursor 3
    healed.crRange.srEnd `shouldBe` MessageCursor 3
    -- Idempotent: a second heal round returns the same durable run.
    again <-
      withDbLog pool (healOldestCoverageGap (minutesToTimeZone 480) "historian-test" 16_000 scope)
        >>= requireJust "repeat heal run"
    again.crId `shouldBe` healed.crId

    -- Publishing the healed island completes coverage; the live cursor and
    -- the neighbouring compartments stay untouched.
    lease <- withDb pool (claimCaptureRun "heal-worker" 600) >>= requireJust "heal lease"
    lease.leaseRun.crId `shouldBe` healed.crId
    source <- withDb pool $ loadCaptureSource healed
    validated <- requireValid healed source (rangeCapture [1003])
    _ <- withDb pool $ recordCaptureGenerated lease "raw heal capture" (rangeCapture [1003]) []
    _ <- withDb pool $ publishCaptureRun scope lease validated
    withDb pool (loadCursor scope historianCursor) `shouldReturn` MessageCursor 4
    withDb pool (findOldestBackfillGap scope) `shouldReturn` Nothing
    withDbLog pool (healOldestCoverageGap (minutesToTimeZone 480) "historian-test" 16_000 scope)
      `shouldReturn` Nothing
    ranges <- withDb pool $ query "SELECT start_ingest_seq, end_ingest_seq FROM conversation_compartments WHERE state = 'active' ORDER BY start_ingest_seq" ()
    (ranges :: [(Int64, Int64)]) `shouldBe` [(1, 2), (3, 3), (4, 4)]

-- | Direct capture publication without a model call: enqueue, claim,
-- validate a canned capture over @evidence@, publish.
publishRange :: DbPool -> ConversationScope -> MessageCursor -> MessageCursor -> [Int64] -> IO ()
publishRange pool scope expected end evidence = do
  let request =
        CaptureRequest
          { requestReason = CaptureIdle,
            requestHistorianProfile = "historian-test",
            requestPromptVersion = historianPromptVersion,
            requestSchemaVersion = historianSchemaVersion
          }
  run <- withDb pool (enqueueCaptureRun scope expected end request) >>= requireJust "capture run"
  lease <- withDb pool (claimCaptureRun "range-worker" 600) >>= requireJust "range lease"
  lease.leaseRun.crId `shouldBe` run.crId
  source <- withDb pool $ loadCaptureSource run
  validated <- requireValid run source (rangeCapture evidence)
  _ <- withDb pool $ recordCaptureGenerated lease "raw range capture" (rangeCapture evidence) []
  _ <- withDb pool $ publishCaptureRun scope lease validated
  pure ()

rangeCapture :: [Int64] -> EpisodeCapture
rangeCapture ids =
  EpisodeCapture
    { captureSummaryP1 = CitedSummary "full summary" ids,
      captureSummaryP2 = CitedSummary "compact summary" (take 1 ids),
      captureSummaryP3 = CitedSummary "anchor" (take 1 (reverse ids)),
      captureImportance = 0.5,
      captureConfidence = 0.9,
      captureEpisodeKind = Ambient,
      captureMemoryProposals = []
    }

requireValid :: CaptureRun -> [LedgerItem] -> EpisodeCapture -> IO ValidatedEpisodeCapture
requireValid run source capture = case validateEpisodeCapture run source capture of
  Right validated -> pure validated
  Left errors -> expectationFailure (show errors) >> error "invalid capture"

fakeHistorian :: Int64 -> Text -> LLMInterpreter '[WithConnection, IOE]
fakeHistorian memberPrincipal raw =
  LLMInterpreter
    { liChat = \ctx profile messages tools sink -> do
        liftIO $ do
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
  "{\"summary_p1\":{\"text\":\"Alice said she likes green tea; Max acknowledged it.\",\"evidence_message_ids\":[1001,1002]},\"summary_p2\":{\"text\":\"Alice likes green tea.\",\"evidence_message_ids\":[1001]},\"summary_p3\":{\"text\":\"Alice's green-tea preference was acknowledged.\",\"evidence_message_ids\":[1001,1002]},\"importance\":0.7,\"confidence\":0.95,\"episode_kind\":\"max_interaction\",\"memory_proposals\":[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":"
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
