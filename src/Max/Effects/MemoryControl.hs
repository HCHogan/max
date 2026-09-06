{-# LANGUAGE TypeFamilies #-}

-- | Explicit memory edits by the current caller. Actor, evidence, lifecycle
-- and visibility are interpreter decisions, never model-supplied authority.
module Max.Effects.MemoryControl (MemoryControl, MemoryControlScope (..), saveMemory, updateMemory, forgetMemory, runMemoryControl) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log (Log, logInfo)
import Effectful.PostgreSQL (WithConnection, query)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.Task.Authorization (authorizeCallerWithin)
import Max.DB.Transaction (withTransaction)
import Max.Memory.Policy
import Max.Memory.Types
import Max.MemoryStore qualified as DB
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId)

data MemoryControlScope = MemoryControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnId),
    principal :: !PrincipalId,
    source :: !CanonicalMessageId
  }

data MemoryControl :: Effect where
  SaveMemory :: MemorySubject -> Text -> MemoryControl m (Either MemoryWriteFailure MemoryItem)
  UpdateMemory :: MemoryId -> ExpectedVersion -> Text -> MemoryControl m (Either MemoryWriteFailure MemoryItem)
  ForgetMemory :: MemoryId -> ExpectedVersion -> MemoryControl m (Either MemoryWriteFailure MemoryItem)

type instance DispatchOf MemoryControl = Dynamic

saveMemory :: (MemoryControl :> es) => MemorySubject -> Text -> Eff es (Either MemoryWriteFailure MemoryItem)
saveMemory subject content = send (SaveMemory subject content)

updateMemory :: (MemoryControl :> es) => MemoryId -> ExpectedVersion -> Text -> Eff es (Either MemoryWriteFailure MemoryItem)
updateMemory identifier version content = send (UpdateMemory identifier version content)

forgetMemory :: (MemoryControl :> es) => MemoryId -> ExpectedVersion -> Eff es (Either MemoryWriteFailure MemoryItem)
forgetMemory identifier version = send (ForgetMemory identifier version)

runMemoryControl :: forall es a. (WithConnection :> es, Log :> es, IOE :> es) => MemoryControlScope -> Eff (MemoryControl : es) a -> Eff es a
runMemoryControl scope = interpret $ \_ -> \case
  SaveMemory subject content -> submit "memory_save" $ case checkContent content of
    Left failure -> pure (Left (MemoryContentInvalid failure))
    Right text -> do
      admitted <- DB.admitMemory AllowDuplicates (actor "memory_save") (subjectNamespace conversation principal subject) (MemoryDraft text MemoryPermanent Nothing evidence)
      pure (either (Left . MemoryAdmissionRejected) Right admitted)
  UpdateMemory identifier expected content -> submit "memory_update" $ case checkContent content of
    Left failure -> pure (Left (MemoryContentInvalid failure))
    Right text -> mutationResult <$> DB.updateVisibleMemory (actor "memory_update") visibility identifier expected (MemoryUpdate text evidence)
  ForgetMemory identifier expected ->
    submit "memory_forget" $
      mutationResult <$> DB.archiveVisibleMemory (actor "memory_forget") visibility identifier expected
  where
    conversation = conversationScopeFor scope.group
    visibility = currentConversationRecall conversation
    PrincipalId principal = scope.principal
    CanonicalMessageId source = scope.source
    actor operation = MemoryActor ActorAgentTool (Just principal) (Just (operation <> " tool"))
    evidence = MessageEvidence conversation (Just principal) source
    mutationResult (MemoryMutationApplied item) = Right item
    mutationResult MemoryMutationRejected = Left MemoryNotWritable
    submit :: Text -> Eff es (Either MemoryWriteFailure MemoryItem) -> Eff es (Either MemoryWriteFailure MemoryItem)
    submit operation action = do
      result <- case scope.turn of
        Nothing -> pure (Left MemoryCallerFenced)
        Just turn -> withTransaction $ do
          authorized <- authorizeCallerWithin turn scope.group scope.principal
          provenance <- query "SELECT EXISTS(SELECT 1 FROM agent_turns WHERE turn_id=? AND trigger_canonical_message_id=?)" (turn, source)
          if authorized && provenance == [Only True] then action else pure (Left MemoryCallerFenced)
      forM_ result $ \item -> logInfo "memory: explicit mutation" (object ["operation" .= operation, "id" .= item.memId, "version" .= item.memVersion])
      pure result
