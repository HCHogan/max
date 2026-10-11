module Max.HookSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, concurrently, withAsync)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft, isRight)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Time (addUTCTime, getCurrentTime, utc)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple qualified as PG
import Effectful.PostgreSQL (execute, query)
import Helpers (insertPendingRawMessage, insertRawMessage, insertRawMessageWithClass, testTime, truncateAll, withDb)
import Max.Context.Read (messageRef, parseReadRequest)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.AgentTurn (startAgentTurn)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.ContextRead (readContext)
import Max.DB.Files (fetchFilesForMessageInScope, insertSeen, listConversationFilesInScope)
import Max.DB.History (fetchMessageInScope)
import Max.DB.Hook qualified as DB
import Max.DB.MessageProjection (claimMessageDispatch, drainProjections, finishMessageDispatch, interruptMessageDispatches, processNextProjection)
import Max.DB.Monitor (armLedgerMatchMonitor)
import Max.DB.Transaction (withTransaction)
import Max.Effects.HookControl qualified as Control
import Max.Effects.HookQuery qualified as Query
import Max.Hook.Runtime (warmHookRuntime)
import Max.Hook.Types
import Max.Monitor.Types (LedgerMatchSpec (..))
import Max.Platform.Delivery.Queue (newDeliveryQueue)
import Max.Platform.Envelope (IngestClass (Backfill))
import Max.Platform.Ingress (newIngress, nextIngress)
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Platform.Types (CanonicalMessageId (..), DeliveryId (..), PrincipalId (..))
import Max.Recall (searchRecallFiltered)
import Max.Recall.Types (RecallFilter (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = beforeAll_ warmHookRuntime $ before_ (truncateAll pool) $ describe "message.inbound hook persistence and admission" $ do
  let scope = conversationScopeFor (GroupId 900)
      put mid sender body = insertRawMessage pool mid 900 sender 99 testTime Nothing body
      putPending mid sender body = insertPendingRawMessage pool mid 900 sender 99 testTime Nothing body
      setup = do
        mid <- put 1 1 "before"
        [Only actor] <- withDb pool (query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only mid))
        pure (mid, actor :: Int64)
      patch source = HookPatch "ignore-members" 0 (Just "message.inbound") (Just source) (Just (object [])) (Just True)
      save actor p = withDb pool (withTransaction (DB.setHook 900 actor p))
      readHook req = withDb pool (DB.queryHooks 900 req) >>= either (error . show) pure
  it "persists definitions, rejects stale updates and keeps previous versions" $ do
    (_, actor) <- setup
    first <- save actor (patch "return {action:'ignore'};")
    first `shouldSatisfy` isRight
    save actor (patch "return {action:'pass'};") >>= (`shouldSatisfy` isLeft)
    let update = HookPatch "ignore-members" 1 Nothing Nothing (Just (object ["new" .= True])) (Just False)
    (a, b) <- concurrently (save actor update) (save actor update)
    length (filter isRight [a, b]) `shouldBe` 1
    current <- readHook (HookGet "ignore-members" Nothing)
    field "revision" current `shouldBe` Number 2
    field "enabled" current `shouldBe` Bool False
    old <- readHook (HookGet "ignore-members" (Just 1))
    field "enabled" old `shouldBe` Bool True
    save actor update {hpExpected = 2, hpSource = Just "return {;"} >>= (`shouldSatisfy` isLeft)
    readHook (HookGet "ignore-members" Nothing) `shouldReturn` current
  it "blocks dispatch and context without deleting the raw message; disable applies only to new arrivals" $ do
    (old, actor) <- setup
    save actor (patch "return {action:'ignore',reason:'blocked_sender'};") >>= (`shouldSatisfy` isRight)
    ignored <- put 2 2 "hidden secret"
    withDb pool (loadDispatchMessage (CanonicalMessageId ignored)) `shouldReturn` Nothing
    withDb pool (fetchMessageInScope scope ignored) >>= (`shouldSatisfy` isNothing)
    request <- either fail pure (parseEither (parseReadRequest utc) (object ["ref" .= messageRef ignored]))
    withDb pool (readContext scope 4096 request) >>= (`shouldSatisfy` isLeft)
    withDb pool (searchRecallFiltered (currentConversationRecall scope) (RecallFilter ["message"] Nothing Nothing Nothing) "hidden secret" Nothing 10) >>= (`shouldSatisfy` null)
    withDb pool (query "SELECT m.rendered_text,NOT p.context_visible FROM messages m JOIN message_projections p USING(canonical_message_id) WHERE canonical_message_id=?" (Only ignored)) `shouldReturn` [("hidden secret" :: Text, True)]
    withDb pool (query "SELECT canonical_message_id FROM agent_messages WHERE group_id=900 ORDER BY ingest_seq" ()) `shouldReturn` [Only old]
    save actor (HookPatch "ignore-members" 1 Nothing Nothing Nothing (Just False)) >>= (`shouldSatisfy` isRight)
    visible <- put 3 2 "visible again"
    withDb pool (query "SELECT canonical_message_id FROM agent_messages WHERE group_id=900 ORDER BY ingest_seq" ()) `shouldReturn` [Only old, Only visible]
    runs <- readHook (HookRuns Nothing Nothing (Just ignored) Nothing 20)
    length (array "runs" runs) `shouldBe` 1
    map (field "message_ignored") (array "runs" runs) `shouldBe` [Bool True]
  it "simulates overrides without writes and rejects foreign messages" $ do
    (mid, actor) <- setup
    save actor (patch "return {action:args.config.ignore?'ignore':'pass'};") >>= (`shouldSatisfy` isRight)
    result <- readHook (HookTest (Just "ignore-members") Nothing Nothing (Just (object ["ignore" .= True])) (Left mid))
    field "simulation" result `shouldBe` Bool True
    field "outcome" (field "result" result) `shouldBe` String "ignore"
    runs <- readHook (HookRuns Nothing Nothing Nothing Nothing 20)
    array "runs" runs `shouldBe` []
    foreignMessage <- insertRawMessage pool 9 901 2 99 testTime Nothing "other chat"
    withDb pool (DB.queryHooks 900 (HookTest (Just "ignore-members") Nothing Nothing Nothing (Left foreignMessage))) >>= (`shouldSatisfy` isLeft)
  it "applies before monitor admission and also filters new backfill rows" $ do
    (mid, actor) <- setup
    turn <- withDb pool (startAgentTurn (GroupId 900) (CanonicalMessageId mid) (PrincipalId actor))
    now <- getCurrentTime
    withDb pool (armLedgerMatchMonitor (GroupId 900) (PrincipalId actor) turn "watch launch" (LedgerMatchSpec Nothing (Just "launch") Nothing False) 0 (addUTCTime 86400 now) 10 Map.empty) >>= (`shouldSatisfy` isRight)
    save actor (patch "return {action:'ignore'};") >>= (`shouldSatisfy` isRight)
    _ <- put 2 2 "launch hidden"
    hidden <- insertRawMessageWithClass pool Backfill 3 900 2 99 testTime Nothing "launch backfill"
    withDb pool (fetchMessageInScope scope hidden) >>= (`shouldSatisfy` isNothing)
    withDb pool (query "SELECT count(*) FROM monitor_fires" ()) `shouldReturn` [Only (0 :: Int64)]
    save actor (HookPatch "ignore-members" 1 Nothing Nothing Nothing (Just False)) >>= (`shouldSatisfy` isRight)
    _ <- insertRawMessage pool 4 900 2 99 now Nothing "launch visible"
    withDb pool (query "SELECT count(*) FROM monitor_fires" ()) `shouldReturn` [Only (1 :: Int64)]
  it "records all hook results, fails closed on errors, and deduplicates ingestion" $ do
    (_, actor) <- setup
    save actor (patch "throw new Error('broken');") >>= (`shouldSatisfy` isRight)
    save actor (patch "return {action:'pass'};") {hpName = "pass-rule"} >>= (`shouldSatisfy` isRight)
    mid <- put 2 2 "blocked by error"
    _ <- put 2 2 "duplicate"
    withDb pool (query "SELECT count(*),bool_and(outcome IN ('pass','error')) FROM message_hook_runs WHERE canonical_message_id=?" (Only mid)) `shouldReturn` [(2 :: Int64, True)]
    withDb pool (fetchMessageInScope scope mid) >>= (`shouldSatisfy` isNothing)
    first <- readHook (HookRuns Nothing Nothing Nothing Nothing 1)
    length (array "runs" first) `shouldBe` 1
    field "next_before" first `shouldSatisfy` (/= Null)
  it "denies non-admin reads/writes and fenced callers at the capability boundary" $ do
    (mid, actor) <- setup
    let p = patch "return {action:'pass'};"
    withDb pool (Control.runHookControl Nothing Nothing (GroupId 900) (PrincipalId actor) False (Control.setHook p)) `shouldReturn` Left "group_administrator_required"
    withDb pool (Control.runHookControl Nothing Nothing (GroupId 900) (PrincipalId actor) True (Control.setHook p)) `shouldReturn` Left "caller_fenced"
    withDb pool (Query.runHookQuery scope False (Query.queryHooks HookList)) `shouldReturn` Left "group_administrator_required"
    turn <- withDb pool (startAgentTurn (GroupId 900) (CanonicalMessageId mid) (PrincipalId actor))
    withDb pool (Control.runHookControl Nothing (Just turn.atrTurnId) (GroupId 901) (PrincipalId actor) True (Control.setHook p)) `shouldReturn` Left "caller_fenced"
    withDb pool (Control.runHookControl Nothing (Just turn.atrTurnId) (GroupId 900) (PrincipalId actor) True (Control.setHook p)) >>= (`shouldSatisfy` isRight)
  it "does not expose edits, forward children or attached files of ignored rows" $ do
    (_, actor) <- setup
    save actor (patch "return {action:'ignore'};") >>= (`shouldSatisfy` isRight)
    parent <- put 2 2 "hidden parent"
    save actor (HookPatch "ignore-members" 1 Nothing Nothing Nothing (Just False)) >>= (`shouldSatisfy` isRight)
    child <- put 3 3 "hidden child"
    void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position) VALUES(?,'contained_in',?,0)" (child, parent))
    withDb pool (fetchMessageInScope scope child) >>= (`shouldSatisfy` isNothing)
    edit <- put 4 2 "hidden edit"
    void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id) VALUES(?,'replace',?)" (edit, parent))
    withDb pool (fetchMessageInScope scope edit) >>= (`shouldSatisfy` isNothing)
    withDb pool (insertSeen "hidden-file" 900 (Just parent) 2 "secret.txt" Nothing)
    withDb pool (fetchFilesForMessageInScope scope parent) >>= (`shouldSatisfy` null)
    withDb pool (listConversationFilesInScope scope) >>= (`shouldSatisfy` null)
    grandchild <- put 5 3 "nested hidden child"
    void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position) VALUES(?,'contained_in',?,0)" (grandchild, child))
    withDb pool (fetchMessageInScope scope grandchild) >>= (`shouldSatisfy` isNothing)
  it "commits raw messages before hooks and freezes policy while protecting the history cursor" $ do
    (old, actor) <- setup
    save actor (patch "throw new Error('broken after ingest');") >>= (`shouldSatisfy` isRight)
    mid <- putPending 2 2 "durable original"
    state <- readHook (HookProjection mid)
    field "status" state `shouldBe` String "pending"
    field "currently_visible" state `shouldBe` Bool False
    withDb pool (query "SELECT rendered_text FROM messages WHERE canonical_message_id=?" (Only mid)) `shouldReturn` [Only ("durable original" :: Text)]
    withDb pool (query "SELECT count(*) FROM message_hook_runs" ()) `shouldReturn` [Only (0 :: Int64)]
    save actor (HookPatch "ignore-members" 1 Nothing (Just "return {action:'pass'};") Nothing (Just False)) >>= (`shouldSatisfy` isRight)
    later <- putPending 3 3 "later no-hook message"
    -- Its no-hook projection is ready, but the reader cannot skip the pending
    -- predecessor and then permanently lose it when a later evaluation passes.
    withDb pool (query "SELECT canonical_message_id FROM agent_messages WHERE group_id=900 ORDER BY ingest_seq" ()) `shouldReturn` [Only old]
    withDb pool drainProjections
    final <- readHook (HookProjection mid)
    field "status" final `shouldBe` String "error"
    map (field "revision") (array "hooks" final) `shouldBe` [Number 1]
    withDb pool (query "SELECT canonical_message_id FROM agent_messages WHERE group_id=900 ORDER BY ingest_seq" ()) `shouldReturn` [Only old, Only later]
    withDb pool (query "SELECT rendered_text FROM messages WHERE canonical_message_id=?" (Only mid)) `shouldReturn` [Only ("durable original" :: Text)]
    withDb pool (DB.queryHooks 901 (HookProjection mid)) `shouldReturn` Left "message_not_found_in_current_conversation"
  it "rolls back interrupted projection work while retaining committed input for a fresh worker" $ do
    (_, actor) <- setup
    save actor (patch "return {action:'pass'};") >>= (`shouldSatisfy` isRight)
    mid <- putPending 2 2 "survives worker cancellation"
    -- Hold the final admission lock so cancellation lands after hook execution,
    -- while the derived writes are still uncommitted in the worker transaction.
    withConn pool $ \connection -> PG.withTransaction connection $ do
      (_ :: [Only Int64]) <- PG.query connection "SELECT conversation_id FROM conversations WHERE legacy_group_id=900 FOR UPDATE" ()
      withAsync (withDb pool processNextProjection) $ \worker -> do
        timeout 5000000 (awaitAdmissionLock pool) `shouldReturn` Just ()
        cancel worker
    state <- readHook (HookProjection mid)
    field "status" state `shouldBe` String "pending"
    field "work_pending" state `shouldBe` Bool True
    withDb pool (query "SELECT count(*) FROM message_hook_runs" ()) `shouldReturn` [Only (0 :: Int64)]
    withDb pool (query "SELECT rendered_text FROM messages WHERE canonical_message_id=?" (Only mid)) `shouldReturn` [Only ("survives worker cancellation" :: Text)]
    withDb pool processNextProjection `shouldReturn` True
    field "status" <$> readHook (HookProjection mid) `shouldReturn` String "ready"
  it "recovers unstarted dispatch without an in-memory wake and never replays a started command" $ do
    (_, actor) <- setup
    save actor (patch "return {action:'pass'};") >>= (`shouldSatisfy` isRight)
    mid <- putPending 2 2 "new request"
    void $ withDb pool (execute "UPDATE message_projections SET dispatch_requested=true WHERE canonical_message_id=?" (Only mid))
    withDb pool claimMessageDispatch `shouldReturn` Nothing
    withDb pool processNextProjection `shouldReturn` True
    restarted <- newIngress =<< newDeliveryQueue (DeliveryId 0)
    withDb pool (nextIngress restarted) `shouldReturn` CanonicalMessageId mid
    withDb pool interruptMessageDispatches `shouldReturn` 1
    withDb pool claimMessageDispatch `shouldReturn` Nothing
    withDb pool processNextProjection `shouldReturn` False
    field "dispatch_status" <$> readHook (HookProjection mid) `shouldReturn` String "interrupted"
    -- A late completion cannot rewrite the interrupted evidence.
    withDb pool (finishMessageDispatch (CanonicalMessageId mid) Nothing)
    field "dispatch_status" <$> readHook (HookProjection mid) `shouldReturn` String "interrupted"
  it "does not evaluate later messages ahead of a locked conversation head or duplicate committed runs" $ do
    (_, actor) <- setup
    save actor (patch "return {action:'pass'};") >>= (`shouldSatisfy` isRight)
    first <- putPending 2 2 "first"
    second <- putPending 3 2 "second"
    other <- insertPendingRawMessage pool 4 901 2 99 testTime Nothing "independent conversation"
    withConn pool $ \connection -> PG.withTransaction connection $ do
      (_ :: [Only Int64]) <- PG.query connection "SELECT canonical_message_id FROM message_projections WHERE canonical_message_id=? FOR UPDATE" (Only first)
      withDb pool processNextProjection `shouldReturn` True
      withDb pool processNextProjection `shouldReturn` False
      withDb pool (query "SELECT work_pending FROM message_projections WHERE canonical_message_id=?" (Only other)) `shouldReturn` [Only False]
      withDb pool (query "SELECT status FROM message_projections WHERE canonical_message_id=?" (Only second)) `shouldReturn` [Only ("pending" :: Text)]
    _ <- concurrently (withDb pool processNextProjection) (withDb pool processNextProjection)
    withDb pool drainProjections
    withDb pool (query "SELECT count(*) FROM message_hook_runs" ()) `shouldReturn` [Only (2 :: Int64)]
    withDb pool drainProjections
    withDb pool (query "SELECT count(*) FROM message_hook_runs" ()) `shouldReturn` [Only (2 :: Int64)]

awaitAdmissionLock :: DbPool -> IO ()
awaitAdmissionLock pool = do
  rows <- withDb pool (query "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT conversation_id FROM conversations WHERE conversation_id=%FOR UPDATE')" ())
  if rows == [Only True] then pure () else threadDelay 1000 >> awaitAdmissionLock pool

field :: Key -> Value -> Value
field key (Object fields) = fromMaybe Null (KM.lookup key fields)
field _ _ = Null

array :: Key -> Value -> [Value]
array key v = case field key v of Array xs -> foldr (:) [] xs; _ -> []
