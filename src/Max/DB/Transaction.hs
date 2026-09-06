{-# LANGUAGE GADTs #-}

-- | Transactions that remain on one physical PostgreSQL connection.
--
-- effectful-postgresql 0.1.0.1 opens the transaction through
-- 'withConnection', but its pooled interpreter lets operations in the body
-- acquire fresh connections. Interposing 'WithConnection' while the body runs
-- makes the transaction boundary real rather than merely syntactic.
module Max.DB.Transaction (withTransaction, withCommittedTransaction, withReadSnapshot, withPinnedConnection) where

import Database.PostgreSQL.LibPQ qualified as PQ
import Database.PostgreSQL.Simple qualified as PostgreSQL
import Database.PostgreSQL.Simple.Internal qualified as PostgreSQLInternal
import Database.PostgreSQL.Simple.Transaction qualified as Transaction
import Effectful
import Effectful.Dispatch.Dynamic (interpose, localSeqUnlift)
import Effectful.PostgreSQL.Connection (WithConnection (..), withConnection)

withTransaction ::
  (WithConnection :> es, IOE :> es) =>
  Eff es a ->
  Eff es a
withTransaction = withTransactionMode Transaction.defaultTransactionMode

-- | For write-through caches: returning must mean COMMIT has completed, so a
-- caller cannot publish state that an enclosing transaction may roll back.
withCommittedTransaction :: (WithConnection :> es, IOE :> es) => Eff es a -> Eff es a
withCommittedTransaction action = withConnection $ \connection ->
  withSeqEffToIO $ \unlift -> liftIO $ do
    status <- PostgreSQLInternal.withConnection connection PQ.transactionStatus
    case status of
      PQ.TransIdle -> Transaction.withTransaction connection (unlift (withPinnedConnection connection action))
      _ -> ioError (userError "write-through cache mutation requires its own transaction")

-- | A standalone read uses one repeatable, read-only snapshot. Nested reads
-- share the caller's transaction/isolation and cannot commit it.
withReadSnapshot :: (WithConnection :> es, IOE :> es) => Eff es a -> Eff es a
withReadSnapshot = withTransactionMode (Transaction.TransactionMode Transaction.RepeatableRead Transaction.ReadOnly)

withTransactionMode :: (WithConnection :> es, IOE :> es) => Transaction.TransactionMode -> Eff es a -> Eff es a
withTransactionMode mode action =
  withConnection $ \connection ->
    withSeqEffToIO $ \unlift ->
      liftIO $ do
        status <- PostgreSQLInternal.withConnection connection PQ.transactionStatus
        let pinned = unlift (withPinnedConnection connection action)
        case status of
          PQ.TransIdle -> Transaction.withTransactionMode mode connection pinned
          -- Composing domain operations must never COMMIT their caller's
          -- transaction. A savepoint scopes failure while preserving the
          -- outer atomic publication/settlement boundary.
          PQ.TransInTrans -> Transaction.withSavepoint connection pinned
          _ -> ioError (userError "database connection cannot enter a transaction in its current state")

-- | Run a sub-computation on one already-held connection instead of letting
-- the pooled interpreter hand out a fresh one per statement.  A caller that
-- owns a connection and then blocks on acquiring a second one can exhaust the
-- pool against itself, so long-lived holders (transactions, LISTEN/NOTIFY
-- waiters) pin their body here.
withPinnedConnection ::
  (WithConnection :> es) =>
  PostgreSQL.Connection ->
  Eff es a ->
  Eff es a
withPinnedConnection connection =
  interpose $ \localEnv -> \case
    WithConnection use ->
      localSeqUnlift localEnv $ \unlift -> unlift (use connection)
