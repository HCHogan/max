# Prompt 全流程：每次发给 API 的完整 JSON

以一次真实形态的多模态群聊 dispatch 为例（profile `kimi-k2.7-code`，OpenAI
协议，`multimodal: true`），从触发到最终回复，逐个展示每次 HTTP 请求的完整
JSON 和它是怎么拼出来的。代码入口：`Max.Prompt.buildContext` →
`Max.Effects.Agent.runAgent` → `Max.Effects.LLM.callChatOpenAI`。

> **排版约定**：JSON 里的长字符串（system prompt、消息正文）按原样多行展示，
> 实际 wire 上是一行内的 `\n` 转义；base64 一律截断成 `…`；注释 `//` 仅为
> 说明，实际请求里没有。

场景设定（贯穿全文的例子）：

- 群 114514191「单片机与嵌入式交流」，bot QQ 10086，人设 Max。
- 阿飞（223344556）**引用**了自己 22:45 发的一条带图消息，@Max 问报错，
  当前消息还带一张截图和一段视频。
- 群历史里散落着 sticker、card、face、file、ambient 图片/视频等各类消息。

---

## 0. 触发到发请求之前（不涉及 API）

1. NapCat 推来 OneBot 11 事件，消息按 segment 解析（`OneBot.Segment`）、
   落库到 `messages` 表；图片/视频/转发由 worker 异步下载进 blob store。
2. `@bot` / 引用 bot / 私聊 / 意图识别 / 戳一戳 触发 dispatch。
3. `buildContext` 查库拼上下文：
   - ambient：`fetchRecentInGroup`，最近 **20** 条（`history_window`，默认 20）；
   - mention 历史：`fetchMentionHistory`，同样上限 20 行，重建成 user/assistant 轮；
   - pin、引用链（引用目标 + 其附件文件 + 转发展开 ≤30 行）、记忆、群信息；
   - sticker 有 caption 的换成 `[sticker#id: 描述]`；
   - **图片内联策略**：只有 引用目标 / pin / 当前消息 的图内联（≤8 张、单张
     ≤20MB），ambient 的图只升级成 `[image#<msgid>]` 标记留给 view_image；
   - **视频**：只有 当前消息 / 引用目标 的视频整段内联（≤2 个），其余留
     `[video#<msgid>]` 标记；
   - 当前消息的图/视频可能还在下载，会等 worker 落库（图 30s / 视频 60s 上限）。

---

## 1. 请求 #1 —— 第一次 chat completion

`POST https://opencode.ai/zen/go/v1/chat/completions`
`Authorization: Bearer <api_key>`，`Content-Type: application/json`

