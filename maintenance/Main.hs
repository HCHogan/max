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
import Data.Map.Strict qualified as Map
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
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Max.DB.Connection (DbConfig (..), DbPool, closeDbPool, newDbPool, withConn)
import Max.DB.Migrations (runMigrations)
import Max.IR
  ( Body (..),
    MentionTarget (..),
    Node (NMention),
    Phase (Canonical),
  )
import Max.IR.Prompt (promptCanonicalText)
import Max.Platform.Types
  ( NativeUserId (..),
    PrincipalIdentityId (..),
    parsePlatform,
  )
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)

data Command = Migrate | Reproject | Verify | Gate
  deriving stock (Eq, Show)

data ProjectionRow = ProjectionRow
  { canonicalMessageId :: !Int64,
    sourcePlatform :: !Text,
    originEndpointId :: !Int64,
    canonicalContent :: !Value,
    renderedText :: !Text
  }

instance FromRow.FromRow ProjectionRow where
  fromRow =
    ProjectionRow
      <$> FromRow.field
      <*> FromRow.field
      <*> FromRow.field
      <*> FromRow.field
      <*> FromRow.field

main :: IO ()
main = do
  command <- parseCommand =<< getArgs
  dbUrl <- requireEnv "MAX_DB_URL"
  migrationsDir <- maybe "migrations" id <$> lookupEnv "MAX_MIGRATIONS_DIR"
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

-- | Refuse to cross the irreversible schema boundary with active work. Older
-- pre-049 databases legitimately lack the canonical outbox tables; each check
-- is therefore discovered before its SQL is prepared.
preflightDrained :: Connection -> IO ()
preflightDrained connection = do
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
    identities <- mentionNatives connection row.originEndpointId body
    let expected = promptCanonicalText (parsePlatform row.sourcePlatform) identities body
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
    "SELECT canonical_message_id, source_platform, origin_endpoint_id, \
    \       canonical_content, rendered_text \
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
      identities <- mentionNatives connection row.originEndpointId body
      let expected = promptCanonicalText (parsePlatform row.sourcePlatform) identities body
      pure
        [ "canonical message "
            <> show row.canonicalMessageId
            <> " has a stale rendered_text projection"
          | expected /= row.renderedText
        ]

mentionNatives ::
  Connection ->
  Int64 ->
  Body 'Canonical ->
  IO (Map PrincipalIdentityId NativeUserId)
mentionNatives _ _ (Body []) = pure Map.empty
mentionNatives connection endpoint body
  | null identities = pure Map.empty
  | otherwise = do
      rows <-
        query
          connection
          "SELECT DISTINCT ON (source.principal_identity_id) \
          \       source.principal_identity_id, destination.native_user_id \
          \FROM principal_identities source \
          \JOIN conversation_endpoints endpoint ON endpoint.endpoint_id = ? \
          \JOIN principal_identities destination \
          \  ON destination.principal_id = source.principal_id \
          \ AND destination.platform_account_id = endpoint.platform_account_id \
          \WHERE source.principal_identity_id = ANY(?) \
          \ORDER BY source.principal_identity_id, destination.updated_at DESC, \
          \         destination.principal_identity_id DESC"
          (endpoint, PGArray (map unPrincipalIdentityId identities))
      pure . Map.fromList $
        [ (PrincipalIdentityId identity, NativeUserId native)
          | (identity, native) <- (rows :: [(Int64, Text)])
        ]
  where
    identities =
      [ identity
        | NMention (MentionIdentity identity) _ <- body.nodes
      ]

scalarCount :: Connection -> Query -> IO Int64
scalarCount connection sql = do
  rows <- query_ connection sql
  case rows of
    [Only count] -> pure count
    _ -> die "release-gate count query returned an unexpected shape"

schemaChecks :: [(String, Query)]
schemaChecks =
  [ ( "required final migrations missing",
      "SELECT count(*) FROM (VALUES \
      \ ('055_canonical_content_v2.sql'), ('056_delivery_lowering.sql'), \
      \ ('057_capability_tiers.sql'), ('058_work_notifications.sql'), \
      \ ('059_meta_event_outbox.sql'), ('060_canonical_forward_children.sql'), \
      \ ('061_remove_legacy_message_writers.sql'), ('062_canonical_source_hash.sql'), \
      \ ('063_admin_timeline_notifications.sql'), \
      \ ('064_admin_timeline_state_notifications.sql') \
      \) required(filename) \
      \LEFT JOIN schema_migrations migration USING (filename) \
      \WHERE migration.filename IS NULL"
    ),
    ( "messages with invalid v2 JSON shape",
      "SELECT count(*) FROM messages \
      \WHERE jsonb_typeof(canonical_content) <> 'object' \
      \   OR canonical_content->>'v' <> '2' \
      \   OR jsonb_typeof(canonical_content->'nodes') <> 'array'"
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
