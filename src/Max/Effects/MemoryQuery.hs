{-# LANGUAGE TypeFamilies #-}

-- | Read semantic memories in one host-bound conversation and subject scope.
module Max.Effects.MemoryQuery (MemoryQuery, listMemories, runMemoryQuery) where

import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope)
import Max.Memory.Policy (MemorySubject)
import Max.Memory.Types (MemoryItem, subjectNamespace)
import Max.MemoryStore qualified as DB
import Max.Platform.Types (PrincipalId (..))

data MemoryQuery :: Effect where
  ListMemories :: MemorySubject -> MemoryQuery m [MemoryItem]

type instance DispatchOf MemoryQuery = Dynamic

listMemories :: (MemoryQuery :> es) => MemorySubject -> Eff es [MemoryItem]
listMemories = send . ListMemories

runMemoryQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> PrincipalId -> Eff (MemoryQuery : es) a -> Eff es a
runMemoryQuery conversation (PrincipalId principal) = interpret $ \_ -> \case
  ListMemories subject -> DB.listMemories (subjectNamespace conversation principal subject)
