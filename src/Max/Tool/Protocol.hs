-- | Decode before entering the domain runner, retaining its explicit outcome.
module Max.Tool.Protocol (argumentTool, readResult, committedResult) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful (Eff)
import Max.Effects.Tools
  ( Tool (Tool),
    ToolFault (ToolFault),
    ToolOutcome
      ( ToolCommitted,
        ToolFailedBeforeEffect,
        ToolRejected,
        ToolSucceeded
      ),
    ToolRetryClass (RetrySafe),
    ToolRunner (OutcomeRunner),
  )
import Max.Tool.Arguments
  ( Arguments,
    argumentsSchema,
    parseArguments,
  )

argumentTool :: Text -> Text -> Arguments a -> (a -> Eff es ToolOutcome) -> Tool es
argumentTool name description arguments run =
  Tool name description (argumentsSchema arguments) . OutcomeRunner $ \raw ->
    either (pure . ToolRejected . fault) run (parseArguments arguments raw)

-- These adapters belong at operations whose normal Left path is known to
-- precede their effects. Exceptions/timeouts are handled separately by Tools.
readResult :: Either Text Value -> ToolOutcome
readResult = either (ToolFailedBeforeEffect . fault) ToolSucceeded

committedResult :: Either Text Value -> ToolOutcome
committedResult = either (ToolFailedBeforeEffect . fault) ToolCommitted

fault :: Text -> ToolFault
fault message = ToolFault "tool_error" message RetrySafe
