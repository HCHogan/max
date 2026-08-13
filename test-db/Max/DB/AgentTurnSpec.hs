module Max.DB.AgentTurnSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket, try)
import Control.Monad (forM, forM_, replicateM)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sort)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime, utc)
import Database.PostgreSQL.Simple (Only (..), SqlError, execute, query)
import Effectful (Eff, IOE, runEff)
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn
import Max.DB.TurnContinuity
import Max.DB.Connection (DbPool, withConn)
import Max.Effects.Blob (Blob, blobRefSha256, putBlob, runBlob)
import Max.IR (Body (..), Node (NText))
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types
import Max.Turn.Continuity (TurnDigest (..), currentPromptMajor, renderContinuationDigest, renderReplayDelta)
import Max.Turn.Replay (ReplayCandidate (..))
import OneBot.Types (GroupId (..))
import System.Directory
  ( createDirectory,
    getTemporaryDirectory,
    removeFile,
    removePathForcibly,
  )
import System.IO (hClose, openTempFile)
import Test.Hspec

data Fixture = Fixture
  { fxGroup :: !GroupId,
    fxTrigger :: !CanonicalMessageId,
    fxPrincipal :: !PrincipalId,
    fxTurn :: !AgentTurnRef
  }

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.DB.AgentTurn" $ do
  it "serializes concurrent turn allocation into a stable conversation ordinal" $ do
    seed <- createSeed pool 42 1001
    turns <-
      mapConcurrently
        (const (withDb pool (startAgentTurn seed.fxGroup seed.fxTrigger seed.fxPrincipal)))
        [1 .. 12 :: Int]
    sort (map (.atrTurnOrdinal) turns) `shouldBe` map TurnOrdinal [1 .. 12]
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT count(*), count(DISTINCT turn_ordinal) FROM agent_turns"
        ()
    (rows :: [(Int64, Int64)]) `shouldBe` [(12, 12)]

  it "orders journal facts, spills large results, and scopes result lookup to the conversation" $ do
    fixture <- createFixture pool 42 1001
    other <- createFixture pool 43 1002
    withTemporaryBlobRoot $ \blobRoot -> do
      noteAndFirst <- withDb pool $ do
        recordModelNote fixture.fxTurn "先检查现状"
        startJournalExecution fixture.fxTurn (journalStart "call-1" "sandbox_exec")
      noteAndFirst.jeExecutionOrdinal `shouldBe` ExecutionOrdinal 2
      second <-
        withDb pool $
          startJournalExecution fixture.fxTurn (journalStart "call-2" "fetch_url")
      second.jeExecutionOrdinal `shouldBe` ExecutionOrdinal 3

      let largeValue = String (T.replicate 20000 "x")
      withDbBlob pool blobRoot $
        finishJournalExecution noteAndFirst (JournalCommitted largeValue)
      withDbBlob pool blobRoot $
        finishJournalExecution second (JournalSucceeded (object ["ok" .= True]))

      largeEnvelope <-
        withDb pool $
          lookupJournalResultEnvelope
            (conversationScopeFor fixture.fxGroup)
            fixture.fxTurn.atrTurnOrdinal
            noteAndFirst.jeExecutionOrdinal
      case largeEnvelope of
        Nothing -> expectationFailure "large committed result was not resolvable"
        Just envelope -> do
          envelope.jreState `shouldBe` "committed"
          envelope.jreInlineValue `shouldBe` Nothing
          envelope.jreArtifactSpilled `shouldBe` True
          envelope.jreSizeBytes `shouldSatisfy` (> 16 * 1024)
          envelope.jrePreview `shouldSatisfy` maybe False (not . T.null)

      crossConversation <-
        withDb pool $
          lookupJournalResultEnvelope
            (conversationScopeFor other.fxGroup)
            fixture.fxTurn.atrTurnOrdinal
            noteAndFirst.jeExecutionOrdinal
      crossConversation `shouldBe` Nothing

      let largeHandle = resultHandleText fixture.fxTurn.atrTurnOrdinal noteAndFirst.jeExecutionOrdinal
          inlineHandle = resultHandleText fixture.fxTurn.atrTurnOrdinal second.jeExecutionOrdinal
      withDbBlob pool blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) Nothing largeHandle)
        `shouldReturn` Just largeValue
      withDbBlob pool blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) Nothing inlineHandle)
        `shouldReturn` Just (object ["ok" .= True])
      withDbBlob pool blobRoot
        (resolveJournalResultValue (conversationScopeFor other.fxGroup) Nothing largeHandle)
        `shouldReturn` Nothing
      future <- addUTCTime 1 <$> getCurrentTime
      withDbBlob pool blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) (Just future) largeHandle)
        `shouldReturn` Nothing

      storageRows <- withConn pool $ \connection ->
        query
          connection
          "SELECT result_inline IS NULL, result_blob_sha256 IS NOT NULL \
          \ FROM execution_journal WHERE journal_id = ?"
          (Only noteAndFirst.jeJournalId)
      (storageRows :: [(Bool, Bool)]) `shouldBe` [(True, True)]

  it "reclaims an interrupted effect exactly once without treating it as retryable" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-crash" "send_file_from_sandbox")
    first <- withDb pool (reclaimInterruptedTurns "boot-1")
    first
      `shouldBe` ReclaimedTurns
        { rrTurnsPendingResume = 1,
          rrTurnsCrashed = 0,
          rrExecutionsUnknown = 1,
          rrRecoveries =
            [ AgentTurnRecovery
                fixture.fxTurn
                fixture.fxGroup
                (Just fixture.fxTrigger)
                Nothing
            ]
        }
    second <- withDb pool (reclaimInterruptedTurns "boot-1")
    second `shouldBe` noReclaimedTurns
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (rows :: [(Text, Text, Maybe Text)])
      `shouldBe` [("recovery-pending", "outcome-unknown", Just "process_restart")]
    view <- withDb pool (recoveryViewForTurn fixture.fxTurn)
    view `shouldSatisfy` T.isInfixOf "[工具执行状态未知：服务重启]"
    view `shouldSatisfy` T.isInfixOf "send_file_from_sandbox"
    -- A genuinely new boot owner can reclaim a turn whose previous recovery
    -- process died before it reopened the LLM round.
    nextBoot <- withDb pool (reclaimInterruptedTurns "boot-2")
    nextBoot.rrTurnsPendingResume `shouldBe` 1

  it "closes a dangling started effect atomically with a terminal turn" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-cancel" "sandbox_exec")
    withDb pool $
      finishAgentTurn fixture.fxTurn TurnAborted 1 (Just "cancelled") Nothing
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (rows :: [(Text, Text, Maybe Text)])
      `shouldBe` [("aborted", "outcome-unknown", Just "turn_terminal")]
    withDb pool (reclaimInterruptedTurns "boot-terminal")
      `shouldReturn` noReclaimedTurns

  it "keeps an asynchronously suspended turn reclaimable for the next boot" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-shutdown" "sandbox_exec")
    withDb pool $
      ensureAgentTurnRecoveryPending fixture.fxTurn "shutdown drain timed out"
    suspended <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (suspended :: [(Text, Text, Maybe Text)])
      `shouldBe` [("recovery-pending", "outcome-unknown", Just "turn_suspended")]
    reclaimed <- withDb pool (reclaimInterruptedTurns "next-process")
    reclaimed.rrRecoveries
      `shouldBe` [AgentTurnRecovery fixture.fxTurn fixture.fxGroup (Just fixture.fxTrigger) Nothing]
    withDb pool (markAgentTurnRunning fixture.fxTurn "test-profile")
    status <- withConn pool $ \connection ->
      query connection "SELECT status FROM agent_turns WHERE turn_id = ?" (Only fixture.fxTurn.atrTurnId)
    (status :: [Only Text]) `shouldBe` [Only "running"]

  it "does not duplicate a canonical send already committed before restart" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-send" "send_message")
    let link = TurnOutputLink fixture.fxTurn.atrTurnId 0
        draft = outbound fixture link "已提交回复"
    sent <- withDb pool (enqueueOutbound draft)
    withTemporaryBlobRoot $ \blobRoot ->
      withDbBlob pool blobRoot $
        finishJournalExecution
          execution
          ( JournalCommitted
              ( object
                  [ "sent" .= True,
                    "_max_journal_canonical_message_id" .= sent.canonicalMessageId.unCanonicalMessageId
                  ]
              )
          )

    reclaimed <- withDb pool (reclaimInterruptedTurns "boot-send")
    reclaimed.rrTurnsPendingResume `shouldBe` 1
    reclaimed.rrTurnsCrashed `shouldBe` 0
    reclaimed.rrExecutionsUnknown `shouldBe` 0
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT count(*), min(agent_turn_id), min(turn_chunk_index) \
        \ FROM messages WHERE canonical_message_id = ?"
        (Only sent.canonicalMessageId.unCanonicalMessageId)
    (rows :: [(Int64, Maybe AgentTurnId, Maybe Int)])
      `shouldBe` [(1, Just fixture.fxTurn.atrTurnId, Just 0)]
    journalRows <- withConn pool $ \connection ->
      query
        connection
        "SELECT state, output_canonical_message_id FROM execution_journal WHERE journal_id = ?"
        (Only execution.jeJournalId)
    (journalRows :: [(Text, Maybe Int64)])
      `shouldBe` [("committed", Just sent.canonicalMessageId.unCanonicalMessageId)]

    recoveryView <- withDb pool (recoveryViewForTurn fixture.fxTurn)
    recoveryView `shouldSatisfy` T.isInfixOf "已提交可见输出 chunk=0"

    nextChunk <- withDb pool (nextAgentTurnOutputChunk fixture.fxTurn.atrTurnId)
    nextChunk `shouldBe` 1
    recoveredOutput <- newTurnOutputContextAt fixture.fxTurn nextChunk
    nextTurnOutputLink recoveredOutput
      `shouldReturn` TurnOutputLink fixture.fxTurn.atrTurnId 1

    duplicate <- try @SqlError (withDb pool (enqueueOutbound draft))
    duplicate `shouldSatisfy` isLeft
    afterDuplicate <- withConn pool $ \connection ->
      query connection "SELECT count(*) FROM messages WHERE agent_turn_id = ?" (Only fixture.fxTurn.atrTurnId)
    (afterDuplicate :: [Only Int64]) `shouldBe` [Only 1]

  it "reclaims the archive-write-before-checkpoint crash window" $ do
    fixture <- createFixture pool 42 1001
    withTemporaryBlobRoot $ \blobRoot -> do
      blob <- withDbBlob pool blobRoot (putBlob "wire-segment-before-checkpoint")
      archiveBefore <- withConn pool $ \connection ->
        query
          connection
          "SELECT trace_archive_sha256 FROM agent_turns WHERE turn_id = ?"
          (Only fixture.fxTurn.atrTurnId)
      (archiveBefore :: [Only (Maybe Text)]) `shouldBe` [Only Nothing]

      reclaimed <- withDb pool (reclaimInterruptedTurns "boot-after-archive-write")
      reclaimed.rrRecoveries
        `shouldBe` [AgentTurnRecovery fixture.fxTurn fixture.fxGroup (Just fixture.fxTrigger) Nothing]

      now <- getCurrentTime
      withDb pool $
        finishAgentTurn
          fixture.fxTurn
          TurnSucceeded
          2
          Nothing
          (Just (blobRefSha256 blob, 30, addUTCTime 3600 now))
      archiveAfter <- withConn pool $ \connection ->
        query
          connection
          "SELECT status, trace_archive_sha256 FROM agent_turns WHERE turn_id = ?"
          (Only fixture.fxTurn.atrTurnId)
      (archiveAfter :: [(Text, Maybe Text)])
        `shouldBe` [("succeeded", Just (blobRefSha256 blob))]

  it "publishes usage, terminal status, and trace archive metadata idempotently" $ do
    fixture <- createFixture pool 42 1001
    now <- getCurrentTime
    withDb pool $ do
      _ <- recordAgentTurnLlmRound fixture.fxTurn.atrTurnId
      _ <- recordAgentTurnLlmRound fixture.fxTurn.atrTurnId
      addAgentTurnUsage fixture.fxTurn.atrTurnId 100 20 (Just 40)
      addAgentTurnUsage fixture.fxTurn.atrTurnId 25 5 Nothing
      finishAgentTurn
        fixture.fxTurn
        TurnSucceeded
        1
        Nothing
        (Just (T.replicate 64 "a", 1234, addUTCTime 3600 now))
      ensureAgentTurnCrashed fixture.fxTurn "late finalizer"
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT status, llm_turns, prompt_tokens, completion_tokens, cached_prompt_tokens, \
        \       trace_archive_sha256, trace_archive_size_bytes, abort_reason \
        \ FROM agent_turns WHERE turn_id = ?"
        (Only fixture.fxTurn.atrTurnId)
    (rows :: [(Text, Int, Int64, Int64, Int64, Maybe Text, Maybe Int64, Maybe Text)])
      `shouldBe` [("succeeded", 2, 125, 25, 40, Just (T.replicate 64 "a"), Just 1234, Nothing)]

  it "host-enriches sandbox started input with durable network mode and defaults" $ do
    fixture <- createFixture pool 42 1001
    _ <- withConn pool $ \connection ->
      execute
        connection
        "INSERT INTO sandboxes \
        \ (conversation_id, sandbox_handle, container_name, volume_name, image, network_mode, status) \
        \ SELECT conversation_id, 's77', 'max-sb-42-s77', 'max-sb-42-s77-data', \
        \        'max-sandbox:latest', 'none', 'active' \
        \ FROM conversations WHERE legacy_group_id = 42"
        ()
    let forged =
          (journalStart "call-network" "sandbox_exec")
            { jsInput =
                object
                  [ "sandbox_id" .= ("s77" :: Text),
                    "command" .= ("curl example.test" :: Text),
                    "_max_host_network_mode" .= ("bridge" :: Text)
                  ]
            }
    enriched <- withDb pool (enrichSandboxJournalStart fixture.fxGroup forged)
    case enriched.jsInput of
      Object fields -> do
        KeyMap.lookup "_max_host_network_mode" fields `shouldBe` Just (String "none")
        KeyMap.lookup "timeout_seconds" fields `shouldBe` Just (Number 30)
        KeyMap.lookup "packages" fields `shouldBe` Just (Array mempty)
      other -> expectationFailure ("expected enriched object, got " <> show other)

  it "stores host-observed sandbox evidence separately from the tool result" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-observed" "sandbox_exec")
    let observation =
          object
            [ "command" .= ("printf done" :: Text),
              "network_mode" .= ("none" :: Text),
              "filesystem" .= object ["file_count" .= (1 :: Int)]
            ]
    withTemporaryBlobRoot $ \blobRoot ->
      withDbBlob pool blobRoot $
        finishJournalExecution
          execution
          ( JournalCommitted
              ( object
                  [ "ok" .= True,
                    "_max_journal_observed_manifest" .= observation
                  ]
              )
          )
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT result_inline, observed_manifest FROM execution_journal WHERE journal_id = ?"
        (Only execution.jeJournalId)
    (rows :: [(Maybe Value, Maybe Value)])
      `shouldBe` [(Just (object ["ok" .= True]), Just observation)]

    envelope <-
      withDb pool $
        lookupJournalResultEnvelope
          (conversationScopeFor fixture.fxGroup)
          fixture.fxTurn.atrTurnOrdinal
          execution.jeExecutionOrdinal
    fmap (.jreInlineValue) envelope
      `shouldBe` Just (Just (object ["ok" .= True]))
    view <- withDb pool (recoveryViewForTurn fixture.fxTurn)
    view `shouldSatisfy` T.isInfixOf "observation="
    view `shouldSatisfy` T.isInfixOf "file_count"

  it "projects worked turns, expands t# in scope, and obeys !clear" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-expand" "sandbox_exec")
    withTemporaryBlobRoot $ \blobRoot ->
      withDbBlob pool blobRoot $
        finishJournalExecution execution (JournalCommitted (object ["ok" .= True, "path" .= ("/work/out.png" :: Text)]))
    sent <- withDb pool (enqueueOutbound (outbound fixture (TurnOutputLink fixture.fxTurn.atrTurnId 0) "画了销量周环比图\n已保存"))
    withDb pool $ do
      setAgentTurnEnvironment fixture.fxTurn currentPromptMajor (T.replicate 64 "c")
      finishAgentTurn fixture.fxTurn TurnSucceeded 2 Nothing Nothing
    now <- getCurrentTime
    recent <- withDb pool (recentTurnDigests (conversationScopeFor fixture.fxGroup) Nothing now)
    map (.tdTurnOrdinal) recent `shouldBe` [fixture.fxTurn.atrTurnOrdinal]
    map (.tdLastOutputId) recent `shouldBe` [Just sent.canonicalMessageId.unCanonicalMessageId]

    expanded <-
      withDb pool $
        expandTurnTrace (conversationScopeFor fixture.fxGroup) Nothing fixture.fxTurn.atrTurnOrdinal Nothing 40
    expanded `shouldSatisfy` isJust

    otherSeed <- createSeed pool 43 2001
    crossConversation <-
      withDb pool $
        expandTurnTrace (conversationScopeFor otherSeed.fxGroup) Nothing fixture.fxTurn.atrTurnOrdinal Nothing 40
    crossConversation `shouldBe` Nothing

    clearedAt <- getCurrentTime
    hiddenRecent <- withDb pool (recentTurnDigests (conversationScopeFor fixture.fxGroup) (Just clearedAt) now)
    hiddenExpand <-
      withDb pool $
        expandTurnTrace (conversationScopeFor fixture.fxGroup) (Just clearedAt) fixture.fxTurn.atrTurnOrdinal Nothing 40
    hiddenReply <-
      withDb pool $
        resolveReplyTurn (conversationScopeFor fixture.fxGroup) (Just clearedAt) sent.canonicalMessageId
    (hiddenRecent, hiddenExpand, hiddenReply) `shouldBe` ([], Nothing, Nothing)

  it "resolves reply linkage, writes scoped U -> T provenance, and builds a deterministic digest delta" $ do
    source <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution source.fxTurn (journalStart "call-source" "sandbox_exec")
    withTemporaryBlobRoot $ \blobRoot ->
      withDbBlob pool blobRoot $
        finishJournalExecution execution (JournalCommitted (object ["ok" .= True]))
    sent <- withDb pool (enqueueOutbound (outbound source (TurnOutputLink source.fxTurn.atrTurnId 0) "初版完成"))
    withDb pool $ do
      setAgentTurnEnvironment source.fxTurn currentPromptMajor (T.replicate 64 "d")
      finishAgentTurn source.fxTurn TurnSucceeded 1 Nothing Nothing

    currentAt <- getCurrentTime
    currentCanonical <- insertRawMessage pool 1002 42 1042 9 currentAt (Just "Alice") "继续把图改成深色"
    [Only currentPrincipal] <- withConn pool $ \connection ->
      query connection "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only currentCanonical)
    fresh <- withDb pool (startAgentTurn source.fxGroup (CanonicalMessageId currentCanonical) (PrincipalId currentPrincipal))
    resolved <-
      withDb pool $
        resolveReplyTurn (conversationScopeFor source.fxGroup) Nothing sent.canonicalMessageId
    target <- maybe (expectationFailure "linked output did not resolve" >> error "unreachable") pure resolved
    target.rttTurn `shouldBe` source.fxTurn
    target `shouldSatisfy` replyTurnIsFinished

    inserted <-
      withDb pool $
        recordForkFrom (conversationScopeFor source.fxGroup) fresh source.fxTurn (PrincipalId currentPrincipal)
    inserted `shouldBe` True
    edgeRows <- withConn pool $ \connection ->
      query
        connection
        "SELECT from_turn_id, to_turn_id, edge_kind FROM turn_edges"
        ()
    (edgeRows :: [(AgentTurnId, AgentTurnId, Text)])
      `shouldBe` [(fresh.atrTurnId, source.fxTurn.atrTurnId, "fork-from")]

    other <- createFixture pool 43 2001
    denied <-
      withDb pool $
        recordForkFrom (conversationScopeFor source.fxGroup) fresh other.fxTurn (PrincipalId currentPrincipal)
    denied `shouldBe` False

    live <- createFixture pool 42 1003
    liveDenied <-
      withDb pool $
        recordForkFrom (conversationScopeFor source.fxGroup) fresh live.fxTurn (PrincipalId currentPrincipal)
    liveDenied `shouldBe` False

    now <- getCurrentTime
    digestView <-
      withDb pool $
        continuationDigest
          (conversationScopeFor source.fxGroup)
          Nothing
          (CanonicalMessageId currentCanonical)
          now
          currentPromptMajor
          (T.replicate 64 "d")
          target
    rendered <- maybe (expectationFailure "continuation digest missing" >> pure "") (pure . renderContinuationDigest utc) digestView
    rendered `shouldSatisfy` T.isInfixOf "host digest; no archived provider-wire replay"
    rendered `shouldSatisfy` T.isInfixOf "sandbox_exec"
    rendered `shouldSatisfy` T.isInfixOf "工具目录 无变化"

    -- One projection, two windows.  The replay tier keeps the drift note and
    -- drops the record, because the wire items above it already are the
    -- record; restating the journal there would show the same work twice.
    let replayNote = maybe "" (renderReplayDelta utc) digestView
    replayNote `shouldSatisfy` T.isInfixOf "工具目录 无变化"
    replayNote `shouldSatisfy` T.isInfixOf "原样保留"
    replayNote `shouldNotSatisfy` T.isInfixOf "sandbox_exec"
    replayNote `shouldNotSatisfy` T.isInfixOf "之前的规范化执行记录"

  it "logically evicts expired archives and enforces the per-conversation LRU cap" $ do
    seed <- createSeed pool 42 1001
    turns <-
      replicateM (52 :: Int) (withDb pool (startAgentTurn seed.fxGroup seed.fxTrigger seed.fxPrincipal))
    let base = testTime
        pruneAt = addUTCTime 1000 base
    forM_ (zip [1 ..] turns) $ \(index :: Int, turn) -> do
      let created = addUTCTime (fromIntegral index) base
          expires
            | index == 52 = addUTCTime (-1) pruneAt
            | otherwise = addUTCTime (30 * 86400) pruneAt
      _ <- withConn pool $ \connection ->
        execute
          connection
          "UPDATE agent_turns SET trace_archive_sha256=?, trace_archive_size_bytes=1, \
          \ trace_archive_created_at=?, trace_archive_expires_at=? WHERE turn_id=?"
          (T.replicate 64 "e", created, expires, turn.atrTurnId)
      pure ()
    pruned <- withDb pool (pruneTurnArchiveReferences pruneAt)
    remaining <- withConn pool $ \connection ->
      query connection "SELECT count(*) FROM agent_turns WHERE trace_archive_sha256 IS NOT NULL" ()
    pruned `shouldBe` 2
    (remaining :: [Only Int64]) `shouldBe` [Only 50]

  it "enforces the live archive cap as terminal checkpoints commit" $ do
    seed <- createSeed pool 42 1001
    turns <-
      replicateM (51 :: Int) (withDb pool (startAgentTurn seed.fxGroup seed.fxTrigger seed.fxPrincipal))
    now <- getCurrentTime
    _ <-
      mapConcurrently
        ( \turn ->
            withDb pool $
              finishAgentTurn
                turn
                TurnSucceeded
                1
                Nothing
                (Just (T.replicate 64 "f", 1, addUTCTime (14 * 86400) now))
        )
        turns
    remaining <- withConn pool $ \connection ->
      query connection "SELECT count(*) FROM agent_turns WHERE trace_archive_sha256 IS NOT NULL" ()
    (remaining :: [Only Int64]) `shouldBe` [Only 50]

  it "walks the fork chain newest first, in scope, bounded by depth" $ do
    now <- getCurrentTime
    -- t#1 ← t#2 ← t#3: each forked from the one before it, so the chain read
    -- from t#3 must come back [t#3, t#2, t#1].
    seed <- createSeed pool 44 4001
    chainTurns <- forM [1 .. 3 :: Int] $ \index -> do
      turn <- withDb pool (startAgentTurn seed.fxGroup seed.fxTrigger seed.fxPrincipal)
      withDb pool $ do
        markAgentTurnRunning turn "test-profile"
        setAgentTurnEnvironment turn currentPromptMajor (T.replicate 64 "c")
        finishAgentTurn
          turn
          TurnSucceeded
          1
          Nothing
          (Just (T.replicate 64 "a", 10, addUTCTime (14 * 86400) now))
      pure (index, turn)
    let byIndex = [(index, turn) | (index, turn) <- chainTurns]
        turnAt index =
          fromMaybe (error ("no turn at index " <> show index)) (lookup index byIndex)
    forM_ [(2, 1), (3, 2)] $ \(child, parent) -> do
      linked <-
        withDb pool $
          recordForkFrom
            (conversationScopeFor seed.fxGroup)
            (turnAt child)
            (turnAt parent)
            seed.fxPrincipal
      linked `shouldBe` True

    chain <- withDb pool (replayChain (conversationScopeFor seed.fxGroup) (turnAt 3) 8)
    map (.rcTurn) chain `shouldBe` [turnAt 3, turnAt 2, turnAt 1]
    map (.rcProfile) chain `shouldBe` replicate 3 (Just ("test-profile" :: Text))
    map (.rcPromptMajor) chain `shouldBe` replicate 3 currentPromptMajor
    map (.rcCatalogFingerprint) chain `shouldBe` replicate 3 (Just (T.replicate 64 "c"))
    map (.rcArchiveSha) chain `shouldBe` replicate 3 (Just (T.replicate 64 "a"))
    map (.rcTriggerCanonicalId) chain
      `shouldBe` replicate 3 (Just seed.fxTrigger.unCanonicalMessageId)

    -- Depth is a fuse: the suffix nearest the target survives, the rest is
    -- digest by construction.
    shallow <- withDb pool (replayChain (conversationScopeFor seed.fxGroup) (turnAt 3) 2)
    map (.rcTurn) shallow `shouldBe` [turnAt 3, turnAt 2]

    -- Eviction is what the validity predicate reads, so it must show through.
    evicted <- withDb pool (pruneTurnArchiveReferences (addUTCTime (30 * 86400) now))
    evicted `shouldSatisfy` (>= 3)
    afterPrune <- withDb pool (replayChain (conversationScopeFor seed.fxGroup) (turnAt 3) 8)
    map (.rcArchiveSha) afterPrune `shouldBe` replicate 3 Nothing

    -- Another conversation's turn is not addressable through this scope even
    -- with a valid turn id in hand.
    other <- createFixture pool 45 4501
    denied <- withDb pool (replayChain (conversationScopeFor seed.fxGroup) other.fxTurn 8)
    denied `shouldBe` []

