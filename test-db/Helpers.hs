-- |
-- Shared scaffolding for the DB integration suite: a runner that
-- bridges from @'Eff' '['WithConnection', 'IOE']@ to plain 'IO', plus
-- 'truncateAll' (wipes every test-touched table between cases).
module Helpers
  ( withDb,
    requireJust,
    resultId,
    testTime,
    withDbLog,
    truncateAll,
    insertRawMessage,
    insertRawMessageAtSeq,
    insertRawKind,
    insertRawReply,
    updateDbSession,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute, execute_, query)
import Effectful (Eff, IOE, runEff)
import Effectful.Log (Log, LogLevel (LogTrace), runLog)
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Log.Logger (Logger, mkLogger)
import Max.DB.Connection (DbPool, withConn)
import Test.Hspec (expectationFailure)
import Max.DB.Session qualified as SessionDB
import Max.Effects.Blob (Blob, runBlob)
import Max.IR (Body (..), Node (NText))
import Max.Platform.Envelope (InboundEnvelope (..))
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store
  ( IngestOptions (..),
    IngestResult (..),
    NewIngest (..),
    RegisteredEndpoint (..),
    defaultIngestOptions,
    ingestEnvelope,
  )
import Max.Platform.Types
  ( CanonicalMessageId,
    EventKind (EventMessage),
    MessageRelation (ReplyTo),
    NativeEventId (..),
    NativeUserId (..),
  )
import Max.Session.Types (Session)
import OneBot.Types (GroupId (..), UserId (..))
import System.IO.Unsafe (unsafePerformIO)

-- | Run an effectful, DB-touching action in plain 'IO'.  The set of
-- effects is fixed to @['WithConnection', 'IOE']@ — most functions
-- under test don't ask for 'Log'.  Use 'withDbLog' when they do.
withDb :: DbPool -> Eff '[WithConnection, IOE] a -> IO a
withDb pool = runEff . runWithConnectionPool pool

-- | Variant that includes a local 'Blob' store and a (silent) 'Log' effect for
-- 'Max.Prompt.buildContext'.  Log messages are dropped.
withDbLog :: DbPool -> Eff '[Blob, WithConnection, Log, IOE] a -> IO a
withDbLog pool =
  runEff
    . runLog "max-test" silentLogger LogTrace
    . runWithConnectionPool pool
    . runBlob "var/images"

