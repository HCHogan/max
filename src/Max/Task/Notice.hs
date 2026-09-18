module Max.Task.Notice (TaskNotice (..), renderNotice) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Max.Task.State (ReportStatus (..), TaskReport (..))
import Max.Task.Types (taskHandle)

data TaskNotice = TaskProgress !Int64 !Text | TaskResult !Int64 !TaskReport
  deriving stock (Eq, Show)

renderNotice :: TaskNotice -> Text
renderNotice = \case
  TaskProgress task summary -> taskHandle task <> " · 进度\n" <> summary
  TaskResult task report ->
    T.intercalate "\n\n" $
      [taskHandle task <> " · " <> statusLabel report.status, report.summary]
        <> section "未解决" report.unresolved
        <> section "证据" report.evidence
  where
    section _ [] = []
    section label items = [label <> "：\n" <> T.unlines (map ("- " <>) items)]
    statusLabel = \case
      ReportSucceeded -> "完成"
      ReportPartial -> "部分完成"
      ReportWaiting -> "等待后续输入"
      ReportFailed -> "失败"
      ReportBudgetExhausted -> "额度已用尽"
      ReportCancelled -> "已取消"
