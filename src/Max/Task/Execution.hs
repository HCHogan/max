-- | Current execution report rejection. Display text never decides control.
module Max.Task.Execution (ExecutionFailure (..), renderExecutionFailure) where

import Data.Text (Text)

data ExecutionFailure
  = ExecutionContextMissing
  | ExecutionReportRejected
  | ExecutionInvalidPayload !Text
  deriving stock (Eq, Show)

renderExecutionFailure :: ExecutionFailure -> Text
renderExecutionFailure ExecutionContextMissing = "没有持久化执行上下文"
renderExecutionFailure ExecutionReportRejected = "报告无效或当前执行已失去 revision/lease 所有权"
renderExecutionFailure (ExecutionInvalidPayload detail) = "payload 不符合当前 output_contract：" <> detail <> "。返回契约要求的原生 JSON 值，不要把对象序列化成字符串。"
