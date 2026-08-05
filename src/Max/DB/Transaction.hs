{-# LANGUAGE GADTs #-}

-- | Transactions that remain on one physical PostgreSQL connection.
--
-- effectful-postgresql 0.1.0.1 opens the transaction through
-- 'withConnection', but its pooled interpreter lets operations in the body
-- acquire fresh connections. Interposing 'WithConnection' while the body runs
-- makes the transaction boundary real rather than merely syntactic.
module Max.DB.Transaction (withTransaction, withPinnedConnection) where

import Database.PostgreSQL.Simple qualified as PostgreSQL
import Effectful
import Effectful.Dispatch.Dynamic (interpose, localSeqUnlift)
import Effectful.PostgreSQL.Connection (WithConnection (..), withConnection)

withTransaction ::
  (WithConnection :> es, IOE :> es) =>
  Eff es a ->
  Eff es a
withTransaction action =
  withConnection $ \connection ->
    withSeqEffToIO $ \unlift ->
      liftIO $
        PostgreSQL.withTransaction connection $
          unlift (withPinnedConnection connection action)

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
