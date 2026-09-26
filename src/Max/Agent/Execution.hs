-- | Local admission, diagnostic storage and feedback supplied by assembly.
module Max.Agent.Execution (ExecutionAdmission (..), ExecutionJournal (..), ExecutionEvents (..), ExecutionResults (..)) where

import Control.Concurrent.STM (STM)
import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff)
import Max.Execution.Authority (CallAuthority)
import Max.Execution.Types
import Max.LLM.Types (ChatMessage)
import Max.Tasks (TurnRuntime)
import Max.Tool.Media (InlineMedia)
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnRef, ExecutionOrdinal)
import OneBot.Types (GroupId)

data ExecutionAdmission es = ExecutionAdmission
  { eaReserveRound :: AgentTurnRef -> Eff es Admission,
    eaCheck :: AgentTurnRef -> Eff es Bool,
    eaAdmitTool :: AgentTurnRef -> ExecutionStep -> Eff es Admission,
    eaCallAuthority :: AgentTurnRef -> Text -> Eff es (Maybe CallAuthority)
  }

data ExecutionJournal es = ExecutionJournal
  { ejRecordNote :: AgentTurnRef -> ExecutionOrdinal -> Text -> Eff es (),
    ejPrepare :: GroupId -> JournalStart -> Eff es JournalStart,
    ejFinish :: JournalExecution -> JournalFinish -> Eff es ()
  }

data ExecutionEvents es = ExecutionEvents
  { eeObserve :: TurnRuntime -> ToolContext -> Eff es [ChatMessage],
    eeInterrupt :: TurnRuntime -> STM (),
    eeFinish :: TurnRuntime -> Eff es Bool,
    eeResults :: TurnRuntime -> ToolContext -> Eff es (Maybe ExecutionResults),
    eeTail :: TurnRuntime -> Eff es [Text]
  }

data ExecutionResults = ExecutionResults {erDeliver :: Text -> Value -> [InlineMedia] -> IO (), erClose :: IO ()}
