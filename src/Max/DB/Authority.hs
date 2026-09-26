-- | Identity and turn/call checks share the business mutation's transaction.
module Max.DB.Authority (authorizeCallerWithin, authorizeCallWithin) where

import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.ConversationLock (lockTurnConversation)
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Execution.Authority (CallAuthority, callIsCurrent)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

authorizeCallerWithin :: (InTransaction :> es, WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> PrincipalId -> Eff es Bool
authorizeCallerWithin = authorizeCallWithin Nothing

authorizeCallWithin :: (InTransaction :> es, WithConnection :> es, IOE :> es) => Maybe CallAuthority -> AgentTurnId -> GroupId -> PrincipalId -> Eff es Bool
authorizeCallWithin authority turn (GroupId group) (PrincipalId actor) = do
  requireTransaction
  locked <- lockTurnConversation turn
  if not locked
    then pure False
    else do
      rows <- query "SELECT t.status FROM agent_turns t JOIN conversations c USING(conversation_id) WHERE t.turn_id=? AND c.legacy_group_id=? AND t.initiator_principal_id=? FOR UPDATE OF t" (turn, group, actor)
      -- Check process-local revocation after taking the database locks: an
      -- invocation may have been cancelled while waiting for this transaction.
      case (rows :: [Only Text], authority) of
        ([Only status], Nothing) -> pure (status `elem` ["starting", "running"])
        ([Only status], Just call) -> do
          current <- liftIO (callIsCurrent call turn)
          pure (current && status `elem` ["starting", "running", "succeeded", "silence", "failed"])
        _ -> pure False
