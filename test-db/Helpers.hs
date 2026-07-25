-- |
-- Shared scaffolding for the DB integration suite: a runner that
-- bridges from @'Eff' '['WithConnection', 'IOE']@ to plain 'IO', plus
-- 'truncateAll' (wipes every test-touched table between cases).
module Helpers
  ( withDb,
    withDbLog,
    truncateAll,
    insertRawMessage,
    insertRawReply,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute, execute_, (:.) (..))
import Database.PostgreSQL.Simple.Types (Null (..))
import Effectful (Eff, IOE, runEff)
import Effectful.Log (Log, LogLevel (LogTrace), runLog)
import Effectful.PostgreSQL (WithConnection)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import Log.Logger (Logger, mkLogger)
import Max.DB.Connection (DbPool, withConn)
import System.IO.Unsafe (unsafePerformIO)

-- | Run an effectful, DB-touching action in plain 'IO'.  The set of
-- effects is fixed to @['WithConnection', 'IOE']@ — most functions
-- under test don't ask for 'Log'.  Use 'withDbLog' when they do.
withDb :: DbPool -> Eff '[WithConnection, IOE] a -> IO a
withDb pool = runEff . runWithConnectionPool pool

-- | Variant that includes a (silent) 'Log' effect, for code paths
-- that take @'Log' ':>' es@ — currently just 'Max.Prompt.buildContext'.
-- Log messages are dropped.
withDbLog :: DbPool -> Eff '[WithConnection, Log, IOE] a -> IO a
withDbLog pool =
  runEff
    . runLog "max-test" silentLogger LogTrace
    . runWithConnectionPool pool

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
      \  messages, \
      \  images, \
      \  message_images, \
      \  videos, \
      \  message_videos, \
      \  sessions, \
      \  group_files, \
      \  fetch_jobs \
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
