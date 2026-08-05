{-# LANGUAGE DataKinds #-}

-- | Offline release gate for ADR 003's atomic schema/content cutover.
--
-- This executable is deliberately not linked into the serving entry point.
-- Run it only after every writer is stopped, with MAX_DB_URL pointing at the
-- database being upgraded.  The serving binary has no dual reader/writer and
-- therefore must not overlap this program.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM, unless, when)
import Data.Aeson (Result (..), Value, fromJSON)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple
  ( Connection,
    Only (..),
    Query,
    execute,
    query,
    query_,
    withTransaction,
  )
import Database.PostgreSQL.Simple.FromRow qualified as FromRow
import Max.DB.Connection (DbConfig (..), DbPool, closeDbPool, newDbPool, withConn)
import Max.DB.Migrations (runMigrations)
import Effectful (runEff)
import Effectful.PostgreSQL.Connection (runWithConnection)
import Max.IR
  ( Body (..),
    Phase (Canonical),
    mentionIdentities,
  )
import Max.IR.Prompt (promptCanonicalText)
import Max.Platform.Store (expiredSendingDeliverySql, mentionPrincipalsFor)
import Max.Platform.Types (PrincipalId, PrincipalIdentityId)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)

data Command = Migrate | Reproject | Verify | Gate
  deriving stock (Eq, Show)

data ProjectionRow = ProjectionRow
  { canonicalMessageId :: !Int64,
    canonicalContent :: !Value,
    renderedText :: !Text
  }

instance FromRow.FromRow ProjectionRow where
  fromRow =
    ProjectionRow
      <$> FromRow.field
      <*> FromRow.field
      <*> FromRow.field

main :: IO ()
main = do
  command <- parseCommand =<< getArgs
  dbUrl <- requireEnv "MAX_DB_URL"
  migrationsDir <- fromMaybe "migrations" <$> lookupEnv "MAX_MIGRATIONS_DIR"
  bracket
    (newDbPool (DbConfig (T.pack dbUrl) 1))
    closeDbPool
    (run command migrationsDir)

run :: Command -> FilePath -> DbPool -> IO ()
run command migrationsDir pool = case command of
  Migrate -> migrate pool migrationsDir
  Reproject -> withConn pool reproject
  Verify -> withConn pool (verify False)
  Gate -> do
    withConn pool preflightDrained
    migrate pool migrationsDir
    withConn pool $ \connection -> do
      reproject connection
      verify True connection

-- | Quarantine abandoned delivery claims, then refuse to cross the
-- irreversible schema boundary with any genuinely active work.  An expired
-- @sending@ lease has already lost its owner; outcome-unknown is the only safe
-- terminal classification because retrying could duplicate a send.  Older
-- pre-049 databases legitimately lack the canonical outbox tables, so every
-- operation is discovered before its SQL is prepared.
preflightDrained :: Connection -> IO ()
preflightDrained connection = do
  deliveriesExist <- tableExists connection "message_deliveries"
  when deliveriesExist $ do
    quarantined <- execute connection expiredSendingDeliverySql ()
    when (quarantined /= 0) $
      putStrLn
        ( "preflight: quarantined "
            <> show quarantined
            <> " expired sending delivery lease(s) as outcome_unknown"
        )
  problems <- fmap concat . forM preflightChecks $ \(table, label, sql) -> do
    exists <- tableExists connection table
    if not exists
      then pure []
      else do
        outstanding <- scalarCount connection sql
        pure [label <> ": " <> show outstanding | outstanding /= 0]
  unless (null problems) $ do
    putStrLn "ADR 003 pre-migration drain check FAILED:"
    mapM_ (putStrLn . ("  - " <>)) problems
    die "drain the old workers before applying ADR 003 migrations"
  putStrLn "preflight: old writer queues are drained"

tableExists :: Connection -> Text -> IO Bool
tableExists connection table = do
  rows <- query connection "SELECT to_regclass(?) IS NOT NULL" (Only table)
  case rows of
    [Only exists] -> pure exists
    _ -> die "release-gate table discovery returned an unexpected shape"

migrate :: DbPool -> FilePath -> IO ()
migrate pool migrationsDir = do
  applied <- runMigrations pool migrationsDir
  case applied of
    [] -> putStrLn "migrations: final schema already present"
    filenames ->
      putStrLn
        ( "migrations: applied "
            <> show (length filenames)
            <> " file(s): "
            <> unwords filenames
        )

