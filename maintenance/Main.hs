{-# LANGUAGE DataKinds #-}

-- | Offline release gate for ADR 003's atomic schema/content cutover.
--
-- This executable is deliberately not linked into the serving entry point.
-- Gate/migrate/reproject require stopped writers; verify and health are read-only.
module Main (main) where

import Control.Exception (bracket)
import Control.Monad (forM, unless, when)
import Data.Aeson (Value, eitherDecodeFileStrict)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple
  ( Connection,
    Only (..),
    Query,
    execute,
    query_,
    withTransaction,
  )
import Effectful (runEff)
import Effectful.PostgreSQL.Connection (runWithConnection)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbConfig (..), DbPool, closeDbPool, newDbPool, withConn)
import Max.DB.Health (operationalChecks)
import Max.DB.Migrations (runMigrations)
import Max.DB.Projection (ProjectionRow (..), expectedProjection, projectionRows)
import Max.EpisodeStore (CaptureRunId (..), reviewRejectedMemoryProposal)
import Max.MemoryStore qualified as Memory
import OneBot.Types (GroupId (..))
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import Text.Read (readMaybe)

data Command
  = Migrate
  | Reproject
  | Verify
  | Health
  | Gate
  | MemoryReview Int64 Int64 Int Text Text FilePath
  | MemoryReviewQueue
  | MemoryRepairSubject Int64 Int64 Int64 Int64 Text
  deriving stock (Eq, Show)

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
  Verify -> withConn pool verify
  Health -> withConn pool operationalHealth
  MemoryReviewQueue -> withConn pool $ \connection -> do
    rows <- query_ connection "SELECT jsonb_build_object('capture_run_id',capture_run_id,'proposal_index',proposal_index,'conversation_id',conversation_id,'outcome_reason',outcome_reason,'review_state',review_state) FROM episode_memory_review_queue ORDER BY capture_run_id,proposal_index" :: IO [Only Value]
    mapM_ (print . fromOnly) rows
  MemoryReview group capture index actor reason path -> do
    proposal <- eitherDecodeFileStrict path >>= either die pure
    result <- withConn pool $ \connection ->
      runEff . runWithConnection connection $
        reviewRejectedMemoryProposal (conversationScopeFor (GroupId group)) (CaptureRunId capture) index actor reason proposal
    putStrLn ("memory review: " <> T.unpack result)
  MemoryRepairSubject group memory version principal reason -> do
    result <- withConn pool $ \connection ->
      runEff . runWithConnection connection $
        Memory.repairMemorySubjectAdmin
          (conversationScopeFor (GroupId group))
          (Memory.MemoryId memory)
          (Memory.ExpectedVersion (Memory.MemoryVersion version))
          principal
          reason
    case result of
      Memory.MemoryMutationApplied item -> putStrLn ("memory subject repaired: id=" <> show item.memId <> " version=" <> show item.memVersion)
      Memory.MemoryMutationRejected -> die "subject repair rejected: identity/evidence/scope/version/duplicate guard did not match"
  Gate -> do
    migrate pool migrationsDir
    withConn pool $ \connection -> do
      reproject connection
      verify connection

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
    expected <- expectedProjection connection row >>= either die pure
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

verify :: Connection -> IO ()
verify connection = do
  schemaProblems <- fmap concat . forM schemaChecks $ \(label, sql) -> do
    violations <- scalarCount connection sql
    pure [label <> ": " <> show violations | violations /= 0]
  projectionProblems <- verifyProjections connection
  counts <- ledgerCounts connection
  putStrLn ("ledger: " <> counts)
  let problems = schemaProblems <> projectionProblems
  unless (null problems) $ do
    putStrLn "ADR 003 release gate FAILED:"
    mapM_ (putStrLn . ("  - " <>)) (take 50 problems)
    when (length problems > 50) $ putStrLn ("  - ... and " <> show (length problems - 50) <> " more")
    die "database integrity verification failed"
  operationalHealth connection
  putStrLn "verification PASSED (schema, IR, projections, and ledger)"

-- | Report stored failures and unresolved effects without changing history.
-- Process-local queue depth and worker liveness require the running admin API.
operationalHealth :: Connection -> IO ()
operationalHealth connection = do
  measurements <- forM operationalChecks $ \(label, critical, sql) -> do
    count <- scalarCount connection sql
    putStrLn ("health: " <> label <> "=" <> show count)
    pure (label, critical, count)
  let problems =
        [ label <> ": " <> show count
        | (label, critical, count) <- measurements,
          critical,
          count /= 0
        ]
  unless (null problems) $ do
    putStrLn "Operational health check FAILED:"
    mapM_ (putStrLn . ("  - " <>)) problems
    die "stored failures or unresolved effects require operator attention"
  putStrLn "Operational health check PASSED"

verifyProjections :: Connection -> IO [String]
verifyProjections connection = do
  rows <- projectionRows connection
  fmap concat . forM rows $ \row ->
    expectedProjection connection row >>= \case
      Left err -> pure [err]
      Right expected ->
        pure
          [ "canonical message " <> show row.canonicalMessageId <> " has a stale rendered_text projection"
          | expected /= row.renderedText
          ]

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

ledgerCounts :: Connection -> IO String
ledgerCounts connection = do
  messages <- scalarCount connection "SELECT count(*) FROM messages"
  events <- scalarCount connection "SELECT count(*) FROM platform_events"
  relations <- scalarCount connection "SELECT count(*) FROM message_relations"
  deliveries <- scalarCount connection "SELECT count(*) FROM message_deliveries"
  pure
    ( "messages="
        <> show messages
        <> ", events="
        <> show events
        <> ", relations="
        <> show relations
        <> ", deliveries="
        <> show deliveries
    )

parseCommand :: [String] -> IO Command
parseCommand = \case
  ["migrate"] -> pure Migrate
  ["reproject"] -> pure Reproject
  ["verify"] -> pure Verify
  ["health"] -> pure Health
  ["gate"] -> pure Gate
  ["memory", "reviews"] -> pure MemoryReviewQueue
  ["memory", "repair-subject", group, memory, version, principal, reason] -> case (readMaybe group, readMaybe memory, readMaybe version, readMaybe principal) of
    (Just g, Just m, Just v, Just p) -> pure (MemoryRepairSubject g m v p (T.pack reason))
    _ -> die "subject repair requires numeric legacy conversation, memory, expected version and canonical principal ids"
  ["memory", "review", group, capture, index, actor, reason, path] -> case (readMaybe group, readMaybe capture, readMaybe index) of
    (Just g, Just c, Just i) -> pure (MemoryReview g c i (T.pack actor) (T.pack reason) path)
    _ -> die "memory review requires numeric legacy conversation id, capture id and proposal index"
  _ ->
    die
      "usage: cabal run max-adr003-maintenance -- \
      \(migrate|reproject|verify|health|gate)\n\
      \  memory reviews\n\
      \  memory repair-subject LEGACY_GROUP MEMORY EXPECTED_VERSION PRINCIPAL REASON\n\
      \  memory review LEGACY_GROUP CAPTURE INDEX ACTOR REASON PROPOSAL_JSON_FILE\n\
      \  environment: MAX_DB_URL (required), MAX_MIGRATIONS_DIR (default: migrations)"

requireEnv :: String -> IO String
requireEnv name =
  lookupEnv name >>= \case
    Just value | not (null value) -> pure value
    _ -> die (name <> " must be set explicitly")