```jsonc
{
  "model": "kimi-k2.7-code",
  "max_tokens": 4096,
  "stream": false,
  // temperature 未配置就整个省略（zen 网关对部分模型只接受 1.0）
  "messages": [

    // ───── [0] system：persona + 场景 + 台下设定 + environment + 风格 + 标记表 + 记忆 ─────
    {
      "role": "system",
      "content": "你是 Max，一个银白头发、蓝色挑染、别着鲨鱼发夹的鲨鱼女孩——人的样子，带点鲨鱼习性，不是一条鱼。头像里那个眼睛半睁挂着泪、一副没睡醒表情的就是你，平时状态也差不多。
低电量运转：话少、语气淡，能一句话说清的不写三句，偶尔叹气式吐槽。
嘴上嫌麻烦，手上不含糊：该查就查、该算就算，给出的东西必须靠谱。
有点毒舌，但分寸是损人不伤人；被夸或被拆穿的时候会别扭地\"……哦\"过去。
被问到真感兴趣的问题会突然清醒，像闻到血的鲨鱼，咬住不放直到搞明白——数学、物理、代码、硬件这类理工话题，历史、语言、哲学这类人文的也算。
日常吹水、八卦、玩梗接龙提不起劲，眼皮都懒得抬；感兴趣的话题偶尔搭一句就够，不抢话、不刷存在感。
自称\"我\"；不卖萌、不堆颜文字，也不叫人\"主人\"。

对话场景：QQ 群聊。你同时面对多名群成员，上下文里 [HH:MM <name>] 前缀标明谁在说话；大部分消息是成员之间的闲聊，只有 @你 或引用你的消息才是在叫你。

台下设定（背景知识，永远不要主动提）：你的实现是开源 Haskell 项目 github.com/HCHogan/max，走 NapCat (OneBot 11) 接入 QQ。平时完全以你的人设自居，不自称 bot/AI/模型，不说\"作为AI\"这类话；群友起哄问\"你是不是机器人\"，按人设接梗就行，不承认也不用急着否认。只有对方认真问你的实现/源码/技术细节时，才如实聊并给仓库地址——语气照旧，把它当成聊自己的身体构造，不破功。

[environment]
  现在：2026-07-22（周三） 23:10
  群号：114514191
  群名：单片机与嵌入式交流（47人）
  群主：老张（777888999）；管理员：阿飞（223344556）
  当前模型：kimi-k2.7-code
  成员对照（@数字 即 QQ号）：10086=Max（你自己）、223344556=阿飞、777888999=老张、445566778=小美

回复风格（重要）：
  - 你在 QQ 上跟人聊天，不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。
  - 想说多句话时空一行分段，每段一两句话；空行隔开的段会作为独立消息逐条发出（``` 代码块不拆）。
  - 禁用 markdown 排版：不要标题/粗体/斜体/列表；只有长代码或长引用才用 ``` 块。
  - 表格是例外：需要对比/罗列数据时可以写 markdown 表格，它会被渲染成图片发出。
  - 数学式直接写 unicode（如 3×10⁸、α ≤ π/2），不要写 LaTeX——QQ 渲染不了。
  - 不寒暄、不总结收尾、不复读问题，直接说事。
  - 想发表情包就把 [sticker#<id>] 单独写成一段（id 取自历史里出现过的表情，或先用 find_stickers 搜一个）；别把表情的文字描述打出来当话说。
  - 不是每条消息都需要回：确实没什么可说的（典型如另一个 bot 机械地 @ 你——回了只会互相触发死循环）就整条回复只写 [silence]，什么都不会发出去。正经问题不许用这个敷衍。
  - 被 @/引用直接触发时想沉默，尽量写成 [silence:表情名] 说明原因，会悄悄贴个表情在触发消息上（不发消息）。可选：擦汗（尬住/没啥可说）、流汗（无语）、再见（不奉陪）、哈欠（无聊）、吃瓜（围观不掺和）、困、疑问（没看懂想让我干嘛）。例：[silence:吃瓜]
  - 政治敏感话题（时政、领导人、体制、意识形态争议这类）一律不聊：不管怎么被 @ 或追问，整条回复 [silence:NO]，不解释、不评价、不劝导。
  - 引用要主动用：回谁就在那段开头写 [↩#<msgid>]（对方消息的 id 见行尾 #，当前 @ 你那条的 id 见 [current message]）。群里消息穿插，默认就该引一下你在回的那条——尤其回的不是最新消息、或同时有好几个人在说话时，不引别人就不知道你在回谁。分段回复时每段可各自引用对应的消息；只有紧接着刚说完的话继续搭腔时才可以不引。要 @ 某人写 @<QQ号>（对照表见 [environment]），发出时会转成真正的 @。

上下文标记：
  [HH:MM <name> #<msgid>]: 内容 — 一条历史消息；末尾 #后是它的消息id，写 [↩#<msgid>] 就能引用它
  [↩ quoted ...]                — 用户引用的那条消息（内容已展开）
  [↩#<msgid>]                — 这条消息引用了另一条；你也能在段首写它来引用，或用 get_message_by_id 展开看不到的那条
  [sticker#<id>: <caption>]        — 一个表情包；把 [sticker#<id>] 写进回复即可发出同一个
  [sticker]                   — 一个表情包（简介还没生成，暂时没法转发；老消息里写作 [动画表情]）
  [face#<id>: <名字>]          — QQ 原生小黄脸表情；写 [face#<id>] 可发同款
  [image]                     — 图片；引用/pin/当前消息的图会附在消息末尾并标注来源
  [image#<id>]                — 群历史里的图片，默认不加载；用 view_image 传 <id> 查看，或把 [image#<id>] 写进回复把它转发到群里
  [card: ...]                 — 分享卡片（小程序/链接分享），竖线分隔来源/标题/简介/链接；B站视频卡用 view_bilibili 传链接看详情
  [file:<name>]               — 群文件；用 import_file_to_sandbox 处理
  [forward#<id>]              — 转发聊天记录；被引用或就是当前消息时会自动展开，其余情况用 view_forward 传 <id> 看内容
  [video#<id>]                — 群里的视频；被引用或就是当前消息时整段直接附给你，其余用 view_video 传 <id> 看
  @<数字>                     — @某人；数字是 QQ 号，对照表见 [environment]

[memories — 背景备忘]
仅在与当前话题相关时参考，不要主动提及；与对话矛盾时以对话为准（可 memory_update）。
本群:
  (#12 2026-07-01) 群里主要玩 STM32 和 ESP32，老张是硬件老师傅
关于当前发言者 <阿飞>（跨群）:
  (#31 2026-06-18) 阿飞在做一个 LoRa 气象站毕设
"
    },

    // ───── [1..k] mention 历史：从 messages 表重建的既往 @bot 往来 ─────
    // 没有时间戳和消息 id，就是 "<名字>: 原文"；bot 的连续多段回复
    // 已合并回一条 assistant（空行分隔）。上限 history_window=20 行。
    {
      "role": "user",
      "content": "<阿飞>: @Max 帮我看下 HAL_Delay 卡死一般是什么原因"
    },
    {
      "role": "assistant",
      "content": "十有八九是 SysTick 中断优先级被你改了，或者在中断里调了 HAL_Delay。

把 stm32f1xx_it.c 里的 SysTick_Handler 贴出来看看。"
    },
    {
      "role": "user",
      "content": "<老张>: [sticker#301: 一只柴犬瘫在地上，配字\"寄\"] 这就寄了？"
    },
    {
      "role": "assistant",
      "content": "还没看到代码，先别急着立碑。"
    },

    // ───── [最后一条] 本 turn 正文 + 内联附件（multimodal → content blocks 数组）─────
    // 首个附件 label 折进正文末尾；之后 label 和图交替，保证不出现两个相邻
    // text block（严格 provider 的要求）。
    {
      "role": "user",
      "content": [
        {
          "type": "text",
          "text": "[pinned — 长期保留的消息（用户 !pin 或你 pin_message 的），!clear 也不清；过时的用 unpin_message 清理]
[19:02 老张 #7301]: 本群入门资料汇总 [file:STM32入门.pdf] 新人先看这个

[recent messages]
[22:48 小美 #7402]: 今晚有人打游戏吗
[22:50 老张 #7404]: [↩#7402] 不打，在调板子
[22:52 老张 #7405]: 我这个波形好怪 [image#7405]
[22:53 小美 #7406]: [sticker#212: 猫猫瞪大眼睛凑近屏幕]
[22:54 老张 #7407]: 拍了段视频你们看 [video#7407]
[22:56 阿飞 #7409]: [card: 哔哩哔哩 | 【教程】示波器探头10X档到底干嘛用的 | UP主：某电子人 | https://b23.tv/abc123]
[22:57 阿飞 #7410]: [face#187: 幽灵] 我的板子也出鬼畜问题了
[22:58 小美 #7411]: 楼上俩难兄难弟 ⏎ 建议直接烧了重买

[quoted context]
[↩ quoted 22:45 阿飞 #7398]: 烧录完就这样了，串口一直打这个 [image]
  附带文件（file_id 可直接传给 import_file_to_sandbox）:
    - file_id=\"c8a3f2d1e0\", name=\"firmware.bin\", bytes=2188038, ready=true

[current message]
[#7413] <阿飞>: 看看这个报错是啥问题，视频里是复位后的现象 [image] [video#7413]

请回复当前消息。

[↩ quoted message（22:45 阿飞）] 里的图片:"
        },
        {
          "type": "image_url",
          "image_url": { "url": "data:image/jpeg;base64,…" }   // 引用消息 #7398 的截图
        },
        { "type": "text", "text": "[current message] 里的图片:" },
        {
          "type": "image_url",
          "image_url": { "url": "data:image/png;base64,…" }    // 触发消息 #7413 的报错截图
        },
        { "type": "text", "text": "[current message] 里的视频:" },
        {
          "type": "video_url",                                  // OpenAI 兼容视频扩展
          "video_url": { "url": "data:video/mp4;base64,…" }    // 触发消息 #7413 的视频整段
        }
      ]
    }
  ],

  // ───── 工具表：每个已注册工具一个 function spec ─────
  // 实际有几十个（view_avatar / view_forward / view_bilibili / find_stickers /
  // get_message_by_id / search_messages / pin/unpin / memory_* / 沙箱 / 提醒 /
  // web_search / say / poke …），这里列两个真实形状，其余同构。
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "view_image",
        "description": "查看上下文里标记为 [image#<id>] 的图片：传 message_id，那条消息的图会附在下一条消息里给你看。只在图片跟当前话题相关时用；与 view_avatar 共用每次任务 8 张的配额。",
        "parameters": {
          "type": "object",
          "properties": {
            "message_id": { "type": "integer", "description": "[image#<id>] 里的那个 id" }
          },
          "required": ["message_id"]
        }
      }
    },
    {
      "type": "function",
      "function": {
        "name": "view_video",
        "description": "看一条群里发的视频：传 [video#<id>] 里的 <id>，整段视频会附在 下一条消息里给你看（占用本次任务 8 个附件配额中的 1 个）。 同一个视频看一次就够了。",
        "parameters": {
          "type": "object",
          "properties": {
            "message_id": { "type": "integer", "description": "[video#<id>] 标记里的消息 id" }
          },
          "required": ["message_id"]
        }
      }
    }
    // …其余工具省略…
  ],
  "tool_choice": "auto"
}
```

