-- | Conversation ownership and admission priority. Progress reviews yield an
-- unpublished activation to real foreground work under the same commit lock.
module Max.DB.Task.Frontend (FrontendAdmission (..), admitFrontend, claimFrontend, frontendWorkWaitingWithin) where

import Control.Monad (unless, void)
import Data.Int (Int64)
import Data.Time (addUTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.AgentTurn (AgentTurnTerminal (TurnAborted), finishAgentTurn)
import Max.DB.Task.FrontendInput (queueInputWithin)
import Max.DB.Task.Record (databaseNow, lockTurnConversation)
import Max.DB.Transaction (withTransaction)
import Max.Task.Policy (frontendLeaseSeconds)
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..))

-- | Caller holds the conversation lock. Only already-eligible foreground work
-- counts: ordinary room chatter has not necessarily asked Max to do anything.
frontendWorkWaitingWithin :: (WithConnection :> es, IOE :> es) => Int64 -> Maybe AgentTurnId -> Eff es Bool
frontendWorkWaitingWithin conversation excluding = do
  rows <-
    query
      "SELECT EXISTS(SELECT 1 FROM agent_turns t WHERE t.conversation_id=?\
      \ AND (?::bigint IS NULL OR t.turn_id<>?) AND t.status IN ('starting','running','recovery-pending')\
      \ AND NOT EXISTS(SELECT 1 FROM task_attempts a WHERE a.turn_id=t.turn_id)\
      \ AND NOT EXISTS(SELECT 1 FROM task_notifications n WHERE n.turn_id=t.turn_id)\
      \ AND NOT EXISTS(SELECT 1 FROM conversation_requests r WHERE r.turn_id=t.turn_id AND r.disposition='delegated'))\
      \ OR EXISTS(SELECT 1 FROM message_dispatches d JOIN messages m USING(canonical_message_id)\
      \ WHERE m.conversation_id=? AND d.status='deferred')"
      (conversation, excluding, excluding, conversation)
  pure (rows == [Only True])

claimFrontend :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Eff es Bool
claimFrontend turn = (== FrontendClaimed) <$> admitFrontend turn Nothing

data FrontendAdmission = FrontendClaimed | FrontendInputQueued | FrontendBusy
  deriving stock (Eq, Show)

-- | Nothing requests a separate frontend; Just records whether the speaker
-- explicitly labelled this input as feedback. Meaning stays with the model.
admitFrontend :: (WithConnection :> es, IOE :> es) => AgentTurnRef -> Maybe Bool -> Eff es FrontendAdmission
admitFrontend turn input = withTransaction $ do
  locked <- lockTurnConversation turn.atrTurnId
  active <-
    if locked
      then
        query
          "SELECT conversation_id,trigger_canonical_message_id FROM agent_turns WHERE turn_id=? AND status IN ('starting','running','recovery-pending') FOR UPDATE"
          (Only turn.atrTurnId)
      else pure []
  case active :: [(Int64, Maybe Int64)] of
    [(conversation, trigger)] -> do
      review <- query "SELECT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=? AND kind='progress')" (Only turn.atrTurnId)
      let progress = review == [Only True]
      waiting <- if progress then frontendWorkWaitingWithin conversation (Just turn.atrTurnId) else pure False
      -- Removing the lease fences every late publication before the new owner
      -- starts. The review's shared lease watcher cancels its model request.
      unless progress $
        void $
          execute
            "DELETE FROM conversation_frontends f USING task_notifications n\
            \ WHERE f.conversation_id=? AND f.turn_id<>? AND n.turn_id=f.turn_id AND n.kind='progress'\
            \ AND NOT EXISTS(SELECT 1 FROM messages m WHERE m.agent_turn_id=f.turn_id)"
            (conversation, turn.atrTurnId)
      occupied <-
        query
          "SELECT turn_id FROM conversation_frontends WHERE conversation_id=? AND turn_id<>? AND lease_until>clock_timestamp()"
          (conversation, turn.atrTurnId)
      queued <- case (input, occupied) of
        (Just explicit, [Only target]) -> queueInputWithin turn.atrTurnId target explicit
        _ -> pure False
      if queued
        then do
          -- A crash between input assignment and source cleanup must not recover
          -- a second frontend for the same input. Both commit together.
          finishAgentTurn turn TurnAborted 0 (Just "input assigned to the active conversation frontend") Nothing
          pure FrontendInputQueued
        else
          if waiting || not (null occupied)
            then pure FrontendBusy
            else do
              now <- databaseNow
              void $
                execute
                  "INSERT INTO conversation_frontends(conversation_id,turn_id,lease_until) VALUES(?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET turn_id=excluded.turn_id,lease_until=excluded.lease_until,accepting_input=true"
                  (conversation, turn.atrTurnId, addUTCTime (fromIntegral frontendLeaseSeconds) now)
              void $ execute "UPDATE agent_turns SET frontend_managed=true WHERE turn_id=?" (Only turn.atrTurnId)
              void $
                execute
                  "UPDATE conversation_frontends SET accepting_input=false WHERE turn_id=?\
                  \ AND (EXISTS(SELECT 1 FROM request_outcomes WHERE turn_id=?)\
                  \ OR EXISTS(SELECT 1 FROM durable_tasks WHERE source_turn_id=? AND parent_task_id IS NULL))"
                  (turn.atrTurnId, turn.atrTurnId, turn.atrTurnId)
              -- Recovery reconstructs the model context. A prior observation was
              -- not a durable model response, so the same owner must see inputs again.
              void $ execute "UPDATE frontend_inputs SET seen_at=NULL WHERE turn_id=? AND released_at IS NULL" (Only turn.atrTurnId)
              void $
                execute
                  "INSERT INTO conversation_requests(message_id,turn_id) SELECT ?,? WHERE ?::bigint IS NOT NULL AND NOT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=?) ON CONFLICT(message_id) DO UPDATE SET turn_id=excluded.turn_id WHERE conversation_requests.disposition='pending'"
                  (trigger, turn.atrTurnId, trigger, turn.atrTurnId)
              pure FrontendClaimed
    _ -> pure FrontendBusy
