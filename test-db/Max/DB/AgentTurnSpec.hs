module Max.DB.AgentTurnSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket, try)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sort)
import Data.Maybe (isJust)
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
import Max.DB.Connection (DbPool, withConn)
import Max.DB.TurnContinuity
import Max.Effects.Blob (Blob, runBlob)
import Max.IR (Body (..), Node (NText))
import Max.Platform.Store (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion)
import Max.Turn.Continuity (TurnDigest (..), currentPromptMajor, renderContinuationDigest)
import Max.Turn.Types
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
      withDbBlob
        pool
        blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) Nothing largeHandle)
        `shouldReturn` Just largeValue
      withDbBlob
        pool
        blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) Nothing inlineHandle)
        `shouldReturn` Just (object ["ok" .= True])
      withDbBlob
        pool
        blobRoot
        (resolveJournalResultValue (conversationScopeFor other.fxGroup) Nothing largeHandle)
        `shouldReturn` Nothing
      future <- addUTCTime 1 <$> getCurrentTime
      withDbBlob
        pool
        blobRoot
        (resolveJournalResultValue (conversationScopeFor fixture.fxGroup) (Just future) largeHandle)
        `shouldReturn` Nothing

      storageRows <- withConn pool $ \connection ->
        query
          connection
          "SELECT result_inline IS NULL, result_blob_sha256 IS NOT NULL \
          \ FROM execution_journal WHERE journal_id = ?"
          (Only noteAndFirst.jeJournalId)
      (storageRows :: [(Bool, Bool)]) `shouldBe` [(True, True)]

  it "persists bounded working checkpoints without changing task authority" $ do
    fixture <- createFixture pool 42 1001
    other <- createFixture pool 43 1002
    withDb pool (readWorkingContext fixture.fxTurn) `shouldReturn` ""
    withDb pool (writeWorkingContext fixture.fxTurn "goal / correction / pending; t#1" 900 1000)
    withDb pool (readWorkingContext fixture.fxTurn) `shouldReturn` "goal / correction / pending; t#1"
    withDb pool (readWorkingContext other.fxTurn) `shouldReturn` ""
    withDb pool (writeWorkingContext fixture.fxTurn "latest" 800 1000)
    withDb pool (readWorkingContext fixture.fxTurn) `shouldReturn` "latest"

  it "expands spilled results by local call id with bounded pages and scope/clear guards" $ do
    fixture <- createFixture pool 42 1001
    withTemporaryBlobRoot $ \root -> do
      execution <- withDb pool (startJournalExecution fixture.fxTurn (journalStart "original" "read"))
      withDbBlob pool root (finishJournalExecution execution (JournalSucceeded (String (T.replicate 20000 "汉"))))
      let readPage scope cleared = expandJournalResult scope cleared "t#1" (Just "original") Nothing 500
      Just (Object page) <- withDbBlob pool root (readPage (conversationScopeFor fixture.fxGroup) Nothing)
      KeyMap.lookup "has_more" page `shouldBe` Just (Bool True)
      KeyMap.lookup "text" page `shouldSatisfy` (\case Just (String t) -> T.length t == 500; _ -> False)
      withDbBlob pool root (readPage (conversationScopeFor (GroupId 43)) Nothing) `shouldReturn` Nothing
      cleared <- getCurrentTime
      withDbBlob pool root (readPage (conversationScopeFor fixture.fxGroup) (Just cleared)) `shouldReturn` Nothing
      _ <- withDb pool (startJournalExecution fixture.fxTurn (journalStart "original" "read"))
      withDbBlob pool root (readPage (conversationScopeFor fixture.fxGroup) Nothing) `shouldReturn` Nothing

  it "reclaims an interrupted effect exactly once without treating it as retryable" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-crash" "send_file_from_sandbox")
    first <- withDb pool reclaimInterruptedTurns
    first `shouldBe` ReclaimedTurns 1 1
    second <- withDb pool reclaimInterruptedTurns
    second `shouldBe` noReclaimedTurns
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (rows :: [(Text, Text, Maybe Text)])
      `shouldBe` [("crashed", "outcome-unknown", Just "process_restart")]
    withDb pool reclaimInterruptedTurns `shouldReturn` noReclaimedTurns

  it "closes a dangling started effect atomically with a terminal turn" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-cancel" "sandbox_exec")
    withDb pool $
      finishAgentTurn fixture.fxTurn TurnAborted 1 (Just "cancelled")
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (rows :: [(Text, Text, Maybe Text)])
      `shouldBe` [("aborted", "outcome-unknown", Just "turn_terminal")]
    withDb pool reclaimInterruptedTurns
      `shouldReturn` noReclaimedTurns

  it "ends an asynchronously interrupted turn without restarting it" $ do
    fixture <- createFixture pool 42 1001
    execution <-
      withDb pool $
        startJournalExecution fixture.fxTurn (journalStart "call-shutdown" "sandbox_exec")
    withDb pool $
      ensureAgentTurnCrashed fixture.fxTurn "shutdown drain timed out"
    suspended <- withConn pool $ \connection ->
      query
        connection
        "SELECT t.status, j.state, j.failure_code \
        \ FROM agent_turns t JOIN execution_journal j USING (turn_id) \
        \ WHERE j.journal_id = ?"
        (Only execution.jeJournalId)
    (suspended :: [(Text, Text, Maybe Text)])
      `shouldBe` [("crashed", "outcome-unknown", Just "turn_terminal")]
    reclaimed <- withDb pool reclaimInterruptedTurns
    reclaimed `shouldBe` noReclaimedTurns
    withDb pool (markAgentTurnRunning fixture.fxTurn "test-profile")
    status <- withConn pool $ \connection ->
      query connection "SELECT status FROM agent_turns WHERE turn_id = ?" (Only fixture.fxTurn.atrTurnId)
    (status :: [Only Text]) `shouldBe` [Only "crashed"]

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

    reclaimed <- withDb pool reclaimInterruptedTurns
    reclaimed.rrTurnsCrashed `shouldBe` 1
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

    duplicate <- try @SqlError (withDb pool (enqueueOutbound draft))
    duplicate `shouldSatisfy` isLeft
    afterDuplicate <- withConn pool $ \connection ->
      query connection "SELECT count(*) FROM messages WHERE agent_turn_id = ?" (Only fixture.fxTurn.atrTurnId)
    (afterDuplicate :: [Only Int64]) `shouldBe` [Only 1]

  it "publishes usage and terminal status idempotently without a wire archive" $ do
    fixture <- createFixture pool 42 1001
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
      ensureAgentTurnCrashed fixture.fxTurn "late finalizer"
    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT status, llm_turns, prompt_tokens, completion_tokens, cached_prompt_tokens, \
        \       trace_archive_sha256, trace_archive_size_bytes, abort_reason \
        \ FROM agent_turns WHERE turn_id = ?"
        (Only fixture.fxTurn.atrTurnId)
    (rows :: [(Text, Int, Int64, Int64, Int64, Maybe Text, Maybe Int64, Maybe Text)])
      `shouldBe` [("succeeded", 2, 125, 25, 40, Nothing, Nothing, Nothing)]

  it "host-enriches sandbox started input with durable network mode and defaults" $ do
    fixture <- createFixture pool 42 1001
    _ <- withConn pool $ \connection ->
      execute
        connection
        "INSERT INTO sandboxes \
        \ (conversation_id, sandbox_handle, container_name, volume_name, image, network_mode, status) \
        \ SELECT conversation_id, 's77', 'max-sb-42-s77', 'max-sb-42-s77-data', \
        \        'max-sandbox:latest', 'max-sandbox', 'active' \
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
        KeyMap.lookup "_max_host_network_mode" fields `shouldBe` Just (String "max-sandbox")
        KeyMap.lookup "timeout_seconds" fields `shouldBe` Just (Number 30)
        KeyMap.lookup "packages" fields `shouldBe` Just (Array mempty)
      other -> expectationFailure ("expected enriched object, got " <> show other)

    forM_ ["maxops", "max-sandbox"] $ \network -> do
      changed <- withConn pool $ \connection ->
        execute connection "UPDATE sandboxes SET network_mode = ? WHERE sandbox_handle = 's77'" (Only (network :: Text))
      changed `shouldBe` 1
      adopted <- withDb pool (enrichSandboxJournalStart fixture.fxGroup forged)
      case adopted.jsInput of
        Object fields -> KeyMap.lookup "_max_host_network_mode" fields `shouldBe` Just (String network)
        other -> expectationFailure ("expected adopted network, got " <> show other)

  it "restores only successful host skill receipts from the same execution" $ do
    fixture <- createFixture pool 42 1001
    independent <- createFixture pool 42 1002
    let instructions = "full skill instructions"
        load = SkillLoad "web" (skillLoadVersion instructions) instructions Nothing Nothing
    execution <- withDb pool $ startJournalExecution fixture.fxTurn (journalStart "skill" "use_skill")
    forged <- withDb pool $ startJournalExecution independent.fxTurn (journalStart "forged" "echo")
    withTemporaryBlobRoot $ \blobRoot -> withDbBlob pool blobRoot $ do
      finishJournalExecution
        execution
        ( JournalSucceeded
            ( object
                [ "instructions" .= instructions,
                  "_max_journal_observed_manifest" .= object ["skill_loads" .= [load]]
                ]
            )
        )
      finishJournalExecution forged (JournalSucceeded (object ["skill_loads" .= [load]]))
    withDb pool (readSkillLoads fixture.fxTurn) `shouldReturn` [load]
    withDb pool (readSkillLoads independent.fxTurn) `shouldReturn` []

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
      finishAgentTurn fixture.fxTurn TurnSucceeded 2 Nothing
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
      finishAgentTurn source.fxTurn TurnSucceeded 1 Nothing

    currentAt <- getCurrentTime
    -- Both rows deliberately share a timestamp.  received_at bounds used to
    -- omit the ambient row; canonical ingest order must retain it.
    _ <- insertRawMessage pool 1004 42 2042 9 currentAt (Just "Bob") "same timestamp ambient"
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
    rendered `shouldSatisfy` T.isInfixOf "same timestamp ambient"

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
noReclaimedTurns = ReclaimedTurns 0 0