-- | Drop-everything log backend.  Shared singleton built lazily; safe
-- because 'mkLogger' with a pure no-op consumer doesn't spawn worker
-- threads or hold resources.
silentLogger :: Logger
silentLogger = unsafePerformIO (mkLogger "silent" (\_ -> pure ()))
{-# NOINLINE silentLogger #-}

-- | Wipe every table the bot writes to.  Run between every test case
-- so specs stay independent.  Don't truncate 'schema_migrations'
-- (migrations only run once per suite invocation).
--
-- TRUNCATE … RESTART IDENTITY CASCADE handles fkeys and resets any
-- auto-increment counters — the test suite shouldn't depend on
-- specific surrogate ids carrying over between cases.
truncateAll :: DbPool -> IO ()
truncateAll pool = withConn pool $ \c -> do
  _ <-
    execute_
      c
      "TRUNCATE \
      \  maintenance_leases, \
      \  platform_ingest_cursors, \
      \  message_relations, \
      \  message_deliveries, \
      \  message_dispatches, \
      \  platform_events, \
      \  principal_identities, \
      \  principals, \
      \  conversation_endpoints, \
      \  conversations, \
      \  platform_accounts, \
      \  context_plan_traces, \
      \  context_materialization_versions, \
      \  context_materializations, \
      \  episode_memory_proposals, \
      \  compartment_evidence, \
      \  conversation_compartments, \
      \  episode_capture_runs, \
      \  conversation_cursors, \
      \  messages, \
      \  images, \
      \  message_images, \
      \  videos, \
      \  message_videos, \
      \  memories, \
      \  sessions, \
      \  group_files, \
      \  fetch_jobs, \
      \  reminders \
      \  RESTART IDENTITY CASCADE"
  pure ()

-- | Insert a single row into 'messages' with control over every
-- relevant column.  Useful for setting up history fixtures without
-- having to fabricate a full 'GroupMessage' + segment JSON.
insertRawMessage ::
  DbPool ->
  Int64 -> -- message_id
  Int64 -> -- group_id
  Int64 -> -- user_id
  Int64 -> -- self_id
  UTCTime -> -- received_at
  Maybe Text -> -- sender_nickname
  Text -> -- rendered_text
  IO ()
insertRawMessage pool mid gid uid sid receivedAt nick body =
  insertCanonicalFixture pool "chat" mid gid uid sid receivedAt nick body Nothing

-- | Like 'insertRawMessage' but with an explicit @ingest_seq@.  Simulates a
-- commit-order skip: the row's sequence value was allocated before rows that
-- are already visible, but its transaction committed later.  Bumps the
-- sequence past the explicit value so later default inserts cannot collide.
insertRawMessageAtSeq ::
  DbPool ->
  Int64 -> -- ingest_seq
  Int64 -> -- message_id
  Int64 -> -- group_id
  Int64 -> -- user_id
  Int64 -> -- self_id
  UTCTime -> -- received_at
  Maybe Text -> -- sender_nickname
  Text -> -- rendered_text
  IO ()
insertRawMessageAtSeq pool seq' mid gid uid sid receivedAt nick body = do
  insertCanonicalFixture pool "chat" mid gid uid sid receivedAt nick body Nothing
  withConn pool $ \c -> do
    _ <-
      execute
        c
        "UPDATE messages SET ingest_seq = ?, conversation_seq = ? WHERE message_id = ?"
        (seq', seq', mid)
    _ <-
      query
        c
        "SELECT setval('messages_ingest_seq_seq', greatest(?::bigint, last_value), true) \
        \ FROM messages_ingest_seq_seq"
        (Only seq') ::
        IO [Only Int64]
    pure ()

-- | Like 'insertRawMessage' but with an explicit @kind@ — @'command'@
-- or @'debug'@ for rows the chat saw but the transcript must skip.
insertRawKind ::
  DbPool ->
  Text -> -- kind
  Int64 -> -- message_id
  Int64 -> -- group_id
  Int64 -> -- user_id
  Int64 -> -- self_id
  UTCTime -> -- received_at
  Maybe Text -> -- sender_nickname
  Text -> -- rendered_text
  IO ()
insertRawKind pool kind mid gid uid sid receivedAt nick body =
  insertCanonicalFixture pool kind mid gid uid sid receivedAt nick body Nothing

-- | Like 'insertRawMessage' but with a @reply_to_message_id@ link.
insertRawReply ::
  DbPool ->
  Int64 -> -- message_id
  Int64 -> -- group_id
  Int64 -> -- user_id
  Int64 -> -- self_id
  UTCTime -> -- received_at
  Maybe Text -> -- sender_nickname
  Text -> -- rendered_text
  Int64 -> -- reply_to_message_id
  IO ()
insertRawReply pool mid gid uid sid receivedAt nick body replyTo =
  insertCanonicalFixture pool "chat" mid gid uid sid receivedAt nick body (Just replyTo)

-- Test fixtures enter through the same final ingest kernel as production.
-- Numeric QQ native ids preserve the exact compatibility ids expected by the
-- older history/session assertions without reviving a legacy table writer.
insertCanonicalFixture ::
  DbPool ->
  Text ->
  Int64 ->
  Int64 ->
  Int64 ->
  Int64 ->
  UTCTime ->
  Maybe Text ->
  Text ->
  Maybe Int64 ->
  IO ()
insertCanonicalFixture pool kind mid gid uid sid receivedAt nick body replyTo =
  withDb pool $ do
    endpoint <- ensureQQEndpointFor (UserId sid) (GroupId gid)
    let nativeMessage = NativeEventId (T.pack (show mid))
        envelope =
          InboundEnvelope
            { endpointId = endpoint.endpointId,
              nativeEventId = nativeMessage,
              senderNativeId = NativeUserId (T.pack (show uid)),
              senderDisplayName = nick,
              occurredAt = receivedAt,
              receivedAt = receivedAt,
              eventKind = EventMessage,
              content = Body [NText body],
              relations = maybe [] (\target -> [ReplyTo (NativeEventId (T.pack (show target)))]) replyTo,
              sourceCursor = Nothing,
              rawPayload = Nothing
            }
        options =
          defaultIngestOptions
            { createDispatch = False,
              createMirrorDeliveries = False,
              transcriptKind = kind
            }
    _ <- ingestEnvelope options envelope
    pure ()

-- | Test-only versioned Session mutation.  Production callers go through
-- 'Max.Session.updateSession'; integration fixtures use this helper when they
-- need a persisted Session value without constructing a runtime registry.
updateDbSession ::
  DbPool ->
  GroupId ->
  Text ->
  (Session -> Session) ->
  IO Session
updateDbSession pool gid defaultModel f = withDb pool $ do
  current <- SessionDB.fetchRecordOrInit gid defaultModel
  let next = f current.session
  SessionDB.saveSessionCAS current next >>= \case
    Just _ -> pure next
    Nothing -> error "test Session CAS unexpectedly conflicted"

-- | Unwrap a fixture that must exist, failing the example instead of the
-- whole suite.  Six specs had grown a private copy of this.
requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)

-- | The frozen clock every ledger fixture is stamped with.
testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"

-- | The canonical id an ingest produced, however it got there.
resultId :: IngestResult -> CanonicalMessageId
resultId = \case
  Ingested fresh -> fresh.canonicalMessageId
  AlreadyIngested canonical -> canonical
  DeliveryEcho canonical -> canonical
  EchoUnmatched -> error "resultId: a reconcile-only ingest stored no message"