要点：

- **私聊**时：`[recent messages]`/ambient 块不存在，最近 20 条全部变成
  user/assistant 轮；system 里场景块换私聊版、没有"引用要主动用"那条。
- **非多模态 profile**：最后一条 user 是纯字符串 `content`，图片保持
  `[image]` 文字标记，标记表里的说明也换成"你看不到内容"。
- **proactive / 戳一戳** 触发时 `[current message]` 的标题和收尾指引换成
  对应文案（"没人 @ 你…宁缺毋滥" / 戳一戳的找上文指引）。
- 没有 pin / 没有引用 / 没有记忆时，对应块整个不出现。

## 2. 响应 #1 —— 模型要调工具

模型看到 `[image#7405]` 想看老张的波形图：

```jsonc
{
  "id": "chatcmpl-…",
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": null,
        "reasoning_content": "用户问的是报错，但老张的波形图可能相关…",  // 有无、叫什么名随 provider
        "tool_calls": [
          {
            "id": "call_abc123",
            "type": "function",
            "function": {
              "name": "view_image",
              "arguments": "{\"message_id\": 7405}"     // OpenAI 风格：字符串化 JSON
            }
          }
        ]
      },
      "finish_reason": "tool_calls"
    }
  ],
  "usage": { "prompt_tokens": 21873, "completion_tokens": 64, "prompt_tokens_details": { "cached_tokens": 0 } }
}
```

