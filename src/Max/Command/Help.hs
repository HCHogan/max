-- |
-- The @!help@ text, in a leaf module so it can be spliced into the
-- @self-knowledge@ builtin skill at registry init ("Max.Skills"
-- replaces @{{commands}}@ with it).  One source of truth: what the
-- bot tells users and what it tells itself about its own commands
-- can't drift apart.  Deliberately imports nothing but text —
-- "Max.Skills" sits below "Max.Env" in the import graph, so anything
-- heavier here risks a cycle.
module Max.Command.Help
  ( helpText,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

helpText :: Maybe Text -> Text
helpText Nothing =
  T.unlines
    [ "可用命令：",
      "  !help [topic]            这条帮助",
      "  !model                   看当前 model",
      "  !model list              列所有 model",
      "  !model <name>            切 model",
      "  !debug                   看 debug 状态（开时工具调用打印到群里）",
      "  !debug on/off/default    开/关/回到配置默认 (session 覆盖)",
      "  !effort                  看当前推理力度（session 覆盖 > profile 配置）",
      "  !effort <级别>/default   设/清 session 覆盖（low/medium/high/xhigh/max…，按 provider 支持）",
      "  !persona                 看当前 persona override",
      "  !persona <text>          设 persona override",
      "  !persona clear           回到默认 persona",
      "  !clear                   清 @-mention 历史 + 置群上下文水位线",
      "  !clear --all             清历史/侧记/persona override + 置水位线 + 销毁 sandbox",
      "  !unclear                 撤销水位线（恢复看 !clear 之前的群消息）",
      "  !pin [id]                pin 一条消息（不带 id 时用引用的那条）",
      "  !unpin [id|all]          移除 pin（同上语法 + all 清空）",
      "  !pins                    列出当前 pin 的消息",
      "  !btw <text>              另起一个问题，不打扰在跑的任务",
      "  !feedback <text>         给在跑的任务补一句（别名 !fb；回复某条触发消息可指定给哪轮，不回复就给最新那轮；没任务在跑就当普通问题另开一轮）",
      "  !memory                  看本群的长期记忆",
      "  !memory rm <id>          删除一条记忆（本群的或你自己的）",
      "  !sticker                 表情包库统计 + 发送开关状态（bot 从群里学表情包）",
      "  !sticker on/off/default  开/关/回到配置默认 bot 主动发表情 (session 覆盖)",
      "  !sticker list            看最近识图完成的表情包",
      "  !sticker ban <sha前缀>   屏蔽某个表情（unban 恢复）",
      "  !proactive               看主动插话状态（意图识别触发，不用 @ 也可能接话）",
      "  !proactive on/off/default 开/关/回到配置默认 (session 覆盖)",
      "  !ps                      看本群在跑的后台任务",
      "  !ps --all                看所有群的任务",
      "  !kill <id>               砍一个任务 (任务 id 来自 !ps)",
      "  !kill --all              砍掉所有群的全部任务",
      "  !version                 看 bot 版本",
      "  !grant [@#qq] <权限名>   给人授权（--deny/-d 显式禁用、--global/-g 全局，均需 owner）",
      "  !revoke [@#qq] <权限名>  撤销授权（scope 需和授权时一致）",
      "  !perms [[@#qq]]          看某人的显式授权（默认看自己）",
      "  !use <群号>              （私聊）之后你发的命令都作用于那个群；!use 看当前，!use clear 退出",
      "  !status                  看（目标）群的概览：model/persona/开关/pin/记忆/任务",
      "  ! <命令>                 在本群沙盒里跑 shell（感叹号后空一格），如 ! ls -al；支持多行",
      "  ! +包名… <命令>          开头 +pkg 把 nixpkgs 放进 PATH，如 ! +ffmpeg ffmpeg -version",
      "",
      "flag 可用短形式：--all=-a、--deny=-d、--global=-g（可合并，如 -dg）。",
      "权限：!model/!effort/!debug/!sticker/!proactive/!kill --all 仅 bot 主人；",
      "!persona/!clear/!kill 需群主/管理员（或被授权）；其余全员可用。",
      "群里发命令：结果私聊发你（加好友才收得到），群里只贴表情。"
    ]
helpText (Just topic) =
  "(目前没有 '" <> topic <> "' 的详细帮助，看 !help)"