createSeed :: DbPool -> Int64 -> Int64 -> IO Fixture
createSeed pool group messageId = do
  canonical <-
    insertRawMessage
      pool
      messageId
      group
      (group + 1000)
      9
      testTime
      (Just "Alice")
      "trigger"
  [Only principal] <- withConn pool $ \connection ->
    query
      connection
      "SELECT author_principal_id FROM messages WHERE canonical_message_id = ?"
      (Only canonical)
  pure
    Fixture
      { fxGroup = GroupId group,
        fxTrigger = CanonicalMessageId canonical,
        fxPrincipal = PrincipalId principal,
        fxTurn = AgentTurnRef (AgentTurnId 0) (TurnOrdinal 0)
      }

createFixture :: DbPool -> Int64 -> Int64 -> IO Fixture
createFixture pool group messageId = do
  seed <- createSeed pool group messageId
  turn <- withDb pool (startAgentTurn seed.fxGroup seed.fxTrigger seed.fxPrincipal)
  withDb pool (markAgentTurnRunning turn "test-profile")
  pure seed {fxTurn = turn}

journalStart :: Text -> Text -> JournalStart
journalStart callId toolRef =
  JournalStart
    { jsCallId = callId,
      jsToolRef = toolRef,
      jsSchemaVersion = 1,
      jsSchemaHash = T.replicate 64 "b",
      jsInput = object ["path" .= ("/work/result" :: Text)],
      jsEffectLabels = toJSON (["workspace-write"] :: [Text]),
      jsRetryClass = "unsafe"
    }

