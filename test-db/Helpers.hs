-- |
-- Shared scaffolding for the DB integration suite: a runner that
-- bridges from @'Eff' '['WithConnection', 'IOE']@ to plain 'IO', plus
-- 'truncateAll' (wipes every test-touched table between cases).
module Helpers
  ( withDb,
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
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute, execute_, query, (:.) (..))
import Database.PostgreSQL.Simple.Types (Null (..))
import Effectful (Eff, IOE, runEff)
import Effectful.Log (Log, LogLevel (LogTrace), runLog)
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Log.Logger (Logger, mkLogger)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Session qualified as SessionDB
import Max.Effects.Blob (Blob, runBlob)
import Max.Session.Types (Session)
import OneBot.Types (GroupId)
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
insertRawMessage pool mid gid uid sid receivedAt nick body = withConn pool $ \c -> do
  -- segments stored as the literal JSON empty array; sender_card stays NULL.
  -- raw_message is the empty string (DEFAULT, but explicit is clearer).
  _ <-
    execute
      c
      "INSERT INTO messages \
      \  (message_id, group_id, user_id, self_id, received_at, \
      \   segments, rendered_text, raw_message, sender_nickname, sender_card) \
      \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, '', ?, ?)"
      ((mid, gid, uid, sid, receivedAt, body, nick) :. Only Null)
  pure ()

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
insertRawMessageAtSeq pool seq' mid gid uid sid receivedAt nick body = withConn pool $ \c -> do
  _ <-
    execute
      c
      "INSERT INTO messages \
      \  (message_id, group_id, user_id, self_id, received_at, \
      \   segments, rendered_text, raw_message, sender_nickname, sender_card, ingest_seq) \
      \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, '', ?, ?, ?)"
      ((mid, gid, uid, sid, receivedAt, body, nick) :. (Null, seq'))
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
insertRawKind pool kind mid gid uid sid receivedAt nick body = withConn pool $ \c -> do
  _ <-
    execute
      c
      "INSERT INTO messages \
      \  (message_id, group_id, user_id, self_id, received_at, \
      \   segments, rendered_text, raw_message, sender_nickname, sender_card, kind) \
      \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, '', ?, ?, ?)"
      ((mid, gid, uid, sid, receivedAt, body, nick) :. (Null, kind))
  pure ()

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
insertRawReply pool mid gid uid sid receivedAt nick body replyTo = withConn pool $ \c -> do
  _ <-
    execute
      c
      "INSERT INTO messages \
      \  (message_id, group_id, user_id, self_id, received_at, \
      \   segments, rendered_text, raw_message, sender_nickname, sender_card, \
      \   reply_to_message_id) \
      \ VALUES (?, ?, ?, ?, ?, '[]'::jsonb, ?, '', ?, ?, ?)"
      ((mid, gid, uid, sid, receivedAt, body, nick) :. (Null, replyTo))
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
