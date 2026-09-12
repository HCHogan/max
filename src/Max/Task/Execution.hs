-- | Current execution report rejection. Display text never decides control.
module Max.Task.Execution (ExecutionFailure (..), renderExecutionFailure) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T

data ExecutionFailure
  = ExecutionContextMissing
  | ExecutionReportRejected
  | ExecutionInvalidPayload !Text
  | ExecutionInputPending
  | ExecutionOwnershipLost
  | ExecutionNotFrontend
  | ExecutionInvalidRequest !Text
  | ExecutionInputUnowned ![Int64]
  | ExecutionTriggerConflict
  | ExecutionRequestConflict
  deriving stock (Eq, Show)

renderExecutionFailure :: ExecutionFailure -> Text
renderExecutionFailure ExecutionContextMissing = "没有持久化执行上下文"
renderExecutionFailure ExecutionReportRejected = "报告无效或当前执行已失去 revision/lease 所有权"
renderExecutionFailure (ExecutionInvalidPayload detail) = "payload 不符合当前 output_contract：" <> detail <> "。返回契约要求的原生 JSON 值，不要把对象序列化成字符串。"
renderExecutionFailure ExecutionInputPending = "有尚未读入上下文的前台输入，暂不能结束。下一轮先阅读收件箱，再重新决定答复；不要重复发送正文。"
renderExecutionFailure ExecutionOwnershipLost = "当前前台执行已结束或失去 lease 所有权，不能提交 request_finish。"
renderExecutionFailure ExecutionNotFrontend = "request_finish 只用于普通前台请求，不能用于后台任务或任务通知。"
renderExecutionFailure (ExecutionInvalidRequest reason) = "request_finish 参数无效：" <> reason
renderExecutionFailure (ExecutionInputUnowned messages) =
  "inputs 含有不属于本轮已读收件箱的 message_id："
    <> T.intercalate ", " (map (T.pack . show) messages)
    <> "。只填写前台收件箱明确提供的追加消息；原始请求由顶层 disposition 处理。"
renderExecutionFailure ExecutionTriggerConflict = "inputs 中原始请求的 disposition 与顶层 disposition 冲突；请移除原始请求条目，或使两者一致。"
renderExecutionFailure ExecutionRequestConflict = "本轮已记录不同的 request_finish；不能覆盖已提交的答复或输入处置。"
