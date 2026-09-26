-- | Local admission, diagnostic storage and feedback supplied by assembly.
module Max.Agent.Execution (ExecutionAdmission (..), ExecutionJournal (..), ExecutionInbox (..)) where

import Control.Concurrent.STM (STM)
import Data.Text (Text)
import Effectful (Eff)
import Max.Execution.Types
import Max.LLM.Types (ChatMessage)
import Max.Tasks (TurnRuntime)
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnRef, ExecutionOrdinal)
import OneBot.Types (GroupId)

data ExecutionAdmission es = ExecutionAdmission
  { eaReserveRound :: AgentTurnRef -> Eff es Admission,
    eaCheck :: AgentTurnRef -> Eff es Bool,
    eaAdmitTool :: AgentTurnRef -> ExecutionStep -> Eff es Admission
  }

data ExecutionJournal es = ExecutionJournal
  { ejRecordNote :: AgentTurnRef -> ExecutionOrdinal -> Text -> Eff es (),
    ejPrepare :: GroupId -> JournalStart -> Eff es JournalStart,
    ejFinish :: JournalExecution -> JournalFinish -> Eff es ()
  }

data ExecutionInbox es = ExecutionInbox
  { eiRead :: AgentTurnRef -> Eff es Text,
    eiInterrupt :: AgentTurnRef -> STM (),
    eiObserve :: TurnRuntime -> ToolContext -> Eff es [ChatMessage]
  }
