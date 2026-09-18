-- | Apply recorded expiry dates without model inference or execution leases.
module Max.Memory.Expiry (expiryWorker, expireDueMemories) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, void)
import Data.Int (Int64)
import Data.Text (Text)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Transaction (withTransaction)
import Max.Memory.Types
import Max.MemoryStore (archiveMemoryWithEvidence)
import Max.Util (catchSync)
import OneBot.Types (GroupId (..))

expiryWorker :: (WithConnection :> es, Log :> es, IOE :> es) => Eff es ()
expiryWorker = localDomain "memory-expiry" . forever $ do
  void expireDueMemories `catchSync` \err -> logAttention "expiry pass failed" (object ["error" .= show err])
  liftIO (threadDelay (300 * 1000000))

expireDueMemories :: (WithConnection :> es, IOE :> es) => Eff es Int
expireDueMemories = withTransaction $ do
  rows <-
    query
      "SELECT expiry.memory_id,expiry.memory_version,expiry.source_message_id,expiry.reason,memory.scope,memory.scope_id, \
      \ COALESCE(memory.source_group_id,memory.scope_id), \
      \ EXISTS(SELECT 1 FROM memory_human_sources source WHERE source.memory_id=expiry.memory_id AND source.memory_version=expiry.memory_version \
      \ AND source.message_id=expiry.source_message_id AND md5(source.rendered_text)=expiry.source_text_hash) \
      \ FROM memory_expirations expiry JOIN memories memory ON memory.id=expiry.memory_id \
      \ WHERE expiry.finished_at IS NULL AND expiry.due_at<=now() ORDER BY expiry.due_at LIMIT 100 FOR UPDATE OF expiry,memory"
      ()
  outcomes <- mapM expire (rows :: [(MemoryId, MemoryVersion, Int64, Text, Text, Int64, Int64, Bool)])
  pure (length (filter id outcomes))
  where
    expire (mid, version, citation, reason, kind, subject, group, sourceMatches) = do
      let scope = conversationScopeFor (GroupId group)
      result <- case if sourceMatches then parseScope kind else Nothing of
        Nothing -> pure MemoryMutationRejected
        Just lane ->
          archiveMemoryWithEvidence
            (MemoryActor ActorMaintenance Nothing (Just reason))
            (memoryNamespace scope lane subject)
            mid
            (ExpectedVersion version)
            (MessageEvidence scope Nothing citation)
      let applied = case result of MemoryMutationApplied {} -> True; _ -> False
      void $
        execute
          "UPDATE memory_expirations SET finished_at=now(),outcome=? WHERE memory_id=? AND memory_version=?"
          (if applied then "applied" :: Text else "stale_or_rejected", mid, version)
      pure applied