reproject :: Connection -> IO ()
reproject connection = withTransaction connection $ do
  rows <- projectionRows connection
  changed <- fmap sum . forM rows $ \row -> do
    body <- decodeBody row
    principals <- mentionPrincipals connection body
    let expected = promptCanonicalText principals body
    if expected == row.renderedText
      then pure (0 :: Int)
      else do
        updated <-
          execute
            connection
            "UPDATE messages SET rendered_text = ? WHERE canonical_message_id = ?"
            (expected, row.canonicalMessageId)
        pure (fromIntegral updated)
  putStrLn
    ( "projection: checked "
        <> show (length rows)
        <> " message(s), regenerated "
        <> show changed
    )

verify :: Bool -> Connection -> IO ()
verify requireDrained connection = do
  schemaProblems <- fmap concat . forM schemaChecks $ \(label, sql) -> do
    violations <- scalarCount connection sql
    pure [label <> ": " <> show violations | violations /= 0]
  projectionProblems <- verifyProjections connection
  counts <- ledgerCounts connection
  putStrLn ("ledger: " <> counts)
  drainProblems <-
    if requireDrained
      then fmap concat . forM drainChecks $ \(label, sql) -> do
        outstanding <- scalarCount connection sql
        pure [label <> ": " <> show outstanding | outstanding /= 0]
      else pure []
  let problems = schemaProblems <> projectionProblems <> drainProblems
  unless (null problems) $ do
    putStrLn "ADR 003 release gate FAILED:"
    mapM_ (putStrLn . ("  - " <>)) (take 50 problems)
    when (length problems > 50) $ putStrLn ("  - ... and " <> show (length problems - 50) <> " more")
    die "database is not safe to start with the final ADR 003 binary"
  putStrLn
    ( if requireDrained
        then "ADR 003 release gate PASSED (schema, IR, projections, ledger, and queues)"
        else "ADR 003 verification PASSED (schema, IR, projections, and ledger)"
    )

projectionRows :: Connection -> IO [ProjectionRow]
projectionRows connection =
  query_
    connection
    "SELECT canonical_message_id, canonical_content, rendered_text \
    \FROM messages ORDER BY canonical_message_id"