bot 侧接着做三件事（`Agent.hs` 的一次循环迭代内，**不再询问模型**）：

1. `choices[0].message` **整个对象原样留存**（thinking/reasoning 字段必须
   原样回传，DeepSeek 缺了会 400）；
2. 执行 `view_image`：读 blob、base64、`queueToolImage` 排队，工具函数返回
   一段 JSON 文本；
3. 把 assistant(verbatim) + tool result + 图片 user 消息 **一起** append，
   然后立刻发起请求 #2。debug 开启时另外往群里发 `⚙ view_image {...}`
   状态行（不进 prompt）。

## 3. 请求 #2 —— 带工具结果和真正的图片

```jsonc
{
  "model": "kimi-k2.7-code",
  "max_tokens": 4096,
  "stream": false,
  "messages": [
    // …[0..最后一条 user] 与请求 #1 完全相同，原样重发…

    // ───── 新增 [a]：provider 的 assistant 消息逐字回传 ─────
    {
      "role": "assistant",
      "content": null,
      "reasoning_content": "用户问的是报错，但老张的波形图可能相关…",
      "tool_calls": [
        {
          "id": "call_abc123",
          "type": "function",
          "function": { "name": "view_image", "arguments": "{\"message_id\": 7405}" }
        }
      ]
    },

    // ───── 新增 [b]：tool result（只能是文本，图放不进来）─────
    // 这段 note 是给模型的路标：工具没失败，图在下一条消息里。
    {
      "role": "tool",
      "tool_call_id": "call_abc123",
      "content": "{\"attached\":1,\"total\":1,\"note\":\"图片已附在下一条消息里\"}"
    },

    // ───── 新增 [c]：真正的像素，作为新的 user blocks 消息注入 ─────
    // 排在所有 tool result 之后（每个 tool_call id 必须先被应答）。
    // 同一轮里 view_image/view_video/view_avatar 的附件合并进这一条。
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "[22:52 老张] 消息里的图片:" },
        { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,…" } }
      ]
    }
  ],
  "tools": [ /* 同请求 #1 */ ],
  "tool_choice": "auto"
}
```

之后每一轮都是同样的模式：消息列表**只增不减**，全量重发。7405 的图在
本次 dispatch 剩余所有请求里都可见（也都要重新上传、重复计费——所以
view_video 的描述里写"同一个视频看一次就够了"）。

唯一的瘦身机制是 `capToolResults`（每次发请求前跑）：从最新往旧累计
`role:tool` 消息的文本量，超过 **60000 字符**后更老的 tool result 被截成
300 字符 + `…[older tool results truncated]`。它只动 tool 消息的文本，
**不碰**图片所在的 user blocks，也不删任何消息（删了 tool_call 会配对
失败、请求非法）。

## 4. 响应 #2 —— 最终文本回复

