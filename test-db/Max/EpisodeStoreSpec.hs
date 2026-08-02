module Max.EpisodeStoreSpec (spec) where

import Control.Exception (SomeException)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute)
import Effectful.PostgreSQL (query)
import Helpers (insertRawKind, insertRawMessage, truncateAll, withDb)
import Max.ContextMaterialization
import Max.ConversationScope (ConversationScope, conversationScopeFor, currentConversationRecall)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.ConversationCursor (advanceCursor, historianCursor, loadCursor)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..))
import Max.EpisodeStore
import Max.MemoryStore (MemoryId, MemoryVersion)
import OneBot.Types (GroupId (..))
import Test.Hspec

groupA, groupB, member, botId :: Int64
groupA = 100
groupB = 101
member = 2001
botId = 1000

scopeA :: ConversationScope
scopeA = conversationScopeFor (GroupId groupA)

scopeB :: ConversationScope
scopeB = conversationScopeFor (GroupId groupB)

request :: CaptureReason -> CaptureRequest
request reason =
  CaptureRequest
    { requestReason = reason,
      requestHistorianProfile = "historian-test",
      requestPromptVersion = "historian/v1",
      requestSchemaVersion = 1
    }

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.EpisodeStore" $ do
  it "enqueues one idempotent exact range including non-transcript ledger rows" $ do
    insertRawMessage pool 1001 groupA member botId testTime Nothing "hello"
    insertRawKind pool "command" 1002 groupA member botId testTime Nothing "!status"
    insertRawMessage pool 1003 groupA botId botId testTime Nothing "answer"
    withConn pool $ \conn -> do
      _ <- execute conn "UPDATE messages SET is_synthetic = true WHERE message_id = ?" (Only (1003 :: Int64))
      pure ()
    end <- latestCursor pool

    first <- withDb pool $ enqueueCaptureRun scopeA (MessageCursor 0) end (request CaptureIdle)
    replay <- withDb pool $ enqueueCaptureRun scopeA (MessageCursor 0) end (request CaptureIdle)
    first `shouldSatisfy` (/= Nothing)
    fmap (.crId) replay `shouldBe` fmap (.crId) first
    fmap ((.srMessageCount) . (.crRange)) first `shouldBe` Just 3

    run <- requireJust "capture run" first
    source <- withDb pool $ loadCaptureSource run
    map (.transcriptEligible) source `shouldBe` [True, False, True]

  it "leases with attempts and does not reclaim a failed run before its retry deadline" $ do
    insertRawMessage pool 1001 groupA member botId testTime Nothing "hello"
    end <- latestCursor pool
    _ <- withDb pool $ enqueueCaptureRun scopeA (MessageCursor 0) end (request CaptureIdle)
    first <- withDb pool (claimCaptureRun "worker-a" 60) >>= requireJust "first lease"
    first.leaseRun.crAttempt `shouldBe` 1
    withDb pool (failCaptureRun first 60 "provider unavailable" []) `shouldReturn` True
    withDb pool (claimCaptureRun "worker-b" 60) `shouldReturn` Nothing

    withConn pool $ \conn -> do
      _ <- execute conn "UPDATE episode_capture_runs SET next_retry_at = now()" ()
      pure ()
    second <- withDb pool (claimCaptureRun "worker-b" 60) >>= requireJust "retry lease"
    second.leaseRun.crAttempt `shouldBe` 2
    second.leaseOwner `shouldBe` "worker-b"
    withDb pool (abandonCaptureRun second "source changed" []) `shouldReturn` True
    withDb pool (claimCaptureRun "worker-c" 60) `shouldReturn` Nothing
    statuses <- withDb pool $ query "SELECT status, last_error FROM episode_capture_runs" ()
    (statuses :: [(Text, Maybe Text)]) `shouldBe` [("abandoned", Just "source changed")]

  it "persists an invalid raw model response for delayed retry" $ do
    insertRawMessage pool 1001 groupA member botId testTime Nothing "hello"
    end <- latestCursor pool
    _ <- withDb pool $ enqueueCaptureRun scopeA (MessageCursor 0) end (request CaptureIdle)
    lease <- withDb pool (claimCaptureRun "worker" 60) >>= requireJust "capture lease"
    let errors = [CaptureValidationError "response" "invalid JSON"]
    withDb pool (recordCaptureRejected lease 60 "parse failed" "not json" errors)
      `shouldReturn` True
    rows <-
      withDb pool $
        query
          "SELECT status, raw_output, parsed_output IS NULL, jsonb_array_length(validation_errors) \
          \ FROM episode_capture_runs"
          ()
    (rows :: [(Text, Maybe Text, Bool, Int)])
      `shouldBe` [("failed", Just "not json", True, 1)]

  it "atomically publishes summaries, citations, memory proposals, and the cursor" $ do
    seedConversation pool
    lease <- prepareLease pool
    source <- withDb pool $ loadCaptureSource lease.leaseRun
    let capture = validCapture [1001, 1002, 1003] [ProposalAdd "user" (Just member) "Alice prefers tea" (Just "preference") [1001]]
    validated <- requireValid lease.leaseRun source capture
    withDb pool (recordCaptureGenerated lease (captureJson capture) capture []) `shouldReturn` True
    compartment <- withDb pool $ publishCaptureRun scopeA lease validated

    active <- withDb pool $ listActiveCompartments scopeA
    map (.activeCompartmentId) active `shouldBe` [compartment]
    map ((.srMessageCount) . (.activeRange)) active `shouldBe` [3]
    withDb pool (loadCursor scopeA historianCursor)
      `shouldReturn` lease.leaseRun.crRange.srEnd

    citations <-
      withDb pool $
        query
          "SELECT summary_tier, source_message_id, source_principal_id \
          \ FROM compartment_evidence ORDER BY summary_tier, source_message_id"
          ()
    (citations :: [(Text, Int64, Int64)])
      `shouldBe` [ ("p1", 1001, member),
                   ("p1", 1002, member),
                   ("p1", 1003, botId),
                   ("p2", 1001, member),
                   ("p2", 1003, botId),
                   ("p3", 1003, botId)
                 ]

    handle <- case active of
      compartment' : _ -> pure compartment'.activeExpandHandle
      [] -> expectationFailure "expected active compartment" >> error "missing compartment"
    firstPage <-
      withDb pool (expandEpisode (currentConversationRecall scopeA) handle Nothing 2)
        >>= requireJust "first expansion page"
    map (\(entry :: LedgerItem) -> entry.history.messageId) firstPage.expansionMessages
      `shouldBe` ([1001, 1002] :: [Int64])
    firstPage.expansionHasMore `shouldBe` True
    firstPage.expansionSourceHashMatches `shouldBe` True
    firstPage.expansionState `shouldBe` "active"

    secondPage <-
      withDb pool (expandEpisode (currentConversationRecall scopeA) handle firstPage.expansionNextCursor 2)
        >>= requireJust "second expansion page"
    map (\(entry :: LedgerItem) -> entry.history.messageId) secondPage.expansionMessages
      `shouldBe` ([1003] :: [Int64])
    secondPage.expansionHasMore `shouldBe` False
    secondPage.expansionNextCursor `shouldBe` Nothing

    crossScope <- withDb pool (expandEpisode (currentConversationRecall scopeB) handle Nothing 100)
    crossScope `shouldSatisfy` isNothing

    outcomes <-
      withDb pool $
        query
          "SELECT outcome, memory_id, memory_version FROM episode_memory_proposals"
          ()
    (outcomes :: [(Text, Maybe MemoryId, Maybe MemoryVersion)])
      `shouldSatisfy` \case [("applied", Just _, Just _)] -> True; _ -> False

    evidence <-
      withDb pool $
        query
          "SELECT evidence_kind, source_conversation_id, source_episode_id FROM memory_evidence"
          ()
    (evidence :: [(Text, Maybe Int64, Maybe Int64)])
      `shouldBe` [("episode", Just groupA, Just compartment.unCompartmentId)]

  it "publishes valid history while recording invalid memory proposals" $ do
    seedConversation pool
    lease <- prepareLease pool
    source <- withDb pool $ loadCaptureSource lease.leaseRun
    let capture =
          validCapture
            [1001, 1002, 1003]
            [ ProposalAdd "group" Nothing "valid group fact" (Just "group_convention") [1001],
              ProposalAdd "user" (Just member) "unsafe inferred relationship" (Just "relationship_context") [1001]
            ]
    validated <- requireValid lease.leaseRun source capture
    withDb pool (recordCaptureGenerated lease (captureJson capture) capture (captureValidationWarnings validated))
      `shouldReturn` True
    _ <- withDb pool $ publishCaptureRun scopeA lease validated

    outcomes <-
      withDb pool $
        query
          "SELECT proposal_index, outcome, outcome_reason IS NOT NULL \
          \ FROM episode_memory_proposals ORDER BY proposal_index"
          ()
    (outcomes :: [(Int, Text, Bool)])
      `shouldBe` [(0, "applied", False), (1, "rejected_validation", True)]
    warnings <- withDb pool $ query "SELECT jsonb_array_length(validation_errors) FROM episode_capture_runs" ()
    (warnings :: [Only Int]) `shouldBe` [Only 1]

  it "rolls the whole publication back when the source hash changes" $ do
    seedConversation pool
    lease <- prepareLease pool
    source <- withDb pool $ loadCaptureSource lease.leaseRun
    let capture = validCapture [1001, 1002, 1003] [ProposalAdd "group" Nothing "a fact" Nothing [1001]]
    validated <- requireValid lease.leaseRun source capture
    withDb pool (recordCaptureGenerated lease (captureJson capture) capture []) `shouldReturn` True
    withConn pool $ \conn -> do
      _ <- execute conn "UPDATE messages SET rendered_text = 'corrected' WHERE message_id = 1002" ()
      pure ()

    withDb pool (publishCaptureRun scopeA lease validated)
      `shouldThrow` (\(_ :: SomeException) -> True)
    withDb pool (listActiveCompartments scopeA) `shouldReturn` []
    withDb pool (loadCursor scopeA historianCursor) `shouldReturn` MessageCursor 0
    counts <- withDb pool $ query "SELECT count(*) FROM memories" ()
    (counts :: [Only Int64]) `shouldBe` [Only 0]

  it "keeps the old active compartment live until a rebuild publishes" $ do
    seedConversation pool
    firstLease <- prepareLease pool
    firstSource <- withDb pool $ loadCaptureSource firstLease.leaseRun
    let firstCapture = validCapture [1001, 1002, 1003] []
    firstValidated <- requireValid firstLease.leaseRun firstSource firstCapture
    _ <- withDb pool $ recordCaptureGenerated firstLease (captureJson firstCapture) firstCapture []
    old <- withDb pool $ publishCaptureRun scopeA firstLease firstValidated
    oldHandle <-
      withDb pool (listActiveCompartments scopeA) >>= \case
        compartment' : _ -> pure compartment'.activeExpandHandle
        [] -> expectationFailure "expected old active compartment" >> error "missing compartment"

    rebuildRun <-
      withDb pool (enqueueRebuildRun scopeA old "manual-rebuild-1" (request CaptureRebuild))
        >>= requireJust "rebuild run"
    withDb pool (enqueueRebuildRun scopeA old "manual-rebuild-duplicate" (request CaptureRebuild))
      `shouldReturn` Nothing
    rebuildLease <- withDb pool (claimCaptureRun "rebuild-worker" 60) >>= requireJust "rebuild lease"
    rebuildLease.leaseRun.crId `shouldBe` rebuildRun.crId
    map (.activeCompartmentId) <$> withDb pool (listActiveCompartments scopeA)
      `shouldReturn` [old]

    rebuildSource <- withDb pool $ loadCaptureSource rebuildLease.leaseRun
    let rebuiltCapture = (validCapture [1001, 1002, 1003] []) {captureSummaryP3 = CitedSummary "rebuilt anchor" [1003]}
    rebuiltValidated <- requireValid rebuildLease.leaseRun rebuildSource rebuiltCapture
    _ <- withDb pool $ recordCaptureGenerated rebuildLease (captureJson rebuiltCapture) rebuiltCapture []
    new <- withDb pool $ publishCaptureRun scopeA rebuildLease rebuiltValidated
    new `shouldNotBe` old
    map (.activeCompartmentId) <$> withDb pool (listActiveCompartments scopeA)
      `shouldReturn` [new]

    oldState <- withDb pool $ query "SELECT state, superseded_by FROM conversation_compartments WHERE id = ?" (Only old)
    (oldState :: [(Text, Maybe CompartmentId)]) `shouldBe` [("superseded", Just new)]
    oldExpansion <-
      withDb pool (expandEpisode (currentConversationRecall scopeA) oldHandle Nothing 100)
        >>= requireJust "superseded episode expansion"
    oldExpansion.expansionState `shouldBe` "superseded"
    map (\(entry :: LedgerItem) -> entry.history.messageId) oldExpansion.expansionMessages
      `shouldBe` ([1001, 1002, 1003] :: [Int64])

    -- Even a direct writer cannot reactivate an overlapping owner.  The
    -- database exclusion constraint is the final coverage guardrail.
    withConn pool (\conn -> execute conn "UPDATE conversation_compartments SET state = 'active', superseded_by = NULL WHERE id = ?" (Only old))
      `shouldThrow` (\(_ :: SomeException) -> True)

  it "publishes controlled legacy backfill without rewinding the live cursor" $ do
    seedConversation pool
    end <- latestCursor pool
    withDb pool (loadCursor scopeA historianCursor) `shouldReturn` MessageCursor 0
    withDb pool (advanceCursor scopeA historianCursor (MessageCursor 0) end)
      `shouldReturn` True
    run <-
      withDb pool (enqueueBackfillRun scopeA (MessageCursor 0) end (request CaptureBackfill))
        >>= requireJust "backfill run"
    lease <- withDb pool (claimCaptureRun "backfill-worker" 60) >>= requireJust "backfill lease"
    lease.leaseRun.crId `shouldBe` run.crId
    source <- withDb pool $ loadCaptureSource run
    let capture = validCapture [1001, 1002, 1003] []
    validated <- requireValid run source capture
    _ <- withDb pool $ recordCaptureGenerated lease (captureJson capture) capture []
    _ <- withDb pool $ publishCaptureRun scopeA lease validated

    withDb pool (loadCursor scopeA historianCursor) `shouldReturn` end
    map (.activeRange) <$> withDb pool (listActiveCompartments scopeA)
      `shouldReturn` [run.crRange]

  it "discovers historical gaps oldest-first without crossing an active owner" $ do
    mapM_
      (\mid -> insertRawMessage pool mid groupA member botId testTime Nothing ("message-" <> T.pack (show mid)))
      [1001 .. 1005]
    cursor3 <- cursorFor pool 1003
    end5 <- cursorFor pool 1005
    withDb pool (loadCursor scopeA historianCursor) `shouldReturn` MessageCursor 0
    withDb pool (advanceCursor scopeA historianCursor (MessageCursor 0) end5)
      `shouldReturn` True

    newer <-
      withDb pool (enqueueBackfillRun scopeA cursor3 end5 (request CaptureBackfill))
        >>= requireJust "newer backfill"
    newerLease <- withDb pool (claimCaptureRun "newer-backfill" 60) >>= requireJust "newer lease"
    newerSource <- withDb pool $ loadCaptureSource newer
    newerValidated <- requireValid newer newerSource (validCapture [1004, 1005] [])
    _ <- withDb pool $ recordCaptureGenerated newerLease (captureJson (validCapture [1004, 1005] [])) (validCapture [1004, 1005] []) []
    _ <- withDb pool $ publishCaptureRun scopeA newerLease newerValidated

    withDb pool (findOldestBackfillGap scopeA)
      `shouldReturn` Just (BackfillGap (MessageCursor 0) cursor3)

    older <-
      withDb pool (enqueueBackfillRun scopeA (MessageCursor 0) cursor3 (request CaptureBackfill))
        >>= requireJust "older backfill"
    olderLease <- withDb pool (claimCaptureRun "older-backfill" 60) >>= requireJust "older lease"
    olderSource <- withDb pool $ loadCaptureSource older
    olderValidated <- requireValid older olderSource (validCapture [1001, 1002, 1003] [])
    _ <- withDb pool $ recordCaptureGenerated olderLease (captureJson (validCapture [1001, 1002, 1003] [])) (validCapture [1001, 1002, 1003] []) []
    _ <- withDb pool $ publishCaptureRun scopeA olderLease olderValidated

    withDb pool (findOldestBackfillGap scopeA) `shouldReturn` Nothing

  it "marks a raw-message hole between independently backfilled compartments" $ do
    mapM_
      (\mid -> insertRawMessage pool mid groupA member botId testTime Nothing ("message-" <> T.pack (show mid)))
      [1001 .. 1005]
    end2 <- cursorFor pool 1002
    cursor3 <- cursorFor pool 1003
    end5 <- cursorFor pool 1005

    firstRun <-
      withDb pool (enqueueBackfillRun scopeA (MessageCursor 0) end2 (request CaptureBackfill))
        >>= requireJust "first backfill"
    firstLease <- withDb pool (claimCaptureRun "backfill-1" 60) >>= requireJust "first backfill lease"
    firstSource <- withDb pool $ loadCaptureSource firstRun
    firstValidated <- requireValid firstRun firstSource (validCapture [1001, 1002] [])
    _ <- withDb pool $ recordCaptureGenerated firstLease (captureJson (validCapture [1001, 1002] [])) (validCapture [1001, 1002] []) []
    _ <- withDb pool $ publishCaptureRun scopeA firstLease firstValidated

    secondRun <-
      withDb pool (enqueueBackfillRun scopeA cursor3 end5 (request CaptureBackfill))
        >>= requireJust "second backfill"
    secondLease <- withDb pool (claimCaptureRun "backfill-2" 60) >>= requireJust "second backfill lease"
    secondSource <- withDb pool $ loadCaptureSource secondRun
    secondValidated <- requireValid secondRun secondSource (validCapture [1004, 1005] [])
    _ <- withDb pool $ recordCaptureGenerated secondLease (captureJson (validCapture [1004, 1005] [])) (validCapture [1004, 1005] []) []
    _ <- withDb pool $ publishCaptureRun scopeA secondLease secondValidated

    active <- withDb pool $ listActiveCompartments scopeA
    map (.activeGapBefore) active `shouldBe` [False, True]
    map (.activeStartedAt) active `shouldBe` [testTime, testTime]
    map (.activeEndedAt) active `shouldBe` [testTime, testTime]
    let materialization =
          MaterializationDraft
            { mdEndCursor = (last active).activeRange.srEnd,
              mdPolicyVersion = "context-policy/v2",
              mdItems =
                [ MaterializedCompartment
                    compartment.activeCompartmentId
                    compartment.activeMaterializationVersion
                    "p2"
                | compartment <- active
                ],
              mdReason = "initial_materialization"
            }
    withDb pool (publishContextMaterialization scopeA Nothing materialization)
      `shouldThrow` (\(_ :: SomeException) -> True)

