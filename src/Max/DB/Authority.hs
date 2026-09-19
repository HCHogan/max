-- | Identity and live-turn checks share the business mutation's transaction.
module Max.DB.Authority (authorizeCallerWithin) where

import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.ConversationLock (lockTurnConversation)
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Platform.Types (PrincipalId (..))
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

authorizeCallerWithin :: (InTransaction :> es, WithConnection :> es, IOE :> es) => AgentTurnId -> GroupId -> PrincipalId -> Eff es Bool
authorizeCallerWithin turn (GroupId group) (PrincipalId actor) = do
  requireTransaction
  locked <- lockTurnConversation turn
  if not locked
    then pure False
    else do
      rows <- query "SELECT true FROM agent_turns t JOIN conversations c USING(conversation_id) WHERE t.turn_id=? AND c.legacy_group_id=? AND t.initiator_principal_id=? AND t.status IN ('starting','running') FOR UPDATE OF t" (turn, group, actor)
      pure (rows == [Only True])
