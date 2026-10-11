-- | Durable post-commit consumption of canonical messages. A row lock owns
-- bounded, effect-free evaluation; cancellation rolls back only derived work.
module Max.DB.MessageProjection
  ( processNextProjection,
    drainProjections,
    claimMessageDispatch,
    finishMessageDispatch,
    interruptMessageDispatches,
  )
where

import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Hook (evaluateSnapshot)
import Max.DB.Monitor (evaluateLedgerMatches)
import Max.DB.Transaction (withCommittedTransaction, withTransaction)
import Max.Dispatch (DispatchMessage (..), dispatchText)
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Util (trySync)

processNextProjection :: (WithConnection :> es, IOE :> es) => Eff es Bool
processNextProjection = withCommittedTransaction $ do
  rows <-
    query
      "SELECT p.canonical_message_id,p.conversation_id,c.legacy_group_id,p.ingest_seq,p.dispatch_requested,p.monitor_requested,m.received_at FROM message_projections p JOIN conversations c USING(conversation_id) JOIN messages m USING(canonical_message_id) WHERE p.work_pending AND NOT EXISTS (SELECT 1 FROM message_projections earlier WHERE earlier.conversation_id=p.conversation_id AND earlier.work_pending AND earlier.ingest_seq<p.ingest_seq) ORDER BY p.ingest_seq LIMIT 1 FOR UPDATE OF p SKIP LOCKED"
      ()
  case rows :: [(Int64, Int64, Int64, Int64, Bool, Bool, UTCTime)] of
    [] -> pure False
    [(mid, conversation, group, sequenceNumber, dispatchRequested, monitorRequested, received)] -> do
      -- The savepoint discards partial audit/monitor work on a synchronous host
      -- error. An async exception escapes both transactions, leaving pending work
      -- for restart recovery. Canonical ingest has already committed either way.
      attempted <- trySync $ withTransaction $ do
        (ignored, failed) <- evaluateSnapshot group mid
        void $
          execute
            "UPDATE message_projections SET status=?,context_visible=?,allow_activation=?,work_pending=false,evaluated_at=now(),last_error=? WHERE canonical_message_id=?"
            (if failed then "error" else "ready" :: Text, not ignored, not ignored, if failed then Just ("hook execution failed; see query_hooks runs" :: Text) else Nothing, mid)
        when (not ignored && (dispatchRequested || monitorRequested)) $ do
          -- Ingest and other monitor operations acquire the conversation before
          -- monitor rows. Do this only after bounded guest execution completes.
          (_ :: [Only Int64]) <- query "SELECT conversation_id FROM conversations WHERE conversation_id=? FOR UPDATE" (Only conversation)
          visible <- loadDispatchMessage (CanonicalMessageId mid)
          forM_ visible $ \message -> do
            when monitorRequested $
              void $
                evaluateLedgerMatches
                  conversation
                  sequenceNumber
                  (CanonicalMessageId mid)
                  message.authorPrincipalId
                  message.selfPrincipalId
                  message.mentionPrincipals
                  (dispatchText message)
                  message.body
                  received
            when dispatchRequested $
              void $
                execute
                  "INSERT INTO message_projection_dispatches(canonical_message_id) VALUES(?) ON CONFLICT DO NOTHING"
                  (Only mid)
      case attempted of
        Right () -> pure ()
        Left err ->
          void $
            execute
              "UPDATE message_projections SET status='error',context_visible=false,allow_activation=false,work_pending=false,evaluated_at=now(),last_error=? WHERE canonical_message_id=?"
              (diagnostic (T.pack (show err)), mid)
      pure True
    _ -> error "projection selection cardinality"

-- | Useful to bounded callers/tests; production uses the same one-row worker.
drainProjections :: (WithConnection :> es, IOE :> es) => Eff es ()
drainProjections = processNextProjection >>= (`when` drainProjections)

-- | Commit the handoff before starting any external command. Unstarted work
-- survives restart; started work is never blindly replayed after a crash.
claimMessageDispatch :: (WithConnection :> es, IOE :> es) => Eff es (Maybe CanonicalMessageId)
claimMessageDispatch = withCommittedTransaction $ do
  rows <-
    query
      "WITH candidate AS (SELECT d.canonical_message_id FROM message_projection_dispatches d JOIN agent_messages m USING(canonical_message_id) JOIN message_projections p USING(canonical_message_id) WHERE d.status='pending' AND p.allow_activation ORDER BY m.ingest_seq LIMIT 1 FOR UPDATE OF d SKIP LOCKED) UPDATE message_projection_dispatches d SET status='started',started_at=now() FROM candidate WHERE d.canonical_message_id=candidate.canonical_message_id RETURNING d.canonical_message_id"
      ()
  pure $ case rows of [Only mid] -> Just (CanonicalMessageId mid); _ -> Nothing

finishMessageDispatch :: (WithConnection :> es, IOE :> es) => CanonicalMessageId -> Maybe Text -> Eff es ()
finishMessageDispatch (CanonicalMessageId mid) failure =
  void $
    execute
      "UPDATE message_projection_dispatches SET status=?,finished_at=now(),last_error=? WHERE canonical_message_id=? AND status='started'"
      (maybe "finished" (const "failed") failure :: Text, diagnostic <$> failure, mid)

interruptMessageDispatches :: (WithConnection :> es, IOE :> es) => Eff es Int64
interruptMessageDispatches =
  execute
    "UPDATE message_projection_dispatches SET status='interrupted',finished_at=now(),last_error='process ended after dispatch started; effects are not replayed' WHERE status='started'"
    ()

diagnostic :: Text -> Text
diagnostic = T.take 512 . T.filter (/= '\0')
