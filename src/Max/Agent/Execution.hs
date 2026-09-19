-- | Local admission, diagnostic storage and feedback supplied by assembly.
module Max.Agent.Execution (ExecutionAdmission (..), ExecutionJournal (..), ExecutionInbox (..)) where

import Data.Text (Text)
import Effectful (Eff)
import Max.Execution.Types
import Max.Turn.Types (AgentTurnRef, ExecutionOrdinal)
import OneBot.Types (GroupId)

data ExecutionAdmission es = ExecutionAdmission
  { eaReserveRound :: AgentTurnRef -> Eff es Bool,
    eaCheck :: AgentTurnRef -> Eff es Bool,
    eaAdmitTool :: AgentTurnRef -> ExecutionStep -> Eff es Bool
  }

data ExecutionJournal es = ExecutionJournal
  { ejRecordNote :: AgentTurnRef -> ExecutionOrdinal -> Text -> Eff es (),
    ejPrepare :: GroupId -> JournalStart -> Eff es JournalStart,
    ejFinish :: JournalExecution -> JournalFinish -> Eff es ()
  }

newtype ExecutionInbox es = ExecutionInbox {eiRead :: AgentTurnRef -> Eff es Text}