decodeBody :: ProjectionRow -> IO (Body 'Canonical)
decodeBody row = case fromJSON row.canonicalContent of
  Success body -> pure body
  Error err ->
    die
      ( "canonical message "
          <> show row.canonicalMessageId
          <> " is not decodable v2 IR: "
          <> err
      )

verifyProjections :: Connection -> IO [String]
verifyProjections connection = do
  rows <- projectionRows connection
  fmap concat . forM rows $ \row -> case fromJSON row.canonicalContent of
    Error err ->
      pure
        [ "canonical message "
            <> show row.canonicalMessageId
            <> " is not decodable v2 IR: "
            <> err
        ]
    Success body -> do
      principals <- mentionPrincipals connection body
      let expected = promptCanonicalText principals body
      pure
        [ "canonical message "
            <> show row.canonicalMessageId
            <> " has a stale rendered_text projection"
          | expected /= row.renderedText
        ]

-- | The gate must resolve mentions exactly the way the writer did, so it
-- calls the writer's own resolution instead of keeping a second copy of the
-- query.  The two did drift once: only this one learned to prefer the
-- mentioned identity itself.
--
-- Since ADR 004 that resolution is identity → principal, which is one
-- always-defined join and no longer depends on the endpoint at all: the
-- prompt names people, not accounts.
mentionPrincipals ::
  Connection ->
  Body 'Canonical ->
  IO (Map PrincipalIdentityId PrincipalId)
mentionPrincipals connection body =
  runEff . runWithConnection connection $
    mentionPrincipalsFor (mentionIdentities body)

scalarCount :: Connection -> Query -> IO Int64
scalarCount connection sql = do
  rows <- query_ connection sql
  case rows of
    [Only count] -> pure count
    _ -> die "release-gate count query returned an unexpected shape"

schemaChecks :: [(String, Query)]
schemaChecks =
    -- The 55-64 ADR 003 chain was squashed into one production baseline, and
    -- 'reconcileSquash' rewrites schema_migrations to record only that file.
    -- Requiring the individual pre-squash names now fails on every database,
    -- including the one this gate exists to protect.
  [ ( "post-cutover schema baseline missing",
      "SELECT count(*) FROM (VALUES ('000_baseline.sql')) required(filename) \
      \LEFT JOIN schema_migrations migration USING (filename) \
      \WHERE migration.filename IS NULL"
    ),
    ( "messages with invalid v2 JSON shape",
      "SELECT count(*) FROM messages \
      \WHERE jsonb_typeof(canonical_content) <> 'object' \
      \   OR canonical_content->>'v' <> '2' \
      \   OR jsonb_typeof(canonical_content->'nodes') <> 'array'"
    ),
    ( "legacy QQ rows whose retained segments were not structurally rebuilt",
      "WITH legacy AS ( \
      \  SELECT message.* FROM messages message \
      \  WHERE message.source_platform = 'qq' \
      \    AND message.message_origin = 'legacy' \
      \    AND jsonb_typeof(message.segments) = 'array' \
      \    AND jsonb_array_length(message.segments) > 0 \
      \), damaged AS ( \
      \  SELECT legacy.canonical_message_id FROM legacy \
      \  WHERE jsonb_array_length(legacy.canonical_content->'nodes') <> ( \
      \    SELECT count(*) FROM jsonb_array_elements(legacy.segments) segment(value) \
      \    WHERE segment.value->>'type' <> 'reply' \
      \      AND NOT (segment.value->>'type' = 'text' \
      \               AND coalesce(segment.value->'data'->>'text', '') = '')) \
      \  OR EXISTS ( \
      \    SELECT 1 FROM ( \
      \      SELECT segment.value, \
      \             row_number() OVER (ORDER BY segment.ordinality) AS node_ordinal \
      \      FROM jsonb_array_elements(legacy.segments) WITH ORDINALITY segment(value, ordinality) \
      \      WHERE segment.value->>'type' <> 'reply' \
      \        AND NOT (segment.value->>'type' = 'text' \
      \                 AND coalesce(segment.value->'data'->>'text', '') = '') \
      \    ) expected \
      \    JOIN jsonb_array_elements(legacy.canonical_content->'nodes') WITH ORDINALITY actual(value, ordinality) \
      \      ON actual.ordinality = expected.node_ordinal \
      \    WHERE CASE expected.value->>'type' \
      \      WHEN 'text' THEN actual.value->>'type' <> 'text' \
      \      WHEN 'at' THEN actual.value->>'type' NOT IN ('mention', 'text') \
      \      WHEN 'face' THEN actual.value->>'type' <> 'emote' \
      \      WHEN 'image' THEN actual.value->>'type' <> 'media' \
      \      WHEN 'file' THEN actual.value->>'type' <> 'media' \
      \      WHEN 'video' THEN actual.value->>'type' <> 'media' \
      \      WHEN 'json' THEN actual.value->>'type' <> 'card' \
      \      WHEN 'forward' THEN actual.value->>'type' <> \
      \        CASE WHEN coalesce(expected.value->'data'->>'id', '') = '' \
      \             THEN 'unsupported' ELSE 'forward' END \
      \      ELSE actual.value->>'type' <> 'unsupported' \
      \    END \
      \  ) \
      \) SELECT count(*) FROM damaged"
    ),
    ( "expired-delivery recovery index missing",
      "SELECT count(*) FROM (SELECT 1 WHERE \
      \ to_regclass('message_deliveries_sending_lease_idx') IS NULL) missing"
    ),
    ( "non-QQ messages retaining compatibility segments",
      "SELECT count(*) FROM messages WHERE source_platform <> 'qq' AND segments <> '[]'::jsonb"
    ),
    ( "duplicate conversation sequence numbers",
      "SELECT count(*) FROM (SELECT conversation_id, conversation_seq \
      \ FROM messages GROUP BY conversation_id, conversation_seq HAVING count(*) > 1) duplicates"
    ),
    ( "inbound messages without a canonical platform event",
      "SELECT count(*) FROM messages message \
      \WHERE message.message_origin IN ('inbound', 'legacy') \
      \  AND NOT EXISTS (SELECT 1 FROM platform_events event \
      \                  WHERE event.canonical_message_id = message.canonical_message_id)"
    ),
    ( "inbound messages without a confirmed source delivery",
      "SELECT count(*) FROM messages message \
      \WHERE message.message_origin IN ('inbound', 'legacy') \
      \  AND NOT EXISTS (SELECT 1 FROM message_deliveries delivery \
      \                  WHERE delivery.canonical_message_id = message.canonical_message_id \
      \                    AND delivery.endpoint_id = message.origin_endpoint_id \
      \                    AND delivery.status = 'confirmed')"
    ),
    ( "orphaned message relations",
      "SELECT count(*) FROM message_relations relation \
      \LEFT JOIN messages message ON message.canonical_message_id = relation.canonical_message_id \
      \WHERE message.canonical_message_id IS NULL"
    ),
    ( "orphaned relation targets",
      "SELECT count(*) FROM message_relations relation \
      \LEFT JOIN messages target ON target.canonical_message_id = relation.target_canonical_message_id \
      \WHERE relation.target_canonical_message_id IS NOT NULL \
      \  AND target.canonical_message_id IS NULL"
    ),
    ( "orphaned deliveries",
      "SELECT count(*) FROM message_deliveries delivery \
      \LEFT JOIN messages message ON message.canonical_message_id = delivery.canonical_message_id \
      \LEFT JOIN conversation_endpoints endpoint ON endpoint.endpoint_id = delivery.endpoint_id \
      \WHERE message.canonical_message_id IS NULL OR endpoint.endpoint_id IS NULL"
    ),
    ( "orphaned dispatches",
      "SELECT count(*) FROM message_dispatches dispatch \
      \LEFT JOIN messages message ON message.canonical_message_id = dispatch.canonical_message_id \
      \WHERE message.canonical_message_id IS NULL"
    ),
    ( "legacy message-writer functions still installed",
      "SELECT count(*) FROM pg_proc \
      \WHERE proname IN ('messages_canonicalize_legacy', 'messages_publish_legacy_source', \
      \                  'messages_set_source_platform') \
      \  AND pg_function_is_visible(oid)"
    ),
    ( "legacy forward columns still installed",
      "SELECT count(*) FROM information_schema.columns \
      \WHERE table_schema = current_schema() AND table_name = 'messages' \
      \  AND column_name IN ('forwarded_in_message_id', 'forward_position', \
      \                      'original_message_id', 'original_sent_at')"
    )
  ]

drainChecks :: [(String, Query)]
drainChecks =
  [ ( "active delivery rows",
      "SELECT count(*) FROM message_deliveries \
      \WHERE status IN ('pending', 'sending', 'failed')"
    ),
    ( "active dispatch rows",
      "SELECT count(*) FROM message_dispatches \
      \WHERE status IN ('pending', 'claimed', 'failed')"
    ),
    ( "unprocessed durable media jobs",
      "SELECT count(*) FROM fetch_jobs WHERE parked_at IS NULL"
    )
  ]

preflightChecks :: [(Text, String, Query)]
preflightChecks =
  [ ( "message_deliveries",
      "active delivery rows before migration",
      "SELECT count(*) FROM message_deliveries \
      \WHERE status IN ('pending', 'sending', 'failed')"
    ),
    ( "message_dispatches",
      "active dispatch rows before migration",
      "SELECT count(*) FROM message_dispatches \
      \WHERE status IN ('pending', 'claimed', 'failed')"
    ),
    ( "fetch_jobs",
      "unprocessed durable media jobs before migration",
      "SELECT count(*) FROM fetch_jobs WHERE parked_at IS NULL"
    )
  ]

ledgerCounts :: Connection -> IO String
ledgerCounts connection = do
  messages <- scalarCount connection "SELECT count(*) FROM messages"
  events <- scalarCount connection "SELECT count(*) FROM platform_events"
  relations <- scalarCount connection "SELECT count(*) FROM message_relations"
  deliveries <- scalarCount connection "SELECT count(*) FROM message_deliveries"
  dispatches <- scalarCount connection "SELECT count(*) FROM message_dispatches"
  pure
    ( "messages="
        <> show messages
        <> ", events="
        <> show events
        <> ", relations="
        <> show relations
        <> ", deliveries="
        <> show deliveries
        <> ", dispatches="
        <> show dispatches
    )

parseCommand :: [String] -> IO Command
parseCommand = \case
  ["migrate"] -> pure Migrate
  ["reproject"] -> pure Reproject
  ["verify"] -> pure Verify
  ["gate"] -> pure Gate
  _ ->
    die
      "usage: cabal run max-adr003-maintenance -- \
      \(migrate|reproject|verify|gate)\n\
      \  environment: MAX_DB_URL (required), MAX_MIGRATIONS_DIR (default: migrations)"

requireEnv :: String -> IO String
requireEnv name = lookupEnv name >>= \case
  Just value | not (null value) -> pure value
  _ -> die (name <> " must be set explicitly")
