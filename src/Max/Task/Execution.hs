-- | Current execution report rejection. Display text never decides control.
module Max.Task.Execution (ExecutionFailure (..), renderExecutionFailure) where

import Data.Text (Text)

data ExecutionFailure = ExecutionContextMissing | ExecutionReportRejected | ExecutionInputPending deriving stock (Eq, Show)

renderExecutionFailure :: ExecutionFailure -> Text
renderExecutionFailure ExecutionContextMissing = "没有持久化执行上下文"
renderExecutionFailure ExecutionReportRejected = "报告无效或当前执行已失去 revision/lease 所有权"
renderExecutionFailure ExecutionInputPending = "有尚未读入上下文的前台输入，暂不能结束。下一轮先阅读收件箱，再重新决定答复；不要重复发送正文。"
