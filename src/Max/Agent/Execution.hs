-- | Narrow interpreter contracts. Admission owns the atomic pre-effect
-- checkpoint, journal records execution facts, and inbox reads feedback.
-- These records are assembly interfaces; they do not grant raw SQL to Agent.
module Max.Agent.Execution (ExecutionAdmission (..), ExecutionJournal (..), ExecutionInbox (..)) where

import Data.Text (Text)
import Effectful (Eff)
import Max.Execution.Types
import Max.Turn.Types (AgentTurnRef)
import OneBot.Types (GroupId)

data ExecutionAdmission es = ExecutionAdmission
  { eaReserveRound :: AgentTurnRef -> Eff es Bool,
    eaCheck :: AgentTurnRef -> Eff es Bool,
    eaStartTool :: GroupId -> AgentTurnRef -> ExecutionStep -> JournalStart -> Eff es (Maybe JournalExecution)
  }

data ExecutionJournal es = ExecutionJournal
  { ejRecordNote :: AgentTurnRef -> Text -> Eff es (),
    ejFinish :: JournalExecution -> JournalFinish -> Eff es (),
    ejUnknown :: JournalExecution -> Text -> Eff es ()
  }

newtype ExecutionInbox es = ExecutionInbox {eiRead :: AgentTurnRef -> Eff es Text}
