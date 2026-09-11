-- | One buffered model decision. No tool executor, database or publication
-- authority is available here; the owning frontend handles those boundaries.
module Max.Task.NoticeReview (reviewNotice) where

import Data.Text (Text)
import Effectful
import Max.Effects.LLM
import Max.Task.Notice

reviewNotice :: (LLM :> es) => ChatCtx -> Text -> [ChatMessage] -> Eff es (Either Text NoticeDecision)
reviewNotice context profile messages = do
  response <- chat context profile (messages <> [MsgSystem noticeReviewPrompt]) []
  pure $ case response of
    Left failure -> Left (renderLLMFailure failure)
    Right (ContentResp text) -> parseNoticeDecision text
    Right (InterruptedResp _ _) -> Left "progress review response was interrupted"
    Right ToolCallsResp {} -> Left "progress review cannot execute tools"
