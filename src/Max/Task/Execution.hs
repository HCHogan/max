-- | Current execution report rejection. Display text never decides control.
module Max.Task.Execution (ExecutionFailure (..), renderExecutionFailure) where

import Data.Text (Text)

data ExecutionFailure = ExecutionContextMissing | ExecutionReportRejected deriving stock (Eq, Show)

renderExecutionFailure :: ExecutionFailure -> Text
renderExecutionFailure ExecutionContextMissing = "没有持久化执行上下文"
renderExecutionFailure ExecutionReportRejected = "报告无效或当前执行已失去 revision/lease 所有权"