seedConversation :: DbPool -> IO ()
seedConversation pool = do
  insertRawMessage pool 1001 groupA member botId testTime Nothing "Alice: tea?"
  insertRawMessage pool 1002 groupA member botId testTime Nothing "Alice clarifies green tea"
  insertRawMessage pool 1003 groupA botId botId testTime Nothing "Max acknowledges"

prepareLease :: DbPool -> IO CaptureLease
prepareLease pool = do
  end <- latestCursor pool
  _ <- withDb pool $ enqueueCaptureRun scopeA (MessageCursor 0) end (request CaptureIdle)
  withDb pool (claimCaptureRun "worker" 120) >>= requireJust "capture lease"

latestCursor :: DbPool -> IO MessageCursor
latestCursor pool = do
  rows <- withDb pool $ query "SELECT max(ingest_seq) FROM messages WHERE group_id = ?" (Only groupA)
  case rows :: [Only (Maybe Int64)] of
    Only (Just cursor) : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "expected a latest cursor" >> pure (MessageCursor 0)

cursorFor :: DbPool -> Int64 -> IO MessageCursor
cursorFor pool messageId = do
  rows <- withDb pool $ query "SELECT ingest_seq FROM messages WHERE message_id = ?" (Only messageId)
  case rows :: [Only Int64] of
    Only cursor : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "expected message cursor" >> pure (MessageCursor 0)

validCapture :: [Int64] -> [EpisodeMemoryProposal] -> EpisodeCapture
validCapture ids proposals =
  EpisodeCapture
    { captureSummaryP1 = CitedSummary "full summary" ids,
      captureSummaryP2 = CitedSummary "compact summary" (take 1 ids <> take 1 (reverse ids)),
      captureSummaryP3 = CitedSummary "anchor" (take 1 (reverse ids)),
      captureImportance = 0.8,
      captureConfidence = 0.9,
      captureEpisodeKind = Mixed,
      captureMemoryProposals = proposals
    }

captureJson :: EpisodeCapture -> Text
captureJson = TE.decodeUtf8 . LBS.toStrict . encode

requireValid :: CaptureRun -> [LedgerItem] -> EpisodeCapture -> IO ValidatedEpisodeCapture
requireValid run source capture = case validateEpisodeCapture run source capture of
  Right validated -> pure validated
  Left errors -> expectationFailure (show errors) >> error "invalid capture"

requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
