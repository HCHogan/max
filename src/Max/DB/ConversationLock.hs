-- | Common commit-lock order for conversation-owned state. Callers hold a
-- pinned transaction; these operations never start or commit one themselves.
module Max.DB.ConversationLock (lockConversation, lockTurnConversation, lockTaskConversation) where

import Data.Int (Int64)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.Turn.Types (AgentTurnId)

lockTurnConversation :: (WithConnection :> es, IOE :> es) => AgentTurnId -> Eff es Bool
lockTurnConversation turn = do
  rows <- query "SELECT c.conversation_id FROM conversations c JOIN agent_turns t USING(conversation_id) WHERE t.turn_id=? FOR UPDATE OF c" (Only turn)
  pure (not (null (rows :: [Only Int64])))

lockTaskConversation :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
lockTaskConversation task = do
  rows <- query "SELECT c.conversation_id FROM conversations c JOIN durable_tasks t USING(conversation_id) WHERE t.task_id=? FOR UPDATE OF c" (Only task)
  pure (not (null (rows :: [Only Int64])))

lockConversation :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es Bool
lockConversation group = do
  rows <- query "SELECT conversation_id FROM conversations WHERE legacy_group_id=? FOR UPDATE" (Only group)
  pure (not (null (rows :: [Only Int64])))
