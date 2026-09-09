-- | Durable foreground input assignment and observation. Callers of the
-- Within functions hold the conversation commit lock. Canonical bodies stay
-- in the ledger; observation never discharges a request.
module Max.DB.Task.FrontendInput
  ( queueInputWithin,
    readInputs,
    unseenInputWithin,
    closeInputWithin,
    settleInputsWithin,
    pendingRequest,
    deferRequest,
  )
where

import Control.Monad (forM_, void, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization (ExecutionStep (ExecutionCheckpoint), authorizeWithin)
import Max.DB.Task.Record (lockTurnConversation)
import Max.DB.Transaction (withTransaction)
import Max.Task.FrontendInput (FrontendInputView (..), renderFrontendInputs)
import Max.Task.State (RequestDisposition (..), dispositionText)
import Max.Turn.Types (AgentTurnId)

-- | A previously accepted obligation bypasses intent reclassification on
-- redispatch. Otherwise cooldown could silently discard an unserved input.
pendingRequest :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
pendingRequest message = do
  rows <-
    query
      "SELECT EXISTS(SELECT 1 FROM conversation_requests WHERE message_id=? AND disposition='pending')"
      (Only message)
  pure (rows == [Only True])

-- | Persist eligibility even when the source came from the intent worker and
-- has no live dispatch owner. Merely retrying the classifier loses requests.
deferRequest :: (WithConnection :> es, IOE :> es) => AgentTurnId -> UTCTime -> Eff es ()
deferRequest turn retryAt = withTransaction $ do
  _ <- lockTurnConversation turn
  sources <-
    query
      "SELECT trigger_canonical_message_id FROM agent_turns WHERE turn_id=? AND trigger_canonical_message_id IS NOT NULL\
      \ AND status IN ('starting','running','recovery-pending')"
      (Only turn)
  forM_ (sources :: [Only Int64]) $ \(Only message) -> do
    void $
      execute
        "INSERT INTO conversation_requests(message_id,turn_id) VALUES(?,?) ON CONFLICT(message_id) DO UPDATE SET turn_id=excluded.turn_id\
        \ WHERE conversation_requests.disposition='pending'\
        \ AND NOT EXISTS(SELECT 1 FROM frontend_inputs input WHERE input.message_id=excluded.message_id AND input.released_at IS NULL)\
        \ AND NOT EXISTS(SELECT 1 FROM conversation_frontends frontend WHERE frontend.turn_id=conversation_requests.turn_id AND frontend.lease_until>clock_timestamp())"
        (message, turn)
    void $
      execute
        "UPDATE message_dispatches SET status='deferred',next_attempt_at=?,completed_at=NULL,lease_owner=NULL,\
        \ lease_expires_at=NULL,updated_at=now() WHERE canonical_message_id=?\
        \ AND EXISTS(SELECT 1 FROM conversation_requests WHERE message_id=? AND turn_id=? AND disposition='pending')"
        (retryAt, message, message, turn)

-- | The source is a newly admitted conversational turn, not a task/monitor
-- or a recovery. Actor equality is a host rule: an incoming message must not
-- borrow another principal's tool capabilities by steering their frontend.
queueInputWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> AgentTurnId -> Bool -> Eff es Bool
queueInputWithin source target explicit = do
  rows <-
    query
      "SELECT message.canonical_message_id,\
      \ (message.reply_to_canonical_message_id=active.trigger_canonical_message_id\
      \ OR EXISTS(SELECT 1 FROM messages output WHERE output.canonical_message_id=message.reply_to_canonical_message_id AND output.agent_turn_id=active.turn_id)) IS TRUE\
      \ FROM agent_turns incoming JOIN agent_turns active USING(conversation_id)\
      \ JOIN conversation_frontends frontend ON frontend.turn_id=active.turn_id\
      \ JOIN messages message ON message.canonical_message_id=incoming.trigger_canonical_message_id\
      \ JOIN messages trigger ON trigger.canonical_message_id=active.trigger_canonical_message_id\
      \ WHERE incoming.turn_id=? AND active.turn_id=? AND incoming.initiator_principal_id=active.initiator_principal_id\
      \ AND message.author_principal_id=active.initiator_principal_id AND message.conversation_id=active.conversation_id\
      \ AND message.ingest_seq>trigger.ingest_seq AND frontend.accepting_input\
      \ AND NOT EXISTS(SELECT 1 FROM conversation_requests request WHERE request.message_id=message.canonical_message_id AND request.disposition<>'pending')\
      \ AND frontend.lease_until>clock_timestamp() AND active.status IN ('starting','running','recovery-pending')\
      \ AND NOT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id IN (?,?))\
      \ AND NOT EXISTS(SELECT 1 FROM task_attempts WHERE turn_id IN (?,?))\
      \ AND (SELECT count(*) FROM frontend_inputs WHERE turn_id=? AND released_at IS NULL)<256"
      (source, target, source, target, source, target, target)
  case rows :: [(Int64, Bool)] of
    [(message, related)] -> do
      let kind = if explicit || related then "steering" else "message" :: Text
      void $
        execute
          "INSERT INTO frontend_inputs(turn_id,message_id,kind) VALUES(?,?,?) ON CONFLICT DO NOTHING"
          (target, message, kind)
      assigned <-
        query
          "SELECT EXISTS(SELECT 1 FROM frontend_inputs WHERE turn_id=? AND message_id=? AND released_at IS NULL)"
          (target, message)
      if assigned /= [Only True]
        then pure False
        else do
          void $
            execute
              "INSERT INTO conversation_requests(message_id,turn_id) VALUES(?,?) ON CONFLICT(message_id) DO UPDATE\
              \ SET turn_id=excluded.turn_id,disposition='pending',reason=NULL,updated_at=now() WHERE conversation_requests.disposition='pending'"
              (message, target)
          -- Dispatch has transferred custody, not answered the request. Commit
          -- this with the inbox so a crash cannot resurrect the source dispatch.
          void $
            execute
              "UPDATE message_dispatches SET status='completed',completed_at=clock_timestamp(),lease_owner=NULL,\
              \ lease_expires_at=NULL,updated_at=now() WHERE canonical_message_id=?"
              (Only message)
          pure True
    _ -> pure False

readInputs :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Text
readInputs turn = withTransaction $ do
  allowed <- authorizeWithin turn ExecutionCheckpoint
  rows <-
    query
      "SELECT input.input_id,message.canonical_message_id,input.kind,message.author_principal_id,\
      \ message.sender_nickname,message.received_at,message.reply_to_canonical_message_id,message.rendered_text\
      \ FROM frontend_inputs input JOIN messages message ON message.canonical_message_id=input.message_id\
      \ WHERE ? AND input.turn_id=? AND input.released_at IS NULL AND input.seen_at IS NULL\
      \ ORDER BY message.ingest_seq,input.input_id LIMIT 32"
      (allowed, turn)
  let inputs = rows :: [(Int64, Int64, Text, Int64, Maybe Text, UTCTime, Maybe Int64, Text)]
  forM_ inputs $ \(identifier, _, _, _, _, _, _, _) ->
    void $ execute "UPDATE frontend_inputs SET seen_at=clock_timestamp() WHERE input_id=?" (Only identifier)
  pure (renderFrontendInputs [FrontendInputView message kind author name received reply body | (_, message, kind, author, name, received, reply, body) <- inputs])

unseenInputWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
unseenInputWithin turn = do
  rows <-
    query
      "SELECT EXISTS(SELECT 1 FROM frontend_inputs WHERE turn_id=? AND released_at IS NULL AND seen_at IS NULL)"
      (Only turn)
  pure (rows == [Only True])

closeInputWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es ()
closeInputWithin turn = void $ execute "UPDATE conversation_frontends SET accepting_input=false WHERE turn_id=?" (Only turn)

-- | A final reply covers only the explicitly named, observed inputs. All
-- other inputs return to durable dispatch, including ones lost to a crash or
-- a streamed draft. Claim-attempt fencing makes a late source finalizer inert.
settleInputsWithin :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Bool -> Bool -> Text -> Eff es ()
settleInputsWithin turn published cancelled reason = do
  rows <-
    query
      "SELECT message_id,disposition FROM frontend_inputs WHERE turn_id=? AND released_at IS NULL ORDER BY input_id"
      (Only turn)
  forM_ (rows :: [(Int64, Maybe Text)]) $ \(message, decision) -> do
    let disposition
          | cancelled = dispositionText RequestCancelled
          | published = fromMaybe "pending" decision
          | otherwise = "pending"
    void $
      execute
        "UPDATE conversation_requests SET disposition=?,reason=?,updated_at=now() WHERE message_id=? AND turn_id=?"
        (disposition, reason, message, turn)
    when (disposition == "pending") $
      void $
        execute
          "UPDATE message_dispatches SET status='pending',next_attempt_at=clock_timestamp(),completed_at=NULL,\
          \ lease_owner=NULL,lease_expires_at=NULL,last_error=NULL,updated_at=now() WHERE canonical_message_id=?"
          (Only message)
  void $ execute "UPDATE frontend_inputs SET released_at=clock_timestamp() WHERE turn_id=? AND released_at IS NULL" (Only turn)
