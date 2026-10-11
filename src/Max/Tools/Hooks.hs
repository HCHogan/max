module Max.Tools.Hooks (hookTools) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import Effectful
import Max.Effects.HookControl (HookControl, setHook)
import Max.Effects.HookQuery (HookQuery, queryHooks)
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Hook.Types (parseHookPatch, parseHookQuery)
import Max.Tool.Protocol (committedResult, readResult)
import Max.Tools.Schema

hookTools :: (HookControl :> es, HookQuery :> es) => [Tool es]
hookTools =
  [ Tool
      "set_hook"
      "配置当前会话的入站 hook（仅管理员）。每条新消息自动运行 JS，无需模型；不能调用工具、网络或 sleep。代码用 args.event 和 args.config，返回 {action:'pass'|'ignore',reason?:string}。event 字段：type,message_id,sender_principal（[@#principal] 人物 ID）,text,body,platform,received_at,occurred_at,ingest_class,reply_to。ignore/运行错误会阻止模型上下文、回复/命令/追加输入及消息自动化；所有消息先提交原始记录，hook在入库后处理；跨平台转发保留。多个 hook 任一 ignore 即忽略。只影响生效后新入库消息（含 backfill），不清理旧上下文。创建须 event、source、expected_revision=0；更新须最新 revision，省略字段保留，source/config 整体替换。停用用 enabled=false。建议先 query_hooks test。"
      ( toolObject
          [ ("name", stringParam "当前会话唯一名称，1..64 小写字母、数字、-、_。"),
            ("event", enumParam ["message.inbound"] "创建时必填；更新时不可改变。"),
            ("expected_revision", integerParam "创建为0；修改填查询到的最新 revision。"),
            ("source", stringParam "JS 函数体，最多32 KiB。例：return {action:args.config.blocked_principals.includes(args.event.sender_principal)?'ignore':'pass'};"),
            ("config", object ["description" .= ("任意 JSON 配置，最多16 KiB；整体替换，null也是实际值。" :: Text)]),
            ("enabled", boolParam "创建默认true；false停用并保留定义。")
          ]
          ["name", "expected_revision"]
      )
      (OutcomeRunner $ \raw -> case parseHookPatch raw of Left err -> pure (committedResult (Left err)); Right patch -> committedResult <$> setHook patch),
    Tool
      "query_hooks"
      "查询当前会话 hook（仅管理员）：projection 用 message_id 查待处理/完成/错误状态、绑定版本、可见性和分发状态；list 返回摘要；get 返回代码/配置，可指定历史 revision；test 对 message_id 或 sample 事件对象纯模拟，可用 source/config 覆盖或仅传 source 测试草稿，不保存、不重新触发消息；runs 查实际执行记录，含错误和最终是否忽略，next_before 用于分页。test 的 sample 形状同 args.event，真实消息用 message_id 取得宿主身份。"
      ( toolObject
          [ ("view", enumParam ["list", "get", "test", "runs", "projection"] "默认list。"),
            ("name", stringParam "get必填；test/runs可选。"),
            ("revision", integerParam "get/test可选：历史版本，默认当前。"),
            ("source", stringParam "test：候选代码，不保存。"),
            ("config", object ["description" .= ("test：候选配置，整体替换，不保存。" :: Text)]),
            ("message_id", integerParam "test：本会话真实入站消息，与sample二选一；runs：按消息筛选；projection：必填。"),
            ("sample", paramOfType "object"),
            ("outcome", enumParam ["pass", "ignore", "error"] "runs：结果筛选。"),
            ("before", integerParam "runs：上页的next_before。"),
            ("limit", boundedIntegerParam 1 100 20)
          ]
          []
      )
      (OutcomeRunner $ \raw -> case parseHookQuery raw of Left err -> pure (readResult (Left err)); Right request -> readResult <$> queryHooks request)
  ]