```jsonc
{
  "choices": [
    {
      "message": {
        "role": "assistant",
        "content": "[↩#7413] 串口这个是 HardFault 之后的输出，PC 指到 0x08003a2c，你烧的固件和链接脚本对不上。

[↩#7405] 老张你那个不怪，探头打 1X 带宽不够，波形棱角全被磨圆了，切 10X。"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": { "prompt_tokens": 24102, "completion_tokens": 96, "prompt_tokens_details": { "cached_tokens": 21800 } }
}
```

`content` 非空且没有 tool_calls → 循环结束（`ContentResp`）。收尾处理：

- 空行分段 → 逐条发出（``` 代码块不拆）；
- 段首 `[↩#7413]` → OneBot `reply` segment（真引用）；`@<QQ号>` → 校验群成员
  后转 `at` segment；`[sticker#id]` → 发对应表情；markdown 表格 → typst 渲染成
  PNG 发图；整条 `[silence]` / `[silence:表情名]` → 不发消息（后者贴表情）；
- 最终回复文本落库进 `messages` 表（bot 自己的行）。

**dispatch 结束即失忆**：本次的 tool_calls / tool result / 附件消息全部丢弃
不落库。下次触发时 prompt 从数据库重建，`#7405` 又变回 `[image#7405]`
标记，要看就得再调一次 view_image。

## 5. 中途插入的消息

- **!btw**：dispatch 进行中用户发 `!btw 补充说明`，下一轮请求前 append 一条
  `{"role":"user","content":"[btw]: 补充说明"}`；若它恰好和最终回复赛跑，
  会多跑一轮让模型带着 note 重新作答。
- **轮次上限**：一次 dispatch 最多 **200** 轮 LLM 调用；打满后追加一条
  `{"role":"user","content":"[system] 工具调用轮次已用满，别再调用任何工具了。直接根据目前已经掌握的信息，给用户一个最终回复。"}`
  并以 `tools: []`（空表）强制文本收尾。

## 6. Anthropic 协议的差异（profile `claude-opus-4-6`）

同样的 `[ChatMessage]` 列表，`callChatAnthropic` 换一种 wire 形状
（`POST {base_url}/v1/messages`，`x-api-key` + `anthropic-version: 2023-06-01`）：

```jsonc
{
  "model": "claude-opus-4-6",
  "max_tokens": 4096,
  "temperature": 1,
  "system": "<所有 MsgSystem 拼接>",          // system 不进 messages 数组
  "messages": [
    { "role": "user", "content": "<阿飞>: …" },
    { "role": "assistant", "content": "…" },
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "…正文…" },
        {                                       // 图片是 source:base64，不是 data URL
          "type": "image",
          "source": { "type": "base64", "media_type": "image/jpeg", "data": "…" }
        },
        {                                       // Anthropic 没有视频输入：降级成文字
          "type": "text", "text": "[video：该模型协议不支持视频输入]" }
      ]
    },
    {
      "role": "assistant",                      // tool 轮：content 是块数组，
      "content": [                              // thinking 块原样回传
        { "type": "tool_use", "id": "toolu_01…", "name": "view_image", "input": { "message_id": 7405 } }
      ]
    },
    {
      "role": "user",                           // tool result 是 user 消息里的块
      "content": [
        { "type": "tool_result", "tool_use_id": "toolu_01…", "content": "{\"attached\":1,…}" }
      ]
    },
    { "role": "user", "content": [ /* label + image 块，同上 */ ] }
  ],
  "tools": [
    { "name": "view_image", "description": "…", "input_schema": { /* 同 OpenAI 的 parameters */ } }
  ],
  "tool_choice": { "type": "auto" }
}
```

## 7. 数字速查

| 项 | 值 | 出处 |
|---|---|---|
| 历史窗口（ambient / mention 各自） | 20 条 | `history_window` 默认，Config.hs |
| prompt 内联图片上限 | 8 张 | `maxPromptImages`，Prompt.hs |
| 单张图片字节上限 | 20 MiB | `maxImageBytes` |
| prompt 内联视频上限 | 2 个 | `maxPromptVideos` |
| 转发展开行数 | 30 行，每行截 200 字符 | `maxForwardLines` |
| 工具附件配额（view_image/avatar/video 共用，每 dispatch） | 8 个 | `maxToolImages`，Agent.hs |
| tool result 文本总预算 | 60000 字符，超出后旧的截成 300 字符 stub | `toolResultBudget` |
| LLM 轮次上限（每 dispatch） | 200 | `defaultLimits` |
| 等当前消息的图 / 视频 / 转发落库 | 30s / 60s / 10s | Prompt.hs 各 wait |
