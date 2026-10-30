# Max Rust 重写

> 状态：草案，2026-10-26 起草，边聊边补。标 **待定** 的条目还没有结论。
>
> 代码在这个仓库的 `maxx` 分支上（2026-10-28 从 `rust` 改名），本地 worktree 是 `~/Development/hs/max-rust`。分支起点打了 tag `haskell-base`（`a5de2e1`）；Haskell 版的代码和文档都在那里，文中指向旧文档的链接固定在这个提交上。

## 目标

1. 用 Rust 重写 Max。上线时 Rust 版要能 drop-in 替换 Haskell 版：功能、数据、部署都接得上，有意删掉的功能除外。
2. 所有代码都要能让人审完。宁可慢一点、少一点，不一次堆上去。
3. 通用的部分交给成熟的库和外部 agent，包括配置解析、数据库、LLM 接入、MCP 和后台 coding agent。Max 自己只写群聊运行时和领域逻辑。

不做的事：

- 不逐行移植 Haskell 代码，按现在的理解重新设计。
- 不为 Haskell 版写兼容层。数据一次性导入新 schema（见[上线](#上线drop-in-替换的条件)）。

## 版本

| 版本 | 内容 | 用途 |
|---|---|---|
| v1 | 见 [v1 范围](#v1-范围) | 只做审核和测试，不上线 |
| v1 之后 | 浏览器、记忆、后台 agent 等，怎么切分 **待定** | 同上 |
| 上线 | [功能对齐清单](#功能对齐清单)全部完成，数据导入演练通过 | drop-in 替换 Haskell 版 |

### v1 范围

2026-10-28 定：已经设计到细节的都进 v1，不再为了让 v1 小一点而往后推。底线是核心和并发调度这些关键部分的复杂度不失控。

包含：

- 平台：QQ（腾讯官方机器人接口，2026-10-28 从 NapCat 改过来，见 [QQ 官方机器人](#qq-官方机器人)）。Matrix 先不做（2026-10-29 定），见 [Matrix](#matrix)。
- 触发：所有入账都经过 [intent](#intent)：@、回复 Max 是它的规则，其它消息由小模型判（2026-10-27 定进 v1，10-28 改成所有消息都经过它）。私聊按白名单触发。命令不是触发，由会话 actor 自己处理。见[运行流程](#运行流程)第 2 步。
- canonical ledger：入站和出站消息都落 Postgres。
- 会话 actor、单一核心实例、输入投递、流式回复、取消（`/kill`）、失败时的简短回复。
- LLM：Responses 和 Chat Completions 两种协议。
- 自写的 agent loop，带工具（2026-10-27 定）：纯 codemode 加一个 `shell`，都跑在群 VM 里，见[工具和 codemode](#工具和-codemode)。所以 v1 也要带上 VM 沙箱和 MCP 服务。第一个开放的 Max 工具是读全文的 `context_read`（2026-10-30 和 `context_search` 并成 `history`），见[后续输入](#后续输入)；其它开放哪几个 **待定**。
- 上下文投影：原始尾巴、易变块，开了 historian 的群在尾巴前面还有摘要块，见[上下文投影](#上下文投影)。historian 和摘要 10-28 定进 v1，10-30 删了，当天晚上又改回来，做成按群的开关，见[摘要](#摘要)。
- 重启：正在跑的 turn 给一段宽限期，到期就中断，回一句话（2026-10-29 改，原来是挂起、重启后接着跑），见[重启](#重启)。
- 配置、日志、优雅关闭。

不包含，但上线前都要做：镜像、浏览器、记忆和召回、后台 agent、自动化、媒体、admin。

### 有意删除的功能

- iMessage
- WeChat hook
- NapCat 和 OneBot（2026-10-28 删）：QQ 改用官方机器人接口，见 [QQ 官方机器人](#qq-官方机器人)。
- reaction 和戳一戳（2026-10-28 删）：官方接口没有。包括处理中、失败时挂的表情，`[silence:表情名]` 回表情，以及收别人的 reaction 和戳一戳。
- 把表格和代码块渲染成图片（typst、codesnap，2026-10-29 删）：QQ 的原生 Markdown 能显示代码块、表格和公式。
- Max 发小黄脸表情（2026-10-29 删）：QQ 官方接口发不出。收到的照样给模型看，见[回复的写法](#回复的写法)。同一天表情包和图片也删过，owner 随即改回来：它们当图片发，见[发图](#发图)。
- Matrix 和镜像（2026-10-29 定，先不做）：见 [Matrix](#matrix)。镜像本来是 QQ 群和 Matrix 房间之间的，跟着一起搁置。
- `/uncompact`（2026-10-28 删）：摘要是自动的，手动撤回的部分迟早又被自动压回去，语义别扭。
- historian、摘要和 `/compact`（2026-10-30 删，当天晚上改回按群的开关，默认关）：见[摘要](#摘要)。
- Inbound message hooks：先不做（2026-10-27）。以后要做的话不能放进 VM，因为每条消息都要跑；候选是声明式规则，Rust 的 `regex` 是线性时间的，不怕不可信的正则。

2026-10-26 讨论时只决定带 QQ 和 Matrix，这两个有人用；10-29 Matrix 也先不做。其余删除项 **待补**。

### 功能对齐清单

功能按 [features.md](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/features.md) 的条目列。所有没删除的功能，上线前都要完成。v1 一列只是提议，聊的时候再改。

| 功能 | v1 | 备注 |
|---|---|---|
| Conversation lifetime and history | 部分 | 单一核心实例、输入投递、空闲窗口；重启时正在跑的 turn 给一段宽限期，到期中断，崩溃时正在跑的记为 `Lost`，见[重启](#重启) |
| Automations | — | |
| Sandbox isolation | 部分 | codemode 的运行环境；v1 要有按需启动、闲置关机、执行命令和 `/work` |
| Attachment fan-out and QQ best-effort recovery | — | |
| Persistence | 部分 | ledger 和 turn 记录；新 schema 见 [schema](#schema) |
| Canonical multi-platform conversations | 部分 | [消息格式](#消息格式)不按平台分支，v1 只有 QQ；Matrix 和镜像先不做，见 [Matrix](#matrix) |
| Triggering | ✓ | @、回复触发；私聊按白名单 |
| Proactive triggering | ✓ | [intent](#intent)，2026-10-27 定进 v1。10-29 精简：只留去抖、小模型判定和每小时上限，Haskell 版的闸门、三类判定和 topic 冷却都删了 |
| Inbound message hooks | — | 先不做，见[有意删除的功能](#有意删除的功能) |
| QQ group allowlist | ✓ | 改成 `/bind`：平台本身只让创建者拉群，没绑定的群不服务，见 [QQ 官方机器人](#qq-官方机器人) |
| Private chats | ✓ | 改成白名单：名单上的人私聊才触发，见[运行流程](#运行流程)第 2 步。Haskell 版私聊一律回复 |
| Agent loop | ✓ | 不再挂处理中和失败的 reaction，失败时回一句话，见[群里看到的](#群里看到的) |
| Background agents and feedback | 部分 | pi + MCP，见[后台 agent](#后台-agent)。2026-10-30 做了 `agent` 系列工具，job 结果唤醒 Max；job 中途能用 `ask_max` 问 Max |
| Prompt shape and budget | 部分 | 见[上下文投影](#上下文投影) |
| Memory | 有 | 换成 Max 自己写的一个文件，每轮注入，见[记忆](#记忆)；Haskell 版的提案、版本、到期都不要了 |
| Group lingo | — | |
| Unified recall and vector search | 部分 | `history` 按字面、按意思搜本会话的消息（带图和表情包的 caption），也按发言人、时间读原文，见[召回](#召回)。不搜记忆，它每轮都在上下文里；视频没有 caption |
| Context operations | — | Haskell 版是 admin 面板里的上下文控制台：覆盖和延迟、重建摘要、重算向量、检索轨迹；跟 Admin JSON API 一起做。模型自己的上下文操作是 `history`，见[召回](#召回) |
| LLM profiles | ✓ | |
| Streaming | ✓ | |
| Share cards | — | |
| Images | — | 工具结果里的图片见[多模态结果](#多模态结果)；Max 发图和表情包见[发图](#发图) |
| Group awareness | — | 群名、人数和 maxx 在群里的身份拿得到（`info`、`bot_state`，实测）；成员列表要白名单，群主和管理员只认得出说过话的（消息里带身份），见 [QQ 官方机器人](#qq-官方机器人)的群管理 |
| Moderation (QQ groups) | — | `recall_message` 和 `mute_member` 2026-10-29 做了，见 [QQ 官方机器人](#qq-官方机器人)的出站和群管理；禁言在测试群实测过，maxx 当管理员撤普通成员的消息没实测 |
| Browser | — | 群 VM 里常驻的 Chromium，程序里经 CDP 直接写 Playwright（2026-10-29 做完），见[浏览器](#浏览器) |
| Replies | ✓ | QQ 一律发原生 Markdown，表格和代码块不再渲染成图片，见 [QQ 官方机器人](#qq-官方机器人)；Max 不发小黄脸，表情包和图片当图片发，见[发图](#发图) |
| Tools | 部分 | 纯 codemode 加 `shell`，见[工具和 codemode](#工具和-codemode)；v1 开放哪几个 **待定** |
| Skills | — | skill 只是文档，加载时只往上下文后面追加，tools 数组不变，见[纯 codemode](#纯-codemode) |
| Destiny 2 (opt-in) | — | |
| Commands | 部分 | `/kill` 等运行时命令；由会话 actor 处理，不进核心 |
| SSH fleet operations | — | |
| Admin JSON API | — | |
| Token accounting | 部分 | |
| Estimated cost | — | |
| Subscription health | — | |

## 技术选型

v1 用到的：

| 用途 | 选择 | 版本 | 备注 |
|---|---|---|---|
| 异步运行时 | tokio、tokio-util、futures | 1.54 / 0.7.20 / 0.3 | `CancellationToken` 和 `FramedRead` / `LinesCodec` 在 tokio-util |
| 序列化 | serde、serde_json | 1 | |
| 错误处理 | color-eyre；调用方要匹配的错误用 thiserror | 0.6.5 / 2.0 | 输出到 journald 时关掉颜色 |
| 日志 | tracing、tracing-subscriber | 0.1 / 0.3 | 输出到 stdout，由 journald 收 |
| 命令行、配置 | clap（derive）、toml | 4.6 / 1.1 | 只有一个来源：TOML 文件；见[配置](#配置) |
| 数据库 | sqlx（postgres、runtime-tokio、macros、migrate、chrono、json） | 0.9.0 | 编译期检查 SQL；`.sqlx` 离线元数据入库；迁移用 sqlx 自带的。不开 TLS，库在本机 |
| 时间 | chrono | 0.4 | sqlx 0.9 不支持 jiff |
| LLM | 自写，reqwest 加 sse-stream | — / 0.13 / 0.2.6 | 只在 `max-llm` 里。线上格式只给读到的十几个字段写小结构，其余存原始 JSON 透传。sse-stream 只把字节流切成事件，rmcp 3.8 用的也是 0.2.6。2026-10-29 从 async-openai 0.42.2 改：byot 模式下请求和响应类型本来就要自己写，它只剩发请求和解析 SSE；它的流每个都 `tokio::spawn` 一个不归我们管的任务，连接断在半路时流只是结束、不报错，还大约每月一个破坏性小版本 |
| HTTP 服务 | axum | 0.8.9 | MCP 服务；以后 admin 也挂在这里 |
| QQ 官方机器人 | 自写，网关用 tokio-tungstenite（rustls），REST 用 reqwest | — / 0.30 / 0.13 | 官方 SDK 只有 Go、Python、Node；见 [QQ 官方机器人](#qq-官方机器人) |
| agent loop | 自写，sans-I/O | — | 调研结论见[核心](#核心) |
| MCP | rmcp | 3.x | Max 的 MCP 服务，VM 里的程序通过它调 Max 的工具，见 [MCP 通道](#mcp-通道) |
| 工具参数 schema | schemars | 1.2 | rmcp 本来就依赖它 |
| codemode 运行时 | Node 和官方 MCP TypeScript SDK | — | 打进群 VM 的 guest 镜像，版本跟着钉住的 nixpkgs；runner 和 SDK 自写 |
| VM | microvm.nix、cloud-hypervisor、NixOS guest，命令走 vsock 上的 SSH | — | 沿用 Haskell 版的 guest；不要 broker，VM 是主进程的子进程，运行时不需要 root，见 [VM 进程](#vm-进程) |
| SSH | russh | 0.65.0 | 调 VM：每个 VM 一条连接，每条命令一个 channel，直接连在 hybrid vsock 的 socket 上 |
| token 估算 | tiktoken-rs | 0.12 | 只在 `max` 里用；算好的数作为数据传进核心，见[核心](#核心) |
| 测试 | cargo-nextest、insta、tokio test-util、`#[sqlx::test]` | 0.9.149 / 1.49 | |
| 构建 | crane | — | 依赖单独缓存 |
| 工具链 | stable，edition 2024 | `rust-toolchain.toml` 钉具体版本 | 不用 nightly，见[工具链](#工具链) |

`max-llm` 和 `qqbot` 都用 reqwest 0.13，不会编出两份 reqwest。

v1 之后再加的：

| 用途 | 选择 | 备注 |
|---|---|---|
| 浏览器 | nixpkgs 的 Chromium（现在 155），playwright-core 1.59.0 | 群 VM 里的常驻服务，程序经 CDP 连，见[浏览器](#浏览器) |
| 向量 | pgvector 0.4.2 | 支持 sqlx < 0.10 |
| 自动化 | croner 4 | |
| 后台 agent | pi（`@earendil-works/pi-coding-agent`），`--mode rpc` | 跑在群 VM 里，在 Nix 里钉住版本 |
| Matrix | matrix-sdk 0.18.0 | 先不做；0.19 和 sqlx 0.9.0 解析不到一起，见 [Matrix](#matrix) |

## 配置

2026-10-27 定。Haskell 版的配置是 CLI、环境变量、YAML 三层逐字段合并：环境变量会悄悄覆盖文件，未知键被静默忽略；线上的配置由三处拼成：sops 模板渲染的整份配置、另一个 sops 模板渲染的 env 文件、module 导出的环境变量。这些都不要了。

### 来源和校验

- **只有一个来源：TOML 文件。** CLI 只有子命令和 `--config`；不读 `MAX_*` 环境变量，日志级别也写在文件里；没有优先级规则。
- **严格解析。** 所有结构体都加 `deny_unknown_fields`；默认值只在代码里写一处；可选功能是 `Option<Section>`，不写就是关闭；启动时做跨字段校验，比如引用的模型必须存在。
- **秘密和私密值只写文件路径。** 密钥用 `api_key_file`、`access_token_file`。不该进公开仓库的标识也一样，比如房间白名单、镜像群号、owners，用 `rooms_file` 这类字段，一行一个。配置文件本身不含任何敏感内容。启动时读所有秘密文件，缺了就报错退出。
- **不热加载**，改了就重启。

### 和 NixOS 的关系

- module 用 freeform 的 `settings`，经 `pkgs.formats.toml` 生成进 nix store。module 自己管的路径（数据库 socket、媒体目录）用 `mkDefault` 写进 `settings`，不导出环境变量，也没有 `environmentFile`。
- 构建时跑 `max check-config` 校验结构，不读秘密文件。配置写错，`nixos-rebuild build` 就会失败。
- 配置一改，store 路径就变，systemd 自动重启；秘密轮换由 sops-nix 的 `restartUnits` 触发重启。
- tank 的 `max.nix` 里 owners 现在是明文，迁过来时一起挪进 sops。

### 两层：配置文件和运行时设置

配置文件管部署时的基础设施和默认值。`/model`、`/effort`、`/persona`、`/proactive` 这类按会话的覆盖存在数据库里。两者不合并成一套"配置"，代码里也用不同的类型。

### LLM：provider、模型、选用

和 Codex、pi、Hermes 一样分三层。Haskell 版把三层揉成了一层：tank 上 23 个 profile 只有 7 个不同的地址，还有两对是同一个模型只差推理强度。

1. **provider：怎么连。** 地址、协议（`responses` 或 `chat`）、认证、请求头、重试、超时、NInfer 的缓存断点 `cache_breakpoints`、空闲窗口 `idle_window_secs`（默认 300，见[运行流程](#运行流程)）。同一个地址既要 chat 又要 responses，就写成两个 provider。空闲窗口按这家缓存的寿命定（2026-10-27 查）：OpenAI GPT-5.6 起默认至少 30 分钟、每次读续命；Anthropic 默认 5 分钟、可选 1 小时；Gemini 官方不给数，第三方估计 3–5 分钟；DeepSeek 几小时到几天；本地 vLLM、SGLang 只受显存限制。
2. **模型：是什么。** 挂在 provider 下，表名就是发给 API 的模型 id。写上下文窗口、最大输出、输入模态、是否支持推理、默认采样参数。
3. **选用：谁用哪个、怎么用。** 默认模型、各个角色（比如 intent）用的模型和推理强度。引用一律写成 `provider/模型`，按第一个 `/` 切开；provider 名里不能有 `/`。

```toml
[database]
url = "postgresql:///max?host=/run/postgresql&user=max"

[platforms.qq]
app_id_file = "/run/secrets/max/qq-app-id"
app_secret_file = "/run/secrets/max/qq-app-secret"

# 第 3 层：谁用哪个、怎么用
[llm]
default = { model = "cliproxy/gpt-5.6-luna", effort = "xhigh" }
intent = { model = "local/qwen3.5-4b" }

# 第 1 层：怎么连
[llm.providers.cliproxy]
base_url = "https://cliproxy.example/v1"
protocol = "responses"
api_key_file = "/run/secrets/max/cliproxy-api-key"
retries = 2
stream_idle_timeout_secs = 120
idle_window_secs = 300

# 第 2 层：是什么（数值只是示例）
[llm.providers.cliproxy.models."gpt-5.6-luna"]
context_window = 400000
max_output = 128000
reasoning = true

[llm.providers.local]
base_url = "http://127.0.0.1:8080/v1"
protocol = "chat"

[llm.providers.local.models."qwen3.5-4b"]
context_window = 32768
```

- 流式请求用空闲超时，不用总时长；重试次数放在 provider 上。Haskell 版是每次尝试最多 1800 秒，晚间网络差时再叠上重试会层层放大。
- 不做内置模型目录。启动时对照服务端的 `/models` 检查一遍。
- `/model` 只选 `provider/模型`，`/effort` 只调强度。不再有 `gpt-5.6-luna-medium` 这种只差强度的 profile。
- 老会话选过的模型和强度不导（2026-10-29 owner 定，原来打算把 profile 名映射成"模型加强度"）：maxx 的配置里没有那些模型，选了不认识的模型，这个会话的每个 turn 都会失败。都用默认，要换再 `/model`。`llm_usage` 不导。

v1 只定义它用得到的几节：database、`platforms.qq`、llm，加上顶层的 `owners_file`、`utc_offset` 和 `log`。intent 没有配置项（2026-10-29 删了 `[intent]` 一节），见 [intent](#intent)。其它节跟着对应功能一起加。

## 运行时结构

任务树、各个 actor 之间的信箱和一次运行的事件顺序见图：<https://claude.ai/artifact/KrciskAXJfMF2qTHF6hDbW>

任务之间只有两种关系：父子（谁拥有、谁负责关掉）和信箱（谁给谁发什么）。

- root scope 下有两个子 scope：
  - services：常驻任务。平台连接（QQ 的网关连接）、平台 sender、VM 服务、MCP 服务、派生数据 worker，以后的自动化调度器。见[三种角色](#三种角色)。
  - conversations：会话表，和每个会话一个 actor。会话表按端点找到会话的 actor，没有就建会话、起 actor；没绑定的群直接丢掉，见[运行流程](#运行流程)第 1 步。actor 起来以后一直在，不按空闲退出；出错退出了，下一条消息再起它，见[重启](#重启)。
- 会话 actor 是这个会话唯一的控制线程，见[会话 actor](#会话-actor)。它的信箱是这个会话所有事件的唯一入口，它自己只 await 数据库。它下面挂三个 scope：
  - `io`：当前核心在途的模型调用和工具调用（`run_code`、`shell`）。每个核心一个，核心结束时（`/kill`、失败、重启的宽限期到期）整个关掉。
  - `side`：intent 分类这类不属于核心的调用。
  - `jobs`：后台 agent，能比发起它的核心活得长。每个 job 一个自己的 scope，丢掉就停了（2026-10-30）。
- `Scope` 由 `JoinSet` 和 `CancellationToken` 组成（2026-10-27 去掉了 reaper、defer 和 Background）：
  - `spawn` 给子任务一个子令牌，同一个令牌也返回给调用方，用来单独取消这一个任务。
  - `close(grace)`：先取消，在宽限期内等子任务自己结束；到期调 `JoinSet::shutdown`，也就是 abort 全部，再等它们真正停下。
  - 被 drop 时：`JoinSet` 自己的 Drop 会 abort 全部子任务。这是同步发起的，不等。
  - `close` 到期用 `shutdown` 而不是直接 drop，是为了保证返回时子任务的 future 都已经真正 drop 掉。否则可能服务已经关了，还有残留的 turn 在往它发东西。

规矩：

1. 禁止裸 `tokio::spawn`，用 clippy 的 `disallowed-methods` 拦住。任务只能经 `Scope` 创建。
2. 脱离要显式：后台 agent 挂在会话的 `jobs` 下，不挂在核心的 `io` 下。
3. 副作用交给活得更久的 owner：发送由会话 actor 入账后交给平台 sender；只能靠 API 停下的外部资源，停止命令交给持有那条连接的常驻服务。见[资源怎么结束](#资源怎么结束)。

关闭顺序：

1. 停接入，不再产生新消息。QQ 的网关连接这时存下 session id 和序号，见 [QQ 官方机器人](#qq-官方机器人)的"跨重启 Resume"。
2. 每个会话 actor 收到停止：核心空闲就结束；否则让它在宽限期里接着做完手上的事，到期还没空闲就关掉 `io`、中断这个 turn（见[重启](#重启)）。然后关掉 `side` 和 `jobs`，actor 退出。内层的宽限期要比外层短。
3. 排空：平台 sender 发完已入账的消息、记完回执，有截止时间。
4. root scope 结束。运行时用 `shutdown_timeout` 关，不直接 drop，因为 drop 会一直等 `spawn_blocking` 的线程。最外层由 systemd 的 `TimeoutStopSec` 兜底，到期杀掉整个服务的 cgroup。

systemd 要设 `KillMode=mixed`：SIGTERM 只发给主进程，VM 这些子进程由主进程按上面的顺序收拾，最后剩下的才由 systemd 统一 SIGKILL。默认的 `control-group` 一开始就把 SIGTERM 发给 cgroup 里的所有进程，cloud-hypervisor 和 virtiofsd 会立刻退出，第 2 步给工具批次的宽限期就落空了。

### 三种角色

2026-10-27 定。运行时里的任务分三种，按它产出什么分：

1. **主体**：会话 actor 和它 spawn 的 I/O 任务。消费请求，产出回复。
2. **派生数据 worker**：lingo、embedding、caption、召回向量、媒体下载和转发展开。输入是 ledger 或另一张派生表，输出是自己独占的一张表，只有它一个写者；从不碰 ledger 和 turn 记录，结果只在投影时被读。读 ledger 的 cursor 按会话记，见[时间线](#时间线)。触发三种：入账通知、定时器或水位、启动和定期的缺口扫描。一个工作单元一个事务，不留半截；重启不存队列，靠扫描补。Haskell 版 9 月的简化最后也把这几个收敛成了"本地有界队列加缺数据扫描"。

   共同的只有约定，不写框架（2026-10-29 owner 定：先写过一个通用驱动器，按 `Throttle`/`Debounce`/`Urgent` 排单元，结果调度策略都堆在驱动器里，完成与否也在驱动器的队列和数据库里各记一份，当天拆回各 worker）：
   - 输出表独占，只有它一个写者；从不碰 ledger 和 turn 记录，结果只在投影时被读。
   - 单元可重入：先查输出表，已经有了就不做。做没做完只看数据库，内存里不记完成状态。
   - 输入是入账通知，或者上游 worker 交来的键（caption 收下载存好的图，embedding 收 caption 写好的表情包）；漏掉的靠扫描按输出表找缺的补：启动时，embedding 和召回向量另外每小时一次。
   - 并发、重试、超时、什么时候跑，是各 worker 自己的常量和自己的循环：常驻任务一个 `Scope`，一个单元一个任务，`Semaphore` 限并发，重试在单元自己的任务里 `sleep`，重试用完只记日志。caption 和 embedding 另有一个"正在做"的 sha256 集合，同一个文件在做的时候又来，不再起一个；它只防重复调模型，丢了也只是多做一次。
   - 关机时在跑的直接 drop，事务回滚，下次启动由扫描补。
   - 入账通知是会话 actor 提交之后同步发的：`Shared` 里一组无界 mpsc，每个 worker 一个（`worker::Rows`），不用 broadcast，它落后了会丢通知。邮箱的类型由 worker 定，从入账的一行转换过来。

   各 worker 现在的策略：下载同时 4 个、重试前等 1 秒和 4 秒，见[媒体](#媒体)；caption 同时 2 个、失败一分钟后再试一次、再失败写空 caption；embedding 同时 2 个、重试前等 10 秒和 60 秒，见[发图](#发图)；召回向量一样，见[召回](#召回)。不像 Haskell 版用 `message_projections` 的标志位当队列。不要：持久化的队列、失败表和重试次数列、租约、`LISTEN/NOTIFY`、配置里的策略旋钮。lingo 来了照这几条写自己的循环。
3. **触发源**：产出的不是表，是输入，全部进会话 actor 的同一个入口（[运行流程](#运行流程)第 2 步）：有核心在跑就喂给它，没有就起一个核心。差别只在源头：
   - 跟着消息来的，全部由会话 actor 里的 [intent](#intent) 判：@、回复是它的同步规则，看起来没说完的先去抖几秒；其它消息由小模型在 `side` 里异步判，判定叫醒有每小时上限，判定回到信箱，不阻塞别的消息。叫醒核心的 `Wake` 都按 `seen` 过滤。自动化的 ledger_match 是规则。
   - 外部来的：cron、HTTP webhook、外部轮询、proactive 的闲置触发。services 下一个调度器，定义在 `automations` 表，到点给对应的会话 actor 发请求。调度器的形状和派生 worker 一样（常驻、定时器、独占写 `automation_fires`、启动时扫一遍），只是 `run` 的结果是发请求。细节等做自动化时补。

### 资源怎么结束

2026-10-27 定。资源有两种结束方式，两种都是正常路径：

- **收尾**：拥有者把活干完，调 `close().await`。它可以等、可以返回错误，有自己的超时策略。
- **取消**：拥有者自己被取消了，比如 `/kill`、超时、关机宽限期到期。拥有者的 future 被 drop，资源跟着 drop，执行 `Drop`。每次 `/kill` 都会走这条路，所以要按正常路径设计和测试。

发起取消全是同步的：drop future、`CancellationToken::cancel()`、关 fd、发 kill 信号、设取消标志。取消真正完成平时没人等，只有关机时由 `Scope::close` 等。

规则：

1. **`Drop` 只同步发起，不阻塞，也不 spawn。** 没有 reaper，也没有 Background。
2. **外部资源优先把生命周期绑在连接或 fd 上。** 连接一断，对端自己收尾；崩溃时内核也会关 fd，所以连崩溃都能覆盖。
   - LLM 请求：drop 掉流就是断开连接。
   - pi：跑在 stdio 上，可以直接杀进程。
   - VM 命令：每条命令是 guest 里的一个 transient unit（`systemd-run --pipe --wait`，`RuntimeMaxSec` 兜底）。SSH channel 关了，guest 不会自己杀它，所以按第 3 条走，见下面的 `VmCommand`。codemode 的 runner 也是一条 VM 命令，它的 MCP 会话在 `Drop` 里同步吊销。
   - VM 本身：主进程的子进程，drop 就杀，见 [VM 进程](#vm-进程)。
   - 浏览器：runner 的子进程，经管道连。runner 退出时 Playwright 杀掉它；runner 被杀时它和 runner 在同一个 unit 里，一起被杀。2026-10-29 实测：同一个 VM 里接着跑的下一次运行，看不到上一次的浏览器进程。
   - 杀进程要杀整棵树，用进程组或 cgroup。只杀直接子进程的话，孙进程还活着，还开着输出管道。
3. **对端只认 API 调用的**：`Drop` 里 `try_send` 一条停止命令给持有那条连接的常驻服务，由它去调 API。它在 services scope 里，关机时按顺序关。
4. **崩溃时 `Drop` 不会执行**：VM 是主进程的子进程，systemd 按 cgroup 把它们和主进程一起杀掉，VM 里的命令和 pi 进程跟着消失，不需要清理孤儿。MCP 会话只存在内存里，进程没了就全部失效。
5. **只有正常结束时要等结果或要报错的类型才有 `close`**，比如要拿退出码、要把待发消息发完、要提交事务。其它类型只有 `Drop`。
6. **`close` 跟着所有权走。** 谁拥有，谁在自己正常路径的末尾调。拥有需要 close 的字段的结构体，自己也要有 `close`，按创建的反序关字段。`close` 拿 `self`，一个值只会在一个地方被 close。body 里的 `?` 不能跳过 `close`：先拿到结果，再 close，最后才处理结果。
7. **`close` 自己被 drop 也要安全。** 中途任何一个 `await` 被丢掉，`Drop` 都还能按取消路径收拾。"已关完"的标记放在最后一步。
8. **不在 `Drop` 里报警，也不用 drop bomb。** 取消就是 drop，报警只会是噪音。忘了调 `close` 由测试来抓：fake 环境记下"因为连接断开而被杀"的资源数，正常路径的测试断言它为 0。

```rust
pub struct VmCommand {
    channel: Channel,             // russh 的 channel，drop 时关闭
    unit: Option<UnitName>,       // guest 里的 transient unit；close 正常收尾后置空
    stop: mpsc::Sender<UnitName>, // 持有这个 VM 的 SSH 连接的任务
}

impl VmCommand {
    pub async fn read_output(&mut self, limit: usize) -> Result<Output>;

    /// 收尾：给命令 grace 时间自己退出，到时间就 stop 它的 unit，再等退出码。
    /// grace 是策略，不是防卡死的保险；卡住时由外层工具调用的超时 drop 掉。
    pub async fn close(self, grace: Duration) -> Result<ExitStatus>;
}

impl Drop for VmCommand {
    // 只同步发起：由连接的持有者在同一条连接上发 `systemctl stop`
    fn drop(&mut self) {
        if let Some(unit) = self.unit.take() {
            let _ = self.stop.try_send(unit); // 发不出去就靠 RuntimeMaxSec
        }
    }
}

async fn exec(call: ExecCall, vm: &Vm) -> Result<ToolOutput> {
    let mut cmd = vm.spawn(&call.command).await?;
    let output = cmd.read_output(call.limit).await; // 这里先不用 ?
    let status = cmd.close(EXIT_GRACE).await;       // 不管 output 成败，都会走到这一行
    Ok(ToolOutput::exec(output?, status?))
}
```

语言级的 async drop（`#![feature(async_drop)]`）还是 nightly 上的实验特性，没有稳定时间表。就算稳定了，`select!`、`JoinSet` 和运行时都是同步 drop future 的，取消时执行的仍然只是同步的 `Drop`；它能省掉的只是"记得调 close"这一步。不用。

### cancellation safety

用 drop 取消，每个 `await` 都可能是终点。被 drop 的 future 自己的局部变量会跟着消失，没人看得到它们停在一半的样子；要管的只是活过这次 drop 的状态。

会话 actor 自己不会被取消，只在关机时随 conversations scope 结束；平时被取消的是它 spawn 的 I/O 任务。I/O 任务和 actor 之间只有信箱，没有共享的可变状态。所以审查时要看的是：一个 I/O 任务在任意 `await` 处被 abort，外面留下了什么。

| 活下来的状态 | 可能出的问题 | 规则 |
|---|---|---|
| 核心 | 停在一次状态转移的中间 | 核心是 actor 的字段，转移是同步的，只在 actor 处理事件时发生；I/O 任务碰不到它 |
| 说出口的话 | 群里发了，账上没记 | 分段器在模型调用任务里，只产出 `Said`；sender 只从 actor 拿入过账的段。任务在哪里被 abort 都只会少说，不会漏记 |
| actor 等的结束事件 | 永远不来，核心一直等着 | 回执在 `Drop` 里补发"没有结果"，见 [I/O 任务和协议适配](#io-任务和协议适配) |
| 平台连接 | 一帧写到一半，整条连接坏掉 | 共享连接只由它自己的任务读写，其他人经 channel 交接 |
| 数据库 | 写到一半 | 用事务；查询半途被 drop 的连接，sqlx 下次使用前会先读完残留的响应。actor 的数据库 `await` 只在关机时可能被丢掉 |
| turn 记录 | 关机时结束的写入被打断 | 事务回滚，等同崩溃，启动时记为 `Lost` |

`select!` 循环里只放 cancel-safe 的分支：

- **可以放**：
  - `mpsc::Receiver::recv`、`CancellationToken::cancelled`、`JoinSet::join_next`；
  - `FramedRead` 加 `LinesCodec` 的 `next()`：缓冲区在流里，不在 future 里。`LinesCodec` 只按 `\n` 切，满足 pi 的要求，要设最大行长；
  - `sleep_until(deadline)`，或者在循环外 pin 住、反复使用的 `Sleep`。
- **不能放**：
  - `read_line`、`read_exact`、`write_all`；
  - 每轮新建的 `sleep(dur)`：每次重建都会把计时器重置。

不拿着锁跨 `await` 修改不变量，clippy 的 `await_holding_lock` 能查到一部分。

测试分两层，都用 tokio 的 `start_paused`，结果是确定的：

1. **actor**：用 fake provider、fake 工具和 fake sender 跑一段剧本，记下 actor 处理的事件序列，长 N。再跑 N 遍，第 k 遍在第 k 个事件之后插一个 `/kill`；停止也这样跑一轮。每次检查：
   - fake sender 收到的，正好是入过账的 Max 的消息；
   - 插入之后才到的旧事件都被丢掉了；
   - 没有泄漏的命令。
2. **I/O 任务**：在每个 poll 点 drop 一次，检查恰好发出了一个结束事件、fake 连接没有收到半帧、没有泄漏的资源。

### 超时

上限只设在工作单元的边界上，单元内部的 `await` 不套超时：拥有者一被取消，内部卡住的 future 也跟着被 drop。

| 位置 | 写几次 | 性质 |
|---|---|---|
| `Scope::close(grace)` | `Scope` 里一次 | 关机时防卡死 |
| 会话 actor 的到期时间 | actor 主循环里一个 `sleep_until`，到期时间取空闲窗口和停止宽限期里早的那个 | 策略：provider 的 `idle_window_secs`、关机的宽限期。turn 没有墙钟：actor 只等数据库，模型调用和工具各有自己的上限 |
| 工具调用上限 | 两处：`run_code`、`shell` 一次运行一个（`shell` 默认 120 秒，调用最多要 600 秒；guest 里的 unit 另有晚 30 秒的 `RuntimeMaxSec`，max 这边丢了也停得掉）；程序里每次调 Max 工具，在 MCP 执行器里一个。具体工具里不写 | 防卡死 |
| VM 开机 | VM 服务里一次：60 秒内要能 SSH 进去，每 100 ms 试一次；等 virtiofsd 建 socket 5 秒；外面再套一层 70 秒 | 防卡死 |
| VM 闲置 | VM 服务里一次：每分钟扫一遍，闲置超过 `idle_minutes`（默认 120）的关掉 | 策略 |
| 网络客户端 | 配置里一次：LLM 的 `stream_idle_timeout_secs`（响应头和之后的每一段都要在这个时间内到，整个调用不设上限）、sqlx 的 `acquire_timeout` 和 Postgres 的 `statement_timeout`、平台连接的心跳；`max-llm` 里写死的连接超时，`qqbot` 里写死的 REST 连接和读超时、网关的连接超时和重连退避 | 防卡死 |
| 先等再升级 | 按需 | 策略，比如 `close` 先给命令时间自己退出 |
| 常驻服务里的等待表 | 每张表一次 | 防泄漏，比如 sender 里等回执的表。常驻服务外面没有取消替它兜底 |
| 派生数据 worker | 各 worker 自己的一处，数值是它的常量：下载靠 HTTP 客户端的 10 秒连接超时和 60 秒整体超时，重试前等 1 秒和 4 秒；caption 每次调用 2 分钟；embedding 每次请求 30 秒 | 防卡死；重试和重扫是策略 |
| 回合外的模型调用 | `Chosen::complete` 一处：判定、caption 都经它调，拿全文、记用量（记不上只打日志，结果照用；turn 和 job 也一样，2026-10-30 改，原来 turn 的用量记不上会让整个会话 actor 退出），整个调用的上限由调用方给（判定 60 秒，caption 2 分钟），不重试 | 防卡死 |
| 模型调用的重试退避 | 模型调用任务里一次：1、2、4、8 秒，只在还没说出任何话的时候重试，次数是 provider 的 `retries` | 策略 |
| sender 等额度 | QQ sender 里一次：主动消息超了每分钟的额度就等到最早那条满一分钟 | 策略：等，不丢 |
| 关机的各级宽限期 | `main` 里一处：接入 5 秒（存网关会话）、会话停止 20 秒（让核心做完手上的事，到期中断）、会话表 25 秒、sender 排空 15 秒、运行时 10 秒，合起来在 systemd 的 60 秒以内；派生数据 worker 不等，手上的单元下次启动由扫描补或者放弃 | 防卡死 |

审查规则：`timeout(` 和 `sleep(` 只出现在上表这些地方。

前提：上限只对停在 `await` 上的 future 有效。所以：
- async 里不阻塞；
- `spawn_blocking` 配取消标志，因为 abort 对已经开始跑的 blocking 任务无效；有上限的计算可以不配，比如算一个最多 64 MiB 的文件的哈希、在尺寸上限内解一张图；
- `Drop` 里不阻塞。

真破了这几条，还有 systemd 的 `TimeoutStopSec` 在最外层兜着。

## 数据和运行模型

2026-10-26 至 10-28 讨论定下。总览：ledger 记录群里说了什么；turn 记录记下 Max 在幕后做了什么；核心是决定 turn 下一步做什么的规则；会话 actor 负责入账和驱动核心，I/O 都在它 spawn 的任务里。

### 原则

1. **库里存事实，只追加。** ledger 和 turn 记录都没有 UPDATE，也没有可变的状态列。
2. **状态由记录推出来，不另存。** turn 处在哪个阶段，看它有哪几种记录就知道。
3. **核心存它给模型看的。** 一次运行留下的是基础上下文和 transcript：每次模型调用的请求，就是基础上下文加上到那次输出为止的 transcript。喂给核心的输入不存，也不从输入重建核心（2026-10-29 改，owner 提出：原来存输入日志、靠重放还原；重启恢复取消以后，重放只剩测试在用，模型输出却在日志和 transcript 里各存一份，推理 blob 也跟着存两份）。结局另外写下来，见 [turn 记录](#turn-记录)。
4. **阶段写成一个带数据的枚举。** 要跑的调用、在途的调用、失败的原因都在各自的阶段里，非法的组合写不出来（2026-10-29 改，原来五个字段一起表示，合法组合靠人维护）。
5. **核心跑的时候不碰库。** 一次运行只写两回：开始时写一个标记；结束时存一份快照，就是上面那份记录。崩溃时正在跑的 turn 记为 `Lost`，见[重启](#重启)。
6. **上下文只在核心里变。** 基础上下文在创建核心时传入，之后不变；transcript 只追加；裁剪只作用在每次的请求上；协议适配层降级时只删不加。
7. **别处已有的存引用，只在 turn 里有的存本体。** ledger 消息和媒体文件存引用；推理 blob、工具输出和基础上下文存本体。
8. **中立格式，原始数据透传，只在边缘降级。** 平台消息和模型条目用同一种做法：中间是中立的类型化结构，平台或 provider 的原始数据原样带着，有损转换只发生在适配器往外发的那一步。见[消息格式](#消息格式)和[条目](#条目)。
9. **一个会话一条时间线，一个写者。** 会话 actor 逐条入账，其它一切都在时间线的某个位置上读，见[时间线](#时间线)。

### ledger

ledger 是会话账本：所有平台上、所有人（包括 Max 自己）说过的每一条消息，统一成同一种[消息格式](#消息格式)，只追加。一个会话的消息按会话 actor 入账的顺序排，就是这个会话的[时间线](#时间线)。它回答"群里发生了什么"。

- 每条消息：会话、发送者、内容、原始 payload、平台 id、序号、时间。Max 发出的消息的平台 id 不在这里，在 `deliveries`，见[出站](#出站)。
- Max 发出的每一段消息额外带 turn id 和段号。

Max 在幕后做的事（模型怎么想、调了什么工具）不进 ledger。ledger 和 turn 之间只有三处引用：Max 发出的消息指向产生它的 turn；turn 指向触发它的消息；后续输入引用对应的消息。以后 turn 的基础上下文从 ledger（加上记忆）投影出来，不读别的 turn 的 transcript，见[上下文投影](#上下文投影)。

### 时间线

2026-10-28 定。一个会话在 ledger 里的所有行，按 id 排，就是这个会话的时间线。运行模型的顺序问题都靠一条规则解决：**会话 actor 是时间线唯一的写者，其它一切都在时间线的某个位置上读。**

- actor 逐条入账，每条提交了才处理下一个事件。所以同一个会话里，id 的顺序、提交顺序、actor 处理的顺序三者一致，位置就是消息 id。
- 写进时间线的：别人的消息和事件（编辑、撤回）、命令消息、Max 说出口的每一段和做的每个动作。全都经 actor：平台连接只归一化，平台 sender 只负责发；别的会话、MCP 工具、调度器要往这个会话发东西，都是给它的 actor 发请求。
- 不进时间线的：平台回执（在 `deliveries`，见[出站](#出站)）、Max 的幕后过程（在 [turn 记录](#turn-记录)里）。

actor 记着三个位置：

| 位置 | 含义 | 用在哪 |
|---|---|---|
| `head` | 时间线的最后一条 | 起核心时取它作快照位置 |
| `from` | 当前核心的快照位置 | 基础上下文只投影 `id <= from`，之后的每一条都喂给核心 |
| `seen` | 进过模型请求的最后一条 | intent 的 `Wake` 作不作废 |

由此直接得到：

- **核心的输入不重不漏。** 起核心时 `from = head`；之后每入账一条，actor 就喂给核心，本 turn 自己说的话和做的动作除外，它们已经在 transcript 里。核心看到的就是"位置 `from` 的快照，加上之后的每一条"，由定义保证，不靠时序。
- **`seen` 好维护。** actor 一入账就喂，核心发请求时会带上攒着的全部输入，所以发模型请求那一刻，请求里正好是 `..=head`，这时设 `seen = head`。`/kill` 和启动时也设 `seen = head`。用法见 [intent](#intent) 的"`Wake` 的去处"。
- **派生 worker 按会话记 cursor。** 一个会话里 id 的顺序就是提交顺序，往前推的 cursor 不会漏掉晚提交的小 id。不同会话之间没有这个保证，所以不用全局 cursor。

### 消息格式

2026-10-27 定：保留 [ADR 003](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/003-message-ir-capability-rendering.md) 的核心想法，去掉它的类型机制。上下文投影、搜索、记忆和以后的镜像都读同一种格式，不按平台分支。

每条消息存两样东西：

- **节点**：文本、提及、表情、媒体、卡片、转发、不支持。每个非文本节点入库时就带好文本兜底，比如提及的显示名、媒体的说明、卡片摘要，之后在哪里降级都不用再查库。
- **原始 payload**：平台发来的原样数据。它是事实源：镜像时原生往返要用，比如把 QQ 表情、转发原样发回 QQ；normalizer 改了，也能从它重建节点。节点相当于所有读者共用的缓存。

入库时不降级。

Haskell 版用 5 个 phase 索引同一棵类型树。这里改成几个具体类型，各管一个边界：

```rust
// 适配器的产出：带平台原生 id，不访问数据库
struct Inbound { /* ... */ }

// 入库的统一格式，由会话 actor 在入账事务里从 Inbound 转换得到
struct Message { nodes: Vec<Node>, raw: serde_json::Value, /* 会话、发送者等 */ }

enum Node {
    Text(String),
    Mention { target: MentionTarget, display: String }, // 某个账号（identity），或者全体
    Emote(Emote),                                       // 平台表情，带名字作兜底
    Media { media: Option<MediaRef>, meta: MediaMeta },
    Card(Card),
    Forward(ForwardRef),
    Unsupported(Unsupported),
}

// 模型能写的部分：文字和提及（2026-10-29 去掉了表情和媒体）
struct Draft { reply_to: Option<MessageId>, nodes: Vec<DraftNode> }

enum DraftNode {
    Text(String),
    Mention(PrincipalId),
}
```

- 发送时每个适配器写自己的 `fn lower(&Draft) -> 原生消息`，没有通用的降级类型。
- 给模型看的文本由一个渲染函数从 `Message` 生成，不是单独的类型。
- 模型用 principal 句柄提及人，发送时再解析成目标平台的账号，沿用 [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md)，见[身份](#身份)。

**镜像**先不做：它本来是 QQ 群和 Matrix 房间之间的，Matrix 先不做了（2026-10-29），见 [Matrix](#matrix)。这些东西都等做镜像时再加：

- 能力表：每个端点对每种节点是原生、转文本还是丢弃。
- 降级记录。

v1 的 ledger 已经存了原始 payload 和文本兜底；投递回执（`deliveries`）和丢掉 echo 的做法 v1 就有，镜像时一个端点一行照用，见[出站](#出站)。到时不用迁移数据。

模型那边的[条目](#条目)是同一个做法：`Item` 的 `kind` 对应节点，`opaque` 对应原始 payload，协议适配层的降级对应发送时的 `lower`。

### 回复的写法

2026-10-28 定，沿用 Haskell 版（见 features.md 的 Replies）。模型的文本输出由分段器（`max-core`）切成一串 `Draft`：

- 空行分段，一段一条消息；代码块里的空行不切；`[split]` 强制切开，条数不限。
- 出现 Markdown 标题（`#` 到 `######` 加空格）以后按节切（2026-10-30 加）：标题开头一条，空行不再切，一节连同表格、列表整个发；标题之前的照旧按空行。分隔线（`---`、`***`、`___`）在哪都是切点，本身不发。起因：群友要 Max 正经问题用 Markdown 写，一个长回答被切成了单独的标题、单独的表格和一条看着是空的 `---`。
- 占位符只有一种写法 `[类型#id]`，后面可以带 `: 描述` 和紧跟的 `(属性)`，都只认 id（2026-10-28 改，沿用 Haskell 版 2026-08 统一后的写法）。原来的 `[↩#id]`、`[@#N]` 是符号，`[撤回了 #id]` 这类是句子，模型会照着说出来；`[unsend#id]` 不会。
- 段首的 `[reply#id]`：这一段回复那条消息；一段里有几个时取第一个，全部去掉。号码无效时怎么办见[解析和发送](#解析和发送)。
- `[mention#N]`：提及一个人，解析规则见[解析和发送](#解析和发送)。
- Max 写文字、提及，和图片、表情包的句柄（2026-10-29 定，同日改）。QQ 官方接口发不出小黄脸，见 [QQ 官方机器人](#qq-官方机器人)：模型照着历史写出的 `[face#id]`，或者只读的 `[face: 名字]` 这类显示形式，分段器认出来直接去掉，免得原样漏进群里。收到的表情给模型看是 `[face: 名字]`。`[sticker#id.序号]`、`[image#id.序号]` 单独成一条，发出去的是那张图，见[发图](#发图)。
- 核心醒着时群里每条消息都进它的 `[新消息]`，所以提示词要它只回在跟它说的：@它、回复它、点名叫它的，和 `[判定 …]` 行指的那几条；别人之间的对话、问别人的问题不插嘴，被叫闭嘴就 `[silence]`（2026-10-29 加：一次判定叫醒后它把同一块里问别人的、两个群友之间的话都回了，被叫闭嘴还顶嘴）。
- 整个输出为空，或者只有 `[silence]`，就什么都不发。段首的引用不影响判断。一段里还有别的内容时，`[silence]` 直接去掉。旧提示词教过的 `[silence:表情名]`（给消息回一个表情）当成 `[silence]`：reaction 不做了，见[有意删除的功能](#有意删除的功能)。
- 模型偶尔把工具调用写进正文，比如 `[find_stickers query="无语"]`：方括号里是英文标识符、空白，再带 `=` 或引号的，去掉。代码块里的不动。
- 分段器是唯一把模型文本变成消息的地方，进度旁白也走它。Haskell 版的教训：每一个自己另写"文本转消息"的发送路径，最后都把 `[split]` 或 `[reply#id]` 原样漏进了群里。
- 切分只看文本，不看流式到达的时机：同一段输出，流式和一次给出切出来的消息完全相同。Haskell 版流式时还会在长段落的句末提前放出一部分，结果取决于时机，这里不做。

### 出站

2026-10-28 定。Max 的话**说出口就入账**：模型调用任务里的分段器切出一段，作为 `Said` 交给会话 actor；actor 入账，再交给平台 sender，不等平台回执。工具发的图和文件、撤回这些动作也一样，先入账再发；禁言不入账，见[群管理](#qq-官方机器人)。所以时间线上 Max 的话和别人的消息谁先谁后，按 Max 的视角排，平台上落地的先后可能相反；但新核心的尾巴一定看得到旧核心说过的话。

- **平台 sender**：每个平台一个常驻任务。同一个会话的东西按入账顺序串行发，不同会话之间并发。撤回 Max 自己的消息、回复它刚说的话，一定排在那条消息的发送后面，轮到时平台 id 已经有了。
- **`deliveries` 表**：每次发送的结果一行：消息、端点、平台 id 或错误、时间。sender 是唯一的写者，只追加。镜像时一条消息每个端点一行，用的也是这张表。撤回这类动作没有自己的平台 id，成了就记 sent、不带平台 id（2026-10-29，迁移 0012）。
- **平台 id 查 `#id`**：入站消息的平台 id 在 `messages`，Max 发出的在 `deliveries`。有人回复或撤回 Max 的消息，actor 入账时查这两处；查不到就按文本兜底。
- **发不出去**：`deliveries` 记一行错误，投影时这条消息后面标"（没发出去）"，下一个核心的模型看得到。不回报给正在跑的核心：一个 turn 里接连发不出去，通常是平台断了，模型知道了也做不了什么。
- **崩溃**：入账了但没有回执的消息，sender 启动时先补记成"结果未知"，投影时标"（可能没发出去）"。不重发，免得发两遍。
- **echo**：平台把 Max 自己发的东西再推回来的，适配器直接丢掉。QQ 的网关不推机器人自己发的消息，没有 echo；以后接的平台要是会推回来，发送时带上 `max-<消息 id>` 这类 id，适配器按它认出来。Max 自己的动作，平台通知如果还会推回来，actor 入账前看时间线上是不是已经有这次动作，有就不记。不是这个进程发的（比如有人拿 Max 的账号手动发），照常入账，发送者是 Max。
- **经 `Post` 发**：不是模型文本输出的发送，都给目标会话的 actor 发 `Post`，由它入账：程序里调工具发消息或撤回（本群或别的群）、以后的自动化。命令的文字输出不经 `Post`：actor 自己入账，就在命令所在的会话里，不引用那条命令（2026-10-29 改：原来提议发到发令人的私聊，后来引用命令，owner 觉得多余）。QQ 没法从群成员的 `member_openid` 找到这个人私聊的 `user_openid`，私聊也只有体验用户进得来。要知道发没发成的（比如工具），`Post` 带一个回信通道，actor 把它交给 sender，sender 记完 `deliveries` 后回信；actor 自己不等。
  - `Post` 带来源 turn `origin: Option<TurnId>`（2026-10-28 定）。MCP 服务从会话里取，命令输出和调度器的为空。actor 入账时把它记成这条消息的 `turn_id`。`origin` 是自己当前核心的 turn 就不喂给核心：`run_code` 结果里内部调用的摘要已经有了，再喂一次模型会看到两遍。别的 turn 发来的，比如群 A 的 turn 往群 B 说一句，照常喂给 B 的核心。2026-10-29 先做了本会话核心的工具发的 `Post`（`send_image`、`recall_message`），回信通道是 sender 记完 `deliveries` 后回的消息 id 或错误；别的会话、调度器发来的，和喂给核心，等有了再做。来源 turn 已经结束时（`/kill` 或别的），`Post` 和工具的 job 请求（也带来源 turn）都拒掉，回"这一轮已经结束了"（2026-10-30 加，review 发现：调用在路上时 turn 被 kill，排在后面的 `send_image` 照样发了出去）。

### turn 记录

一次连续的运行是一个 turn：从一个触发起核心开始，到空闲窗口到期、`/kill`、失败或重启为止，中间吸收的触发都是它的输入（2026-10-27 改成单一核心实例，见[会话 actor](#会话-actor)）。turn 在库里有两种记录，全部只追加（2026-10-27 定，10-29 去掉了恢复用的 `TurnResumed`；10-30 把快照并进结局，原来的 `turn_snapshots` 和结局一一对应、同一个事务里写）：

```rust
// 触发起核心时。身份、触发和首次开始合在一条里（2026-10-27 合并了原来的 TurnAccepted）
struct TurnStarted { turn, conversation, ordinal /* t#，给模型引用 */, trigger /* intent 的 Wake，以后还有 job 结果、自动化 */, from /* 快照位置，见“时间线” */, started_at }
// 结局，连同核心整个存下来；崩溃时丢的 turn（Lost）没有 run
struct TurnFinished { turn, outcome: Outcome, run: Option<RunRecord>, finished_at }

// 一次运行留下的：给模型看的和它说的。2026-10-29 之前的行是输入日志的形状（core_version、first、inputs），没有代码读
struct RunRecord { spec: RunSpec, base: Context, transcript: Vec<Item> }

// 模型输出、工具结果、打断和失败是核心各自的方法，不是输入（10-29 改，见"核心"）
enum Input {
    Messages { ids: Vec<MessageId>, item: Item, people: Vec<PrincipalId> }, // 时间线上的新消息和事件，引用 ledger，同时存核心看到的样子；people 是第一次出现的人
    Wake(Wake),
    // 以后：AutomationFire { fire, item }。job 结果没有单独的输入，是一种 Wake，见下
}

struct Wake {
    ids: Vec<MessageId>,          // 它涉及的消息，作废的 actor 已经滤掉了；job 结果为空
    reason: Reason,               // Direct、Judged { note }、Job { job }（2026-10-30 加）
    item: Option<Item>,           // 给模型看的判定行或 job 的报告；直接触发为空，消息行上已经标着
}

enum Outcome { Answered, Silent, Interrupted, Failed(FailReason), Lost }
enum FailReason { Model { error: String }, ContextExhausted }
```

写入时机：

| 情况 | 写什么 |
|---|---|
| 触发起核心 | `TurnStarted` |
| turn 结束，包括重启时被中断 | `TurnFinished`，带着 run |
| 崩溃 | 什么都没写，启动时补一条 `Lost` 结局 |

- **trigger 记在 `TurnStarted` 里**：直接触发可以从消息本身重新判断，但判定、去抖合并了哪几条、自动化触发都不行。单一核心实例之后，触发来了就立刻起核心，"接受了但没起"这个状态不存在，所以不再单独记一条。
- **一个 turn 一份快照**：结束时和结局写在同一行里。核心不在运行中途写库，所以也没有"库里一份、内存里一份"的问题。
- **状态**：有 `TurnFinished` 就是已结束；没有就是在当前进程里跑着，启动时看到这种，就是崩溃时正在跑。
- **结局**：唯一存下来的派生结果。`Answered` 和 `Silent` 只说这次运行有没有发过话。查"哪些 turn 没结束"要靠它，所以写下来。`Lost` 例外，它由启动流程直接写，表示崩溃时它正在跑，没有快照。
- Max 回复的正文在 ledger 里，不在结局里。

### 条目

基础上下文、transcript 和请求都由条目组成：

```rust
struct Item {
    kind: ItemKind,
    source: Option<ModelTag>,          // 模型产生的条目，记下协议和模型
    opaque: Option<serde_json::Value>, // provider 附带的不透明字段，核心只搬运不解读
    tokens: u32,                       // max 估算好传进来；模型输出的条目取 provider 的用量
}

enum ItemKind {
    Text(String),
    ToolCall(ToolCall),
    ToolResult(ToolResult),
    Reasoning { text: Option<String> }, // 可读部分：摘要或明文推理
    // ...
}

struct ModelOutput {
    items: Vec<Item>,
    usage: Usage, // 含推理 token 数
}
```

推理内容这样处理：

- **Responses**：请求带 `store: false` 和 `include: ["reasoning.encrypted_content"]`，不依赖 provider 端的 `previous_response_id`。每个 `reasoning` 条目对应一个 `Reasoning`：`opaque` 存整个原始条目（含 `encrypted_content`），`text` 存摘要。
- **Chat**：`reasoning_content`（或 `reasoning`）对应一个 `Reasoning`。挂在工具调用上的签名（比如经 cliproxy 转发的 Gemini）放进那个 `ToolCall` 的 `opaque`。
- **把思考写进正文**：正文开头的 `<think>…</think>` 拆成 `Reasoning`。正文要是以"Thinking Process:""**Thought Process**""思考过程："这种独占一行的标题开头，就一个字都不说，这次调用算 `Error::Aloud` 失败，可重试，由模型调用任务重发。2026-10-29 Gemini 4 Argon 在群里连着三次这样：那三次调用 0 个思考 token，它把编号的分析步骤当回复写了出来，被分段发进群里；第一次漏出去以后，上下文里的"自己的上一条"就是这个样子，后两次跟着照写。标题后面有没有真正的回复分不出来，所以不拆，整条重来。
- **推理只属于本 turn**：它在核心的 transcript 里，随 transcript 进快照；不进 ledger，不进以后 turn 的基础上下文，不发到群里，也不让 `history` 这类工具读到。
- 流到一半被打断的推理不存，不完整的 blob 没用。

### 核心

自写，sans-I/O（2026-10-26 定）。2026-10 调研过 rig、yoagent、adk-rust、autoagents、swiftide-agents、aisdk、genai，以及 pi-agent（第三方的 Rust 移植，官方仓库里没有这份代码）。它们的共同问题是自带 provider 层或 session 层，和我们自己的协议适配、ledger 冲突；体量也远大于我们要用的部分：rig-core 加 rig-agent 约 13 万行，yoagent 约 3.9 万行。自写预计 1.2k–1.5k 行，包含两种协议的适配。借鉴两处：rig-agent 的 `AgentRun`，把 loop 写成 sans-I/O 状态机；pi 和 yoagent 的 steer 语义。

核心是纯状态机：方法都是同步的，每次调用是一次完整的状态转移；不 `await`、不 spawn、不读时钟、不碰网络。草图，签名 **待定**：

```rust
struct Run {
    spec: RunSpec,            // 不变：模型档、窗口、输出上限、这个 turn 能用的 Max 工具
    base: Context,            // 不变：基础上下文的条目和名册，第一批输入在它的易变块里
    transcript: Vec<Item>,    // 本 turn 产生的条目，只追加
    pending: Vec<Input>,      // 攒下的消息和 Wake，下一次调模型时渲染成一个 [新消息] 块
    phase: Phase,             // 在哪个阶段，阶段自己的数据在阶段里，见下
    measured: Option<(u32, usize)>, // provider 报的上一次请求加输出的 token 数，以及它覆盖到 transcript 的哪里
    unhandled: Vec<Wake>,     // 上次空闲以来的 Wake，第一批的也算：模型还没处理完的
    roster: BTreeSet<PrincipalId>, // base 的名册，加上之后给模型看过的新人
    // 以及 round
}

// 2026-10-29 改：原来是 in_flight、due、outstanding、model_due、ended 五个字段一起表示阶段，
// 合法的组合靠人维护（owner 指出）；现在一个枚举，非法组合写不出来
enum Phase {
    ModelDue,                 // 下一步调模型：开始时、工具结果回齐后、调用被打断后、有格式不对的调用、来了触发
    Calling,                  // 模型调用在途
    ToolsDue(Vec<Call>),      // 上一次输出里格式正确、还没开始的工具调用
    Running(Vec<CallId>),     // 工具批次在途：还没回结果的，不为空
    Waiting,                  // 没有在途的，也没有该做的：现在结束不丢东西
    Interrupted,
    Failed(FailReason),
}

enum Step {
    CallModel(Request),       // 请求由核心完整构造，之后不再改动：条目、两个工具、输出上限、名册
    RunTools(Vec<Call>),      // 已经解析成 run_code 或 shell 的调用
    Idle,                     // 没有在途的，也没有该做的；等还是结束由 actor 定
}

impl Run {
    fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self;
    fn record(&self) -> RunRecord<'_>;              // 借着核心的数据序列化，不复制
    fn busy(&self) -> bool;                         // 有模型调用或工具在途；actor 只在它为假时问 next_step
    fn next_step(&mut self) -> Step;                // 开始调用或批次，阶段跟着变
    fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected>;
    fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected>;
    fn tool_result(&mut self, call: CallId, out: ToolOutput) -> Result<(), Rejected>;
    fn input(&mut self, input: Input) -> Result<(), Rejected>; // 只收 Messages 和 Wake，随时可塞，核心决定何时生效
    fn interrupt(&mut self) -> Result<(), Rejected>; // 谁 /kill 的记在日志里
    fn fail(&mut self, reason: FailReason) -> Result<(), Rejected>;
    fn at_limit(&self) -> bool;                     // transcript 加上攒着的输入超过上限，actor 在边界上结束核心
    fn unhandled(&self) -> Vec<Wake>;               // 没处理完的触发，失败或中断时找要回一句话的那条
    fn idle(&self) -> bool;                         // 没有在途的、没有该做的：现在结束不丢东西
    fn outcome(&self) -> Outcome;                   // 结束时由 actor 读取
}
```

- 和状态对不上的（没有模型调用在途时来的 `ModelOutput`、不认识的调用的结果、结束之后的任何输入）返回 `Rejected`，什么都不改。
- 模型调用在途时到的消息不属于这次请求，等下一次（2026-10-28 定）。原来为了重放分得清，开始调用和工具批次各记一条输入；不重放以后（10-29）就只是 `next_step` 里的阶段转移。

核心负责的规则：

- **构造请求**：请求由基础上下文、transcript 和固定的两个工具组成，不裁剪（2026-10-28 定）。单条输入和工具结果各有上限（见[后续输入](#后续输入)），整体大小由下面的上限控制，撞上限就结束这次运行，请求不会超出窗口。唯一的例外是图片，超出视觉预算时省略较早的，见[多模态结果](#多模态结果)。
- **工具**：`run_code` 和 `shell`，固定不变。程序能调哪些 Max 工具由 spec 定，整个 turn 不变，加载 skill 也不改变它，见[纯 codemode](#纯-codemode)。格式不对的调用直接回错误结果，不交给 actor 执行。
- **token 数是数据**（2026-10-28 定）：核心不估算 token。基础上下文、每条输入、每个工具结果，都带着 `max` 估算好的 token 数进来；模型输出用 provider 返回的用量。算大小时以上一次请求 provider 报的输入 token 为准，再加上之后新增的条目，估算误差只落在这段增量上。数随条目存进快照。provider 没报用量（输入是 0）时不当成实测，接着用前一次实测或估算累加（2026-10-30 改，review 发现：原来会把之前的全部当成 0，核心永远撞不到上限）。
- **轮数和 token 上限**（2026-10-28 改）：

  ```
  可用     = C − 输出预留 − 余量
  核心上限 = min(可用 − 基础上下文, C / 2)
  ```

  C 是模型窗口；输出预留是模型配置的 `max_output`，没配就取 C / 8（Haskell 版的做法）；余量吸收估算误差，提议 C 的 5%。transcript 加上攒着的输入超过核心上限后 `at_limit` 为真，actor 在下一个边界结束这次运行：核心空闲就算正常结束；否则记 `Failed(ContextExhausted)`，没处理完的直接触发回一句话（2026-10-29 改，原来是把没处理完的触发交给一个新核心，见[运行流程](#运行流程)第 4 步）。基础上下文本身就占满了可用空间时，上限是 0，同样算撞上限。上限把攒着的输入算进去，所以请求不会被撑爆。例子：400k 窗口、`max_output` 128k 的模型，可用约 252k，基础上下文 100k 时核心上限 152k；只按 C / 2 算会给到 200k，请求就会超出 provider 允许的 272k 输入。
- **处理完的定义**：模型看到一个输入之后，走到一次不调工具的输出、核心变空闲，这个输入就处理完了，回没回话都算。标记在核心变空闲的那一刻打，不等 actor 下一次问 `next_step`。`unhandled` 返回第一批和之后交进来的输入里还没处理完的触发（`Wake`，以后还有 job 结果、自动化）；消息不取，它们在 ledger 里。核心失败或被中断时，actor 用它找出要回一句话的直接触发，见[群里看到的](#群里看到的)。
- **输入的时机**：等这一批工具结果都回来之后、下一次调模型之前。一批输入里有触发（`Wake`、job 结果、自动化）才会引起调模型。消息本身不是触发，什么时候叫醒由 [intent](#intent) 定；只有消息就留着，到下一次调模型时一起进去。
- **中断**：给还没回结果的工具调用补一条"已取消"的结果，保证历史合法。Responses 要求每个 `function_call` 都有对应的 output。
- **空闲判断**：模型这一轮只输出文本、没有工具调用，攒着的输入里又没有触发，`next_step` 就返回 `Idle`。结束由 actor 定：空闲窗口到期、撞上限、`/kill`、失败、重启。整次运行没发过话，结局就是 `Silent`；发没发过话用分段器看模型写的文本，切出消息就算。

### I/O 任务和协议适配

会话 actor 把核心要做的 I/O spawn 成任务，挂在这个核心的 `io` scope 里，结果作为事件回到 actor 的信箱（2026-10-28 定，见[会话 actor](#会话-actor)）。任务之间、任务和 actor 之间不共享可变状态。

- **模型调用**：一次 `CallModel` 一个任务。它持有模型客户端和分段器：把请求交给协议适配层降级成线上格式，发出去、读流；流式文本切出一段就发 `Said`，流结束发 `ModelDone`。可重试的错误在任务里重试，前提是还没发过 `Said`；发过就不重试，直接报错，已入账的文本由 actor 记成 `partial_output`（2026-10-28 定）。否则重试会把发过的段落从头再发一遍，晚间丢包时最容易碰上。流里一出现 `run_code` 或 `shell` 调用，就通知 VM 服务启动群 VM。
- **`run_code`、`shell`**：一个调用一个任务，在群 VM 里跑，结束发 `ToolDone`。同一批的几个并发跑，先跑完的先喂给核心。
- **intent 分类**：挂在 `side` 里，结束发 `Verdict`，见 [intent](#intent)。
- **回执**：每个任务拿着一个回执（`Report`），正常结束时用它发结束事件；被 abort 或 panic 时，它在 `Drop` 里补发一条"没有结果"。所以每个任务恰好一个结束事件，和 `Said` 走同一个信箱，排在它们后面。
- **过期事件**：每个任务有一个会话内递增、不复用的编号，事件都带着它。不是当前核心在途的任务发来的（核心结束之后才到的）直接丢掉。

协议适配层是无状态的，两次调用之间什么也不保留。降级只删条目或调整形状，不添加内容：

- `source` 和当前模型对不上的 `opaque` 直接丢掉。turn 内的模型由 spec 固定，正常情况下总能对上，这条只是兜底。
- **Responses**：本 turn 内的推理条目全部回传。
- **Chat**：同一轮的几个条目拼回一条 assistant 消息；`reasoning_content` 在本 turn 的工具调用循环里回传。
- 工具结果里的图片和视频怎么降级，见[多模态结果](#多模态结果)。

### 会话 actor

会话 actor 是一个会话唯一的控制线程：既是[时间线](#时间线)唯一的写者，也是核心的驱动者。2026-10-26 定为普通 async 代码、状态不持久化；10-27 改成单一核心实例，一个会话同一时刻至多一个核心，没有请求队列；10-28 改成由 actor 直接驱动核心。

核心是 actor 的一个字段。模型调用、工具调用、intent 分类都 spawn 成 I/O 任务（见 [I/O 任务和协议适配](#io-任务和协议适配)），结果作为事件回到同一个信箱。actor 自己只 await 数据库，从不等模型、工具和网络，所以 `/kill` 总能立刻处理。一个会话只有这一个控制线程，也就没有两份状态要互相对齐。

```rust
struct Conversation {
    head: MessageId,           // 见“时间线”
    seen: MessageId,
    core: Option<Active>,
    intent: Intent,            // 纯状态机，见“intent”：hold、攒着的消息、在途的分类、计数
    side: Scope,               // intent 分类
    stopping: Option<Instant>, // 停止宽限期的到期时间
    // 共享的句柄：数据库、sender、会话表、模型；自己信箱的发送端，交给 I/O 任务
}

struct Active {
    turn: TurnId,
    run: Run,                  // 核心，接口见“核心”
    from: MessageId,           // 快照位置
    io: Scope,                 // 在途的模型调用和工具调用
    live: HashSet<TaskId>,     // 在途任务的编号；不在这里的事件都过期了
    said: String,              // 这次模型调用已经入账的文本，被打断时就是 partial_output
    idle_since: Instant,       // 上一次模型输出结束的时刻，空闲窗口从这里算
    started: Instant,          // 给 /status 看
}

enum Event {
    Inbound(Inbound),                                  // 平台连接，经会话表
    Bound(Inbound),                                    // 刚绑上这个群的 `/bind <码>`，见“QQ 官方机器人”
    Said { task: TaskId, segment: Segment },           // 模型调用任务里的分段器切出一段
    ModelDone { task: TaskId, out: Result<ModelOutput, String> },
    ToolDone { task: TaskId, call: CallId, out: ToolOutput },
    Verdict(Option<Verdict>),                          // 在途那一批的判定，失败是 None
    Stop,                                              // 正常重启
    // 以后：Post（别的会话、MCP 工具、调度器要往这里发，带来源 turn），JobDone、Fire
}

impl Conversation {
    async fn run(mut self, mut mailbox: UnboundedReceiver<Event>) -> Result<()> {
        loop {
            let deadline = self.deadline(); // 空闲窗口、去抖、停止宽限期里最早的
            tokio::select! {
                event = mailbox.recv() => match event {
                    Some(event) => self.handle(event).await?, // 只 await 数据库
                    None => self.stop(),
                },
                () = sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    self.timer().await?;
                }
            }
            self.advance().await?;
            if self.stopping.is_some() && self.core.is_none() {
                return Ok(());
            }
        }
    }

    /// 每个事件之后调一次：核心没有在途的 I/O 时，决定下一步
    async fn advance(&mut self) -> Result<()> {
        let Some(a) = self.core.as_mut() else { return Ok(()) };
        if a.run.busy() {
            return Ok(()); // 等在途任务的事件
        }
        if self.stopping.is_some() && a.run.idle() {
            return self.end(End::Idle).await; // 正在停：手上没事的核心直接结束，不等空闲窗口
        }
        if a.run.at_limit() {
            // 撞上限就认输；下一个触发从 ledger 重新投影，起新核心
            let how = if a.run.idle() { End::Idle } else { End::Failed(FailReason::ContextExhausted) };
            return self.end(how).await;
        }
        match a.run.next_step() {
            Step::CallModel(req) => {
                self.seen = self.head; // 请求带上了攒着的全部输入，正好是 ..=head
                a.spawn_model(req);
            }
            Step::RunTools(calls) => {
                for call in calls {
                    a.spawn_tool(call);
                }
            }
            Step::Idle => {} // deadline() 从 idle_since 算空闲窗口
        }
        Ok(())
    }
}
```

`handle` 依次做两件事，第三件是上面的 `advance`：

1. **入账**：平台来的消息和事件、`Post`、Max 说出口的一段，先在一个事务里入账，`head` 前进，再发入账通知给[派生数据 worker](#三种角色)。`Said` 入账后交给平台 sender，不等回执，见[出站](#出站)。
2. **路由**：
   - 命令：一律由 actor 自己处理，从不进核心（2026-10-28 定）。所以 `/model` 不会变成模型的输入，`/kill` 也不用排在工具批次后面。命令消息本身照样入账，下一个核心的尾巴里看得到。intent 也看得到它。
   - 有核心：喂给它；本 turn 自己说的话和做的动作除外，它们已经在 transcript 里。经工具做的动作靠 `Post` 的 `origin` 认出来，见[出站](#出站)。job 结果、自动化也一样。
   - [intent](#intent)：每条入账都交给 `intent.observe`，判定交给 `intent.verdict`，到期时间到了调 `intent.tick`。返回的 `Wake` 先过 `seen`，涉及的消息都不超过 `seen` 就丢掉；否则有核心就喂一个 `Input::Wake`，没有就起一个（[运行流程](#运行流程)第 3 步）。`Classify` 在 `side` 里 spawn 小模型。没有核心也没有 `Wake` 时什么都不做，消息在时间线上，下一个核心的基础上下文里有。
   - `ModelDone`、`ToolDone` 喂给核心；任务编号不在 `live` 里的丢掉。

`Stop` 只记下停止宽限期的到期时间（20 秒），核心照常往下跑。到期时间到了：停止宽限期到期就 `end(End::Stopped)`，空闲窗口到期就 `end(End::Idle)`，见[取消](#取消)；去抖到期由 `intent.tick` 处理。

另外两条：

- 信箱是无界的。往信箱里写的有共享的平台连接和别的 actor：在有界信箱上等，一个卡住的会话会拖住所有会话，两个会话互相 `Post` 还会死锁。actor 自己也从不在有界通道上 await。
- 核心结束不需要交接通道。结束之后入账的东西由 actor 直接处理，有触发就起下一个核心，和"没有核心时来了触发"是同一个函数。

这样多人同时 @ 由模型在同一批输入里一起回应，不会答两遍；也没有排队顺序、每人上限、过期、"反馈还是新请求"这些问题。Claude Code 的对应关系：群里的新消息是 steer，job 结果是后台任务完成通知，自动化是定时触发。重启会丢掉这些：

- 正在跑的核心：正常重启时给一段宽限期，到期中断；崩溃时直接丢。见[重启](#重启)。
- 后台 job。pi 的会话文件还留在 VM 里，但不会自动接上。
- intent 的全部状态：每小时的计数清零，等着分类的闲聊不再分类；还在去抖的直接触发丢掉，没人回（2026-10-28 接受）。

### 运行流程

每一步都是会话 actor 处理一个事件。

1. **消息进来**：平台连接把消息或事件归一化成 `Inbound`，经会话表交给会话 actor；actor 在一个事务里把它转换成 `Message` 入账。平台连接不碰数据库。
   - 群白名单（2026-10-28 定）在会话表这一步拦：没用 `/bind` 绑定的 QQ 群（见 [QQ 官方机器人](#qq-官方机器人)）直接丢掉，不建会话、不起 actor、不入账，只记 debug 日志。命令和 owner 的消息也一样丢，只有 `/bind <码>` 例外。别的会话或工具往没绑定的群发 `Post`，也在这里拒掉，带回信通道的回一个错误。私聊不过这一道，见第 2 步。
2. **判定**（2026-10-28 改）：每条入账都交给 [intent](#intent)，由它决定什么时候叫醒核心：@、回复 Max 立刻叫醒，看起来没说完的先等几秒；其它消息由小模型判。job 结果和自动化不经过 intent，本身就是触发。触发源见[三种角色](#三种角色)。命令由 actor 自己处理，见[会话 actor](#会话-actor)。
   - 有核心在跑：消息照样立刻喂给它，但只有触发才让它调模型。
   - 没有核心：来了触发就进第 3 步；否则什么都不做。
   - 私聊（2026-10-28 定）：私聊里的消息都算直接触发，等同群里的 @。QQ 上能私聊 Max 的只有管理端里加的体验用户，这份名单就是私聊白名单，见 [QQ 官方机器人](#qq-官方机器人)。以后接的平台要是谁都能私聊，再加一份白名单，为空就是谁都不服务，和 Haskell 版"为空就全服务"相反。
3. **开始 turn**：快照位置 `from = head`。从 ledger（只读 `id <= from`）加上记忆，投影出基础上下文，裁到预算内，见[上下文投影](#上下文投影)；第一批输入在易变块里：叫醒它的触发，`Wake` 带着它涉及的消息（去抖时是同一个人的几条）。其它消息都在尾巴里。写 `TurnStarted`（带 trigger 和 `from`），调 `Run::new(spec, base, first)`。第一批就超过核心的上限（见[核心](#核心)的"轮数和 token 上限"），核心一起来就撞上限，记 `Failed(ContextExhausted)`，引用触发回一句（2026-10-29 改，原来是不起核心，单独记 `InputTooLarge`）。
4. **推进**：actor 每处理完一个事件，核心没有在途的 I/O，就问 `next_step`。中途不写 turn 记录：
   - `CallModel`：`seen = head`，spawn 模型调用任务。每个 `Said` 入账、交给 sender；`ModelDone` 时调 `model_output`。攒着的输入渲染成一个 `[新消息]` 块追加在请求末尾，见[后续输入](#后续输入)。
   - `RunTools`：这一批工具调用各 spawn 一个任务，在群 VM 里并发跑，每个 `ToolDone` 调一次 `tool_result`。
   - `Idle`：什么都不做，之后入账的照样喂进去；只有闲聊的话 `next_step` 还是 `Idle`，窗口不重置。上一次模型输出结束后空闲满一个窗口（provider 的 `idle_window_secs`，默认 300 秒，2026-10-27 定）就结束。窗口内来了触发，模型还带着刚才的工具结果，追问不用重查。到期和触发同时到时，actor 总有一个先处理：先到期就结束，那条触发接着起新核心；先来触发就接着跑。两种结果都对。
   - **撞上限**：核心 `at_limit`，就在这个边界结束：空闲就算正常结束，否则记 `Failed(ContextExhausted)`，没处理完的直接触发回一句话（2026-10-29 改）。下一个触发照常从 ledger 重新投影、起新核心，这就是我们的 compaction：不压 transcript，重新投影。

     原来（10-27 定）是在这里换核心：没处理完的触发交给新核心，带一行交接说明，列出旧核心做过的有副作用的调用，免得再做一遍；每个触发最多交接一次；还有 30 分钟的墙钟。撞上限几乎不会发生，认输的代价只是让人再问一次，这些机制不值得（2026-10-29 删）。
   - **失败**：`ModelDone` 带着错误。这次调用已经入账的文本记成 `partial_output`，调 `fail`，写快照和结局。
5. **取消（`/kill`）**：见[取消](#取消)。攒着的输入作废。
6. **正常重启和启动**：见[重启](#重启)。

### 群里看到的

2026-10-28 改：处理中不显示任何状态。Haskell 版给触发消息挂托腮、失败时换成裂开，QQ 官方接口没有 reaction。

- turn 失败或被重启中断时，还没处理完（见[核心](#核心)的"处理完的定义"）的直接触发里最新的一条，引用它回一句简短的话。没有挂表情可换，不回的话 @ 了 Max 的人什么也看不到。判定叫醒的不回：Max 本来就可以不接话。三种说法：
  - provider 出错："出错了，这条没回上。"
  - `ContextExhausted`："要读的东西太多，读不完，这条没回上。"换个说法、少贴点东西重发就能解决。
  - 重启："我要重启一下，这条没回上，等会儿再问一次吧。"
- `/kill` 不回，是有人主动停的。
- 这句话照常入账，是 Max 说的话，不进核心。

### 取消

`/kill` 就是 actor 处理的一个事件，不需要单独的信号，也不用在 `select!` 里等：`seen = head`，有核心就 `end(End::Kill)`。核心的其它结束方式走同一个函数，区别只在中间一步：

```rust
enum End {
    Kill(String), // /kill
    Failed(FailReason),
    Idle,         // 空闲：窗口到期，或者 Max 在停
    Stopped,      // Max 在停，宽限期到了还没空闲
}

async fn end(&mut self, how: End) -> Result<()> {
    let Some(mut a) = self.core.take() else { return Ok(()) };
    drop(a.io); // abort 在途的模型流和工具调用：同步发起，不等
    if !a.said.is_empty() {
        a.run.partial_output(a.said.join("\n\n"), tokens); // 被打断的那次模型调用已经入账的文本
    }
    match &how {
        End::Kill(reason) => a.run.interrupt(reason.clone()), // 给没回结果的工具调用补“已取消”
        End::Stopped => a.run.interrupt("Max 在重启".into()),
        End::Failed(reason) => a.run.fail(reason.clone()),
        End::Idle => Ok(()),
    };
    turns::finish(&mut conn, a.turn, &a.run.record(), &a.run.outcome(), now).await?; // 快照加结局，一个事务
    self.report_unanswered(&a.run, &how).await // 没处理完的直接触发回一句话，见“群里看到的”
}
```

- `io` 里的任务已经发出、还没处理的事件，任务编号不在 `live` 里了，到了就丢掉。"说出口"以入账为准：已经进了信箱、还没入账的 `Said` 被丢掉，就算没说，sender 也从没拿到过它。
- 空闲窗口到期和撞上限都发生在边界上，没有在途的 I/O，`drop(a.io)` 什么都不做。
- 写 turn 记录这一步要 await 数据库，期间来的事件在信箱里排着，写完再处理。

只靠 drop 不够、需要多做一步的地方：

- **每个拥有 scope 的任务的最外层**：一处 `run_until_cancelled` 或 `select!`。会话 actor 的就是它的主循环。
- **有外部副作用、drop 不会自动停下的**：比如 VM 里的命令、pi 进程。生命周期绑在连接上，`Drop` 里只同步发起，见[资源怎么结束](#资源怎么结束)。
- **不能只做一半的**：发消息先入账再交给平台 sender；数据库写入用事务，sqlx 的事务没提交就被 drop 会回滚。其余见 [cancellation safety](#cancellation-safety)。
- **没有 `await` 点的长时间 CPU 计算**：drop 不掉。放进 scope 的 `spawn_blocking`，配一个取消标志。

### 重启

2026-10-29 定：正常重启时，正在跑的 turn 给一段宽限期，到期就中断，不再挂起、重启后接着跑。Haskell 版也是重启中断 turn。

原来（10-26 定，10-28 进 v1）是在下一个边界挂起、存快照，重启后在窗口内 `resume`，给没跑完的工具补"进程重启，结果未知"接着跑。为此要有 attempt、一个 turn 多份快照、`TurnResumed`、`Expired`、恢复时重新校验权限。部署时正好有 turn 在跑的情况不多，被中断的人再问一次就行，不值得。

- **正常重启（部署、SIGTERM）**：会话 actor 收到停止事件，记下宽限期的到期时间（20 秒）。核心空闲就直接结束，不等空闲窗口。不空闲就让它接着跑，模型调用、工具批次和之后的模型调用都照常；宽限期内变空闲就正常结束。到期还没空闲就 `End::Stopped`（见[取消](#取消)）：
  - 关掉 `io`，已经入账的文本记成 `PartialOutput`；
  - 同一批里已经跑完的工具照常记结果，没跑完的补"已取消"；
  - 结局是 `Interrupted`，快照和结局一起写；
  - 还没处理完的直接触发，引用它回"我要重启一下，这条没回上，等会儿再问一次吧。"，这句照常交给 sender，关机时 sender 排空了才退出。
- **崩溃**：什么都不写。
- **会话 actor 出错**（2026-10-30 加）：actor 处理事件时出错（多半是库的错），就放弃这个会话。核心和 job 都停掉；这个会话没有结局的 turn 记 `Lost`，跟崩溃一样，免得它们看着还在跑；没处理完的直接触发回一句"出错了，这条没回上。"，停掉的 job 也说一句。库连不上就只记日志，这些 turn 留给下次启动去记。之后会话表收到这个会话的下一条消息时重新起 actor；actor 退出前那一刻进来的消息跟着丢掉。不按事件隔离错误、让 actor 接着跑，因为出错以后，内存里的 `head`、`seen` 不一定和库一致。

启动时，每个没有结局的 turn 都记 `Lost`：正常重启不会留下没有结局的 turn，剩下的只能是崩溃时正在跑的。它已经发出去的消息还在 ledger 里，靠 turn id 能找到。每个会话的 `seen` 从当时的 `head` 开始，intent 的状态从空开始。

QQ 的网关跨重启 Resume：重启那段时间群里说的话由服务端补发，照常入账、照常经过 intent，所以停机期间 @ Max 的人照样有人回，见 [QQ 官方机器人](#qq-官方机器人)。要再问一次的只有停机那一刻正在回的那条。

崩溃时丢掉的 turn 要不要在群里说一声 **待定**：可以在启动后根据 `Lost` 补发。

### 体积和保留期

- **体积**：推理 blob 每条几 KB 到几十 KB，而且压不小；一个 turn 跑几十轮，大约几百 KB 到几 MB，核心上限给它封了顶。v1 都存在快照的 JSONB 里，交给 Postgres 的 TOAST。以后体积成问题，再把超过阈值的内容统一挪到一张按 sha256 寻址的 blob 表，工具输出和基础上下文同样适用。
- **保留期**：turn 结束 N 天后，清掉快照里的 `opaque` 和基础上下文，保留可读文本和 token 数。之后这个 turn 还能查看，但不能再原样重发它的请求。N **待定**。

### 核心和 actor 的测试

- 核心和 intent 用同步单元测试，按剧本喂输入、检查输出，不需要 tokio 和 fake provider；intent 的时间由测试传入。intent 至少覆盖：直接触发立刻叫醒、去抖合并同一个人的几条、攒批、每小时上限和 `/proactive`。核心至少覆盖：输入的送达时机、只有闲聊不调模型、中断时补齐结果、格式不对的工具调用、轮数和 transcript 上限、失败时哪些触发算没处理完。
- 会话 actor 用真的数据库（`#[sqlx::test]`）、剧本模型和只记录的 sender，测取消、停止和它的宽限期、空闲窗口、撞上限、过期事件和 `seen` 对 `Wake` 的过滤；在任意两个事件之间插 `/kill` 的遍历见 [cancellation safety](#cancellation-safety)。2026-10-29 改：actor 测试用真实时间，不用 `start_paused`。actor 在等 Postgres 的时候，暂停的时钟会自动跳到下一个到期时间，空闲窗口和去抖就提前到了。所以测试里的等待都很短，而且有上限；纯时间的逻辑（intent、sender 的额度）照样用 `start_paused`。
- 协议适配层用录下来的 Responses 和 Chat 响应做 fixture，测推理条目和不透明字段原样往返。
- 快照里是每次请求的内容，线上任何一次模型调用都能离线原样重发。

### 同一模式的其它地方

判断标准：有协议状态、规则复杂、需要精确测试。符合的有：

- 流式分段器：喂入文本增量，吐出可以发送的段落。
- pi RPC 适配器：在途命令、`agent_settled` 的判定、`clear_queue` 和 `abort` 的顺序。
- QQ 网关的会话：心跳、Resume、重连。
- 镜像投递（v1 不做）：回执和 echo 对账。

会话 actor 是普通的 async 代码：规则都在核心和分段器里，它只负责入账、路由和按核心说的 spawn。

### 待定

- ~~基础上下文怎么存~~：已定（2026-10-27），存渲染结果，见[上下文投影](#上下文投影)。
- 保留期 N。
- 核心上限的余量（提议 C 的 5%）。
- ~~`/kill` 的权限~~：已定（2026-10-29），群主、管理员和 owner，见[权限](#权限)。
- ~~裁剪规则~~：已定（2026-10-28），不裁剪，见[核心](#核心)的"构造请求"。
- ~~恢复窗口多长~~：不恢复了（2026-10-29），见[重启](#重启)。崩溃时丢掉的 turn 和 job 要不要在群里说一声。

## 上下文投影

2026-10-27 定，10-30 改。起初参考 [magic-context](https://github.com/cortexkit/magic-context) 做了 historian 和会衰减的摘要，10-30 删了，当天晚上又做成按群的开关，见[摘要](#摘要)。关着的群只有原始尾巴，加上每轮都带的[记忆](#记忆)，更早的靠模型自己搜；开着的群尾巴前面还有摘要块。工具输出只活在一个 turn 的 transcript 里，下一个 turn 从 ledger 重新投影，不会跨 turn 堆积。

Haskell 版的教训：原始尾巴是按 token 的滑动窗口，填满后每来一条消息就从头挤掉一条；摘要层级每轮按距今天数重算；caption 到了回头改旧行。三件事都让前缀缓存几乎每轮失效。historian 按 token 切段、一段一个摘要，不按话题。"上一轮做了什么"有四套机制（`[recent turns]`、续接摘要、`context_resume`、turn 内压缩），同一行消息有三种 token 算法。

### 请求布局

按变化频率排，每一块都在前一块之后：

1. system：人设、规则、Max 工具的 TypeScript 声明、skill 索引。按会话固定。
2. 工具：`run_code` 和 `shell`，固定不变。
3. 摘要块：只有开了 historian 的群有。活跃摘要按时间顺序，每条按[衰减](#衰减)选一层渲染。
4. 原始尾巴：尾巴的标记之后、到快照位置 `from` 为止的所有消息（第一批里的除外），`[HH:MM 名字 #id]: 文本` 一行一条；换日插日期，间隔久了插间隔标记。Max 自己的消息和别人的一样是一行，发不出去的带标记，见[出站](#出站)。
5. 易变块：现在时间、[名册](#模型看到的)、[记忆](#记忆)、引用的消息和转发、第一批输入（触发；闲聊不在这里，在尾巴里）、附图。

基础上下文就是这几块，由会话 actor 在创建核心前投影一次（[运行流程](#运行流程)第 3 步），之后不变；transcript 接在后面。比尾巴早的原文不在上下文里，模型用 `history` 查，见[召回](#召回)。

### 后续输入

核心活着的时候，后来的输入在下一次调模型前渲染成一个 `[新消息]` 块，追加在 transcript 末尾，不动前缀：

- 消息行和尾巴同一种格式，触发的行标上"@你""回复你的 #123"，其它不标。第一次出现的人补一行名册。
- job 结果是 `[job#3 完成] …`，自动化是 `[自动化 m#2 触发] …`。
- **单条上限**（2026-10-27 定）：消息、job 结果、自动化结果共用一个上限，`min(C × 15%, 25k)` token，最低 2k；尾巴和第一批里的消息同样适用。超过的只渲染开头约 2,000 字，加一行"全文见 `#123`"，模型用 `history` 取（`{ around, before: 0, after: 0 }`；原来是读全文的 `context_read`，所以它是 v1 第一个开放的工具）。它按页取，一页不超过单条上限，读一条超长消息不会一下把核心撑到上限。原文本来就在 ledger 或 job 记录里，不另存。VM 起不来时没有工具，模型只能看到摘录。`run_code` 和 `shell` 的结果也按这个上限截，全文写成 VM 里的文件，结果里给路径，下一次调用自己读。现在两个都先按字节截：超过 16 KiB 只留头尾各 8 KiB，全文在 `/work/.max/out/<unit>.txt`；`run_code` 的 console 输出另外截，全文在 `<unit>.log`。
- 参考（2026-10-27 查）：Claude Code 的 Bash 输出约 3 万字符、Read 每次 2.5 万 token；Codex 的工具输出 1 万 token；OpenCode 和 pi 2,000 行或 50 KiB；Gemini CLI 4 万字符；Hermes 每条 10 万字符，按窗口缩到 15%。超出时它们都把全文留着，给模型路径或句柄。用户自己发的内容基本都不截。
- **放不下就认输**：不按条数折叠。攒着的输入连同 transcript 超过核心的上限，就在这个边界结束这次运行，记 `ContextExhausted`，见[核心](#核心)和[运行流程](#运行流程)。
- 系统提示里说清：一批里可能有几件要回应，也可能都不用，不用就什么都不输出；回应多个人时各自 reply。

### 前缀稳定的规则

目标：两次截断（开了 historian 的群：两次发布）之间，易变块之前的逐字节相同。

- **尾巴的起点只在截断时移动**（2026-10-28 定，10-30 改成自己记标记）。尾巴从 `conversations.tail_after` 之后开始（迁移 0018），和 `/clear --all` 的水位取大的；平时只增长。投影时尾巴超过高水位，就从标记往后按固定的长度（高水位减低水位）一段一段截，截到剩下低水位到高水位之间，把新标记写回去；不一条一条往外挤，否则又成了每来一条消息缓存就失效一次的滑动窗口。切点从标记往后数，不从末尾往前数，所以起点在新消息进来时不动。还没有标记的会话从第一行数起，部署后第一次投影要读一遍整个会话，只这一次。先截尾巴，再算引用的消息和名册，截掉的人不进名册，引用了截掉那段的行照常带上被引用的消息。
- **开了 historian 的群**：尾巴从最新一条活跃摘要之后开始，和标记、`/clear --all` 的水位取大的，所以起点也在 historian 发布时移动。尾巴由 historian 压着，超过高水位的两倍才截，那只在 historian 一直失败时发生。摘要的层级也只在发布时变：衰减的三个输入（序位、importance、预算压力）都只在发布时变，`/model` 换了窗口会重算一次。
- **不等 caption。** 有什么渲染什么；caption 到了那一行就变，接受这一次失效。不阻塞。Haskell 版会轮询等媒体 worker，图片最多 30 秒、视频 60 秒。
- **一个会话同时只有一个 turn**，不需要藏起在途的触发消息。
- 变的东西都在易变块里。

### 预算

默认值按窗口 C 推，封顶；配置可改，数值在 v1 里调：

| 块 | 默认 |
|---|---|
| 尾巴高水位 | `min(C / 8, 64k)`（2026-10-30 owner 从 32k 调到 128k：1M 的窗口上尾巴只有 16k–32k，约 270–540 条，比 Haskell 版短得多，群友觉得 Max 健忘。当天晚上降到 64k：128k 时输入翻倍，Max 说话风格也变了，见[摘要](#摘要)）。超过就截 |
| 尾巴低水位 | 高水位的一半。截完剩下低水位到高水位之间 |
| 摘要块 | `min(C / 32, 8k)`，只有开了 historian 的群有 |
| 记忆块 | 3k，见[记忆](#记忆) |

Haskell 版尾巴是 W/2，26 万的窗口上约 10 万 token 原始群聊，每轮都付。token 估算只有一个函数（tiktoken-rs，在 `max` 里），所有地方共用；核心只拿算好的数，见[核心](#核心)。

### 摘要

2026-10-27 照 magic-context 做了 historian 和三层摘要，2026-10-30 owner 定全部删掉，只靠原始尾巴、[记忆](#记忆)和[召回](#召回)。原因：

- **贵**：过去一天 historian 调了 49 次，输出 40.6 万 token，比所有 turn 的输出（30.4 万）还多，输出是最贵的部分。
- **二手的错**：摘要会记错，原话不会。10-30 Max 自己在群里说被一条摘要坑过：把"13 块搓完整个原型"记成了"修一轮 bug 花 13 块"。
- **复杂**：historian 的排程、校验、重试、discard-last，衰减曲线，水位和发布时机，`/compact`，摘要的向量和搜索，加起来三千多行。
- **方向**：模型够强时，原始记录加自己搜，比预先加工的好（MemoryTax，见[记忆](#记忆)）。摘要最有用的是"那几天聊过什么"这个索引，换成了 `history` 按时间读原文、按发言人筛。

删掉的：historian worker 和 `[llm] historian` 配置、摘要块和衰减、`/compact`、`context_search` 的摘要结果、`context_read` 的 `{ summary }`、摘要的向量。`summaries`、`summary_runs`、`summary_embeddings` 三张表和里面的数据留着。

当天晚上 owner 改了主意：删掉以后 Max 说话的风格变了，自动的 historian 其实也不差，想长期一个群开、一个群关地比。于是 historian、摘要块、衰减和 `/compact` 原样恢复，做成按群的开关 `/historian on|off`（只有 owner 能改，默认关；`conversation_settings.historian`，迁移 0021）：

- **开着**：historian 照下面写这个群的摘要，上下文里带摘要块，系统提示的上下文结构里多一行讲摘要块，尾巴从最新一条摘要之后开始，见[前缀稳定的规则](#前缀稳定的规则)。
- **关着**：historian 不碰这个群（capture 先查开关，关着什么都不做），上下文和关之前一样只有原始尾巴。以前写的摘要留在表里，再开时接着用：historian 从最新一条摘要之后接着写，中间没写的那段先由它补上，补上之前那段不在上下文里，`history` 查得到。
- **不恢复的**：摘要的向量和搜索。`history` 只查消息，摘要不进召回；`summary_embeddings` 照旧不读不写。
- `[llm] historian` 不配就没有 historian，`/historian on` 回"没有配置摘要模型"。私聊不写摘要。

#### historian

- **一个[派生数据 worker](#三种角色)**（2026-10-27 定）：和会话 actor 没有共享状态。它的邮箱收每一行入账（只看群）和 `/compact`（带回信通道），token 数在 capture 时从库里算：读未覆盖的行，用和投影同一个渲染函数和估算函数。排程是它自己的一个结构，只看收到了什么和现在几点，不做 I/O：群里入账一行，从这个群的第一行算起一分钟后做一次压力检查；从最后一行算起十分钟后写安静摘要；`/compact` 最先，不占并发数。同一个群一次只跑一个 capture。检查同时最多 2 个，一次最多 11 分钟（两次模型调用各 5 分钟，加读和发布）。失败了这个群的这一种检查歇 10 分钟再试一次，再失败就放弃，等下一行入账；`/compact` 失败直接回错。`summaries` 只有它一个写者。正在跑的 turn 从 `turns` 表查，不问会话 actor。
- **水位按会话的主模型算**，和投影用的窗口一样。
- **触发**：安静（10 分钟没入账，可压的部分至少是低水位的一半；一段安静只看一次）；压力（入账后一分钟查一次，未覆盖的超过高水位就压）；`/compact`。启动不扫。
- **范围**：从 cursor 往后，留出低水位的尾巴，一次最多 24k token，更长的分几次。cursor 是最新一条活跃摘要的 `last_message_id`，和 `/clear --all` 的水位取大的；每次 capture 先把水位之前还没写的那段写完，所以摘要一直连着，`/unclear` 以后没有缺口。不含正在跑的 turn 的触发消息及其之后的。`/compact` 不留尾巴。
- **输入**：现在的时间；最近 4 条摘要的 p2；这一段里的人，Max 标成"就是 Max"；这一段消息（和投影一样的行）。historian 不管记忆，见[记忆](#记忆)。
- **输出和校验**：JSON，`compartments[{first, last, title, kind, importance, p1, p2, p3}]`，边界由模型定。按行序一段接一段、不重叠、合起来覆盖整段；kind 在六种里；importance 1 到 100；长度有上限，超了算错。失败重试一次：答错了把答案和错在哪里一起给回去。
- **discard-last**：安静触发时至少两段就丢掉最后一段，下次连着后文重读。
- **发布**：一个事务写 `summaries` 和 `summary_runs`；每次模型调用都记 `summary_runs`，失败的也记；用量记在 `llm_usage`，purpose 是 historian。发布不影响正在跑的 turn；下一个 turn 投影时读到新摘要。

#### 衰减

三层：p1 全文、p2 简述、p3 一行，写一次不再改。渲染时每条选一层，用 magic-context 的曲线：

```
H = 24 · 2^((importance − 50) / 25) / max(p, 0.1)
z = 序位 / H          序位从最新数起，最新是 0
z < Z1 → p1；z < Z2 → p2；z < Z3 → p3；否则归档
```

`p` 是预算压力：按压力 1 算出的总成本除以摘要块预算。成本用每条摘要各层实际的 token 数。Z1 = 0.201、Z2 = 0.729，归档 2.587。归档的不渲染。缺层的向上取最近的一层。

渲染：摘要块以 `[早先的聊天，摘要]` 开头，每条一个头 `[summary#45 2026-10-03 周六 14:02–16:30]`。p1、p2 在头后面接标题，下一行是正文；p3 只有头和那一行。摘要里的 `[mention#N]` 进名册。

### 命令

- `/clear --all`：只是消息 id 水位，之前的消息不进提示；`history` 照样查得到，见[召回](#召回)。回复里带上怎么恢复。
- `/unclear`（2026-10-29 owner 要的，群主、管理员）：撤掉水位，之前的消息回到上下文，最远到尾巴的标记。只有一个水位，清过几次也一次撤完；没清过回"跳过：没有清空过"。开了 historian 的群，之前的摘要也回来；historian 先把水位之前写完才写水位之后的，所以只有那一步失败过时，清空时的尾巴才会夹在两段摘要中间、不回上下文，回复里说明这一点。
- `/historian`（2026-10-30 加，只有 owner 能改，谁都能看）：`on`、`off`、`default`（关）。从下一个核心起生效。`/status` 里也有一行。
- `/compact`（群主、管理员）：只在开了 historian 的群，立即 capture 到当前，尾巴留 0。会话 actor 不等 historian，拿到结果后回一句；一次最多 24k token。没开的回"这个群没开摘要"。

### 记忆

2026-10-30 定，owner 提出：记忆是 Max 自己写的一个文件，不是 historian 抽出来的条目。

- **为什么**：
  - Haskell 版的记忆是 historian 预先抽的条目。733 条里 85% 是自动写的；标成群规的大半是技术知识，该常驻的反而没记，比如群友对 Max 的称呼。101 条有日期的承诺里 88 条过期了没人管。注入按"最近改过的 12 条"挑，和重要不重要无关。
  - maxx 上线时没有记忆。10-30 群友叫"小鲨鲨"，Max 不认得；被说了"不记得了"才去搜，一搜就找到了。
  - [MemoryTax](https://arxiv.org/html/2610.29823)（2026-10）：模型够强时，留着原始记录让模型自己搜，比预先抽取的记忆（Mem0、Zep）好、也更省。原始记录和搜索我们已经有了（ledger、`history`）。但那篇的问题都在提示"去查"，群聊里要用记忆的时候往往没人提示，模型不知道自己忘了什么。所以还要一份每轮都带上的东西，由主模型自己判断记什么，照 Claude Code 的 auto memory 做。
- **文件**：每个会话一个 `/work/.max/memory.md`，在会话 VM 的 `/work` 里，宿主上是 `<vm.dir>/<会话 id>/work/.max/memory.md`。Max 用 shell 改；没配 VM 就没有记忆，VM 起不来时只能读不能写。
- **注入**：起核心投影时，宿主像 `send_image` 那样不跟符号链接地读这个文件，放进易变块的 `[记忆]`，在名册之后。不放 system，原因有三：改了不会让前面的缓存失效；群友能影响它写什么，不该当系统指令；靠后，模型更容易注意到。代价是每个 turn 多付最多 3k 不走缓存的 token。turn 里改的，下一个 turn 才看到；本 turn 改了什么，transcript 里本来就有。
- **上限** 3000 token（`max_core::project::MEMORY`）：
  - 到 80% 在末尾加一句，提醒整理；
  - 超了只注入放得下的那些行，说明后面的没加载、要整理；
  - 文件超过 256 KiB 整个不读，只说一句。

  和 Claude Code 对 MEMORY.md 的做法一样：它是 200 行或 25 KB，超了截掉、提醒重写。只是它在写的时候查，我们在下一次投影时查，因为文件是在 VM 里写的，宿主看不到这一次写入。
- **怎么写**，在系统提示里：
  - 记长期成立、影响以后怎么说话做事的：称呼、约定和梗；某个人的身份、长期在做的事、偏好；有日期的安排，写明到哪天。
  - 什么时候当场记，列成具体的几种：被纠正、有人让记、起了称呼、定了规矩；发现自己忘了或认错了人；有人说起自己的身份、近况、喜好。
  - 加一条就 `echo '- 名字：内容（日期 #消息编号）' >> memory.md` 追加到末尾，归节交给 dreamer；记不用让人等：回复和记的 shell 写在同一次输出里，回复先发出去，记完只写 `[silence]`。（10-30 加，owner 提出。上线当天 90 个 turn 里 Max 只写过 1 次：原来要它按节、按人插进文件中间，用 shell 很费事；"每多跑一次 run_code 群友就多等一轮"也会让它不愿多调一次工具。）
  - 不记技术知识，也不记哪天聊了什么：那些在记录里，靠搜索。
  - 格式：分「## 群里」「## 人」两节，人按「### 名字」分，一行一条。结尾写（日期 #消息编号），编号是能作证的原话，`history` 能查（owner 加的）。
  - 细节放进 `/work/.max/memory/` 下的别的文件，这里留一行指过去。
  - 有人让记的不一定对，Max 自己判断。
- **整理：dreamer**（2026-10-30 加，owner 提出：模型只会往里加，不整理）：
  - 每天本地 5 点跑一次。只看这一天里 Max 写过的文件（看文件的修改时间），一个文件调一次模型（`[llm] dreamer`，不配就不整理），让它整体重写：Max 追加在末尾的行归进该去的节，说同一件事的合成一条，矛盾的留新的，写明到哪天、已经过了的删掉，超了上限删最不要紧的；不改写意思、不新增。
  - 写回前再读一次，Max 刚好改过就不写，留到下一晚。写回的文件保留 Max 写它的时间，所以第二晚不会再整理一遍；整理前的版本留在旁边的 `memory.prev.md`，坏了能拿回来。模型写出来的不像这份文件（没有标题，或者比原来短了三分之二以上）就不写，记一条日志。
  - 不另做机制：不重试，错过的一晚由下一次 Max 改文件后补上。用量记在 `llm_usage`，purpose 是 `dreamer`。
- **没有的**：记忆表、分类、到期、historian 的记忆提案、注入时的挑选。`history` 不搜记忆，它每轮都在上下文里。
- **迁移**（10-30）：旧库的记忆由一个子 agent 手工离线迁成每个群的初始文件，没用的全删。同一天又从旧摘要里迁了一批长期成立的事（梗、称呼、群规、人），摘要删掉后 Max 对群里的老梗接不上。

### 召回

2026-10-29 做了 `context_search`（按字面和按意思搜）和 `context_read` 的几种读法，2026-10-30 并成一个工具 `history`（owner 定）：两个分开时，"小明前天说的那个"要先想好用哪个、参数怎么拼；搜和读本来就是同一组筛选（谁、什么时候），只差有没有词。Haskell 版也是一个入口统一召回（features.md 的 Unified recall），这里沿用，只是不搜记忆。

- **范围**：只搜这个会话的消息（2026-10-30 起；之前还搜摘要，见[摘要](#摘要)）。
  - 搜的只看 kind 是 chat 的行，命令和事件不搜，撤回了的不搜。词在 `messages.text`（渲染后的文本）里，或者在这条消息里图和表情包的 caption 里，都算。表情包的也搜（2026-10-29 owner 定："永远是全部能搜"；原先提议不搜，因为它写的是表情包是什么、什么时候用）。读的和尾巴一样，什么行都有。
- **`/clear --all`**：不管它，水位之前的消息照样搜、照样读（2026-10-29 owner 定，同上；和 Haskell 版一样）。`/clear --all` 只管上下文里显示什么。
- **参数**：都能一起用，除了 `around`。
  - `query`：给了就是搜，回结果列表；没给就是读，回原文。
  - `who`：发言人名字里的几个字，和词一样转小写当子串比 `messages.sender_name`，也就是当时的群名片（2026-10-30 加）。按名字不按 `[mention#N]`：旧平台和新 bot 上同一个人是两个 principal，名字多半一样。
  - `from`、`to`：本地的 `YYYY-MM-DD`、`YYYY-MM-DD HH:MM`，或者 `#id`。先换成行的 id 再查（`from` 是那时或之后的第一行，含；`to` 是之后的第一行，不含；日期的 `to` 算到第二天零点，所以两头都含当天），搜和读用同一个 id 区间。按 `sent_at` 找第一行，迁移 0017 加了 `(conversation_id, sent_at)` 的索引。`from` 之后没有行就是空区间。
  - `around`、`before`、`after`：读这条和它前后的行，默认各 10，最多 50，多了按 50 算；两个都是 0 就是这一条的全文（"全文见 `#123`"用的就是它）。不和别的筛选、`limit` 一起用；`before`、`after` 也只跟 `around` 用。
  - `limit`、`page`：见下面。什么筛选都没有回 `bad_arguments`。
- **搜**：
  - **匹配**：query 按空白切词，最多 8 个、每个 50 字，重复的去掉，逐字转小写，和 Postgres 的 `lower` 一个字对一个字，片段的位置不会错开。每个词在小写的文本里当子串找（`lower(text) like '%词%'`，转义 `% _ \`），不分词。有一个词就算候选。
  - **索引**：迁移 0011 装 pg_trgm，在 `lower(messages.text)` 和 `lower(media_captions.text)` 上建 `gin_trgm_ops`。三个字以上的词走索引；一两个字的没有三元组，在这个会话里一行一行比。ctype 是 C 的库（dev shell 的就是）不给中文切三元组，中文的词都是逐行比，结果一样；tank 的 `maxx` 是 en_US.UTF-8，有。查询在事务里设 `plan_cache_mode = force_custom_plan`：sqlx 的预备语句跑几次后换成通用计划，看不到词有多长，会为两个字的词读整个索引。
  - **排序**：分数 0 到 1，字面的是有几个词除以总词数，按意思的是余弦相似度，两样都找到的取高的；同分的新的在前。消息按正文去重，复读只留最新的一条。`limit` 默认 10，最多 30。不分页。
  - **结果**：`{ results: [{ ref, time, text, read }] }`。`ref` 是 `#id`；`time` 像 `2026-10-03 周六 14:02`；`text` 是"名字：正文"，正文和尾巴里一样，图带 caption，超过 160 字就截命中处前 40 字起的一段（只按意思找到的从头截），截掉的地方加"…"；`read` 是 `{ around: id }`，原样交回 `history` 就是读这条前后各 10 行。
- **读**：和尾巴一样的格式：日期行，一条一行，超长的只有开头。按整行分页，一页不超过单条上限，`page` 选第几页；一条的全文按字平均切页。
  - 有 `from`：从区间开头往后读 `limit` 行；没有：读区间里最新的 `limit` 行，照时间顺序排。`limit` 默认 50，最多 100。为的是"前天聊的那个"这种没有关键词的问法：翻那天的原文，代替原来摘要的那一行；也能只看一个人说过的话。
  - 还有更多时回 `next`，原样交回就接着读：从 `from` 读的，`from` 换成最后一行的下一个 id，往后接；读最新的，`to` 换成第一行，往前接。`who`、`limit` 带上。区间里没有行回一行"（没有这样的消息）"。
- **限制**：每次运行最多调 60 次（原来搜 20 次、读不限，合在一起放宽）；所有群合计同时最多 4 个搜索，短词要比一个会话的每一行，读的不占。系统提示里原始记录那一行说了：更早的不在上下文里，要找以前的事用 `history` 查，能按内容搜，也能按人、按时间读原文。
- **实测**（2026-10-29）：tank 的 `maxx` 上只读跑，还没有这两个索引，所以都是逐行比。最大的会话 6.2 万行：消息 1 个词约 85 ms，2 个约 97 ms，8 个约 145 ms。摘要（848 条的会话）2 个词约 36 ms，8 个约 61 ms。走索引的情况用 tank 上旧的 Haskell 库测（29 万行，`rendered_text` 上有一样的三元组索引）：3 个字的词 19 ms，4 个字 2 ms，两个 3 字的词 13 ms；两个字的词定制计划不碰索引，逐行 182 ms，通用计划读整个索引要 496 ms。`ilike` 比 `lower() like` 慢三倍多（50 ms 对 178 ms），所以不用它。三元组索引在旧库是 88 MB。
- **按意思**：整个 query 算一个向量，模型和[表情包库](#发图)共用（bge-m3，1024 维），等 5 秒；没配模型、出错、超时，就只按字面搜，不报错。`max_db::recall` 按余弦距离取最近的消息，过滤和字面的一样（chat、没撤回、时间、发言人），只比同一个模型的向量；条数和字面的一样（3·limit）。相似度至少 0.5 才算候选（提议，是估的，没在真数据上调过）。和字面的候选按 id 合在一起，同一个 `ref` 取高的分；之后的去重、排序、结果形状都不变。
- **向量**：一条 chat 消息一个（迁移 0013，`message_embeddings`；10-30 前摘要也有，在 `summary_embeddings`，留着不读）。按行不按窗口：结果本来就是一行（`#id`），上下文由 `history` 的 `around` 给；ledger 只追加，一行的向量永远不过期，窗口的会随后来的消息变；旧库的向量也是按行的，按 id 直接导。消息的文本是 `text` 去掉不带字的句柄（`[mention#3]`、`[reply#12]`、`[image]` 这类，SQL 函数 `recall_text`），剩下不到 4 个字的不算（"在吗""好的"按意思搜不出什么，字面照样搜得到；Haskell 版也是 4），只取前 2000 字。表情包和图的 caption 不单独算向量，字面照样搜。
- **精度**：`halfvec(1024)`，不像表情包库用 `vector`：22.5 万条时表和 HNSW 索引一共约 1.2 GB，`vector` 要 3 GB。最近的还是那些：2 万条随机向量（彼此的距离最挤，最难分）里搜 50 次，前十都一样，49 次顺序也一样，距离最多差 0.00004。HNSW（`halfvec_cosine_ops`）之外还有 `conversation_id` 的 btree：查询在事务里设 `hnsw.iterative_scan = relaxed_order`，HNSW 先取的 40 个被会话、时间过滤掉了会接着往下找；小会话里规划器直接按会话取出来精确排序，所以和字面的一样用定制计划。
- **召回向量 worker**（`max::recall`）：入账的每一行都交给它，没有当前模型向量的才算，同时 2 个请求，失败重试两次（10 秒、60 秒）就放弃。启动时和之后每小时扫一遍：新的在前，16 条一个请求，不重试，下一次扫描就是重试；一页失败了就一条条再试一次，免得一条服务不收的文本挡住比它旧的全部，一条都不成就是服务挂了，等下一次。换了模型会全部重算。只有它写这张表；用量不记 `llm_usage`。没配 embedding 模型就没有它。
- **实测**（2026-10-29，dev 的 Postgres 17，Mac，`maintenance_work_mem` 64 MB，22.5 万条随机的单位向量）：在有数据的表上建 HNSW，`vector` 9 分 30 秒、索引 1.76 GB，`halfvec` 6 分钟、586 MB；迁移是在空表上建，几毫秒。往建好索引的空表里插（导入就是这样）：22.5 万条 `halfvec` 17 分钟（同时在编译，偏慢）；2 万条 `vector` 50 秒，`halfvec` 38 秒。查询（`halfvec`，limit 90）：5.6 万行的会话走 HNSW 36 ms，2,250 行的走 btree 加排序 16 ms。
- **导入**：旧库 22.5 万条消息、3.2 千段摘要的 bge-m3 向量由 `max-import vectors` 按 id 导，见[导入](#导入)；摘要的现在不用了。

### 砍掉的

- `[recent turns]` 摘要、续接摘要、`context_resume` 和 turn 内的定位符压缩。turn 内也不裁旧工具输出，太大就结束这次运行，见[核心](#核心)。以后要看上一轮做了什么，加一个读 turn 快照的 `turn_read(t#N)` 工具。
- 自动注入检索结果。每轮只带上 Max 自己的记忆文件，见[记忆](#记忆)，其它靠模型调 `history`。

## 媒体

2026-10-29 定，在 v1 之后第一个做（owner 选的）。参考了 Haskell 版，它的教训写在各条后面。

- **节点和句柄**：入站时 QQ 附件的下载地址写进节点，`Media { media: Some(Remote(url)) }`。ledger 只追加，下载的结果记在 `message_media`（消息、序号、sha256）。序号是这条消息里第几个媒体，从 0 数；给模型的句柄是 `image#消息id.序号`，`video#`、`audio#`、`file#` 同理。Haskell 版的 `[image#id]` 指的是消息，不是哪张图，一条消息最多 20 个媒体，后来才改成两段（ADR 004）。
- **内容库**：`/var/lib/maxx/media/objects/<sha256 前两位>/<sha256>`，只读权限，先写临时文件再 rename，已有的不再写。和 Haskell 版同一种布局，导入时直接搬。不做 GC。
- **下载**：一个[派生数据 worker](#三种角色)，入账通知触发，同时最多 4 个下载，每个 60 秒超时，单个超过 64 MiB 的只记元数据、不下。失败重试两次（1 秒、4 秒）就放弃，只记日志，不留失败表。启动时只补最近 1 小时没下完的：QQ 的地址会过期，Haskell 版每次重启都把几百个过期链接重排一遍，刷半小时警告（9f27fa7）。图、表情包、视频、语音、文件都下，[读文件](#读文件)和以后的工具要用。
- **给模型的版本**：下载时做一次，`media` 里记它的 sha256。长边超过 1568 像素或者超过 1 MiB 的图，重编码成长边 1568 的 JPEG；GIF 取第一帧；其它用原图。Haskell 版一开始发多 MB 的原图，base64 纯属浪费（0a2addb）。
- **caption**：配置 `[llm] caption`，没配就不写；这个模型要能看图。存在它自己的 `media_captions` 表里，`media` 是下载 worker 的。下载 worker 存好一张图（有给模型的版本）就交给它；启动时的扫描只补 14 天内第一次见到、还没写的。按 sha256 一张一个，表情包重发不重写（975eb59）。每次调用 2 分钟超时，同时最多 2 个，用量记成 `caption`。一到两句中文，截图说明是什么、关键文字原样摘录，存 300 字以内。失败两次就放弃，记成空 caption，不再试。视频、文件不写；语音用腾讯给的识别文本。表情包另用一个提示词（2026-10-29 加，沿用 Haskell 版）：写它是什么、适合什么时候用，比如"翻白眼的猫，表示无语"；不像表情包的（私人照片、截图）判 SKIP，不进[表情包库](#发图)。同一个 sha256 只写一次，提示词按第一次见到时的种类选。
- **模型看到的**：
  - 尾巴里只有文字：`[image#123.0: caption]`，还没有 caption 就是 `[image#123.0]`。历史里的图不发图：Haskell 版的教训是它们抢注意力（0ec5752）。caption 到了，那一行就变，接受这一次缓存失效，见[前缀稳定的规则](#前缀稳定的规则)。
  - 附图：第一批输入和它们引用的消息里的图和表情包，作为真正的图片输入跟在易变块后面，每张标上句柄；后续输入里的图跟在 `[新消息]` 块后面。一次运行最多 8 张，多的只留文字。每张先按 1200 token 估，之后以 provider 报的用量为准。
  - 不支持看不了图的模型（2026-10-29 owner 定）：Max 用的模型都当作能看图，不设 `input` 配置，也不做纯文字的降级。意图分类只读文字，不受影响。
  - 想看历史里的图，在程序里调 `max.image('image#123.0')`（还没做，现在只收 `/work` 下的文件），见[多模态结果](#多模态结果)。
- **请求里**：条目只存引用（原则 7）。`User` 条目带一个 `images` 列表，每项是"哪条消息的第几个媒体"，不是 sha256：消息一入账就要展示，那时图通常还没下完。每次调模型前，`max` 查 `message_media` 和 `media` 找到给模型的版本，从内容库读出来，编成 base64 的 data URL 交给 `max-llm`。Responses 降成 `input_image`，Chat 降成 `image_url`，每张前面一段文字写句柄。入账不到 10 秒、还没下完的图就等它，在调模型的任务里等，不卡会话 actor；更早的、下不来的、读不出的直接不发，只记警告，句柄还在文字里。不传 QQ 的地址，它会过期，provider 也未必访问得到。
- **`/chat`**：原打算在 VM 里只读挂一个这个会话的媒体视图，硬链接到内容库；2026-10-29 改成程序按句柄拷进 `/work/chat`，见[读文件](#读文件)。

分六小步做（2026-10-29 加了第 4、5 步）：

1. 内容库、`media` 和 `message_media`、下载 worker；入站节点带上地址。
2. 模型的 `input`、条目里的图、两种协议的降级、附图和句柄。
3. caption worker，表情包另用一个提示词；导入老的图片描述和表情包。2026-10-29 上线：模型是经 cliproxy 的 GPT-5.6 Luna，effort low；老描述在新 maxx 启动前导好（图 21,040、表情包 3,421，其中 94 个 SKIP），启动扫描补了最近 14 天漏掉的 10 张。
4. 发图：qqbot 的上传，sender 发图和 `file_info` 缓存，分段器留下句柄、入账时解析，`send_image`。2026-10-29 上线，群里实测：回复里写句柄发出了 JPEG 和 GIF 表情包（GIF 会动），`send_image` 发出了 VM 里画的 PNG，带说明文字。
5. 表情包库：embedding 和 `find_stickers`。2026-10-29 做完，见[发图](#发图)的 `max.find_stickers`。
6. 读记录里的媒体和 `max.image()`。`max.image()` 收 `/work` 下的图，2026-10-29 做完；`/chat` 换成了 `max.file()`，同一天做完，见[读文件](#读文件)。`max.image()` 收消息句柄还没做，先 `max.file()` 拷出来再交路径。

### 发图

2026-10-29 定。同一天先删了，owner 随即改回来；表情包库跨群共享也是 owner 定的。QQ 那边怎么发、实测结果见 [QQ 官方机器人](#qq-官方机器人)的出站。

Max 发的图都走同一条[出站](#出站)：先入账成 Max 的一条消息，节点是指向内容库的媒体（`Blob(sha256)`），`message_media` 同时记上，再交给 sender。所以 Max 发的图在时间线上也有句柄，和群友发的一样能引用、能再发。

- **回复里的句柄**：模型在回复里写 `[sticker#123.0]` 或 `[image#123.0]`，发出去的就是那张图。表情包主要靠这个发：它是说话的一部分，先后要和文字对得上，也省一次工具调用。分段器把句柄单独切成一条，同一段里前后的文字各成一条，顺序照写的；照着显示形式抄来的 `: 描述` 去掉。会话 actor 入账时查 `message_media`，和查 `[reply#id]` 一样（见[解析和发送](#解析和发送)）：本会话的图和表情包都能发；别的会话的只能发表情包，图不出会话。种类按那条消息里节点的种类算。查不到的、没下载好的、不让发的，去掉，记 warn。
- **`max.send_image({ path, caption? })`**：发 VM 里做出来的图，比如图表、截图、从网上下的图。在宿主上从这个群的 `/work` 读，不跟符号链接，出不了 `/work`。按文件头只认 PNG、JPEG、GIF，WebP 转成 PNG；最大 10 MiB。存进内容库、写 `media`，经 `Post`（带 `origin`）入账，等 sender 回信，返回新消息的句柄。`caption` 是图下面的说明文字，和图在同一条消息里。每次运行最多 5 次。有副作用，后台 job 不开放。
- **`max.find_stickers({ query, limit? })`**：在表情包库里按意思搜，只搜不发，返回 `{ stickers: { handle, description }[] }`，`limit` 1 到 10，默认 5，模型挑一个把句柄写进回复。一次运行最多 5 次。库是所有会话见过的表情包（节点种类是 sticker），按 sha256 去重，句柄给最近一次以表情包出现的那条，哪个会话的都算；caption 判了 SKIP 的、空的不进库，按图的提示词写的 caption（第一次是当图见到的）也不进。搜描述的向量，embedding 和 `history` 共用。2026-10-29 做完：
  - 模型沿用 Haskell 版的 bge-m3（1024 维），线上是 h610 上的 Ollama，tank 连它（10-29 从 tank 试过，回 1024 维、归一化的向量；老库的向量和它算的一样，距离 0）。配置 `[embedding]`：`base_url`（OpenAI 兼容，`/v1` 结尾）、`model`、可选的 `api_key_file`。不配就没有 embedding worker，`find_stickers` 回 `unavailable`。维数跟着表，不是配置项：模型给的长度不是 1024 就当出错。
  - 向量存在 `caption_embeddings`，一个文件一行，记着模型；搜的时候只比当前模型的。
  - embedding worker：caption worker 写了表情包的 caption（不是 SKIP、不空）就交给它；启动时和之后每小时扫一遍没有当前模型向量的，所以换了模型会全部重算。一个文件一个单元，同时 2 个，每次请求 30 秒，失败重试两次（10 秒、60 秒）就放弃，等下一次扫描。tank 到 h610 晚上丢包，不做别的补救。用量不记 `llm_usage`。
  - 老表情包的向量由 `max-import vectors` 导，见[导入](#导入)。
  - 查询：query 算成向量，按余弦距离取最近的，失败回 `unavailable`，不重试。不设距离门槛（Haskell 版是 0.65）：10-29 在老库的 3,328 个向量上试了十几个查询，相关和无关的距离重叠（相关的多在 0.31–0.45，"吃瓜看戏"最近的 0.45，"今天天气怎么样"最近的也有 0.44），门槛分不开，交给模型看描述挑。
- **sender**：上传拿 `file_info`（5 MiB 以内 base64 直传，再大分片，见 [QQ 官方机器人](#qq-官方机器人)），再发 `msg_type = 7`，只有 `send_image` 带 `content`，文件不带。`file_info` 按（端点、sha256、文件名）缓存在内存里，提前一小时作废，所以同一张表情包一天里再发不用重新上传；重启就丢，重新传。上传失败和别的发送失败一样记进 `deliveries`。每张图算一条主动消息，占群的额度。
- **提示词**：表情包偶尔用，一次回答最多一张，别句句都配；记录里没有合适的，用 `find_stickers` 找。

### 发文件

2026-10-29 加（owner 要的）。QQ 那边怎么传、实测结果见 [QQ 官方机器人](#qq-官方机器人)的出站。

- **`max.send_file({ path, name? })`**：发 VM 里的文件，比如生成的文档、表格、PDF、压缩包。和 `send_image` 一样在宿主上从这个群的 `/work` 读，不跟符号链接；空文件不发；最大 64 MiB，和下载的上限一样：QQ 收到 200 MiB，但一次调用只有 60 秒，10-29 从 tank 传 32 MiB 用了 14 秒。`name` 是群里显示的文件名，默认用路径里的；去掉首尾空白，不能有 `/`、`\` 和控制字符，最长 100 字。存进内容库、写 `media`（不记 mime），经 `Post` 入账成 Max 的一条消息，节点是带名字的文件媒体（`DraftNode::File`），等 sender 回信，返回 `file#id.0`。每次运行最多 5 个。有副作用，后台 job 不开放。
- **sender**：按名字上传成 `file_type = 4`，消息不带 `content`。
- 记录里已有的文件不能写句柄再发，分段器只认图和表情包的句柄；要再发，先 `max.file` 拷进 `/work` 再 `send_file`，见[读文件](#读文件)，用得多再说。
- 私聊里也能发：10-29 用 qqbot 的 `send` 例子给 owner 的私聊发了一个 txt，收到了。

### 读文件

2026-10-29 加（owner 要的）。原计划是在 VM 里只读挂一个 `/chat`，硬链接到内容库。改成按需拷：不用再起一个 virtiofsd、不用改 guest；硬链接还有个坑，guest 的 root 在 virtiofs 上就是 `maxx`，挂成可写的话能 chmod、改写内容库里同一个 inode。

- **`await max.file(handle)`**：SDK 函数，和 `max.image` 一样不是 Max 的工具，不算进"调了 Max 的工具"，也不限次数。runner 发 MCP 调用 `max.file`，宿主按句柄查 `message_media`。句柄写 `file#123.0`，记录里显示的 `[file#123.0: 名字]` 也认；图、表情包、视频、语音的句柄也行。只认本会话的、下载下来了的（64 MiB 以内），拷到 `/work/chat/`，返回 `{ path, name, size }`。
  - 有文件名的叫 `<消息id>.<序号>-<文件名>`：文件名是群友起的，`/`、`\`、控制字符换成 `_`，最多留 150 字节。
  - 别的叫 `<消息id>.<序号>.<扩展名>`，扩展名按 mime 取，`image/jpeg` 是 `jpg`，短的子类型照用，别的不加。
- **写进 /work**：guest 能在 `/work` 里放符号链接，宿主写的时候不能跟。不跟链接地打开 `/work`，建或打开 `chat`，在里面先写临时文件，再 rename 到位。`chat` 是链接、目标是目录，都报 `bad_path`；目标位置原来是链接，换掉的是链接本身。同一个文件再拿一次就再拷一次。
- **宿主碰 /work 都走一处**（2026-10-30，review 发现的）：`max::mcp::work` 读、写、建目录，目录一段一段建、一段一段打开，哪段都不跟链接。`run_code` 和 `shell` 的完整输出（`.max/out`）、job 报告（`.max/jobs`）、dreamer 也经它；原来前两个用普通文件 API，guest 把 `/work/.max/out` 换成链接，宿主就会以 maxx 用户把输出写到 `/work` 外面。完整输出边跑边写，只新建，那个名字上已经有东西（链接也算）就不写。
- 不清理：`/work/chat` 里是普通文件，程序自己删。

## schema

2026-10-27 定：不沿用 Haskell 版的 schema，重新设计，上线时用导入程序一次性迁移。Haskell 版经过 135 个迁移，留下两套会话键（`conversation_id` 和 QQ 群号 `legacy_group_id`，后者没有外键，却被约 25 个模块当主键用）、三套消息 id、四份正文、31 张没有代码读的表，和互相撤销的迁移。只能从头来。

### 约定

- **一个实体一个键。** 会话只有 `conversation_id`，QQ 群号只出现在 `endpoints.native_id`。消息只有 `id`，同一个会话里就是入账顺序（见[时间线](#时间线)），模型句柄 `#id` 用它；平台原生 id 是属性，`(endpoint_id, native_id)` 唯一，入站的在 `messages`，Max 发出的在 `deliveries`。人只有 `principal_id`，平台账号在 `identities`。
- **JSONB 只放三种**：`nodes`、`raw`，和按设计整体存取的 blob（turn 快照、`opaque`、工具输出）。其它结构都是列。
- ledger 和 turn 记录只追加（[原则](#原则) 1）。
- 命名：PK 叫 `id`，外键 `<表>_id`，时间列用 `timestamptz`、叫 `*_at`。
- 迁移从 1 号开始，上线前随意合并，上线后只追加。
- 不做 source hash，不做 CAS cursor。Haskell 版的 `conversation_source_hash` 对 IR 做 sha256，IR 格式一改就要全库重打。
- id 列都是 `generated by default as identity`，导入程序可以写旧 id。
- 查询都在 `max-db` 里，接受 `&mut PgConnection`，由调用方决定哪些写在同一个事务里；要几条语句一致的查询自己开事务，调用方已经在事务里时就是 savepoint。
- `.sqlx` 离线元数据在 `crates/max-db/.sqlx`，Nix 构建设 `SQLX_OFFLINE=true`。改了迁移或查询，跑 `scripts/prepare-queries`：按迁移重建开发库，重新生成这份元数据。
- 向量用 pgvector。它不是 trusted 扩展，`maxx` 不是超级用户，迁移建不了：NixOS module 在 `postgresql-setup` 里以 postgres 建好，迁移里的 `create extension if not exists vector` 就什么都不做（10-29 在开发库上用非超级用户的角色试过）。库删了重建，要再建一次扩展，重启 `postgresql-setup` 就行。

### v1 的表

| 区域 | 表 | 说明 |
|---|---|---|
| 平台 | `conversations` | kind（group、direct）、标题 |
| | `endpoints` | 会话、平台、`self_identity_id`（Max 用哪个账号）、`native_id`。v1 一个会话一个端点；镜像时一个会话多个。现在就分开（2026-10-27 定），免得再迁移。`native_id` 是适配器自己的字符串：QQ 是 `group:<group_openid>` 或 `c2c:<user_openid>`，导入的老 QQ 端点（平台 `qq_legacy`）是 `group:<群号>` 或 `private:<QQ 号>` |
| | `principals`、`identities` | 人，和他在各平台的账号。多个写者：各会话 actor 入账时建，见[身份](#身份)的"写者" |
| | `conversation_settings` | `/model`、`/effort`、`/persona`、`/proactive`、`/historian`、`/clear --all` 的消息 id 水位。可变 |
| ledger | `messages` | 会话、端点、`sender_identity_id` 和发送者名字、角色的快照（见[身份](#身份)）、`native_id`、`sent_at`、`received_at`、kind（chat、command、event）、`reply_to`、`nodes`、`raw`、`text`（渲染后的文本，给搜索和全文索引；`lower(text)` 上有三元组索引，见[召回](#召回)）；Max 自己的消息带 `turn_id` 和段号。撤回、编辑是 `kind = event` 的行，`event` 列说是哪种（edit、unsend），带 `target_id` 和文本兜底；编辑的新内容在 `nodes`。只有会话 actor 写 |
| | `deliveries` | 出站回执：消息、端点、平台 id 或错误、状态（sent、failed、unknown）、时间。平台 sender 是唯一的写者，只追加。镜像时一个端点一行，见[出站](#出站) |
| 媒体 | `media` | 按 sha256 寻址：mime、大小、宽高、第一次见到的时间、给模型的版本的 sha256。种类在消息的节点里：同样的字节可能这条是图、那条是表情包。见[媒体](#媒体) |
| caption | `media_captions` | 按 sha256 一行，只写一次：用哪个提示词（图或表情包）、文字（模型放弃时为空）、`skip`（不像表情包的，不进表情包库）、哪个模型写的（导入的为空）。caption worker 是唯一的写者；读行的查询给没有描述的媒体节点填上它，所以哪里读到的行都带着 caption。见[媒体](#媒体) |
| | `media_captions` | sha256、caption（放弃了就是空的）、写它的模型、时间。caption worker 是唯一的写者 |
| | `caption_embeddings` | 按 sha256 一行：表情包 caption 的向量（`vector(1024)`）、哪个模型算的、时间。embedding worker 是唯一的写者；换了模型，它的扫描按新模型全部重算，搜索只比同一个模型的向量。见[发图](#发图) |
| | `message_embeddings` | 按消息 id 一行：会话、`halfvec(1024)` 的向量、哪个模型算的、时间。召回向量 worker 是唯一的写者，换了模型全部重算。见[召回](#召回)。`summary_embeddings` 是摘要的，10-30 起不读不写 |
| | `message_media` | 消息、序号、sha256。入站节点里是下载地址，下载完记在这里；程序交的图（`max.image()`）节点里直接是 sha256 |
| turn | `turns`、`turn_outcomes` | 见 [turn 记录](#turn-记录)。`t#N` 是 `turns.ordinal`，每个会话从 1 数 |
| | `llm_usage` | turn（可空）、用途（turn、intent、historian、caption、job、dreamer）、provider、模型、强度、token（含缓存命中数，按 provider 看命中率、调空闲窗口；还有其中的推理 token）、费用。token 用 bigint；费用 `cost_micros` 是百万分之一美元，用整数，不要 decimal，价格未知时为空。还有三个毫秒数（2026-10-30 加）：`first_ms` 是发出请求到模型第一次输出（正文、推理或工具调用都算），`took_ms` 是到回答结束，`quiet_ms` 是流里最长一段什么都没到的时间，也就是 `stream_idle_timeout_secs` 掐的那个。turn 和走 `complete` 的调用（intent、historian、dreamer、caption）都记；job 的调用经 pi 转发，不记，为空。要降空闲超时，先看 `quiet_ms` 正常情况下有多长 |
| 上下文 | `summaries` | historian 写的摘要：首尾消息 id、时间、标题、kind、importance、p1、p2、p3、status（active、superseded）。活跃的范围不重叠，用排他约束。只有开了 historian 的群读写，见[摘要](#摘要) |
| | `summary_runs` | historian 的每次模型调用：范围、原因（quiet、pressure、compact）、模型、原始输出、错误 |

以后随功能加：`automations`、`lingo_*`、`bungie_*`、`destiny_*`。

### 旧表的去向

- `platform_events`：原始 payload 进 `messages.raw`。
- `message_deliveries`、`message_delivery_parts`：换成 `deliveries`。
- `message_projections`、`message_hook_*`、`agent_messages` 视图：hook 不做了。
- `execution_journal`、`llm_calls`：turn 快照里就是模型的全部输入和输出。
- `platform_ids`：没有兼容 id。
- `conversation_cursors`：没有 cursor，尾巴从 `conversations.tail_after` 之后开始，见[前缀稳定的规则](#前缀稳定的规则)。
- `compartment_evidence`：搜索直接搜正文。
- `memories` 和它的 `memory_*`、`episode_memory_*` 表：记忆换成文件，旧的记忆 2026-10-30 手工迁成了文件，见[记忆](#记忆)。
- `skills`、`skill_versions`：skill 是文档，放文件。
- `sandboxes`：VM 的生命周期在进程里。
- `admin_timeline_revisions` 和那几个 NOTIFY 触发器：admin 以后再说。
- 31 张死表（durable task、plan、workflow、browser workspace 等）：不导。

### 导入

- **消息 id 沿用旧的 `canonical_message_id`**（2026-10-27 定），新消息从最大值加一接着编。旧摘要和记忆正文里的 `#123`、`[image#123.0]` 句柄因此还有效。导入时校验它和 `ingest_seq` 的顺序一致；不一致就另加一列记顺序。
- **全部消息都导**（2026-10-27 定），包括被 hook 忽略过的（`message_projections.context_visible = false`）。库里忠实保留群里的所有事实。
- `canonical_content` 的 v2 nodes 转成新 `Node`；`raw` 从 QQ 的 `segments` 列取，Matrix 从 `platform_events.raw_payload` 取；`text` 重新渲染。老的 Matrix 消息导成哪个平台 **待定**：Matrix 先不做，代码里的 `Platform` 暂时没有它，库的约束还认 `matrix`。
- 老 QQ 的账号和端点导成平台 `qq_legacy`：官方接口给的是 openid，和 QQ 号、群号不在一个命名空间，对不上。新群用 `/bind <老群号>` 接到老会话上，时间线连续，见 [QQ 官方机器人](#qq-官方机器人)。
- 老 QQ 号的人怎么接上见[身份](#身份)。旧库按 QQ 号存人：583 个 QQ 身份，一人一个，`native_user_id` 就是 QQ 号。官方接口只给 openid，同一个人在每个群、在私聊里的 openid 都不同，`union_openid` 是空的，所以一个人在几个群要在每个群各接一次。不做昵称匹配：旧数据里同群最新昵称撞名的有 4 人，45 个昵称只有一个字，自动认人总会认错。没接上的人算新人；合并是别名，之前的行渲染出来跟着变。
- 老的 reaction、戳一戳事件不导。Max 的 `debug` 行（工具回显，4.7k 条）不导。微信、iMessage、Matrix 的行（约 2.6k 条，那些群接不到新 bot 上）不导。
- Max 自己的消息不写 `deliveries`：sender 启动时只补记 `qq` 端点上结果未知的，`qq_legacy` 的不管。旧 `agent_turns` 不导，只有 3 段摘要引用了 `t#`；`turn_id` 留空。
- `conversation_compartments` 只导 `active` 的（3,249 段）。它们按群号（`legacy_group_id`）挂，不是按 `conversation_id`，导入时经群号找会话。范围从 `ingest_seq` 换成首尾消息 id；importance 0..1 换成 1..100；单摘要时期的 40 段只有 `summary`，放进 p1，其它层空着。旧摘要没有标题，标题留空，渲染时不留多余的空格。句柄从 `episode:<uuid>` 换成 `summary#<id>`。
- `principals` 和 `principal_identities` 直接搬，id 不变，旧摘要和记忆里的 `[mention#N]` 因此还有效；改名之前写的 `[@#N]` 导入时改写成 `[mention#N]`。旧表按 Max 的账号（`platform_account_id`）区分 identity，每个平台一个账号，直接换成平台：QQ 的换成 `qq_legacy`。`sender_name` 从旧 `messages` 的 `sender_card`、`sender_nickname` 取，群名片优先：2026-08-04 起 `sender_nickname` 存的就是有名片时的名片（`QQ.hs:94`）。`sender_role` 从 `platform_events` 原始 payload 的 `sender.role` 取，08-04 之前的为空。没有身份、没有消息的 611 个空 principal 不导。`endpoint_known_identities` 不导。
- `sessions` 只导人设、`/proactive` 和 `/clear --all`，模型和强度不导，见[配置](#配置)。旧记忆不经过导入工具，见[记忆](#记忆)。
- 媒体：内容库的文件和旧库在同一个 bcachefs 上，用 `cp --reflink` 拷到 `/var/lib/maxx/media`，属主改成 `maxx`。`media` 和 `message_media` 从 `message_images`、`message_videos`、`group_files` 建；旧的 `seg_index` 是第几个节点，不是第几个媒体，要按节点重算序号；没有表记着的，按节点里写的 blob 补上（多是 Max 发的图）。文件要先拷好，导入时每个都要在。给模型的版本和图片尺寸由 `max-import pictures` 生成，和下载时一样。caption 等第 3 小步有了 `media_captions` 再导：老库 21,519 张图的描述，和表情包库（3,397 张；3,328 张有描述和 bge-m3 向量，94 张 banned 的记成 SKIP）。由 `max-import captions` 导，maxx 照常跑着也行；它先跑迁移，所以要在带 caption worker 的 maxx 启动之前导，否则 worker 启动时的扫描会把最近 14 天导入的图重新写一遍：只导 maxx 有的文件，同一个文件表情包的描述优先，maxx 自己已经写了的不动，所以能重复跑。表情包的向量由 `max-import vectors` 导（第 5 小步）：老 `stickers` 表的 bge-m3 向量，只导老表记的文本哈希（`embedding_content_hash`，描述的 sha256）和 maxx 的 caption 文字对得上的，模型名照抄（`bge-m3`，所以 `[embedding] model` 要写成这个），已经有向量的不动，所以能重复跑、maxx 跑着也行；它也先跑迁移。10-29 在 tank 上只读地对过：maxx 有 3,334 条该有向量的表情包 caption，3,319 条能导；8 条老描述有换行或首尾空白，导 caption 时理成了一行，文字不同；7 条是 maxx 自己写的 caption，老库没有向量；这 15 条由 embedding worker 补。消息和摘要的向量也由它导，按 id：maxx 的召回向量 worker 要算的（够 4 个字的 chat 消息、活跃的摘要）、还没有向量的，从旧 `messages`（`canonical_message_id`）和 `conversation_compartments` 拿 1024 维的，模型名照抄；旧向量是从旧的渲染文本算的，句柄写法不同，意思一样。2000 条一批，已经有的不动。要在带召回向量 worker 的 maxx 启动之前导，否则 worker 会先花几个小时重算。
- 转发：旧库把转发里的每条消息存成单独的行，导入时折进转发那条消息的节点，一条一行（嵌套的缩进），和现在官方接口给的转发一样；里面的图算在那条消息上。
- Max 是一个 principal：旧 QQ 号的 Max，加上 bot 的 openid 作 `qq` 身份，旧行渲染出来是"（你）"。Max 的旧行没有平台 id，它们本该在不导的 `deliveries` 里。
- owner 的旧私聊接到 owner 新的 c2c 私聊上；别人的旧私聊不接。owner 的 openid 接在 owner 旧 QQ 号的 principal 上。
- 各群 VM 的 `/work` 也迁（2026-10-27 定）：按群号找到对应的会话，把这个群当前沙箱卷里的 `work` 拷到新卷，属主改成 `maxx`（见 [VM 进程](#vm-进程)）。`nix.img`（guest 里可写的 Nix store，存的是装过的包）提议不迁，用到时重新装。旧卷在 root 所有的目录下，读它要 root。
- 自动化、lingo、Destiny 等各自功能做到时再导；表情包随 caption 一起导。
- 导入写了旧 id 的表，最后要把它们的 identity 序列调到最大值之后（`setval`），否则新行会撞旧 id。
- 规模：2026-10-28 有 293,848 条消息、605 个有身份的人；库 3.3 GB，内容库 3.4 万个文件、26 GB。导入是分钟级的事。向量都导，见上面的媒体一条。
- maxx 自己的库（测试群的 113 条消息、3 段摘要）导入时整个重建，不留（2026-10-29 owner 定）：它的 id 和要保留的旧 id 撞。测试群导入后重新 `/bind`，导入前 `/link` 过的人导入后再发一次。
- 工具是单独的 crate `max-import`：`import` 在一个事务里导进空库，连旧库只读；`pictures` 再补给模型的图，跑过的跳过。演练就是导进一个临时库。上线跑一段时间后删掉。旧库和 `/var/lib/max` 等 owner 说了再删。`qq_legacy` 的行和合并是数据，留着。
- 上线步骤（2026-10-29 定）：
  1. 记下 bot 的 openid（现在的库里 Max 端点的 `self_identity_id`），停 maxx。
  2. root 把旧表和节点用到的文件从 `/var/lib/max/media/objects` 用 `cp --reflink` 拷进 `/var/lib/maxx/media/objects`，属主 `maxx`，只读。
  3. 删掉 `maxx` 库，建一个空的，属主 `maxx`。以 `maxx` 用户跑 `max-import import`（旧库用 postgres 角色连，只读），再跑 `max-import pictures`。
  4. 起 maxx。主人在私聊里给每个老群发 `/bind <老群号>`，把码发到新群。

## 身份

2026-10-27 定。沿用 [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md) 的三条判断：

- **模型面对人，ledger 存账号。** 人是 principal，平台账号是 identity。消息的发送者和提及节点存 identity，因为平台认证的是那个账号；渲染给模型时再查到 principal。合并因此不碰 ledger。
- **principal 只是"这几个账号是同一个人"的断言**：QQ 的 `/bind` 合并 owner 自己的账号，老群的人由 maxx 按头像接到老 QQ 号上（见下面的[按头像接上](#按头像接上)），错了 owner 改库。不从名字推断，也不信用户自己说的。
- **合并是别名，不改写。** `principals.merged_into` 指向保留的那个，被合并的行留作墓碑；读的时候用 `coalesce(merged_into, id)`，链深固定为 1，可以撤销。

### 表

| 表 | 列 | 说明 |
|---|---|---|
| `principals` | `display_name`、`merged_into`（可空） | 人。`display_name` 建行时取第一次见到的名字，只在这个人在当前端点没有发言快照时用 |
| `identities` | `principal_id`、platform、`native_user_id` | 账号，`(platform, native_user_id)` 唯一。Max 自己也是一个 principal，它在各平台的账号是 identity，不另设账号表 |
| `endpoints` | `self_identity_id` | 这个端点用 Max 的哪个账号收发。"是不是 Max 说的"就是 `sender_identity_id = self_identity_id` |
| `messages` | `sender_identity_id`、`sender_name`、`sender_role` | 发送时的快照。名字 QQ 取事件里的 `username`，为空时写"某人"（导入的老消息群名片优先，空则取昵称）。角色是 owner、admin、member，QQ 取事件里的 `member_role`；私聊为空 |

没有成员表。Haskell 版的 `endpoint_known_identities` 记谁在哪个端点出现过，这里由 ledger 推出来。名字和角色都是消息自带的快照，不向平台查，也不缓存。

**写者**（2026-10-28 定）：别的表都只有一个写者（见[运行时结构](#运行时结构)的图），`principals` 和 `identities` 是例外。会话 actor 入账时遇到没见过的账号（发送者，或者被提及的人）就建 identity 和它的 principal；同一个新人同时在两个群说话，两个 actor 会一起建。启动时解析 owners、`/bind` 合并 owner 的账号、按头像接上也写这两张表。规则：

- 只插不改，`merged_into` 除外。
- 建之前先不加锁查一次，查到就用。查不到，就在入账事务里按（平台，账号）取 `pg_advisory_xact_lock`，再查一次，还没有才建。同一个新账号因此只会建出一个 principal；见过的账号不用锁，所以平时各会话的入账互不等待。

### 按头像接上

2026-10-29 owner 定，取代当天去掉的 `/link`（见[权限](#权限)）。官方接口只给 openid，同一个人在每个群里的都不同；老群的人按 QQ 号存着。maxx 拿账号的头像和老 QQ 号的头像比，对得上谁就接到谁身上，不用谁来申请，也就没法替别人申请。

- **头像**：官方 bot 能按 openid 取账号头像（`q.qlogo.cn/qqapp/<AppID>/<openid>/640`），公开接口能按 QQ 号取（`q1.qlogo.cn/g?b=qq&nk=<号>&s=640`）。两张都缩成 16×16 灰度（印记，256 字节），均方根差在 5% 以内算同一张。2026-10-29 实测：同一个人的两张差 0.03%，别人的差 36–60%。没设头像的账号拿到的都是同一张默认图；QQ 对不存在的 openid 也给这张（1512 字节），maxx 就这样取它的印记。
- **比谁**：只在接着老群往下聊的群里（会话同时有 `qq` 和 `qq_legacy` 端点），拿这个群里还没比过、没并进别人的 `qq` 账号，和在这个会话的老记录里说过话的老号比。主人和 Max 的账号不比。老号的印记存在 `legacy_avatars`，超过 7 天的用到时重取，取不到的用旧的，从没取到过的不参与。
- **接不接**：账号是默认图，不接（`default`）；没有老号像它（`none`）；不止一个老号像它（`ambiguous`）；像的是主人或 Max 的老号（`barred`），不接，记 warn，多半是冒充；这一批里还有别的账号也像这个老号，或者这个群里已经有账号接在它上面（`taken`），都不接，记 warn：冒充者和本人都在群里时两个都不接，由 owner 查。只有一个老号像它，而且没人跟它抢，才把它的 principal 并进那个老号的人（`linked`）。每个账号只比一次，结果和比中的老号记在 `avatar_checks`；账号头像取不到的不记，下次说话、过 10 分钟再试。
- **什么时候**：启动时把每个这样的群里没比过的账号比一遍；之后每个账号第一次说话时比，把那个群里没比过的都带上。worker 订阅入账的行，和别的派生数据 worker 一样，见[运行时结构](#运行时结构)。
- **错了怎么办**：owner 直接改库：`principals.merged_into` 改掉或清掉；要它重新比，删掉它在 `avatar_checks` 的那行。冒充的风险还在，头像谁都能换：换成一个不在群里的老成员的头像，就会被接成那个人。owner 接受，看日志兜底。
- 10-29 去掉 `/link` 时清掉了它接上的 18 条，这些账号随后按上面的规则重新比。

### 模型看到的

- 人的句柄是 `[mention#12]`，和 `#123`、`[image#123.0]`、`t#42` 同一套语法，见[回复的写法](#回复的写法)。ADR 004 推迟的带类型前缀写法这次也不做，没观察到不同命名空间的号码被混用。
- 尾巴每行 `[HH:MM 名字 #id]`，名字用 `sender_name` 快照，所以有人改名，旧行也不变，前缀不受影响。正文里的提及渲染成 `[mention#12]`。
- **名册**在创建核心时随基础上下文一起投影，放在易变块（2026-10-27 定）。范围是上下文里出现的人：截过的尾巴里的发送者和被提及的人、第一批输入的发送者。一人一行，如 `[mention#12] 名字（管理员）`；名字和角色取这个人在本端点最新一条消息的快照，没发过言的取 `principals.display_name`。一次 `DISTINCT ON` 查询，走 `messages (endpoint_id, sender_identity_id, id)` 索引。
- 核心活着时第一次出现的人，在那一批 `[新消息]` 块里补一行名册，`Input::Messages` 带上这些人。核心在把这一批给模型看的时候把他们加进名册集合，之后的输出可以 @ 他们。
- 模型看不到平台号码。

### 解析和发送

- 核心持有名册里的 principal 集合，随基础上下文存进快照，模型调用任务的分段器拿着它。`[mention#N]` 不在集合里的不变成提及，模型编出来的号码不会变成真 @：带了名字（`[mention#N: 名字]`）的发成 `@名字` 文本，没带的去掉。
- 引用（2026-10-28 定）：会话 actor 入账 `Said` 时检查 `[reply#id]`：它必须是这个会话时间线上的一条消息，而且不是事件行（撤回、编辑）。不是的话，比如编出来的号码、别的会话的消息，就去掉引用，正文照发，记一条 warn。这一步不像提及那样在核心里查：模型可以合法地引用它用工具查到、不在上下文里的旧消息，只有数据库知道这个号码在不在这个会话里。发送时引用的消息没有平台 id（比如它自己就没发出去），`lower` 就不带引用。
- 发送时，`DraftNode::Mention(principal)` 由适配器的 `lower` 解析成目标端点平台上这个人的 identity，发原生 @；有多个时取在这个端点最近发过言的那个；没有就降成 `@名字` 文本。
- 镜像时这套规则不用改：两边都有账号的人两边都是原生 @，只有一边有账号的，另一边是文本。

### 权限

- owners 写在 sops 文件里，一行一个 `平台:原生号`，启动时解析成 identity（没见过就建），按 principal 判权限。一个 owner 并进来的所有账号都有权限。QQ 只写私聊的 `user_openid`，群里的账号由 `/bind` 并进来，见 [QQ 官方机器人](#qq-官方机器人)。
- 平台角色只看消息自带的 `sender_role`：命令消息本身就带着发送者当时的角色，不另外查平台。
- **命令以 `/` 开头**（2026-10-29 定，owner 的意思）：`/` 或全角 `／` 后面跟命令名；`!` 不再是命令前缀，`/nix/store` 这类也不是命令。群里的命令还得 @Max（同一天 owner 定：群里有别的机器人，也认 `/` 命令），不带 @ 的就是普通消息；私聊里不用。回复 Max 不算。提示怎么用命令的话（`/bind` 的码、`/clear`）在群里都写成 `@maxx /…`。QQ 官方机器人的指令面板（`/v2/panels` 或管理端的「高级设置」）只把指令填进输入框，用户自己按发送，bot 收到的是普通消息，所以面板和手打走同一条路。面板写不了参数提示，而且全群可见。面板就是命令列表，所以没有 `/help`（2026-10-29 定）。2026-10-29 用 `POST /v2/panels` 登记了一个群面板（`scope: group`、`target_type: all`），同日按 owner 的意思改过一次：`status`（查看当前状态）所有人能点，`compact`（压缩上下文）、`kill`（停止当前会话）`only_admin`；原来所有人能点的 `link` 随命令一起去掉了。`persona` 不在面板上，命令照样能用。名字不带 `/`，QQ 填进输入框时自己加。名字最多 7 个汉字，说明最多 15 个；每个面板最多 20 项，一个 bot 最多 20 个面板。改面板用 `PUT /v2/panels/{panel_id}`，不写进代码。以后做 Matrix 时再看：Element 会拦截 `/` 开头的消息。
- **命令的回复像日志**（2026-10-29 owner 定）：放在 `text` 代码块里，第一行是 `/命令 → 结果`，多的行接在下面；口吻简短、机械，"已切换：…"、"错误：…"、"拒绝：仅限主人"，和 Max 在 turn 里说的话一眼分得开。内容里有三个以上连续反引号时（比如人设）围栏加长。命令和回复照样进上下文，回复就是 Max 说的话：owner 觉得模型不会因此学着用日志口吻聊天。
- **`/status`** 是 Haskell 版 `!version` 那样的小名片，`!version` 并进来，不显示版本号（2026-10-29 定）：第一行 maxx 和构建它的 commit（flake 在 `max` 包上设 `MAX_COMMIT`，cargo 自己构建的写 dev），下面一行一个键值，键对齐：系统和架构、下一次回复用的模型和推理强度（10-29 owner 要的；在跑的 turn 用的和它不同时，turn 那行另标）、主动接话、在跑的 turn、清过的话加上下文水位、maxx 和主机的运行时长。全用英文。放进代码块以后去掉了原来每行前面的 emoji。模型和人设不放（owner 定），看 `/model`、`/persona`。
- 命令的权限沿用 Haskell 版（2026-10-29 定）：查看类（`/status`、不带参数的 `/model` 等、`/model list`）谁都能用；只影响这个会话的（`/kill`、改人设、`/clear --all`、`/unclear`）要群主、管理员或 owner；花钱或影响全局的（换模型、`/effort`、`/proactive`、`/historian`、`/bind`）只有 owner。没权限的回"拒绝：仅限主人"或"拒绝：仅限群主、管理员"。`/kill` 不回话。
- **`/persona`**：不带参数看当前的，`clear`、`reset`、`default` 回到默认（`default` 2026-10-30 加：Haskell 版只认 `clear`，`/persona default` 存成了一个只写着 default 的人设，一个群从 07-31 起一直用着它；迁移 0019 清掉这种）。默认人设和规则里的"不要怎样"同一天去掉了（owner 定），能正着说的改成正着说：列出来不让做的事，反倒把那件事放进了模型眼前。只留一段红线（同一天 owner 加）：中国政治、翻墙、色情赌博毒品邪教，QQ 上谈了会封群封号；有人提起就装傻岔开或者 `[silence]`。它在规则里不在人设里，换了人设也在。

### v1 不做、位置留好的

- ~~`/link <QQ号>`~~（2026-10-29 加，同一天去掉）：凭头像验证，把发令人的账号接到老 QQ 号的人上。头像是公开的，当天就有人换上别人的头像接到了别人身上。owner 定：命令和催人接的提醒都去掉，已有的 18 条关联清掉；老群的人由 maxx 自己按头像接，见[身份](#身份)，有冲突、对不上的只记日志，有问题 owner 直接改库，不信用户自己说的。
- 跨平台的权限跟着 principal 的合并走，不单独做；记忆是会话的文件，换平台接上同一个会话就还在。

## intent

2026-10-27 定进 v1，原来只判没有 @ Max 的消息。10-28 改：**所有入账都经过 intent**，@、回复这些也不绕过，由它决定什么时候叫醒核心。这样它看得到全部信息，规则和小模型判定在一处，去抖也自然放在这里。

10-29 精简：只留"没说完"的去抖和小模型判定，外加一个每小时上限当保险。删掉的有 Haskell 版的闸门、三类判定（called、followup、topic）和 topic 冷却，以及 10-28 新加的"本群情况"、接住率和被嫌烦。先看小模型自己判得怎么样，要加规则再加。Haskell 版的行为见它的 `docs/features.md` 的 Proactive triggering。

intent 和[核心](#核心)一样是 `max-core` 里的纯状态机，是会话 actor 的一个字段：

```rust
// 同步、不碰 I/O、不读时钟，时间由 actor 传入
impl Intent {
    fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision>; // 每条入账的别人的消息、事件和命令
    fn verdict(&mut self, v: Option<Verdict>, now: Instant) -> Vec<Decision>; // 在途那一批的结果，失败是 None
    fn tick(&mut self, now: Instant) -> Vec<Decision>; // 去抖到期
    fn deadline(&self) -> Option<Instant>;              // 并进 actor 的 deadline()
    fn set_proactive(&mut self, on: bool);              // /proactive
}

enum EntryKind { Direct /* @、回复 Max、私聊 */, Command, Chatter /* 其它，事件也算 */ }

enum Decision {
    Wake { ids: Vec<MessageId>, reason: Reason }, // 叫醒核心：有就喂一个 Input::Wake，没有就起一个
    Classify { batch: Vec<MessageId> },           // actor 在 side 里 spawn 小模型
}

enum Reason { Direct, Judged { note: String } }
struct Verdict { trigger: bool, reason: String }
```

数值都是 `max-core` 里的常量，没有配置项（10-29 删了 `[intent]` 一节），在 v1 里调。

### 直接触发和去抖

- **直接触发**：@ Max、回复 Max，以及私聊里的消息（见[运行流程](#运行流程)第 2 步）。不调小模型，不受上限影响，默认立刻 `Wake`。
- **去抖**（2026-10-28 定，来自 [DSH 调研](#调研dsh-和-qq-bridge)）：直接触发看起来没说完就先 hold，等这个人停下 10 秒再 `Wake`，最多等 20 秒。这期间他的后续消息（命令除外）并进同一个 `Wake`，一起作为核心的第一批；否则触发在易变块里、它的后半句却在尾巴里，顺序反了。"看起来没说完"是纯函数：
  - 去掉 @ 之后什么都没有；
  - 以"，、；：…"这类标点结尾；
  - 以"但是、然后、我跟你讲、对了、就是、所以、而且、还有、那个、因为"结尾；
  - 同一个人 5 秒内的第三条。
- **命令**不是触发，由 actor 执行。

### 小模型判定

- **什么时候分类**：`/proactive` 开着时，所有闲聊都分类（2026-10-29 改，原来沿用 Haskell 版的闸门：文本里有"max"或者 Max 3 分钟内说过话才分，其它闲聊每 15 分钟最多分一次）。手打的"@max"是纯文本，也走这条路（2026-10-20 定，不解析成提及）。
- **攒批**：每个会话同时最多一个分类在途；在途时来的闲聊攒着，等它回来再一起分，取最新的 30 条。所以分类的频率跟着小模型的速度走：热聊时一批接一批，不会每条一次。不用 Haskell 版 2 秒的去抖计时器。
- **输入和输出**：人设的前 500 字、最近 15 条消息作上下文（和尾巴同一种行格式）、待判的消息。行里的 `[mention#N]` 换成 `@名字`，@ Max 的是 `@maxx`：小模型没有核心那样的名单，从名字看出话是对谁说的（2026-10-29 改：之前它看不出 @ 的是谁，把 @ 别人的话当成在 @ Max）。输出一行 JSON：`trigger` 和不超过 20 字的 `reason`。提示词里写了该接话的两种情形（没打 @ 的点名、它能给出具体有用东西的话题）和不该接的（成员之间的对话，包括 @ 别人、回复别人；叫别人去用 AI；只是提到 Max；嫌 Max 烦；别的机器人和贴进来的代码、通知），拿不准就不接。原来还有一种"Max 参与的对话有了后续"，2026-10-29 删掉：4B 的小模型只要看到 Max 刚说过话，后面谁说什么都判成后续，判定叫醒连成一串；对 Max 的回应本来就是回复或 @，直接叫醒。分类任务自己读库拼输入；拼提示词和解析输出都是 `max-core` 里的纯函数。
- **`Wake` 的去处**：判定回到信箱，actor 交给 `intent.verdict`。同时只有一个在途，intent 记着这一批，所以不用带任务 id；分类任务失败或 panic 也要回一个 `None`，否则这个会话再也不分类。要接话的变成 `Wake { reason: Judged }`，ids 是这一批的消息。所有 `Wake`，包括去抖到期的直接触发，都过同一条规则：涉及的消息都不超过 `seen` 就作废。这些消息已经在某次模型请求里，模型自己决定过了；`/kill` 之前的也都这样作废。其余的作为一个输入（`Input::Wake`）进核心：没有核心就起一个，trigger 记成这个 `Wake`；有核心就喂给它。所以核心空闲、闲聊还没进过请求时，判定会叫醒核心；核心因为空闲窗口结束了，判定会起一个新核心。判定在 `[新消息]` 块里是一行，如 `[判定：在追问你刚才的回答]`；直接触发不加行，消息行上本来就标着"@你""回复你的 #123"。`seen` 见[时间线](#时间线)。
- **上限**：判定叫醒每个会话每小时最多 8 次，是防小模型失控的保险，直接触发不算。超了的判定直接丢掉。每个会话用 `/proactive` 开关，`/status` 看得到开没开。
- **失败**：不重试，记日志后丢掉。intent 只是建议，消息都在 ledger 里；瞬时错误由 provider 自己的重试兜住，不再叠一层。Haskell 版在 provider 重试之外又重试最多 3 次。
- **模型**：`[llm] intent` 选一个小模型。判定之后起的 turn 用会话自己的模型，和 @ 触发的一样，不按触发类型换模型或推理强度。
- 每次分类记一条 `llm_usage`，用途是 intent。

### 状态只在内存里

2026-10-28 定：hold 着的触发、攒着的闲聊、在途的那一批、每小时的计数都在 actor 的内存里，重启清零，不建表。代价是关机或崩溃时还在 hold 的直接触发会丢，没人回；接受。

## QQ 官方机器人

2026-10-28 定：QQ 改用腾讯官方的机器人接口（QQ 开放平台，个人认证，机器人叫 maxx），不再用 NapCat 和 OneBot。原来的 QQ 号当天被腾讯封了；官方接口封的是机器人，不是账号，也不用再维护 NapCat 和扫码登录。老消息照样导入，见[导入](#导入)。下面是 2026-10-28 查文档和用凭证实测的结果，标了"实测"的等适配器能收发后在测试群里验证。

- **连接**：AppID 和 AppSecret 换 access token（`bots.qq.com/app/getAppAccessToken`，有效约两小时；旧 token 最后一分钟才换得到新的，旧的再多活一分钟，所以到期前 50 秒换）。REST 走 `api.bot.qq.com`（2026-08 起的新域名，老的 `api.sgroup.qq.com` 也还通），调用带 `Authorization: QQBot <token>`；有的错误回 200，所以看 body 里的 `err_code`。事件走 WebSocket 网关，Max 主动连出去，tank 不需要公网入口。网关和 Discord 是一套：Hello 给心跳间隔，Identify 带 token 和 intents，断线后用 session id 和最后的序号 Resume；每天能新建 1500 次会话。不用 Webhook：它要公网 HTTPS 入口，而且和 WebSocket 二选一。2026-10-29 实测：`qqbot` 的 `listen` 例子从 Mac 连上网关，Identify 拿到 READY，心跳正常。
- **跨重启 Resume**（2026-10-29 定）：关机时把网关的 session id 和最后的序号存进库，启动时先拿它们 Resume，不新建会话，这样重启那几秒里群里发的消息由服务端补发。新建会话不会补发（实测丢过一条）。实测（2026-10-29）：停 2 分钟和停 10 分钟都 Resume 上了，期间的消息都补发了；更长的没测。超出窗口就只能新建会话，那段消息丢掉。实现（2026-10-29）：`qqbot` 把事件送进无界通道，丢掉连接的 future 时不会有已经计入序号、却还没送出的事件，所以接入停下后读完通道里剩下的，`Session::resumable` 的序号就是该接着的地方。补发的消息可能和停机前已经入账的重复，actor 按平台 id 丢掉已经入账的。为这个拆出一个常驻的平台进程、或者加 Redis 这类队列，都不划算：拆进程能换来的只有连接不断，Resume 做到了同样的事。
- **进哪些群**：个人主体的机器人只能由创建者拉进他当群主或管理员的群。2026-10-28 定：只进这样的群，而且群主要在群设置里打开两个开关：
  - "接收群内全部消息"：所有消息都走 `GROUP_MESSAGE_CREATE`，@ Max 的也是，是不是 @ 看 `mentions`。不开只收 @。
  - "机器人主动发言"：Max 随时能发。Max 的消息全是主动消息，不开就一条也发不出去，QQ 回 40034105"主动消息失败, 无权限"（实测）。
- **私聊**：个人主体的机器人暂时只能和管理端"开发设置"里加的体验用户私聊（实测）。这份名单就是私聊白名单，QQ 不用 `private_file`。私聊也只发主动消息，额度还没实测。
- **身份**：没有 QQ 号和群号，只有按机器人分配的 openid。群是 `group_openid`；群成员是 `member_openid`，同一个人在不同群里不一样；私聊是 `user_openid`，又是另一个。所以 QQ 上一个 identity 是一个群里的一个人，或者一个私聊对象。跨群认人本来就不做，记忆也按会话隔离；能跨群的 `union_openid` 要单独申请，不申请。只有 owner 要认出来，靠 `/bind`。
- **端点**：`native_id` 是 `group:<group_openid>` 或 `c2c:<user_openid>`。老库的 QQ 端点和账号导成另一个平台 `qq_legacy`，两边的号码不在一个命名空间，`qq_legacy` 也没有适配器。
- **`/bind`**：新群一开始没绑定，消息直接丢掉，不建会话，和名单外的群一样（见[运行流程](#运行流程)第 1 步）。绑定分两步：
  1. owner 私聊 Max 发 `/bind <老群号>`，或者不带群号的 `/bind`（新开一个会话）。Max 回一个 6 位码，10 分钟有效。
  2. owner 在新群里发 `/bind <码>`。这个群的端点挂到老群号对应的会话上（`qq_legacy` 端点所在的会话），时间线接着老消息往下走；同时把发令人在这个群的 identity 并进 owner 的 principal（设 `merged_into`），之后在这个群里认得出 owner。

  码在内存里，重启就失效。一个群只绑一次，不支持改绑。没绑定的群里只认 `@Max /bind <码>` 这一条命令；码不对就丢掉，只记日志，因为没有端点可以回话。绑上的那条 `/bind` 由会话表交给 actor（`Event::Bound`），照常入账，回一句"绑好了"，不当命令执行。一段老记录只能接到一个群上（2026-10-29 定）：一个会话只能有一个适配器在服务的端点，否则会有两个 actor 写同一条时间线。所以发码时查一次，用码时再查一次（同一个老群发过两个码的情况）。owners 文件里 QQ 只写私聊的 `user_openid`：第一次私聊 Max 后从库里的 `c2c:` 端点取。
- **入站**：
  - 群消息和私聊共用一个消息类型，`group_openid` 可空（2026-10-29）；群事件缺 `group_openid` 算格式不对，记 warn。别的事件（进群、退群、开关主动消息这些）不入账，只按 info 记下事件名和原始内容。
  - 发送者：`username` 是 QQ 昵称，不是群名片（2026-10-29 实测），群名片拿不到。QQ 客户端里引用和 @ 显示的却是群名片，所以 Max 叫人用的名字可能和群里看到的不一样。2026-10-29 定：接受，只用昵称。`member_role` 是 owner、admin、member。
  - @：正文里写成 `<@member_openid>`，`mentions` 里也有，@ Max 的那一项带 `is_you: true`。开了全量消息，@ Max 的消息也走 `GROUP_MESSAGE_CREATE`（实测）。
  - 引用：这条消息的 `message_type` 是 103，被引用的消息在 `msg_elements` 里（只有原文和引用号，实测不带作者），引用号也在 `message_scene.ext` 的 `ref_msg_idx`。
  - 媒体：图片、语音、文件在 `attachments`，带下载地址；语音还有转好的 wav 和腾讯的识别文本。实测图片带宽高和大小；文件的 `content_type` 是 `file`，带文件名，当文件发的视频也是；原生视频是 `video/mp4`，带宽高和大小，没有时长和封面；语音是 `.amr`；这些地址都不用鉴权就能下。
  - QQ 表情（实测）：正文里写成 `<faceType=1,faceId="306",ext="<base64>">`，`ext` 解开是 `{"text":"牛气冲天"}`，名字直接带着，不用查表。`faceType=3` 是超级表情；`6` 是收藏的表情包，名字为空，图在 `attachments`。给模型看是 `[face: 名字]`。
  - 合并转发（实测）：`message_type = 102`，正文是 QQ 拼好的文字记录，每条有内容和发送者昵称，没有结构化的子消息。转发里的图片也写在文字里，带文件名、尺寸、大小和下载地址。
  - 卡片（实测）：`message_type = 3`，`ark_data` 里有标题、来源和预览图，正文是文字摘要。B 站、知乎这类小程序卡片不带原链接，Max 只看得到标题。
  - 一条消息有两个 id：事件的 `id` 用来被动回复和撤回，`msg_idx` 用来引用。`native_id` 存前者。Max 发出的消息，发送接口返回 `id` 和 `ext_info.ref_idx`。实测（2026-10-29）：用户的消息被引用时，`ref_msg_idx` 和原消息的 `msg_idx` 一字不差；Max 的消息被引用时引用号也稳定，但和发送时拿到的 `ref_idx` 不一样，两个都能用来引用。提议：入站消息的 `msg_idx` 存一列加索引，引用按它精确查；查不到的是 Max 的消息，按 `msg_elements` 里的原文在 Max 最近发的消息里找。Max 自己发引用时用存下的 `ref_idx` 或 `msg_idx`。
  - 网关不推机器人自己发的消息，没有 echo 要丢。
- **出站**：
  - 全是主动消息（2026-10-29 定）：不发被动回复，假定 Max 在的群都开了"机器人主动发言"。原来是被动优先：回复的消息发出不到 5 分钟、还没回满 5 次，就带它的 `id` 和递增的 `msg_seq` 发被动回复，否则发主动消息（实测第 6 次回 40034128；5 分钟按消息自己的发送时间算，停机后补发的消息按收到的时间算会回 40034005"回复消息msg_id已过期"）。在没开主动发言的测试群里，一个回答的第 6 段就发不出去了。被动回复要数窗口和次数，又和"所有群都开主动发言"的前提重复，所以删掉。
  - 额度：主动消息整个机器人每分钟 60 条，每个群每分钟 20 条、每天 1000 条。sender 按群排队，超了就等，不丢。
  - 格式：纯文本，或者原生 Markdown（`msg_type = 2`，2026-04-23 起群聊和私聊都开放，不用申请模板）。2026-10-29 实测：标题、粗体、斜体、删除线、行内代码、嵌套列表、有序列表、引用块、代码块（带语法高亮和复制按钮）、表格都能渲染，`<` 和 `&` 不用转义。单个换行就断行，行尾两个空格会多空一行；粗体后面的空格会被吃掉。LaTeX 的 `$…$`、`\(…\)`、`$$…$$` 和 `math` 代码块能渲染，`\[…\]` 不行，发之前换成 `$$…$$`。Markdown 链接和裸链接都能点；纯文本里的网址也没被拒，同样能点（文档说的 40054010 没碰到）。Markdown 里的图片只显示 QQ 自己域名上的，外站的图裂开。长度上限还没测。2026-10-29 定：一律发 Markdown，省掉判断，Markdown 被拒时退回纯文本。2026-10-30 改（review 发现）：只有 QQ 明确回了错误、或者根本没连上，才算被拒、改发纯文本；请求发出去以后超时、回包解析不了，平台可能已经收下了，不再发，这一条记成 `unknown`，模型看到"（可能没发出去）"，等着的工具被告知不知道发没发出去。原来什么错都再发一遍纯文本，最后一律记成失败，可能发两条。
  - @：`<qqbot-at-user id="<member_openid>" />`，实测在 Markdown 里显示成 @群名片。
  - 表情（实测）：发不出去，`<faceType=…>` 和 `<emoji:id>` 都原样显示。2026-10-29 定：Max 不发表情，见[回复的写法](#回复的写法)。
  - 引用：`message_reference.message_id` 填被引用消息的 `msg_idx` 或 `ref_idx`，实测可行。
  - 撤回：`DELETE /v2/groups/{group_openid}/messages/{id}`，私聊是 `/v2/users/{user_openid}/messages/{id}`，成功回 200，没有 body。文档（2026-08 更新）：谁的消息发出超过 2 分钟都撤不了（40064004）；机器人是群管理员时能撤自己的和普通成员的（成员的用事件的 `id`），不是管理员只能撤自己的，否则回 40062003"无操作权限"；50065001 是稍后重试。私聊只能撤机器人自己发的。实测（2026-10-29，测试群，maxx 是普通成员）：发一条马上撤，成了；同一个 id 再撤一次也回成功；编的 id 回 40061001"请求参数无效"。超过 2 分钟的、别人的没实测。
  - **`recall_message({ id })`**（2026-10-29 做了）：Max 的工具，按 `#id` 撤回本群的一条消息，撤不撤由 Max 判断，沿用 Haskell 版。回复的每一段本来就是一行、一条 QQ 消息，各有 `#id`，所以一个 id 只撤一条，整个回复要一段段撤，不像 Haskell 版一个 id 撤几条。QQ 一定会拒的先在宿主上拒掉、说明原因，不入账：超过 2 分钟的（Max 的按回执时间算，别人的按消息时间）、群主和管理员的（看消息里的身份快照，2 分钟里基本不会变）、私聊里别人的、Max 没发出去或不知道发没发出去的、已经撤回的。Max 是不是管理员要另问 QQ（`bot_state`，见下面的群管理），这里不问：别人的消息照样去撤，被拒就把原因告诉程序。撤回经 `Post` 入账成 Max 的一行 unsend，带 turn；sender 按入账顺序撤，所以撤 Max 刚说的话也排在那条的发送后面。成了 `deliveries` 记 sent，被拒记 failed，投影里那行是 `[unsend#id]（没发出去）`。每次运行最多 10 次。
  - 媒体要先上传拿 `file_info`，再发 `msg_type = 7`。实测可以直接传 base64，`file_info` 一天有效；`content` 是图片下面的说明文字，和图在同一条消息里。2026-10-29 实测：GIF 能发，也会动，134 帧、1.9 MB 的也行；`content` 可以不带，不带时群里只有图，和群友发的表情包一样；上传返回的 `raw_url` 是空的，图嵌不进 Markdown。怎么用见[发图](#发图)和[发文件](#发文件)。
  - 发文件（`file_type = 4`，2026-10-29 实测）：上传要带 `file_name`，群里显示成这个名字的文件，能下载；txt、PDF 都发过。测试群起先回 50015014"系统繁忙"，`upload_prepare` 才说出原因：40093003"群文件超过上限"，那个群的群文件满了，同样的请求在别的群就能过。
  - 大小：base64 直传 6 MiB 能过，8 MiB 回 850012，所以 sender 超过 5 MiB 就分片，图和文件都是。分片：`upload_prepare` 带 `file_type`、`file_name`、`file_size`、`md5`、`sha1`、`md5_10m`（前 10,002,432 字节的 MD5），少了摘要回 850012；回 `upload_id`、`block_size` 和每片的 `index`（从 1 数）、预签名地址、`block_size`（都是字符串）。每片 PUT 到它的地址，再 `upload_part_finish` 报上 `upload_id`、`part_index`、`block_size` 和这片的 MD5；最后对 `files` 发 `upload_id`、`file_type`、`file_name`，回 `file_info`。文件 10 MiB 一片，图整张一片；同一个文件再传不会"秒传"，照样走一遍。12 MiB 的文件、9 MiB 的 PNG 都传上了，5.5 MiB 的 txt 分片发进了群。
  - 平台审核：内容违规会被拒（40034006），记成 `deliveries` 里的失败。机器人被封"暂不支持解封"。
- **没有的**：reaction、戳一戳、编辑、群名片、发表情；也没找到"有人撤回了消息"的事件，别人撤回的消息时间线上看不出来。群管理的接口见下一条。
- **群管理**：接口是 2026-08-10 和 09-03 加的，下面是 2026-10-29 查文档、在测试群实测的结果；禁言是 owner 当天把 maxx 设成测试群管理员以后测的，别的是 maxx 还是普通成员时测的。路径都在 `/v2/groups/{group_openid}/` 下。
  - 不用是管理员，实测能用：`info`（群名、简介、分类、标签、人数）和 `bot_state`（maxx 在这个群的 `member_openid`、入群时间、身份 owner/admin/member、开没开主动消息、收全部消息还是只收 @）。文档说这两个只给白名单，实测 maxx 都拿得到。各 30 次/分钟。
  - 要 maxx 是群管理员：禁言 `POST restrict_chat_setting`，body 是 `members: [{op, member_openid, mute_expire_at}]`，`op` 是 add、update、del，到期时间用 RFC3339，最长 30 天，一次最多 20 人；add、update 只能对普通成员，del 传空串就立刻解除。`GET restrict_chat_setting` 查全员禁言的规则和正在禁言的人。还有入群申请的列表 `join_request_list` 和审批 `approval_join_request/{member_openid}`，申请事件 `GROUP_JOIN_REQUEST` 也只有管理员收得到；`<qqbot-at-everyone />` @全体（2026-10-26 加），每个群一天一次。实测：都不是 11253；maxx 不是管理员，回 11703"机器人不是群管理员"（err_code 40011030），查禁言、查入群申请、对一个没被禁言的普通成员 del 一次，都是这样。
  - 禁言实测（maxx 是管理员，`bot_state` 回 `member_role: admin`，对一个普通成员）：add、到期时间是 60 秒后的 `+08:00` 时间，回 200 和 `{}`；马上 `GET` 看得到这个人，到期时间比给的早 1 秒；del 带空串，回 200 和 `{}`，再 `GET` 没人了。到期时间给空串的 add 回 40103009"请求参数mute_expire_at无效"；对没被禁言的人 del 回 200。没实测：update、对禁着的人 add、禁群主或管理员、超过 30 天。
  - 白名单（文档写"内邀接入中"）：成员列表 `members`、单个成员 `members/{member_openid}`、批量踢人 `batch_remove_members`（可以顺便拉黑）、黑名单的查询和增删 `member_blacklist`。实测成员列表和单个成员回 11253"应用无接口访问权限"（err_code 40012010），maxx 不在白名单上，所以拿不到不说话的人的 openid。
  - 事件：`GROUP_MEMBER_ADD`、`GROUP_MEMBER_REMOVE`（intent `GROUP_MEMBER_EVENT`，`1<<24`），只带 `member_openid`，没有昵称。
  - **`mute_member({ member, seconds })`**（2026-10-29 做了）：Max 的工具，在本群禁言一个人或者解除，禁不禁、禁多久由 Max 判断，禁完在群里简短说一声。`member` 是 `[mention#N]` 的编号，按这个人在本群最近说话的账号找 `member_openid`，没在本群说过话的找不到，禁不了。`seconds` 为 0 是解除（del），最长 2592000 秒（30 天）；不是 0 的先 `GET` 看这人是不是正禁着，禁着就 update、没有就 add，到期时间按 `+08:00` 写。QQ 一定会拒的先在宿主上拒掉：私聊、Max 自己、群主和管理员（看这人最近一条消息里的身份快照）。Max 是不是管理员不问，QQ 拒了（40011030）照实说原因。不经 actor 和 sender、不入账：禁言不是时间线上的一条消息，没有要和 Max 的话排先后的；重复禁一次也没坏处，所以不知道成没成时再禁一次就行。工具直接调 QQ 客户端（`qq::admin`），只留一行日志；下一个核心只能从 Max 在群里说的话知道禁过谁。每次运行最多 5 次。

配置在 `[platforms.qq]`：`app_id_file`、`app_secret_file`。AppID 不算秘密，但它能找到这个机器人，和群号一样不进仓库。

## Matrix

2026-10-29 定：先不做，包括[镜像](#消息格式)。原来和 QQ 一起做，是为了不让[消息格式](#消息格式)长成某一个平台的形状；现在消息格式已经定型，以后要做就加一个适配器。下面是 10-27、10-28 为加密房间定下和查到的，留作以后参考。

2026-10-27 定：支持加密房间。matrix-sdk 的 `e2e-encryption` 和 `sqlite` 特性都开；不加密的房间照常工作。Haskell 版只用 access token 调 Client-Server API，读不了加密房间。

- **状态存储**：matrix-sdk 的房间状态和密钥存在状态目录下的 sqlite 里（`/var/lib/max/matrix/`），口令来自 sops（`store_passphrase_file`）。这是 matrix-sdk 自己的存储，Max 的代码不读它，也不和 Postgres 混在一起。
- **登录和设备**：第一次启动用密码登录（`password_file`），把会话（user id、device id、access token）存进同一个目录，以后启动都恢复这个会话。设备 id 因此不变，别人的客户端不会每次重启都看到一个新设备。
- **交叉签名和密钥备份**：bot 账号开 secret storage 和服务器端密钥备份，恢复密钥放在 sops 里（`recovery_key_file`）。启动时用它恢复：设备由 bot 自己的身份签名，收到的房间密钥会备份到服务器。状态目录丢了，就重新登录成一个新设备，再从备份取回房间密钥，历史消息仍然能解开。
- **解不开的消息**：密钥晚到是常事。适配器先等一会儿（提议 60 秒），期间收到密钥就重新解密。超时就落一行占位消息，文本兜底是"[无法解密]"，`raw` 存密文事件；之后解开了，像编辑一样追加一行 `kind = event`、`target_id` 指向它。ledger 仍然只追加。
- **`raw` 存明文**：加密房间的 `raw` 存解密后的事件，不存密文，因为镜像和重建节点都要用明文。这意味着加密房间的明文也会进 Postgres，库的保护级别要按这个来定。
- **媒体**：加密房间里的媒体本身是加密的，解密密钥在事件里，`raw` 保留着它。等做媒体下载（v1 不做）时，由 matrix-sdk 下载并解密。
- **发送**：matrix-sdk 发送时自动加密，房间密钥发给成员的所有设备，不要求对方先验证。
- **初次设置**：`max matrix-bootstrap` 子命令。用密码登录、建设备，开交叉签名、secret storage 和密钥备份，把恢复密钥打印出来，由人放进 sops。服务本身启动时缺 `recovery_key_file` 照样报错退出，恢复密钥只能先经这一步拿到。
- **依赖约束**（2026-10-28 实测）：matrix-sdk 钉 0.18.0。sqlx 即使不开 sqlite 特性，sqlx-sqlite 也参与依赖解析：sqlx 0.9.0 要求 `libsqlite3-sys` `<0.38`，matrix-sdk 0.19 的 rusqlite 0.40 要求 `^0.38`，两边都声明 `links = "sqlite3"`，cargo 直接拒绝解析。0.18.0 用 rusqlite 0.37（`libsqlite3-sys` 0.35），能和 sqlx 0.9.0 一起解析，reqwest 也还是只有一份。等 sqlx 放宽这个范围再升 matrix-sdk。
- **测试**：单元测试用解密后的事件做 fixture；加密的完整路径在新建的加密测试房间里验证，用同一个 bot 账号登录成一个新设备，Haskell 版只同步它配置的那一个房间，互不影响。原来的镜像房间不加密，也不要给它开加密，开了就关不掉。

配置在 `[platforms.matrix]`：`homeserver`、`user_id`、`password_file`、`recovery_key_file`、`store_passphrase_file`、`rooms_file`（一行一个房间）。

## 工具和 codemode

2026-10-27 定。

### 纯 codemode

- **模型只有两个工具：`run_code` 和 `shell`。** tools 数组固定不变，请求前缀不会因为工具变化而失效；要守的是"固定"，不是"只有一个"。`run_code` 的参数是 `{code, args?, timeout_ms?}`：`code` 是 async 函数体，`return` 的值就是结果；`timeout_ms` 和 `shell` 的一样。同一轮可以有多个 `run_code`，各跑各的。
- **程序里调 Max 的工具**：`tools.<名字>(args)` 返回 Promise，`Promise.all` 就是并发。沿用 Haskell 版 SDK 的形状：`max.raw` 拿完整的成败结果，`max.cancel` 和 `max.race` 取消调用，`tools.agent()` 派后台 agent（2026-10-30 做了，见[后台 agent](#后台-agent)）。做成的（2026-10-29）：`tools.x()` 失败抛 `ToolError`；`max.raw` 不抛，返回 `{ok: true, value}` 或 `{ok: false, error: {code, message}}`；`max.cancel` 中止那次请求，`max.race` 取先完成的、取消其余的；没 await 就读字段会直接报错，提示先 await。
- **`shell`**（2026-10-28 定）：跑终端命令不用从 JS 绕。只有 `run_code` 的话，每次都要写 `child_process`，非零退出直接抛异常，stderr 拿不到；命令套在 JS 字符串里再套进 JSON，转义多一层，模板字符串里的 `${VAR}` 还会先被 JS 吃掉。主流模型在 shell 工具上训练得最多，形状贴近它们熟悉的最好用。
  - 参数 `{command, workdir?, timeout_ms?}`，贴近 Codex 的 shell 工具。在群 VM 里用 `bash -lc` 执行，默认工作目录 `/work`。
  - 结果是退出码加合并的输出；过长保留头尾，全文写进 VM 里的文件。墙钟上限和 `run_code` 一样。
  - 不能调 Max 的工具，不开 MCP 会话。调 Max 工具、并发编排、交图（`max.image`）都用 `run_code`：跑命令用 `shell`，写程序用 `run_code`。
  - 安全上没有新东西：`run_code` 本来就能 `execSync`，VM 里本来就是 root。
  - 小摩擦：`shell` 生成的图要看，得再调一次 `run_code` 交图。用得多再考虑在 guest 里放一个交图的命令。
- **工具说明**：系统提示里放 Max 工具的 TypeScript 声明，带返回类型，内容固定。
- **skill 只是文档。** `use_skill` 是普通的 Max 工具，返回说明书和相关工具的声明，和别的结果一样只往上下文后面追加。能调哪些工具由群和会话决定，一个 turn 里不变，不随 skill 加载变化。所以核心里没有"活动工具集"，Responses 的 `tool_search` 和 Chat 的元工具也都不需要。
- **调用格式**：用最通用的 function tool，参数是 JSON。代码是原文还是转义进 JSON 字符串，取决于模型自己的工具调用格式：Claude 的字符串参数和 Qwen 3.5/3.6 的 XML 参数是原文；GPT 和 Gemini 要转义，Gemini 偶尔还会多转义一层（gemini-cli 专门写了修正代码）。aider 2024 年测过，代码包进 JSON 后，所有被测模型的通过率都下降了，幅度不一。暂不处理，见[待定事项](#待定事项)。
- **代价**：所有工具都依赖 VM。VM 起不来就没有工具，模型还能纯文字回答；`/status` 要能看到 VM 的状态。前沿模型写 JS 没问题，qwen3.8-27b 这类本地模型要在 v1 里评测。

### 在群 VM 里跑

程序跑在群 VM 里的 Node 上，不用进程内的 JS 引擎（Haskell 版是 wasmtime 里的 QuickJS）。好处：

- 和后台 pi 共享 `/work`，交接任务只要留文件；群里的图片和文件用 `max.file()` 拷进 `/work/chat` 再读，见[读文件](#读文件)。
- 浏览器直接写 Playwright，见[浏览器](#浏览器)。
- Max 不用维护 JS 引擎、单步协议和 ABI。

做法：

- **每次运行一个新进程**：宿主通过 vsock 上的 SSH，在群 VM 里执行 `node /run/max/runner.js`。runner 和 SDK 打进 guest 镜像，只读。stdin 传程序、参数、会话 token 和 Max 工具的名字；stdout 只有返回值（字符串原样，别的转成 JSON），`console` 和程序自己往 stdout 写的都改到 stderr，作为日志带回；退出码 0 是正常返回，1 是抛了异常，带上程序自己的行号。和 `shell` 一样是一个 transient unit，经 `bash -lc` 启动，程序里的子进程有登录环境。不做常驻进程，免得运行之间共享状态。`shell` 也是每次一个 SSH channel，直接 `bash -lc`，不经过 runner。
- **启动**：VM 按需启动，约 4.5 秒后能执行命令（Haskell 版实测），闲置两小时关机。模型输出流里一出现 `run_code` 或 `shell` 调用就开始启动 VM，和模型写代码的时间重叠；不用工具的 turn 不启动。
- **限制**：VM 的 CPU、内存上限和网络策略；`run_code` 和 `shell` 一次运行的墙钟上限；drop 时杀掉命令。不要求确定性，也没有 fuel。
- **和核心的关系**：`run_code` 和 `shell` 在核心眼里都只是一次工具调用。程序里的 Max 工具调用不是核心的输入，结果里附一份内部调用的摘要，方便排查。Max 重启时宽限期到了还在跑的调用随连接断开被杀，核心给它补"已取消"，见[重启](#重启)。
- **已知风险**：VM 里的命令都以 root 运行。之前的提示注入如果在 VM 里留下了常驻进程，它可以拿到 runner 的 token 或接上它的 fd，用这一轮的工具。影响范围就是这一轮模型本来就能调的工具，新增的只是跨 turn 的持久化。接受。
- **测试**：runner 只认 stdio 和 MCP，测试里在本机跑 node，接 fake MCP 服务，不需要 VM。

### VM 进程

2026-10-27 定：沿用 Haskell 版的 VM 方案（cloud-hypervisor 加 NixOS guest），但去掉 broker。VM 是主进程的子进程，运行时不需要 root。

Haskell 版的做法见 [ADR 011](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/011-native-systemd-runtime.md)（当时还是 nspawn）：主进程没有 root，起停 VM、建网络命名空间、分配地址、准备卷、在 guest 里执行命令、装包，都交给一个 socket 激活的 root broker，约 1,000 行。VM 的 unit 没设 `User=`，以 root 运行。

这里的做法和 microvm.nix 自己的 host 模块一样：cloud-hypervisor 以普通用户、`kvm` 组运行，tap 由 root 预先建给这个用户。

- **需要 root 的只有开机时的声明式配置**，都在 NixOS 里：
  - `maxx` 加入 `kvm` 组。
  - 一个 oneshot unit `maxx-taps` 用 `ip tuntap` 预建一组 tap（数量是配置，默认 32），属主 `maxx`，开多队列和 vnet header。不用 systemd-networkd：module 不替宿主选网络栈。这个 unit 停了 tap 还在，重启它不会断开在跑的 VM。
  - 每个 tap 是自己的 /30（默认从 `10.235.0.0/24` 里切）：宿主一端是 `.1`，guest 是 `.2`，所有 VM 用同一个 MAC。地址不用 DHCP（2026-10-29 改，原先 2026-10-27 定的是 DHCP）：主进程起 VM 时把 `max.ip`、`max.gateway`、`max.dns` 和这次开机的 SSH 公钥 `max.key` 加在 guest 的内核命令行上，guest 里一个 oneshot 在网络起来之前读出来配好。宿主上不用跑 DHCP，也不用为 DNS 和公钥另开一个共享目录。
  - tap 之间不桥接，VM 互相不通靠路由和 nft。nft 只许 VM 用自己 tap 的 `.2` 作源地址、只许去公网地址、不许 IPv6；VM 连宿主一律拒绝，宿主只回已经建立的连接；出去的做 masquerade。
- **起 VM**：主进程选一个空闲槽位（没有就关掉闲置最久、没在用的那个），在 `/var/lib/maxx/vm/<会话 id>/` 下准备 `work` 和 `nix.img`，起两个 virtiofsd（只读的 store、读写的 `/work`）和 cloud-hypervisor，都是 `kill_on_drop` 的子进程。然后每 100 ms 试一次 SSH，连上就算起好了，不另做就绪通知。不挂会话的媒体视图，见[读文件](#读文件)。
- **vCPU 至少 2 个**：tap 是多队列的，cloud-hypervisor 要两对队列以上才按多队列打开它，而每个 vCPU 最多配一对。
- **每个 VM 的 tap 名不同**，而 microvm.nix 生成的 `microvm-run` 把 tap 名写死在构建时。2026-10-29 定：主进程自己拼 cloud-hypervisor 和 virtiofsd 的命令行，只借用 guest 的 kernel、initrd 和内核命令行，由 guest 的构建产出一个 JSON，路径写进配置。每个 VM 本来就有好几个参数不同（目录、tap、Landlock 规则），microvm.nix 的 runner 还会自己建盘、起 socat 转发通知，和"主进程直接管两个子进程"对不上。
- **通道**：hybrid vsock 的 socket 就在这个目录里，主进程直接用。连 22 端口跑 russh，每个 VM 一条连接，每条命令一个 channel；在 `notify.vsock_7777` 上监听 MCP，见 [MCP 通道](#mcp-通道)。
- **生命周期就是进程的生命周期**：闲置关机就是 drop；`maxx.service` 停止或崩溃时，systemd 按 cgroup 把 VM 一起杀掉。不需要清理孤儿、实例元数据和配置代数，下次起的 VM 用的就是当前配置。服务重启时 VM 和里面在跑的命令一起结束；VM 重启只要几秒，可以接受（2026-10-27）。
- **卷**归 `maxx` 所有，只在显式删除时删。
- **装包、搜包**：`maxx` 经 nix daemon 构建，gc root 放在 `/var/lib/maxx/gcroots/<会话 id>/`，guest 通过只读的 store 共享看到它们。不需要 root。
- **资源上限**：内存和 vCPU 由 hypervisor 参数限住，总量由 `maxx.slice` 限住，单个 VM 没有自己的 cgroup。以后需要再做 cgroup 委托。
- **安全**：VM 逃逸拿到的是 `maxx`，比 Haskell 版的 root 好，但 `maxx` 能读数据库和秘密。cloud-hypervisor 开 seccomp 和 Landlock，virtiofsd 进自己的命名空间，见下面的验证。
- **和 Haskell 版的区别**：每个 VM 不再有自己的网络命名空间。Haskell 版用 netns 加 NAT，guest 固定是 `10.0.2.2`；guest 镜像的网络配置要跟着改。
- **在 tank 上验证过**（2026-10-29，借 Haskell 版的 guest，以 `maxx` 身份、套着 `maxx.service` 的加固跑）：
  - cloud-hypervisor 52 用预建的多队列 tap，不需要 `CAP_NET_ADMIN`。它只提示 tap 已经存在、不改它的地址。
  - virtiofsd 1.13 以普通用户运行时，自己进新的 user、mount、pid、net 命名空间，根目录换成共享目录，没有任何 capability。`/work` 里建删改名、软硬链接、chmod、flock、git、写 300 MB 文件都正常。guest 的 root 映射成 `maxx`，其它 uid 都压成 `maxx`，所以 chown 不报错但不生效；mknod 失败，和 Haskell 版一样。`meta` 和 `chat` 也要这样映射，否则 guest 里 `authorized_keys` 的属主不是 root，sshd 不认。
  - `maxx.service` 的加固要放开四处，其它不动：
    - 去掉 `ProtectKernelTunables`、`ProtectKernelLogs`、`ProtectHostname`。它们在 `/proc` 上叠了只读挂载，内核就不让 virtiofsd 在自己的 user 命名空间里再挂一个 proc。这三项对没有 capability 的服务本来也挡不了什么。
    - `RestrictNamespaces` 放开 user、mnt、pid、net，virtiofsd 的沙箱要用。
    - `SystemCallFilter` 加上 `@mount`。
    - `PrivateDevices` 留着，用 `BindPaths` 把 `/dev/kvm` 和 `/dev/net/tun` 带进来，`DeviceAllow` 放行。

    `RestrictSUIDSGID` 顺带挡住了 guest 在 `/work` 里设 setuid 位。
  - cloud-hypervisor 的 Landlock 能开，要补两条规则：`/sys/devices/virtual/net` 只读（读 tap 的 flags），VM 目录读写（建 vsock 的 socket）。开了以后它没有 capability，`NoNewPrivs`，有 seccomp 过滤。
  - 从起进程到 SSH 连得上约 3.8 秒。hybrid vsock 上的 SSH 先发 `CONNECT 22\n`，systemd 的 `systemd-ssh-proxy vsock-mux/<socket>` 就能连，russh 照做即可。
  - guest 里 `systemd-run --pipe --wait` 能带回输出和退出码。它会往输出里写设终端标题的转义，要设 `SYSTEMD_ADJUST_TERMINAL_TITLE=0`。
  - tank 的 CPU 开了嵌套 KVM，module 的 NixOS 测试里也能起 guest。flake 的 `nestedChecks.x86_64-linux.vm` 就是这样：测试机里 module 建好 tap、nft 和加固过的 `maxx.service`，再用同样加固的 `maxx-vm-check` 起一个 VM，经 `shell` 的同一条路径跑 `uname -a`。2026-10-29 在 tank 上跑通，测试机里的 VM 10 秒起好。CI 的 runner 自己就是 VM，给不了测试机 KVM，所以它不在 `checks` 里，要在 tank 上手动跑。
- 运维网络（maxops 加 tailscale）换成另一组 tap，挂在一个路由进 maxops 命名空间的网桥上。v1 不做，上线前做。

### MCP 通道

VM 里的进程调 Max 的工具，一律走 Max 的 MCP 服务。codemode 的 runner 和后台 pi 都是它的客户端，区别只在会话权限。

- **通道**：cloud-hypervisor 的 hybrid vsock 里，guest 连主机的某个端口，会落到宿主上 `<vsock socket>_<端口>` 这个 unix socket，Haskell 版的就绪通知就走这条路。Max 在每个 VM 的这个位置监听一个端口，用 axum 加 rmcp 跑 Streamable HTTP。连进来的是哪个 VM，由 socket 路径决定。guest 里把 `127.0.0.1:7777` 转发到这个 vsock 端口，客户端都配 `http://127.0.0.1:7777/mcp`。IP 层照样连不到宿主，外面也照样连不进 VM。做成的：guest 里是 socket 激活，每个连接一个 socat 连到 vsock 的 2:7777；宿主在 VM 启动前就在 `notify.vsock_7777` 上监听，每个 VM 一个 MCP 服务，跟着 VM 起停。
- **协议**（2026-10-29）：rmcp 3.8，协议版本 2026-07-28，无状态，回复用 JSON 不用 SSE。这个版本每个请求都要带 `MCP-Protocol-Version`、`Mcp-Method`、`Mcp-Name` 头，`_meta` 里也要有协议版本和客户端能力。runner 自己用 fetch 拼，不装 MCP 的 SDK。更早协议的客户端也收（2026-10-30）：pi 1.4 的是 2025-11-25，先发 `initialize`；rmcp 默认要给它建会话，而服务没有会话管理，回 500。关掉 `legacy_session_mode` 后它的每个请求各自处理。
- **会话**：每次 `run_code`、每个后台 job 各开一个，记着 token、所属的群和 turn、允许的工具、在途的调用。`run_code` 的会话能用全部 Max 工具；job 的会话只列、只许调标了 `job` 的工具（读的，不动群：`history`、`web_search`），别的回 `not_allowed`，另外能经 `/llm` 调它的模型，见[后台 agent](#后台-agent)。会话还记着每个工具调了几次、失败几次，附在结果后面。

  | 会话 | 能用的工具 | 生命周期 |
  |---|---|---|
  | `run_code` | 这个 turn 的工具，由 `RunSpec` 定 | 这一次运行 |
  | 后台 job | 标了 `job` 的工具，和 `/llm` | 这个 job |

- **鉴权**：`Authorization: Bearer <token>`。token 所属的群必须和连进来的 VM 是同一个群。`tools/list` 只列出这个会话允许的工具。
- **吊销是同步的**：从内存表里删掉会话，它在途调用的 future 一起 drop，所以可以放进 `Drop`。会话只存在内存里，Max 重启或崩溃后旧 token 全部失效，不需要过期时间。
- **执行器**：所有调用都经过同一个执行器，负责 schema 校验、单次调用的超时、并发上限 64、输出大小上限，以及按会话限制有副作用的调用次数（代码里可以循环发送、撤回、禁言）。做成的：单次 60 秒，每个会话同时 64 个，多的排队；参数按工具契约查（见下）。输出上限和副作用次数等有了会产生大输出或有副作用的工具再加，`history` 自己分页。
- **结果**：工具声明 `outputSchema`，成功结果放在 `structuredContent` 里，`tools.x()` 拿到的就是 JSON。失败设 `isError`，`structuredContent` 是 `{code, message}`。取消用 `notifications/cancelled`。无状态的 HTTP 里取消就是断开连接，rmcp 会取消那次调用，`max.cancel` 就是中止 fetch。
- **不重试，不按副作用分类**（2026-10-29 定，owner 同意）：原打算给每个工具标只读、幂等、有副作用，失败结果里再带 outcome（rejected、failed-before-effect、outcome-unknown）和能否重试，用来决定宿主重试、后台 job 能用哪些、中断后算不算"结果未知"。都用不上：宿主一律不重试，交给模型；后台 job 的会话列一份能用的工具；会动群的操作（发消息、发图、撤回）都经会话 actor 入账，做没做成，下一轮在时间线上看得到。所以超时和取消一律说"可能已经生效，先看记录再决定要不要再来"。最坏是同一次运行里拿到超时马上再调，多发一张图，接受。
- **工具契约**（2026-10-30 做成，review 提的：原来名字、描述、两个 schema 和 TypeScript 声明都手写在 max-core 的 `MAX_TOOLS` 里，参数结构体和执行函数在 max 里，三份各写各的，schema 里的约束有的运行时没查）：一个 Max 工具只在 max 里写一处，实现 `mcp::tool::Tool`：名字、MCP 列表里的一句描述、一次运行最多调几次、后台 job 能不能用、参数类型、返回类型、系统提示里的用法说明（`guide`）和执行函数。参数和返回值是普通的 serde 类型，派生 schemars 的 `JsonSchema`；约束写成属性（`length`、`range`），参数字段的说明写成 `description`，说明和 `guide` 里的数字直接引用代码里的常量。注册表 `mcp::tool::TOOLS` 从这些生成三样东西：
  - MCP 列出的 `inputSchema` 和 `outputSchema`：子 schema 全部内联，去掉 title 和整数的 format；只留参数字段自己的说明，类型上的英文文档注释不进去。返回值有好几种形状时（`history`）是 `anyOf`，根上补 `type: object`，MCP 要求根是对象。
  - 调用前的参数检查：按 schema 查字符串长度（按字符数）和数值范围，报"history 的 before 要在 0 到 50 之间"这样的错；类型、必填、多余字段在 serde 读参数时查。超出范围的直接报错，不再悄悄截断。
  - 系统提示里的 TypeScript 声明：`/** guide */` 加从两个 schema 转出来的签名。可选字段写成 `x?: T`，必填但可以是 null 的写成 `x: T | null`。
  
  serde_json 开了 `preserve_order`，字段按类型里声明的顺序列出。max-core 不再有 Max 工具的清单，`prompt::system` 收现成的声明文本。换过来时生成的声明和手写的逐字节相同，提示词没变；声明的全文有 insta 快照，改了哪个工具的说明，快照的 diff 里看得到。

### 多模态结果

参考了 Codex、pi 和 Hermes 的做法。

- **程序显式交图**，学 Codex code mode 的 `image()`：`max.image(src, {detail})`、`max.video(src, {start, end})`。`src` 是 VM 里的路径（`/work/…`）或消息句柄（`image#123.0`），不接受 http 地址。只有交了的才进上下文；截图、下载这类操作只产出文件。不需要单独的 `view_image` 工具。
- **宿主自己取文件，不经过 MCP**：`/work` 是 virtiofs 共享，宿主能直接读；消息句柄的图在内容库里。宿主校验能否解码、按模型的上限缩放，按 hash 存进内容库，turn 记录里只存引用（原则 7）。要复制一份，是因为 `/work` 里的文件之后可能被改或被删。
- **中立格式**：`ToolOutput { parts: Vec<Part>, error: bool }`，`Part` 是 `Text` 或 `Media(MediaRef)`，和消息里的 `Media` 节点共用一套渲染。
- **在适配层降级**（原则 8）：
  - Responses：放进 `function_call_output` 的数组，`input_text` 加 `input_image`。
  - Chat：tool 消息里只放文字，带"图 1 见下"这类标记；这一轮所有 tool 消息之后跟一条 user 消息放图。有的 provider 不接受数组形式的 tool 内容，这样也避开了。
  - 视频：抽帧成图。
- **预算**：
  - 交图时就缩放到上限。
  - 每次运行最多交 N 张。
  - 同一张图（hash 相同）再交时只写"同上文图 x"。
  - 组装请求时超出视觉 token 预算，从最旧的图开始换成"`[image#…` 已省略，需要时再 `max.image`]"，turn 记录不变（原则 6）。

  Hermes 加这类预算的起因，是一个子 agent 在 15 分钟里把 5 张截图重新加载了 158 次。

做成的（2026-10-29，先只做图）：

- **SDK**：`await max.image(src)`，`src` 是 `/work` 下的路径，或者图片的 Buffer（比如 `page.screenshot()` 的返回值）。Buffer 先写进 `/work/.max/shown/`，宿主存好就删。返回原图的 `{width, height}`；读不了、不是图、超过上限都抛 `ToolError`。消息句柄和视频还没做。
- **怎么交给宿主**：runner 用这次运行的 token 发一个 MCP 调用 `max.image`，只带路径；它不是 Max 的工具，不在工具列表里，也不算进"调了 Max 的工具"。宿主像 `send_image` 那样一段一段打开 `/work` 下的文件、不跟符号链接、10 MiB 封顶，用和下载一样的办法做给模型的版本（长边 1568 的 JPEG，或者原图），存进内容库，记进这次 MCP 会话。程序结束后，`run_code` 的结果在文字后面按顺序加上这些图（`Part::Media`，内容库的 sha256），每张按 1200 token 估。
- **预算**：一次 `run_code` 最多交 4 张，同一张（hash 相同）只算一次。组装请求时只带工具结果里最新的 8 张，更早的在那个位置写"[这张图省略了，要看再 max.image]"，turn 记录不变。"同上文图 x"没做。
- **降级**：Responses 把有图的结果写成 `input_text` 和 `input_image` 的数组，没图的仍是字符串。Chat 在 tool 消息里写"[图 n，见下]"，连着的几条 tool 消息之后跟一条 user 消息，按编号放图。

### 网页搜索

2026-10-29 定，排在媒体第 1 小步之后（owner 选的）。`web_search` 当天做完：配置 `[search] api_key_file`，不配就回 `unavailable`；所有群合计同时最多 4 个搜索；没有单独的超时，MCP 执行器的 60 秒管着；每个 Max 工具可以声明一次运行最多调几次（`per_run`），超了回 `too_many`。

- **`web_search(query, limit?)`**：Max 的工具，宿主上经 MCP 调 Exa 的 REST 接口（`type: auto`，带 highlights），key 留在宿主，sops 里沿用 Haskell 版的 `search-exa-api-key`。返回前几条的标题、链接、摘要和发布时间，`limit` 1 到 10，默认 5；标题 200 字、摘要 800 字封顶。失败回 `{code, message}`，不做 Haskell 版那套免 key 的 MCP 优先、冷却和重试。一次运行最多调 20 次。Exa 走 tank 的日本出口，中文结果一般；以后不够用，在同一个签名后面换博查或智谱，它们国内直连。
- 工具常驻在系统提示的声明里，不藏进 skill：Haskell 版藏进 `web` skill 以后，模型不搜了，凭记忆答错剧情和价格（a51424d）。
- **抓网页不做成宿主工具**：宿主连得到 tailnet 里的服务，做成工具就是 SSRF 的口子。VM 镜像里加一个 `webread <url>` 命令：Python 加 trafilatura 抽正文、转 Markdown，PDF 用 `pdftotext`（2026-10-29 做完；原打算用 Node 的 Readability 加 turndown，trafilatura 少一套 npm 打包，也认得 GBK 这类老编码）；跟 5 次跳转、20 秒、10 MB 封顶，打印开头 1.2 万字，全文写进 `/work/.max/web/`，`--offset` 从存下的全文接着读。测试在本机用 dev shell 的 Python 跑这个脚本，接本地的 HTTP 服务。nft 本来就不让 VM 碰内网。要跑 JS 或登录的页面用[浏览器](#浏览器)。
- 不做：答案合成、模型 API 自带的搜索（工具数组固定不变，结果程序也拿不到）、结果缓存、图片搜索。

### 浏览器

v1 不做。2026-10-29 先做成每次运行现起 camoufox，当天晚上改成 VM 里常驻的 Chromium（owner 定），做法见本节末尾的"做成的"。

- **为什么换**：模型看完页面、下一次 `run_code` 再点，页面得还在。各家给模型用的浏览器（Playwright MCP、chrome-devtools-mcp、agent-browser、Hermes 的 `browser_exec`）都让浏览器常驻，Hermes 和我们一样是代码模式：每次调用起新的解释器，经 CDP 连同一个 Chromium。camoufox 做不到这样：Playwright 的连接一断，服务端就关掉这个客户端开的 context（playwright-core 1.59 的 `cleanupContexts`），想跨进程留住页面，得自己写个常驻进程持有它；Firefox 又已经不支持 CDP。CDP 的状态在浏览器进程身上，断开连接不关页面，在本机用 Chrome 和 playwright-core 1.59 验证过：上一个进程开的页面和填的字，下一个进程连上来都在。
- **代价**：反指纹不如 camoufox。自己起的 Chromium 不带 Playwright 的自动化开关，`navigator.webdriver` 是 false，User-Agent 去掉了 HeadlessChrome；但 VM 里的 WebGL 指纹、CDP 本身的痕迹还在，Cloudflare 这类检查更容易拦。真被拦得多了，再在 VM 里跑 camofox-browser 这类常驻服务。
- 不再有 navigate、click 这类浏览器工具，程序里直接用 Playwright 连这个浏览器。SDK 附带一个快照助手，给出带编号的可访问性树：各家给模型看的页面都收敛到这个形状（Playwright MCP 的 `[ref=e5]`、Claude 的 `ref_N`、agent-browser 的 `@e1`），Playwright 1.59 自带，不用自己写。原来沿用 Haskell 版的“可交互元素加 CSS 选择器”清单删了。
- 登录状态（2026-10-29 定，owner 选的）：只给 Max 自己的小号用，存在本群浏览器的 profile 里，写明全群的程序都用得到；不做个人登录，Haskell 版那种按人加密、程序看不到 cookie 的做法要宿主侧的工具，以后再说。
- 截图交给 `max.image` 看，下载存进 `/work`。

做成的（2026-10-29）：

- **服务**：guest 里的 `max-browser.service`，nixpkgs 的 Chromium，`--headless=new`，CDP 只听 127.0.0.1:9222；root 跑、关掉 Chromium 自己的沙箱，VM 就是沙箱。profile 在 `/work/.max/chromium`，cookie 和登录跨 VM 重启都在；VM 没关干净留下的 profile 锁，启动前删掉。中文界面和 `Accept-Language`，时区 Asia/Shanghai，窗口 1280×900，内存上限 2 GiB，崩了 systemd 重启（标签页没了，profile 还在）。不开机就起：第一个要浏览器的程序 `systemctl start` 它，等 CDP 端口能连才返回。VM 闲置关机时它跟着停，常驻的浏览器不让 VM 算作在用。
- **SDK**：`await max.browser()` 返回浏览器唯一的 BrowserContext，`await max.page()` 返回最近打开或 `bringToFront()` 过的标签页，没有就开一个。顺序取 Chromium 自己的 `/json/list`（按最近激活排，导航不算），不用 `context.pages()`：后来连上的程序拿到的 `pages()` 是 Chromium 挂上它们的顺序，不是打开的顺序；2026-10-29 tank 上第一次 vm-check 就因此拿到了 Chromium 启动时自带的新标签页，它上面也有个搜索框，读回来是空的。之后照常写 Playwright。一个程序里只连一次。程序结束只是断开连接，标签页留着，下一个程序接着用；用完的由程序自己关。`await max.snapshot(page, {selector?, depth?})` 是 Playwright 的 `ariaSnapshot({mode: "ai"})`，前面加上标题和地址：每个元素带 `[ref=e5]`，iframe 里的是 `f1e2` 这样，`page.locator("aria-ref=e5")` 找得到。`selector` 只拍那个元素（取第一个），`depth` 限层数。编号存在这次连接注入页面的脚本里，下一个程序连上来要先拍一次；页面没变，编号也一样（本机用 Chrome 验证过）。
- **打包**：`nix/runner.nix` 把 runner、SDK 和 playwright-core 1.59.0（没有依赖，直接取 npm 的包）放在一起，guest 的 `/run/max/runner.js` 链到包里。原来 camoufox 的发行包、camoufox-js 和它的补丁都删了。
- **字体**：guest 装了 Noto Sans CJK，Chromium 经 fontconfig 找到它。
- **实测**（tank 上的嵌套测试，VM 2 个 vCPU、1 GiB 内存）：`vm-check` 的第三个程序起浏览器、打开一个 data: 页面、快照、截图存进 `/work`，测试检查快照里的选择器和截图。VM 10 秒起好。VM 开机后第一次起浏览器要 22 秒，多半是经 virtiofs 冷读 store，加上嵌套虚拟化；同一个 VM 里再起 4.3 秒，打开页面 0.4 秒。开着两个 context 时这次运行的匿名内存 370～410 MiB，cgroup 峰值（含页缓存）775 MiB。宿主上直接跑：加载模块 0.6 秒，起浏览器 0.5 秒，第一个页面 1.4 秒。真实网站没测，测试机不通外网。VM 默认 4 GiB 内存，不用加。
- **提议**：Haskell 版用了 humanize（模拟鼠标轨迹）和虚拟显示（Xvfb，比 headless 难认出来），这里先只用 headless；被网站认出来再加。

### 待定事项

- v1 开放哪几个 Max 工具。
- ~~调 VM 用 `ssh` 命令还是 russh~~：已定（2026-10-27），russh，见 [VM 进程](#vm-进程)。
- 每次运行最多交几张图、视觉 token 预算多大。
- 代码转义的问题（2026-10-27 记下，暂不决定）：要不要让 GPT 用 Responses 的 custom（freeform）工具直接写原文，Codex 的 code mode 就是这么做的，cliproxy 也已支持；Gemini 过度转义要不要在 runner 里兜底，比如原文解析失败、去掉多余转义后能解析时才用修正版。先看 v1 里转义出错的频率。

## 后台 agent

v1 之后做。

- 每个 job 驱动群 VM 里的一个 pi 进程，通过 stdio 上的 RPC JSONL 通信。
- 适配器在 `crates/max/src/job.rs`（2026-10-30）：`job::pi` 是协议，`job::drive` 给任务、转 steer、到点中断、等它停下，取最后一条助手消息的文字作报告，再关 stdin。用量、工具调用经 `Watch` 报出去。没有再抽一层 `AgentBackend`：只有 pi 一个实现，等真有第二个再抽。命令用 `Vm::open` 起，stdin 一直开着。
- **模型**（2026-10-30 定）：`[llm]` 里单独配 `job = { model, effort }`，没配就没有后台 agent。pi 不拿 provider 的 key：它的模型请求发到 VM 里的 `http://127.0.0.1:7777/llm/<端点>`，和 MCP 是同一个服务、同一个 token。宿主认出是哪个 job 的会话，把 `model` 换成配置里的，带上 provider 的 key 和头转过去，回答原样流回来。provider 在 `stream_idle_timeout_secs`（默认 120 秒）里没出声，不管是回答开始前还是流到一半，都和 max-llm 一样掐断：pi 当作这次调用失败，自己重试，不会干等到 job 到点（10-30 Max 自己 review 时指出的）。只认这个 provider 协议的端点（`chat/completions` 或 `responses`），请求最大 64 MiB；job 结束、会话吊销后 token 就没用了。没选的办法：cliproxy 的管理接口能在运行时加删 key，但改完要写回配置文件，tank 上那是 sops 渲染出来的；给 VM 一个固定的 cliproxy key，等于给了群里所有人。
- 领域工具走 Max 的 MCP 服务，见 [MCP 通道](#mcp-通道)。工具要的东西（数据库、搜索、嵌入、内容库、QQ 管理）在 main 里建一份 `mcp::Services`，所有调用共用，里面的 `None` 只表示没配置。谁在调由 `mcp::Caller` 说：`Turn` 带着这一轮的 `Poster`，`Job` 带着它的上游，`Check` 是 `vm-check`。能用哪些工具只看 `Caller` 和 `job` 标记（2026-10-30 改：原来每处手拼一份上下文，job 那份漏了嵌入，`context_search` 静默退化成只按字面搜）。每个 job 开一个会话，会话活多久 job 就多久，所以工具的次数上限按一次运行的 10 倍算（`web_search` 一次运行 20 次，一个 job 200 次）。只开放只读工具，比如 `context_search`、`context_read`、`memory_list`；job 结束时吊销。pi 在 VM 里也能跑 codemode 的 runner，用 job 自己的会话批量调这些工具。
- 会影响群的动作（发消息、发文件、撤回、禁言、建自动化）不给后台 agent。它的结果是一种唤醒（`Reason::Job`）：会话有核心在跑就喂给它，没有就起一个；由前台的模型决定怎么说。job 中途提问同样处理，见下面的**提问**。
- **工具**（2026-10-30）：Max 在 `run_code` 里用四个 Max 工具管 job，都由会话 actor 回答（经 `Poster`，带回信通道），后台 agent 自己用不了：
  - `agent({ task, title? })` 马上返回 `{ job: "job#3" }`。job 在会话 actor 的表里，编号只在这次运行里递增，重启从 1 数。同时最多 3 个，每个 2 小时（原来 30 分钟，读一遍三万行代码都不够，10-30 改）。剩 5 分钟时 steer 一句让它停手写报告，到点先 `clear_queue` 再 `abort`，交出做到一半的。不提醒的话，到点时它多半正在调工具，最后一条助手消息没有文字，什么也交不出来（2026-10-30 job#2 就是这样）。一次运行最多起 3 个。没配 `llm.job`、没有 VM、正在重启时报错。
  - `agent_steer({ job, message })` 转给 pi 的 `steer`；它在等 Max 答复时（见**提问**），这一句就是答复。`agent_cancel({ job })` 从表里删掉，scope 丢掉就停了，unit 由 VM 的 stopper 停，结果不要了；`agent_status({ job? })` 列标题、分钟、模型和工具调用次数、最近的工具。`job` 写 `job#3` 或 3。
  - `/kill` 连 job 一起停，回一句停了哪些；`/status` 每个 job 一行。
- **结果**：pi 停下后取最后一条助手消息，存成 `/work/.max/jobs/job-<n>-<时间>.md`，再给会话 actor 一个 `JobDone`。actor 起一个 `Wake { ids: [], reason: Job { job }, item }`，`item` 是 `[job#3 完成] 标题`、`[job#3 到点停了，下面是做到一半的] 标题` 或 `[job#3 失败] 标题：原因`，下面是报告；超过单条上限只给开头 2000 字。末尾写全文的路径。没有报告时（失败的除外）指给它 `/work/.max/jobs` 里 pi 的会话记录。和判定一样，有核心就进它的下一批，没有就起一个。已经取消的 job 的结果丢掉。这条唤醒失败了（模型出错）不补发，全文还在文件里。
- **用量**：pi 每次模型调用记一行 `llm_usage`，`purpose` 是 `job`（迁移 0015），没有 turn。
- **提问**（2026-10-30）：后台 agent 卡在只有 Max 或群友才知道的事上，用 `ask_max({ question })` 问。这个工具是 guest 里的一个 pi 扩展（`nix/ask-max.ts`），调 `ctx.ui.input(问题)`：RPC 里成了一个 `input` 对话框，pi 在这个工具调用里一直等，上下文不断。`job::drive` 把它交给会话 actor（`Event::JobAsks`），actor 像报告一样唤醒 Max（`Reason::Job`），`item` 是 `[job#3 问] 标题`，下面是问题和“用 agent_steer 回答它，10 分钟内没答复它就自己判断”；已经取消的 job 的问题丢掉。问题没答复时，这个 job 的下一句 steer 就是答复，作为对话框的 `value` 回去，工具返回 `Max 答复：…`。10 分钟（`job::WAIT`）没答复，max 回 `cancelled`，工具返回“Max 这次没有答复，按你自己的判断继续，在报告里写明你做了哪些假设”；之后再来的 steer 照常是 steer。到点收尾和到点叫停前，先回掉没答复的问题：它在工具里等着，收不到 steer。`ask_max` 一次只跑一个（`executionMode: "sequential"`），同时来第二个问题或叫停后来的问题直接回 `cancelled`。没走 MCP 工具：一个等十分钟的 MCP 调用会撞上客户端的超时，而且 Max 自己的工具表里不该有它。2026-10-30 在 tank 上用 pi 1.4.0 实测过扩展：答复和 `cancelled` 两条路都对。
- **pi 的系统提示**：追加一段，说它是 Max 的后台 agent，看不到群聊，要聊天记录用 `mcp__max__history`，查网页用 `mcp__max__web_search` 和 `webread`；卡在只有 Max 或群友才知道的事上用 `ask_max` 问，能自己查到、试出来的别问；最后一条消息就是报告，先结论后要点和出处，2000 字以内；文件放 `/work`；快到点时会提醒它收尾。

pi 适配器要处理的行为（2026-10-29 用 pi 1.4.0 实测）：

- `steer` 不打断正在跑的工具，要等这一轮工具调用都跑完、下一次 LLM 调用之前才送达。默认是 `one-at-a-time`，改成 `all` 后两条 steer 在同一次调用前一起送到。
- `abort` 不清队列。到点时先发 `clear_queue` 再发 `abort`：正在跑的 `sleep 40` 立刻被杀，`agent_settled` 带 `aborted: true`，`abort` 的回答在它之后。取消路径直接停 unit。
- stdin EOF：空闲时 pi 0.01 秒内退出；跑到一半也立刻退出，子进程跟着死。所以它的生命周期可以绑在 stdio 上。
- `agent_end` 不代表结束，要等 `agent_settled`；自动重试、排队的 steer 都在它之前。
- 助手消息的 `message_end` 带用量。pi 的 `input` 不含缓存读写，记账时把 `cacheRead`、`cacheWrite` 加回去，才是整个请求。失败的调用 `stopReason` 是 `error`，原因在 `errorMessage`；重试成功后以最后一次为准。
- stdout 只按 LF 切行，不能用会把 U+2028 当换行的读行器。`agent_end` 带整个运行的消息，很长；超过 16 MiB 的行丢掉。
- RPC 模式下扩展会发 `extension_ui_request`。`select`、`confirm`、`input`、`editor` 会一直等回答。`input` 是 `ask_max` 的问题，标题就是问题，交给 Max（见**提问**）；别的后台没人能答，一律回 `cancelled`；`notify` 只记日志，比如 MCP 服务连不上时 pi 发的那条。
- MCP 工具在 `mcp.json` 里配 `"exposure": "direct"`，直接以 `mcp__max__<工具>` 出现在工具表里。pi 的 MCP 客户端说 2025-11-25 的协议，见 [MCP 通道](#mcp-通道)。

guest 里的 pi 来自 numtide 的 llm-agents.nix，flake 里钉在一个 rev 上。包装脚本 `max-pi`（`nix/max-pi.sh`）从 stdin 第一行读这个 job 的 JSON：token、模型 id、协议、窗口、输出上限、effort 和追加的系统提示。它在 unit 的 RuntimeDirectory 里写 `models.json`（provider 只有一个 `max`，`baseUrl` 是 `/llm`，`apiKey` 是 `$MAX_JOB_TOKEN`）和 `mcp.json`，再 exec `pi --mode rpc --no-approve`，带上 `--extension` `ask-max.ts`（路径由 `max-pi.nix` 的 `MAX_ASK_MAX` 给）；会话存在 `/work/.max/jobs`。`/work` 里的 `.pi/` 是群里能写的，不信任。unit 停了目录就删，token 跟着没了。

pi 2026-04 被 Earendil 收购，仓库搬到了 `earendil-works/pi`，几乎每天发补丁，RPC 协议没有版本字段。所以在 Nix 里钉版本，录几段真实的 JSONL 做适配器回放测试，升级前先跑这些测试。录下来的在 `crates/max/src/job/fixtures/`（去掉了流式增量、系统提示和本机路径）。

## crate 划分

2026-10-27 定。拆 crate 只认三个理由：强制依赖方向（编译器替你挡住违规 import）、隔离重依赖的编译时间、单独复用或发布。"这是一个功能"不算：lingo、embedder、召回向量都要用库、LLM 客户端和消息渲染，各拆一个只会多出一堆 Cargo.toml 和一张互相依赖的网，什么都没挡住。

| crate | 内容 | 拆开的理由 |
|---|---|---|
| `qqbot` | QQ 官方机器人接口：token、网关（心跳、Resume、重连）、事件和 REST 的类型、发送和撤回，发图时再加上传。不认识 Max：没有 Node，没有会话 | 依赖方向：协议层不能长成 Max 的形状。也是唯一值得复用的一块 |
| `max-core` | 所有纯逻辑：Node/Message/Draft/Item 类型、核心和 intent 两个状态机、请求构造、分段器、给模型看的渲染。只依赖 serde、serde_json、thiserror，以及不开 `clock` 特性的 chrono（渲染 `HH:MM`、换日、间隔标记要用） | 依赖方向：sans-I/O 靠编译器保证 |
| `max-db` | schema、迁移、全部 sqlx 查询和行类型 | 编译时间；`.sqlx` 离线元数据集中在一处 |
| `max-llm` | Responses 和 Chat 适配、流式解析、推理透传、多模态降级 | 协议细节都关在这里，用录下来的响应单独测 |
| `max` | 二进制：配置、CLI、services、会话 actor 和 I/O 任务、平台 sender、QQ 适配、投影、lingo、worker 框架、VM、MCP 服务、工具、命令 | 其余都是业务，放一起 |
| `max-import` | 二进制：旧库导入 | 旧 schema 的代码只在这里，切换后整个删掉 |
- 依赖只能往下：`qqbot` 和 `max-core` 在底层，互不依赖；`max-db`、`max-llm` 依赖 `max-core`；`max` 依赖全部。QQ 事件到 Node 的映射在 `max` 里，不在 `qqbot`。
- `max-core` 的依赖白名单写进 CI：`cargo tree -p max-core -e normal` 里只能出现那四个库。CI 再单独跑一次 `cargo check -p max-core`：只构建这一个包时，chrono 的特性不会和 `max` 合并，核心里调 `Utc::now` 就编不过。
- intent 的状态机和拼分类提示词、解析输出在 `max-core`；分类任务（读库、调小模型）是 `max` 里的 I/O 任务。派生数据 worker 各一个模块，比如 `max/src/recall.rs`；它们的纯逻辑（提示词、校验）放 `max-core`，不起库就能测。
- 平台适配先不拆出 crate，`max` 大到难受再分。
- `qqbot` 暂不单独 repo。workspace crate 已经有单独 repo 的全部技术好处；v1 期间协议层的形状还会动，分开只会多一套 PR 流程。要发布时 `cargo publish -p qqbot` 从这个仓库发，path 依赖换成版本号就行。
- lint 集中在 workspace 的 `[workspace.lints]`；裸 `tokio::spawn` 用 `clippy.toml` 的 `disallowed-methods` 拦。

### 工具链

stable，edition 2024（2026-10-27 定）。`rust-toolchain.toml` 钉具体版本号，不写浮动的 `stable`；Nix 里 crane 和 devenv 用同一个版本。升级单独提交。

不用 nightly。这个设计里可能想要的 nightly 特性都有稳定的替代：

- async drop：已决定不用，见[资源怎么结束](#资源怎么结束)。
- trait 里的 `async fn`：1.75 起稳定。要 `dyn` 的地方（工具注册表）返回 `Pin<Box<dyn Future + Send>>`，不用 `impl_trait_in_assoc_type`。
- `gen` 块、`try` 块：不需要。
- rustfmt 的 import 分组选项：用 stable 的默认格式。
- 要 nightly 的工具（cargo-udeps）不进 CI，用 cargo-machete 代替。

## 审阅性约束

- 直接依赖集中写在 workspace 根 `Cargo.toml` 的 `[workspace.dependencies]` 里。新增依赖单独提交，并在提交里写理由。
- 用 cargo-deny 检查许可证、重复版本和来源；安全公告用 cargo-audit 对 flake 里钉住的 advisory-db 查，Nix 的构建沙箱里没有网。
- 每个提交都要能单独审完（2026-10-27 定）：手写的改动以 400 行左右为准，`Cargo.lock`、`.sqlx`、快照和 fixture 不算；按内容合理拆分，略超可以（2026-10-28 放宽）。一个提交只做一件事，单独拿出来也能编译、测试通过。
- crate 数量保持少，按需再拆。初始划分见 [crate 划分](#crate-划分)。
- 不写 legacy 和兼容代码，要删就删干净。
- ADR 只记真正的取舍。
- `timeout(` 和 `sleep(` 只出现在[超时](#超时)一节列出的地方；`select!` 循环里只放 cancel-safe 的分支，见 [cancellation safety](#cancellation-safety)。

## 测试

- 用 cargo-nextest 跑全部测试。
- 纯逻辑用 fake provider 和 fake 平台测；超时和宽限期用 tokio 的 `start_paused`。
- 取消：会话 actor 在任意两个事件之间插 `/kill`，I/O 任务在每个 poll 点 drop 一次，见 [cancellation safety](#cancellation-safety)；正常路径的测试断言没有资源是因为连接断开而被杀的，以此抓漏调的 `close`。
- 数据库测试用 `#[sqlx::test]`，每个测试一个临时库。本地用开发 shell 里的 `devenv up` 起的 Postgres（端口 5434，角色和库都叫 `max`）；flake 的 nextest 检查自己起一个临时 Postgres，只听 TCP。
- prompt 渲染用 insta 快照。是否取代 `max-prompt-flow` 生成的文档 **待定**。
- codemode 的 runner 在本机跑 node，接 fake MCP 服务，不需要 VM。
- 平台层用录下来的 QQ 网关事件做 fixture。fixture 里只用假的 openid 和 AppID。

### 测试环境

2026-10-27 定：

- QQ（2026-10-28 改）：老账号被封，Haskell 版在 QQ 上已经停了。Rust 版用官方机器人 maxx，拉进一个 owner 当管理员、开了两个开关的测试群，见 [QQ 官方机器人](#qq-官方机器人)。不碰 NapCat。
- **和 Haskell 版完全分开**（2026-10-27 定）：Rust 版在 tank 上是一套并行的服务，名字一律用 `maxx`，和 Haskell 版的 `max` 区分开：
  - systemd：`maxx.target` 管整套服务，所有单元都挂在 `maxx.slice` 下，资源上限单独算。VM 是 `maxx.service` 的子进程，没有单独的单元，见 [VM 进程](#vm-进程)。
  - 存储：系统用户 `maxx`，状态目录 `/var/lib/maxx`，运行时目录 `/run/maxx`，sops 里的 `maxx/` 前缀，Postgres 里单独的 `maxx` 库和角色。
  - VM：tap 池和子网单独一套，子网避开 Haskell 版用的 10.231 和 10.233。不碰 Haskell 版的 broker 和它的 `max-sb-` 名字空间：Haskell 版启动对账时会删掉这个前缀下自己数据库里没有的实例和卷。
  - 这个名字是 NixOS module 的一个参数，文中其它地方的例子仍按 `max` 写。

## v1 实施顺序

2026-10-27 定，10-28 补上 tank 那一步和重启恢复，10-29 删掉 Matrix 和重启恢复两步，编号不变。每一步是一串小提交；前五步不碰 tank。没定的数值先用文中的提议值，做到那一步再调。

1. **骨架**（2026-10-28 完成）：workspace、钉住版本的 `rust-toolchain.toml`、crane 加 devenv（带 Postgres）、检查项（fmt、clippy、nextest、`max-core` 的依赖白名单）。全部检查是 flake 的 `checks`，CI 只跑 `nix flake check --impure`。
2. **`max-core`**（2026-10-28 完成）：消息类型、渲染、分段器、核心和 intent 两个状态机、投影，全用 fake 测。两个状态机的签名在这一步定下来，写的时候改动的地方已经更新到[核心](#核心)和 [intent](#intent) 两节。
3. **`max-db`**（2026-10-28 完成）：四个迁移覆盖 v1 表里平台、ledger、turn、用量和摘要几块（媒体和记忆随功能加），以及会话 actor 和 sender 要用的查询，全部用 `#[sqlx::test]` 测（10-29 加了第 6 个迁移，去掉恢复用的表和列）。写的时候定下的细节已经补进 [schema](#schema)。
4. **`qqbot`**（2026-10-28 从 `onebot` 改，10-29 完成）：token、网关、事件和 REST 的类型、发送和撤回，fixture 里用假 openid。网关会话是不做 I/O 的状态机，断线、Resume、僵死连接和各个关闭码都在里面测；驱动用本地 WebSocket 服务测。`listen` 例子只连网关、打印事件，不发消息。
5. **`max-llm`**（2026-10-29 完成）：Responses 和 Chat 两种协议的请求降级和流式解析，解析器不做 I/O。客户端一次只发一次，用 `Error::retryable` 给错误分类；重不重试由 `max` 的模型调用任务决定，因为只有它知道有没有已经说出去的文字。录了四家的真实响应做回放测试：cliproxy 的 gpt-5.6-luna 走 Responses，加密推理原样回传；cliproxy 的 Gemini、DeepSeek、taipan 上的 Qwen 走 Chat，带 `reasoning_content`。录的时候发现两件事：一是 Responses 默认把函数工具设成 strict，会把可选参数全变成必填，所以显式发 `strict: false`；二是 Gemini 会报推理 token 却不给推理内容，这部分不算进任何条目，因为条目的 token 是它下次再发时的花费。NInfer 的缓存断点做成 Chat 的选项：后面紧跟另一个 user 条目的 user 条目打断点，也就是基础上下文里易变块之前的那几块，已在 taipan 上验证。工具结果里的图片 2026-10-29 随 `max.image()` 降成真正的图，见[多模态结果](#多模态结果)。
6. **tank 上的 `maxx`**（2026-10-29 完成）：`nixosModules.maxx` 按名字生成用户、Postgres 角色和库、目录、slice、target 和服务，配置文件在构建时跑 `max check-config`；`nixosModules.max` 是同一个 module 换成上线后的名字。`max` 现在只做三件事：迁移数据库，用 QQ 凭据问一次自己是谁，等 SIGTERM。QQ 的 AppID 和 secret 在 sops 的 `maxx/` 下。module 有一个 VM 测试，用和 tank 一样的 Postgres 16。部署时遇到两件事：一是 sqlx 0.9 不认 `postgresql://max@/max?host=…`（有用户名就不能是空主机），改成 `postgresql:///max?host=/run/postgresql&user=max`；二是 tank 的集群建在 glibc 2.40 上，系统现在是 2.42，`template1` 的 collation 版本对不上，新建库就失败，所以刷新了 `template1` 的版本记录（它里面没有用户对象）。同一天按 owner 的意思，把 `postgres`、`luckperms`、`minecraft`、`matrix-synapse` 几个库 `REINDEX DATABASE CONCURRENTLY` 加 `REINDEX SYSTEM` 后也刷新了。
7. **`max`**（2026-10-29 完成，测试群里实测过）：配置、会话表和会话 actor、I/O 任务、平台 sender 和 `deliveries`、QQ 适配和 `/bind`、命令、intent。做完第一次实机：测试群里纯文字对话，顺便实测 [QQ 官方机器人](#qq-官方机器人)里标了实测的几项。工具在第 9 步之前一律回错误"工具还没接上，现在用不了。"。实测结果：`/bind` 接上测试群；@ 的对话和闲聊经 intent 判定都正常；停服务 2 分钟和 10 分钟，网关都 Resume 上了，停机期间的 @ 补发过来并且回答了。10 分钟那次回答被 QQ 拒了（40034005），被动回复的窗口改成按消息的发送时间算。同一天按 owner 的意思做了一轮减法：核心撞上限就认输，不再交接（见[运行流程](#运行流程)第 4 步）；重启时给宽限期再中断，不再挂起恢复（见[重启](#重启)）；intent 只留去抖、小模型判定和每小时上限（见 [intent](#intent)）；Max 不发表情；Matrix 先不做。这一步定下的：命令输出留在同一个会话（见[出站](#出站)）、命令权限（见[权限](#权限)）、actor 测试用真实时间（见[核心和 actor 的测试](#核心和-actor-的测试)）、一段老记录只接一个群（见 [QQ 官方机器人](#qq-官方机器人)）。tank 上的主模型是经 cliproxy 的 Gemini 3.8 Flash（Chat 协议），intent 用 h610 上的 qwen3.5-4b。
8. ~~**Matrix**，带加密房间和 `matrix-bootstrap`~~：2026-10-29 删，先不做，见 [Matrix](#matrix)。
9. **VM、MCP、codemode runner**。[VM 进程](#vm-进程)里要先在 tank 上验证的几件事 2026-10-29 验证完了。同一天做完第一段：VM 服务、`shell` 工具、module 里的 tap、nft 和加固，`max vm-check` 和嵌套的 NixOS 测试，测试在 tank 上通过。地址改走内核命令行，不用 DHCP。部署到 tank 后在测试群里实测过：模型调 `shell`，群的 VM 3 秒多起好，结果回到模型。第一次没调成，因为系统提示里还留着第 7 步那句"工具还没接上，别调用"。同一天按 owner 的意思，提示词里改叫 maxx（以前叫 Max）。tank 上的 Haskell 版同日删掉，数据留给导入。第二段同日做完：MCP 服务、guest 里的 runner、`run_code` 和第一个开放的工具 `context_read`，做法见 [MCP 通道](#mcp-通道)。runner 的测试在本机用 Node 跑，接真的 MCP 服务；嵌套测试里 `vm-check` 跑一个程序，经 MCP 服务查到数据库。
10. **historian**（2026-10-29 做完，10-30 删了，当天晚上改回按群的开关，见[摘要](#摘要)）：capture、`summary_runs`、`/compact`，当天挪到通用驱动器上，又拆回自己排。
11. ~~**重启恢复**~~：2026-10-29 删，重启时给宽限期再中断，见[重启](#重启)。
12. **媒体**（2026-10-29 开始）：v1 之后第一块，分六小步（10-29 加了发图和表情包库），见[媒体](#媒体)。第 1 小步当天做完、上了 tank，测试群里的一张图入账后半秒内下载好。第 2 小步当天做完：媒体句柄、条目里的图、两种协议的降级、附图；owner 定了不支持看不了图的模型。
13. **网页搜索**（2026-10-29 做完，插在媒体第 1 小步之后）：`web_search` 和 VM 里的 `webread`，见[网页搜索](#网页搜索)。
14. **导入**（2026-10-29 做完）：`max-import`，先导进临时库演练，再停机约 12 分钟正式导入，见[导入](#导入)。网关的 Resume 信息在被换掉的库里，停机期间群里的消息没补发过来。

## 上线：drop-in 替换的条件

- [功能对齐清单](#功能对齐清单)全部完成。
- 写一个数据导入程序，把 Haskell 版数据库一次性导入新 schema，映射见 [schema 的导入](#导入)。它要能重复跑，上线前先演练。
- NixOS module 的接口不保持兼容，tank 的 nix-config 跟着改，见[配置](#配置)。
- 测试期间新版在 tank 上叫 `maxx`，和 Haskell 版并行（见[测试环境](#测试环境)）。上线时停掉 Haskell 版的 `max` 那一套，由新版替换；名字是 module 的参数，改回 `max` 只动一处。
- Haskell 版各群 VM 的 `/work` 迁到新版，见[导入](#导入)。
- 切换：在 `maxx` 分支上 `git merge -s ours main`，保留 main 期间的 Haskell 历史、内容全部用 Rust 的；然后 main 快进到 `maxx`，不 force push。main 最后一个 Haskell 提交打 tag `haskell-final`。
- 回滚：Haskell 版保留到 Rust 版稳定为止；Rust 版上线后产生的新数据怎么处理 **待定**。

## 调研：DSH 和 qq-bridge

2026-10-28 记。只是记录，不是待办；后来采纳和否决的在条目里注明。

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）是 DeepSeek 2026 年 8 月开源的 agent harness。QQ 上流行的是社区插件 [qq-bridge](https://github.com/Derpyu520/qq-bridge)：走 OneBot v11，每个群一个只追加的 DSH 会话，主打"AI 仿真群友"。腾讯官方的 [dsh-qqbot](https://github.com/tencent-connect/dsh-qqbot) 被 @ 才回，群聊上没有设计。

**机制和 Max 相反，不借。** qq-bridge 里模型的文本只算思考，说话要调 `qq_send_message`；什么时候醒、读到哪、下次怎么叫醒，都由模型调工具自己管（`qq_wait_for_messages` 长轮询、`qq_mark_read`、`qq_set_wake_config`）。为了补模型的健忘，又加了防"永眠"的提醒和潜水前强制观察 5 分钟的闸门；每次唤醒往一个从不重新投影的会话里追加三到六千字状态。Max 由 actor 驱动核心，空闲窗口、intent 判定和重新投影做的是同一件事。它的模型太爱潜水，Max 的判定器是拿不准就不说，方向也相反。

可能有用的做法，按在 Max 里的位置记：

- **"没说完"去抖**（`src/v2-wait.js`）：触发消息以"但是、然后、我跟你讲、对了"这类词或"，、；："结尾，或者同一个人 15 秒内连发 3 条以上，先等 8～12 秒没人说话再回。**已采纳**（2026-10-28），在 [intent](#intent) 的规则层。
- **时间感**（`src/bridge.js` 的 `buildTimeSenseLine`）：一行"现在几点、最新一条是多久前发的"，加三档规则：10 分钟内正常接；2 小时内别用"刚"这类实时口气；更久默认不回，要回先说"才看到"。起因是模型睡了几十分钟被叫醒，还把旧消息当成刚发的。**否决**（2026-10-28）：qq-bridge 的问题出在模型自己管睡眠；Max 入账就处理，每条消息又都带着时间，模型自己会判断。
- **参与度**（`src/bridge.js` 的 `formatParticipationV2`）：确定性算出"你近 1 小时发言 N 次，群友 M 条，近 5 分钟 K 条、P 人"，附一句"这轮少说"或"别一个人撑场"。2026-10-28 采纳过，做成 intent 分类输入里的"本群情况"；10-29 随 intent 精简删掉，见 [intent](#intent)。
- **人设文案**（`dsh/agent-presets/qq-chat-v2/agent.cordis.yml`、`roles/小鲸鱼.md`）：一份"AI 味黑名单"（"首先、其次"、"希望对你有帮助"、"你们觉得呢"、每句都加"～"）配正反例；不当主持人（不总结话题、不劝架、不挨个回应）；潜水回来别假装一直在场；同一个人反复说同一件事，之后只接情绪；刚说完别马上补一条。和 Rust 无关，可以先在 Haskell 版的提示词上试。
- **主动插话的反馈**：intent 触发的发言之后几分钟内，有没有人回复、引用或 @ Max，按群算成功率，用来调冷却，或者喂给判定器。2026-10-28 采纳过，就是 intent 的接住率；10-29 删掉。
- **记忆标来源**（[dsh-qq-bot-playbook](https://github.com/rentaoyan0628-collab/dsh-qq-bot-playbook) 第 07 篇）：分"对方说的"和"模型判断的"。还要在人设里写清什么时候该记：他们跑了两天，存了 1477 条原文，经历只记下 2 条。
- **出站拦 secret**：发出去的内容含凭据、token 就拦。在 Max 里是 actor 入账 `Said` 前按已知的 secret 值过滤，VM 里的程序拿得到 MCP token。

不借的：装傻和已读乱回、好感度数值、`reply_gate` 工具（`[silence]` 已经等价）、一代按空格分句。

## 调研：判断模型

2026-10-28 记。只是记录，不是待办。

[Jev](https://docs.typesafe.ai/models)（TypeSafe AI，2026-09）是不自回归的判断模型：是非、选择、打分三种题，直接给概率；每百万输入 token $0.042，输出免费；只有美国的托管 API，闭源；官方说英文最好，中日韩能用但弱一些。

暂不用它替代 intent 的小模型：

- 省的钱不在瓶颈上。现在的小模型跑在自己的机器上，没有按次的费用；花钱的是误触发，每次白跑一个前沿模型的 turn。Haskell 版 7 月两天的日志：约 7,500 条没点名的消息，分类 2,051 次，触发 77 次。
- 中文多人群聊上没有任何公开证据；英文测试里加了注入后判决翻转 22%，被测的评审模型里最高（[Braintrust](https://www.braintrust.dev/evals/jev-vs-gpt-eval-judges)）。
- 每条闲聊都要发给一家美国公司；版本 30～60 天弃用，每次升级都要重评、重定阈值。

可能有用的：

- 小模型改读标签的 logprob（llama.cpp 的 `n_probs`），直接拿概率、设阈值，比生成 JSON 快得多；代价是没有 `reason`，判定那一行少了说明。
- 评测集从 ledger 里建：真正 @ 或回复 Max 的消息去掉 @ 和引用，是"没打 @ 的点名"正例；判定触发后主模型回 `[silence]` 是弱负例，之后有人 `/proactive off` 或叫它闭嘴是强负例；再人工抽几百条难例。评测集是真实群聊，不进公开仓库。有了评测集，可以花几美分离线测一次 Jev。
- 标签里最值的是"在不在跟 Max 说话"、"是不是在等 Max 回应"、"是不是嫌 Max 烦"；最后一个做过 intent 的 `dismiss`，10-29 删掉，现在只写在分类提示词里。话题切换、值不值得记、情感、垃圾和注入检测不值得逐条判。

## 待讨论

1. ~~代码放在哪~~：已定（2026-10-27），放在这个仓库的 `maxx` 分支，见文首。
2. ~~初始 crate 划分~~：已定（2026-10-27），见 [crate 划分](#crate-划分)。
3. ~~v1 带不带工具~~：已定（2026-10-27），带，见[工具和 codemode](#工具和-codemode)。intent 分类也进 v1，见 [intent](#intent)。
4. ~~新 schema 的设计，以及从旧库导入的映射~~：已定（2026-10-27），见 [schema](#schema)。
5. ~~NixOS module 的接口要不要保持不变~~：已定（2026-10-27），不保持，见[配置](#配置)。
6. ~~Matrix 加密房间要不要支持~~：已定（2026-10-27），支持；10-29 Matrix 整个先不做，见 [Matrix](#matrix)。
7. ~~v1 的测试环境~~：已定（2026-10-27），并行的 `maxx` 一套服务，见[测试环境](#测试环境)。
8. ~~Rust 工具链版本和 edition~~：已定（2026-10-27），stable 钉版本、edition 2024，见[工具链](#工具链)。
9. ~~每个提交的大小上限~~：已定（2026-10-27），见[审阅性约束](#审阅性约束)。
10. [数据和运行模型](#数据和运行模型)一节末尾的待定项：保留期、崩溃时丢掉的 turn 要不要通知。基础上下文的存法和裁剪规则已定，不再恢复挂起的 turn。
11. ~~身份模型~~：已定（2026-10-27），见[身份](#身份)。跨平台合并和镜像一起做。
12. [工具和 codemode](#工具和-codemode) 一节末尾的待定项：v1 开放哪几个 Max 工具、图片预算、代码转义。调 VM 已定用 russh。
