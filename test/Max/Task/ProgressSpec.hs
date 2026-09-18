module Max.Task.ProgressSpec (spec) where

import Data.Text qualified as T
import Max.Task.Notice
import Max.Task.State
import Test.Hspec

spec :: Spec
spec = describe "direct task notices" $ do
  it "preserves progress text and canonical placeholders for the shared resolver" $ do
    let text = "[reply#42] [mention#7: Alice] 验证完成"
    renderNotice (TaskProgress 12 text) `shouldBe` "task#12 · 进度\n" <> text

  it "shows incomplete status, unresolved issues and evidence without a second model" $ do
    let report = TaskReport ReportPartial "配置已更新" ["检查日志"] ["尚未部署"] Nothing Nothing Nothing
        output = renderNotice (TaskResult 12 report)
    output `shouldSatisfy` T.isInfixOf "task#12 · 部分完成"
    output `shouldSatisfy` T.isInfixOf "配置已更新"
    output `shouldSatisfy` T.isInfixOf "未解决：\n- 尚未部署"
    output `shouldSatisfy` T.isInfixOf "证据：\n- 检查日志"

  it "labels host cancellation and exhaustion without claiming success" $ do
    let report status = TaskReport status "执行已停止" [] [] Nothing Nothing Nothing
    renderNotice (TaskResult 12 (report ReportCancelled)) `shouldSatisfy` T.isInfixOf "已取消"
    renderNotice (TaskResult 12 (report ReportBudgetExhausted)) `shouldSatisfy` T.isInfixOf "额度已用尽"
