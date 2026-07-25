-- |
-- The @fetch_jobs@ work list: what inbound media we still owe
-- ourselves.  Backs the image, forward and file workers, which before
-- this queued into plain 'Control.Concurrent.STM.TQueue's and so lost
-- everything pending whenever the process went down.
--
-- __Claim, don't hold a transaction.__  A fetch can take 30s (or
-- longer for a 200 MiB file), and @SELECT … FOR UPDATE@ held across it
-- would pin a pool connection for the duration.  Instead a claim is a
-- short transaction that stamps a lease on the row and returns; the
-- @FOR UPDATE SKIP LOCKED@ inside it is only there so the image
-- worker's pool can claim concurrently without colliding.  A process
-- that dies mid-fetch leaves its lease to expire, which is why boot
-- needs no explicit recovery step.
--
-- __At least once, not exactly once.__  A crash between \"bytes
-- stored\" and 'completeJob' re-runs the fetch.  That is fine here and
-- deliberately not worked around: every write the workers do is
-- idempotent (blobs are content-addressed, the @images@ / @videos@ /
-- @message_images@ inserts are all @ON CONFLICT DO NOTHING@), so the
-- redo costs one wasted download and nothing else.
module Max.DB.FetchQueue
  ( JobKind (..),
    ClaimedJob (..),
    maxAttempts,
    enqueueJob,
    claimJobs,
    completeJob,
    failJob,
  )
where

import Data.Aeson (FromJSON, Result (..), ToJSON, Value, fromJSON, toJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)

-- | Which worker owns a row.  Stored as the @kind@ column, and also
-- what tells 'claimJobs' how to decode @payload@.
data JobKind
  = JobImage
  | JobForward
  | JobFile
  deriving stock (Show, Eq)

kindText :: JobKind -> Text
kindText = \case
  JobImage -> "image"
  JobForward -> "forward"
  JobFile -> "file"

-- | How many times a job may be claimed before it parks.  Lives here
-- and only here — the partial index keys on @parked_at@ precisely so
-- this number never has to be repeated in SQL.
maxAttempts :: Int
maxAttempts = 5

-- | A leased job, with the attempt number this claim represents (1 on
-- the first). Callers compare it against 'maxAttempts' to decide
-- whether a failure is worth another go.
data ClaimedJob a = ClaimedJob
  { cjId :: !Int64,
    cjAttempt :: !Int,
    cjPayload :: !a
  }
  deriving stock (Show)

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

-- | Queue a fetch unless @dedupe_key@ already has one.  Called on
-- every inbound message, so it is deliberately one statement that
-- usually conflicts away to nothing.
enqueueJob ::
  (WithConnection :> es, IOE :> es, ToJSON a) =>
  JobKind ->
  -- | Natural key for the job — see the call sites for the shape.
  Text ->
  a ->
  Eff es ()
enqueueJob kind key payload = do
  _ <-
    execute
      "INSERT INTO fetch_jobs (kind, dedupe_key, payload) \
      \ VALUES (?,?,?) \
      \ ON CONFLICT (kind, dedupe_key) DO NOTHING"
      (kindText kind, key, Jsonb (toJSON payload))
  pure ()

-- | Lease up to @limit@ pending jobs of one kind.  Rows whose payload
-- no longer decodes are parked rather than returned: that only happens
-- if the job record's shape changed under a queue that outlived a
-- deploy, and retrying would never fix it.
claimJobs ::
  (WithConnection :> es, Log :> es, IOE :> es, FromJSON a) =>
  JobKind ->
  -- | How long the lease should hold — comfortably longer than the
  -- slowest fetch this kind can do.
  Int ->
  -- | Max rows to take.
  Int ->
  Eff es [ClaimedJob a]
claimJobs kind leaseSeconds limit = do
  rows <-
    query
      "UPDATE fetch_jobs \
      \   SET claimed_until = now() + ((?::int) * interval '1 second'), \
      \       attempts = attempts + 1 \
      \ WHERE id IN ( \
      \   SELECT id FROM fetch_jobs \
      \    WHERE kind = ? \
      \      AND parked_at IS NULL \
      \      AND (claimed_until IS NULL OR claimed_until < now()) \
      \    ORDER BY id \
      \    LIMIT ? \
      \    FOR UPDATE SKIP LOCKED \
      \ ) \
      \ RETURNING id, attempts, payload"
      (leaseSeconds, kindText kind, limit)
  concat <$> traverse decodeRow rows
  where
    decodeRow (jid, attempt, raw) = case fromJSON raw of
      Success p -> pure [ClaimedJob {cjId = jid, cjAttempt = attempt, cjPayload = p}]
      Error err -> do
        logAttention "fetch queue: undecodable payload, parking" $
          object ["id" .= (jid :: Int64), "kind" .= kindText kind, "error" .= T.pack err]
        parkJob jid (T.pack err)
        pure []

-- | Done: the row's whole purpose is discharged, so drop it.  Keeps
-- the table to just live work, which is what lets the claim query stay
-- a plain index walk.
completeJob :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es ()
completeJob jid = do
  _ <- execute "DELETE FROM fetch_jobs WHERE id = ?" (Only jid)
  pure ()

-- | Failed.  Records why and drops the lease so the next claim picks
-- the job straight back up — unless the attempt budget is spent, in
-- which case the same statement parks it.  Deciding here rather than
-- at the call site keeps 'maxAttempts' out of all three workers.
failJob :: (WithConnection :> es, IOE :> es) => Int64 -> Text -> Eff es ()
failJob jid err = do
  _ <-
    execute
      "UPDATE fetch_jobs \
      \   SET last_error = ?, \
      \       claimed_until = NULL, \
      \       parked_at = CASE WHEN attempts >= ? THEN now() ELSE NULL END \
      \ WHERE id = ?"
      (err, maxAttempts, jid)
  pure ()

-- | Out of attempts (or undecodable): stop claiming it, keep the row.
parkJob :: (WithConnection :> es, IOE :> es) => Int64 -> Text -> Eff es ()
parkJob jid err = do
  _ <-
    execute
      "UPDATE fetch_jobs \
      \   SET last_error = ?, claimed_until = NULL, parked_at = now() \
      \ WHERE id = ?"
      (err, jid)
  pure ()
