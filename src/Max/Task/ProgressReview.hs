-- | One buffered model decision. No tool executor, database or publication
-- authority is available here; the owning frontend handles those boundaries.
module Max.Task.ProgressReview (reviewProgress) where

import Data.Text (Text)
import Effectful
import Max.Effects.LLM
import Max.Task.Progress

reviewProgress :: (LLM :> es) => ChatCtx -> Text -> [ChatMessage] -> Eff es (Either Text ProgressDecision)
reviewProgress context profile messages = do
  response <- chat context profile (messages <> [MsgSystem progressReviewPrompt]) []
  pure $ case response of
    Left failure -> Left (renderLLMFailure failure)
    Right (ContentResp text) -> parseProgressDecision text
    Right (InterruptedResp _ _) -> Left "progress review response was interrupted"
    Right ToolCallsResp {} -> Left "progress review cannot execute tools"