outbound :: Fixture -> TurnOutputLink -> Text -> OutboundDraft
outbound fixture link body =
  OutboundDraft
    { legacyConversationId = case fixture.fxGroup of GroupId raw -> raw,
      transcriptKind = "chat",
      sourceCanonicalMessageId = Just fixture.fxTrigger.unCanonicalMessageId,
      canonicalBody = Body [NText body],
      replyToCanonicalMessageId = Nothing,
      turnOutputLink = Just link,
      monitorFireId = Nothing
    }

withDbBlob :: DbPool -> FilePath -> Eff '[Blob, WithConnection, IOE] a -> IO a
withDbBlob pool root =
  runEff
    . runWithConnectionPool pool
    . runBlob root

withTemporaryBlobRoot :: (FilePath -> IO a) -> IO a
withTemporaryBlobRoot action = bracket allocate removePathForcibly action
  where
    allocate = do
      base <- getTemporaryDirectory
      (path, handle) <- openTempFile base "max-agent-turn-blobs"
      hClose handle
      removeFile path
      createDirectory path
      pure path

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

noReclaimedTurns :: ReclaimedTurns
noReclaimedTurns =
  ReclaimedTurns
    { rrTurnsPendingResume = 0,
      rrTurnsCrashed = 0,
      rrExecutionsUnknown = 0,
      rrRecoveries = []
    }
