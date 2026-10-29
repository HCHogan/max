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
- 自写的 agent loop，带工具（2026-10-27 定）：纯 codemode 加一个 `shell`，都跑在群 VM 里，见[工具和 codemode](#工具和-codemode)。所以 v1 也要带上 VM 沙箱和 MCP 服务。第一个开放的 Max 工具是读全文的 `context_read`，见[后续输入](#后续输入)；其它开放哪几个 **待定**。
- 上下文投影：摘要块、原始尾巴、易变块，见[上下文投影](#上下文投影)。historian 进 v1（2026-10-28 定）。
- 重启：正在跑的 turn 给一段宽限期，到期就中断，回一句话（2026-10-29 改，原来是挂起、重启后接着跑），见[重启](#重启)。
- 配置、日志、优雅关闭。

不包含，但上线前都要做：镜像、浏览器、记忆和召回、后台 agent、自动化、媒体、admin。

### 有意删除的功能

- iMessage
- WeChat hook
- NapCat 和 OneBot（2026-10-28 删）：QQ 改用官方机器人接口，见 [QQ 官方机器人](#qq-官方机器人)。
- reaction 和戳一戳（2026-10-28 删）：官方接口没有。包括处理中、失败时挂的表情，`[silence:表情名]` 回表情，以及收别人的 reaction 和戳一戳。
- 把表格和代码块渲染成图片（typst、codesnap，2026-10-29 删）：QQ 的原生 Markdown 能显示代码块、表格和公式。
- Max 发表情、表情包和图片（2026-10-29 删）：Max 只写文字和提及。QQ 官方接口发不出小黄脸；表情包和图片要媒体，v1 本来也不做。收到的表情照样给模型看，见[回复的写法](#回复的写法)。
- Matrix 和镜像（2026-10-29 定，先不做）：见 [Matrix](#matrix)。镜像本来是 QQ 群和 Matrix 房间之间的，跟着一起搁置。
- `/uncompact`（2026-10-28 删）：摘要是自动的，手动撤回的部分迟早又被自动压回去，语义别扭。
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
| Background agents and feedback | — | pi + MCP，见[后台 agent](#后台-agent) |
| Prompt shape and budget | 部分 | 见[上下文投影](#上下文投影) |
| Memory | — | |
| Group lingo | — | |
| Unified recall and vector search | — | |
| Context operations | — | |
| LLM profiles | ✓ | |
| Streaming | ✓ | |
| Share cards | — | |
| Images | — | 工具结果里的图片见[多模态结果](#多模态结果) |
| Group awareness | — | |
| Moderation (QQ groups) | — | |
| Browser | — | camoufox 搬进群 VM，见[浏览器](#浏览器) |
| Replies | ✓ | QQ 一律发原生 Markdown，表格和代码块不再渲染成图片，见 [QQ 官方机器人](#qq-官方机器人)；Max 不再发表情、表情包和图片，见[回复的写法](#回复的写法) |
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
| 浏览器 | camoufox（Playwright server 模式） | 跑在群 VM 里，见[浏览器](#浏览器) |
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
historian = { model = "cliproxy/gpt-5.6-luna", effort = "medium" }

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
- 数据导入要做名字映射：会话选过的 profile 名、`llm_usage` 里记录的 profile，都换成"模型加强度"。比如 `gpt-5.6-luna-medium` 映射为 `cliproxy/gpt-5.6-luna` 加 `effort = "medium"`。

v1 只定义它用得到的几节：database、`platforms.qq`、llm，加上顶层的 `owners_file`、`utc_offset` 和 `log`。intent 没有配置项（2026-10-29 删了 `[intent]` 一节），见 [intent](#intent)。其它节跟着对应功能一起加。

## 运行时结构

任务树、各个 actor 之间的信箱和一次运行的事件顺序见图：<https://claude.ai/artifact/KrciskAXJfMF2qTHF6hDbW>

任务之间只有两种关系：父子（谁拥有、谁负责关掉）和信箱（谁给谁发什么）。

- root scope 下有两个子 scope：
  - services：常驻任务。平台连接（QQ 的网关连接）、平台 sender、VM 服务、MCP 服务、派生数据 worker，以后的自动化调度器。见[三种角色](#三种角色)。
  - conversations：会话表，和每个会话一个 actor。会话表按端点找到会话的 actor，没有就建会话、起 actor；没绑定的群直接丢掉，见[运行流程](#运行流程)第 1 步。actor 起来以后一直在，不按空闲退出。
- 会话 actor 是这个会话唯一的控制线程，见[会话 actor](#会话-actor)。它的信箱是这个会话所有事件的唯一入口，它自己只 await 数据库。它下面挂三个 scope：
  - `io`：当前核心在途的模型调用和工具调用（`run_code`、`shell`）。每个核心一个，核心结束时（`/kill`、失败、重启的宽限期到期）整个关掉。
  - `side`：intent 分类这类不属于核心的调用。
  - `jobs`：后台 agent（v1 之后），能比发起它的核心活得长。
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
2. **派生数据 worker**：historian、lingo、embedding、caption、媒体下载和转发展开、记忆到期。输入是 ledger 或另一张派生表，输出是自己独占的一张表，只有它一个写者；从不碰 ledger 和 turn 记录，结果只在投影时被读。读 ledger 的 cursor 按会话记，见[时间线](#时间线)。触发三种：入账通知、定时器或水位、启动和定期的缺口扫描。一个工作单元一个事务，失败记退避，不留半截；重启不存队列，靠扫描补。Haskell 版 9 月的简化最后也把这几个收敛成了"本地有界队列加缺数据扫描"。差别只在单元粒度：historian 和 lingo 是一段消息，embedding 一行，caption 一个文件，下载一个附件。写成一个框架，各 worker 只填三个函数：

   ```rust
   trait Derivation {
       type Input;                                    // 入账的一行；caption 是下载 worker 交来的 sha256
       type Unit: Clone + Eq + Hash;                  // 也是去重的键：排着的不再加，在跑的跑完再来一次
       fn on_input(&self, input: Self::Input) -> Vec<(Self::Unit, Wait)>; // 不做 I/O
       fn conversation(&self, unit: &Self::Unit) -> Option<ConversationId> { None } // 同一会话的一次一个
       async fn scan(&self) -> Result<Vec<Self::Unit>>;             // 启动和定期：按自己的输出表找缺的
       async fn run(&self, unit: &Self::Unit, attempt: Attempt) -> Result<()>; // 一个事务，可重入
   }

   enum Wait { Now, Urgent, Throttle(Duration), Debounce(Duration) }
   ```

   驱动器通用（2026-10-29 照下载和 caption 两个实例定）：每个 worker 一个常量的 `Policy`（名字、并发数、每次尝试的超时、重试前等多久、多久重扫一次），自己的 `Scope`，按单元去重，重试用 `sleep_until` 等最早的那个。`Wait` 说单元什么时候跑：`Now` 排队；`Urgent` 插到最前、不占并发数，有人在等它，比如 `/compact`；`Throttle` 从第一个输入算起，期间的输入不改时间，比如 historian 一分钟一次的压力检查；`Debounce` 从最后一个输入算起，比如安静了才写的摘要。单元在跑的时候又来了，跑完再排一次，来几次都只一次。`conversation` 给了会话的单元，同一会话一次只跑一个：historian 是 `summaries` 唯一的写者，两次 capture 同时跑会盖同一段。重试用完就放弃，只记日志；`Attempt` 告诉 `run` 是不是最后一次，caption 最后一次失败时写空的 caption。关机时在跑的单元直接 drop，事务回滚，下次启动由扫描补。入账通知是会话 actor 提交之后同步发的：`Shared` 里一组无界 mpsc，每个 worker 一个，不用 broadcast，它落后了会丢通知。不像 Haskell 版用 `message_projections` 的标志位当队列。不要：持久化的队列、失败表和重试次数列、租约、`LISTEN/NOTIFY`、配置里的策略旋钮。

   historian 比这个框架早，10-29 挪了上来（owner 选的），见 [historian](#historian)；`/compact` 要往同一个邮箱里放，所以订阅入账通知时，邮箱的类型由 worker 定，从入账的一行转换过来。lingo 来了直接填这几个函数。
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
   - 浏览器：runner 被杀时，它到 Playwright server 的连接断开，它开的 browser context 跟着关掉。做浏览器时实测。
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
   - 核心等于对自己快照的重放；
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
| 派生数据 worker | 驱动器里一处：每次尝试一个 `timeout`，重试前一个 `sleep_until`，重扫一个 interval，数值是各 worker 的常量 `Policy`（下载 60 秒、重试前等 1 秒和 4 秒；historian 11 分钟、重试前等 10 分钟）；下载的 HTTP 客户端另有 10 秒的连接超时和 60 秒的整体超时 | 防卡死；重试和重扫是策略 |
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
3. **存输入，不存派生结果。** 核心的序列化就是它的输入日志，transcript 这些派生状态不存。核心合成的东西（比如中断时补的"已取消"结果）也不存，重放时再合成一次。唯一的例外是结局，见 [turn 记录](#turn-记录)。
4. **只有一条代码路径。** 核心的每个输入方法都是"构造一条输入，再 apply"，重放就是对日志逐条 apply。
5. **核心跑的时候不碰库。** 一次运行只写两回：开始时写一个标记；结束时，把核心整个存成一份快照。崩溃时正在跑的 turn 记为 `Lost`，见[重启](#重启)。
6. **上下文只在核心里变。** 基础上下文在创建核心时传入，之后不变；transcript 只追加；裁剪只作用在每次的请求上；协议适配层降级时只删不加。
7. **别处已有的存引用，只在 turn 里有的存本体。** ledger 消息和媒体文件存引用；推理 blob、工具输出和基础上下文存本体。
8. **中立格式，原始数据透传，只在边缘降级。** 平台消息和模型条目用同一种做法：中间是中立的类型化结构，平台或 provider 的原始数据原样带着，有损转换只发生在适配器往外发的那一步。见[消息格式](#消息格式)和[条目](#条目)。
9. **一个会话一条时间线，一个写者。** 会话 actor 逐条入账，其它一切都在时间线的某个位置上读，见[时间线](#时间线)。

### ledger

ledger 是会话账本：所有平台上、所有人（包括 Max 自己）说过的每一条消息，统一成同一种[消息格式](#消息格式)，只追加。一个会话的消息按会话 actor 入账的顺序排，就是这个会话的[时间线](#时间线)。它回答"群里发生了什么"。

- 每条消息：会话、发送者、内容、原始 payload、平台 id、序号、时间。Max 发出的消息的平台 id 不在这里，在 `deliveries`，见[出站](#出站)。
- Max 发出的每一段消息额外带 turn id 和段号。

Max 在幕后做的事（模型怎么想、调了什么工具）不进 ledger。ledger 和 turn 之间只有三处引用：Max 发出的消息指向产生它的 turn；turn 指向触发它的消息；后续输入引用对应的消息。以后 turn 的基础上下文从 ledger（加上记忆和摘要）投影出来，不读别的 turn 的 transcript，见[上下文投影](#上下文投影)。

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
- 占位符只有一种写法 `[类型#id]`，后面可以带 `: 描述` 和紧跟的 `(属性)`，都只认 id（2026-10-28 改，沿用 Haskell 版 2026-08 统一后的写法）。原来的 `[↩#id]`、`[@#N]` 是符号，`[撤回了 #id]` 这类是句子，模型会照着说出来；`[unsend#id]` 不会。
- 段首的 `[reply#id]`：这一段回复那条消息；一段里有几个时取第一个，全部去掉。号码无效时怎么办见[解析和发送](#解析和发送)。
- `[mention#N]`：提及一个人，解析规则见[解析和发送](#解析和发送)。
- Max 只写文字和提及（2026-10-29 定）。QQ 官方接口发不出小黄脸，见 [QQ 官方机器人](#qq-官方机器人)；表情包和图片要媒体，v1 不做。模型照着历史写出 `[face#id]`、`[sticker#id]`、`[image#id.序号]`，或者只读的 `[face: 名字]` 这类显示形式，分段器认出来直接去掉，免得原样漏进群里。收到的表情给模型看是 `[face: 名字]`。
- 整个输出为空，或者只有 `[silence]`，就什么都不发。段首的引用不影响判断。一段里还有别的内容时，`[silence]` 直接去掉。旧提示词教过的 `[silence:表情名]`（给消息回一个表情）当成 `[silence]`：reaction 不做了，见[有意删除的功能](#有意删除的功能)。
- 模型偶尔把工具调用写进正文，比如 `[find_stickers query="无语"]`：方括号里是英文标识符、空白，再带 `=` 或引号的，去掉。代码块里的不动。
- 分段器是唯一把模型文本变成消息的地方，进度旁白也走它。Haskell 版的教训：每一个自己另写"文本转消息"的发送路径，最后都把 `[split]` 或 `[reply#id]` 原样漏进了群里。
- 切分只看文本，不看流式到达的时机：同一段输出，流式和一次给出切出来的消息完全相同。Haskell 版流式时还会在长段落的句末提前放出一部分，结果取决于时机，这里不做。

### 出站

2026-10-28 定。Max 的话**说出口就入账**：模型调用任务里的分段器切出一段，作为 `Said` 交给会话 actor；actor 入账，再交给平台 sender，不等平台回执。工具发的图和文件、撤回、禁言这些动作也一样，先入账再发。所以时间线上 Max 的话和别人的消息谁先谁后，按 Max 的视角排，平台上落地的先后可能相反；但新核心的尾巴一定看得到旧核心说过的话。

- **平台 sender**：每个平台一个常驻任务。同一个会话的东西按入账顺序串行发，不同会话之间并发。撤回 Max 自己的消息、回复它刚说的话，一定排在那条消息的发送后面，轮到时平台 id 已经有了。
- **`deliveries` 表**：每次发送的结果一行：消息、端点、平台 id 或错误、时间。sender 是唯一的写者，只追加。镜像时一条消息每个端点一行，用的也是这张表。
- **平台 id 查 `#id`**：入站消息的平台 id 在 `messages`，Max 发出的在 `deliveries`。有人回复或撤回 Max 的消息，actor 入账时查这两处；查不到就按文本兜底。
- **发不出去**：`deliveries` 记一行错误，投影时这条消息后面标"（没发出去）"，下一个核心的模型看得到。不回报给正在跑的核心：一个 turn 里接连发不出去，通常是平台断了，模型知道了也做不了什么。
- **崩溃**：入账了但没有回执的消息，sender 启动时先补记成"结果未知"，投影时标"（可能没发出去）"。不重发，免得发两遍。
- **echo**：平台把 Max 自己发的东西再推回来的，适配器直接丢掉。QQ 的网关不推机器人自己发的消息，没有 echo；以后接的平台要是会推回来，发送时带上 `max-<消息 id>` 这类 id，适配器按它认出来。Max 自己的动作，平台通知如果还会推回来，actor 入账前看时间线上是不是已经有这次动作，有就不记。不是这个进程发的（比如有人拿 Max 的账号手动发），照常入账，发送者是 Max。
- **经 `Post` 发**：不是模型文本输出的发送，都给目标会话的 actor 发 `Post`，由它入账：程序里调工具发消息或撤回禁言（本群或别的群）、以后的自动化。命令的文字输出不经 `Post`：actor 自己入账，就在命令所在的会话里，不引用那条命令（2026-10-29 改：原来提议发到发令人的私聊，后来引用命令，owner 觉得多余）。QQ 没法从群成员的 `member_openid` 找到这个人私聊的 `user_openid`，私聊也只有体验用户进得来。要知道发没发成的（比如工具），`Post` 带一个回信通道，actor 把它交给 sender，sender 记完 `deliveries` 后回信；actor 自己不等。
  - `Post` 带来源 turn `origin: Option<TurnId>`（2026-10-28 定）。MCP 服务从会话里取，命令输出和调度器的为空。actor 入账时把它记成这条消息的 `turn_id`。`origin` 是自己当前核心的 turn 就不喂给核心：`run_code` 结果里内部调用的摘要已经有了，再喂一次模型会看到两遍。别的 turn 发来的，比如群 A 的 turn 往群 B 说一句，照常喂给 B 的核心。

### turn 记录

一次连续的运行是一个 turn：从一个触发起核心开始，到空闲窗口到期、`/kill`、失败或重启为止，中间吸收的触发都是它的输入（2026-10-27 改成单一核心实例，见[会话 actor](#会话-actor)）。turn 在库里有三种记录，全部只追加（2026-10-27 定，10-29 去掉了恢复用的 `TurnResumed`）：

```rust
// 触发起核心时。身份、触发和首次开始合在一条里（2026-10-27 合并了原来的 TurnAccepted）
struct TurnStarted { turn, conversation, ordinal /* t#，给模型引用 */, trigger /* intent 的 Wake，以后还有 job 结果、自动化 */, from /* 快照位置，见“时间线” */, started_at }
// turn 结束时，把核心整个存下来
struct TurnSnapshot { turn, run: RunRecord, taken_at }
// 结局
struct TurnFinished { turn, outcome: Outcome, finished_at }

// 核心的序列化：只有输入。反序列化就是重放
struct RunRecord { core_version, spec: RunSpec, base: Context, first: Vec<Input>, inputs: Vec<Input> }

enum Input {
    CalledModel,                                     // 核心开始一次模型调用（next_step 返回 CallModel）
    RanTools,                                        // 核心开始上一次输出里的工具批次
    ModelOutput(ModelOutput),                        // 见"条目"
    PartialOutput { text: String, tokens: u32 },     // 模型流到一半被打断时，已经发出去的文本；可以为空
    ToolResult { call: CallId, output: ToolOutput },
    Messages { ids: Vec<MessageId>, item: Item, people: Vec<PrincipalId> }, // 时间线上的新消息和事件，引用 ledger，同时存核心看到的样子；people 是第一次出现的人
    Wake(Wake),
    Interrupt { reason: String },
    Fail { reason: FailReason },
    // 以后：JobResult { job, item }（job 只在内存里，报告正文只有这里有）、AutomationFire { fire, item }
}

struct Wake {
    ids: Vec<MessageId>,          // 它涉及的消息，作废的 actor 已经滤掉了
    reason: Reason,
    item: Option<Item>,           // 给模型看的判定行；直接触发为空，消息行上已经标着
}

enum Outcome { Answered, Silent, Interrupted, Failed(FailReason), Lost }
enum FailReason { Model { error: String }, ContextExhausted }
```

写入时机：

| 情况 | 写什么 |
|---|---|
| 触发起核心 | `TurnStarted` |
| turn 结束，包括重启时被中断 | `TurnSnapshot` 加 `TurnFinished`，同一个事务 |
| 崩溃 | 什么都没写，启动时补一条 `Lost` 结局 |

- **trigger 记在 `TurnStarted` 里**：直接触发可以从消息本身重新判断，但判定、去抖合并了哪几条、自动化触发都不行。单一核心实例之后，触发来了就立刻起核心，"接受了但没起"这个状态不存在，所以不再单独记一条。
- **一个 turn 一份快照**：结束时和结局在同一个事务里写。核心不在运行中途写库，所以也没有"库里一份、内存里一份"的问题。
- **状态**：有 `TurnFinished` 就是已结束；没有就是在当前进程里跑着，启动时看到这种，就是崩溃时正在跑。
- **结局**：唯一存下来的派生结果。`Answered` 和 `Silent` 只说这次运行有没有发过话。它本来也能从输入推出来，但查"哪些 turn 没结束"要靠它，所以写下来；重放时校验它和核心算出来的一致。`Lost` 例外，它由启动流程直接写，表示崩溃时它正在跑，没有快照。
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
- **推理只属于本 turn**：它在核心的 transcript 里，随 `ModelOutput` 进快照；不进 ledger，不进以后 turn 的基础上下文，不发到群里，也不让 `context_read` 这类工具读到。
- 流到一半被打断的推理不存，不完整的 blob 没用。

### 核心

自写，sans-I/O（2026-10-26 定）。2026-10 调研过 rig、yoagent、adk-rust、autoagents、swiftide-agents、aisdk、genai，以及 pi-agent（第三方的 Rust 移植，官方仓库里没有这份代码）。它们的共同问题是自带 provider 层或 session 层，和我们自己的协议适配、ledger 冲突；体量也远大于我们要用的部分：rig-core 加 rig-agent 约 13 万行，yoagent 约 3.9 万行。自写预计 1.2k–1.5k 行，包含两种协议的适配。借鉴两处：rig-agent 的 `AgentRun`，把 loop 写成 sans-I/O 状态机；pi 和 yoagent 的 steer 语义。

核心是纯状态机：方法都是同步的，每次调用是一次完整的状态转移；不 `await`、不 spawn、不读时钟、不碰网络。草图，签名 **待定**：

```rust
struct Run {
    spec: RunSpec,            // 不变：模型档、窗口、输出上限、这个 turn 能用的 Max 工具
    base: Context,            // 不变：基础上下文的条目和名册，第一批输入在它的易变块里
    first: Vec<Input>,        // 第一批输入；已经渲染在 base 里，留着是为了算 unhandled
    log: Vec<Input>,          // 喂过的所有输入
    transcript: Vec<Item>,    // 本 turn 产生的条目，只追加
    pending: Vec<Input>,      // 攒下的消息和 Wake，下一次调模型时渲染成一个 [新消息] 块
    in_flight: InFlight,      // 模型调用、工具批次，或者都没有
    due: Vec<Call>,           // 上一次输出里格式正确、还没开始的工具调用
    outstanding: Vec<CallId>, // 已开始、还没回结果的
    model_due: bool,          // 开始时、工具结果回齐后、调用被打断后，没有触发也要调模型
    measured: Option<(u32, usize)>, // provider 报的上一次请求加输出的 token 数，以及它覆盖到 transcript 的哪里
    handled: Option<usize>,   // 核心最近一次变空闲时 log 的长度：这之前交进来的都处理完了
    roster: BTreeSet<PrincipalId>, // base 的名册，加上之后给模型看过的新人
    // 以及 ended、round
}

enum Step {
    CallModel(Request),       // 请求由核心完整构造，之后不再改动：条目、两个工具、输出上限、名册
    RunTools(Vec<Call>),      // 已经解析成 run_code 或 shell 的调用
    Idle,                     // 没有在途的，也没有该做的；等还是结束由 actor 定
}

impl Run {
    fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self;
    fn replay(record: &RunRecord) -> Result<Self, ReplayError>; // 核心版本不同、某条输入对不上状态，都是错误
    fn snapshot(&self) -> RunRecord;
    fn busy(&self) -> bool;                         // 有模型调用或工具在途；actor 只在它为假时问 next_step
    fn next_step(&mut self) -> Step;                // 开始调用或批次时记一条 CalledModel 或 RanTools
    fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected>;
    fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected>;
    fn tool_result(&mut self, call: CallId, out: ToolOutput) -> Result<(), Rejected>;
    fn input(&mut self, input: Input) -> Result<(), Rejected>; // 只收 Messages 和 Wake，随时可塞，核心决定何时生效
    fn interrupt(&mut self, reason: String) -> Result<(), Rejected>;
    fn fail(&mut self, reason: FailReason) -> Result<(), Rejected>;
    fn at_limit(&self) -> bool;                     // transcript 加上攒着的输入超过上限，actor 在边界上结束核心
    fn unhandled(&self) -> Vec<Wake>;               // 没处理完的触发，失败或中断时找要回一句话的那条
    fn idle(&self) -> bool;                         // 没有在途的、没有该做的：现在结束不丢东西
    fn outcome(&self) -> Outcome;                   // 结束时由 actor 读取
}
```

- 和状态对不上的输入（没有模型调用在途时来的 `ModelOutput`、不认识的调用的结果、结束之后的任何输入）返回 `Rejected`，不应用、不进日志。
- **开始调用也是输入**（2026-10-28 定，写核心时发现）：模型调用在途时到的消息不属于这次请求。只有输出没有"开始"的话，重放分不清哪些输入是开始之后才到的，所以 `next_step` 开始模型调用或工具批次时各记一条 `CalledModel`、`RanTools`，重放到这里做同样的事。"构造一条输入再 apply"的原则照旧。

核心负责的规则：

- **构造请求**：请求由基础上下文、transcript 和固定的两个工具组成，不裁剪（2026-10-28 定）。单条输入和工具结果各有上限（见[后续输入](#后续输入)），整体大小由下面的上限控制，撞上限就结束这次运行，请求不会超出窗口。唯一的例外是图片，超出视觉预算时省略较早的，见[多模态结果](#多模态结果)。
- **工具**：`run_code` 和 `shell`，固定不变。程序能调哪些 Max 工具由 spec 定，整个 turn 不变，加载 skill 也不改变它，见[纯 codemode](#纯-codemode)。格式不对的调用直接回错误结果，不交给 actor 执行。
- **token 数是数据**（2026-10-28 定）：核心不估算 token。基础上下文、每条输入、每个工具结果，都带着 `max` 估算好的 token 数进来；模型输出用 provider 返回的用量。算大小时以上一次请求 provider 报的输入 token 为准，再加上之后新增的条目，估算误差只落在这段增量上。数存在输入里，换了分词器也不影响重放。
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
3. **开始 turn**：快照位置 `from = head`。从 ledger（只读 `id <= from`）加上记忆和摘要，投影出基础上下文，裁到预算内，见[上下文投影](#上下文投影)；第一批输入在易变块里：叫醒它的触发，`Wake` 带着它涉及的消息（去抖时是同一个人的几条）。其它消息都在尾巴里。写 `TurnStarted`（带 trigger 和 `from`），调 `Run::new(spec, base, first)`。第一批就超过核心的上限（见[核心](#核心)的"轮数和 token 上限"），核心一起来就撞上限，记 `Failed(ContextExhausted)`，引用触发回一句（2026-10-29 改，原来是不起核心，单独记 `InputTooLarge`）。
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
    turns::finish(&mut conn, a.turn, &a.run.snapshot(), &a.run.outcome(), now).await?; // 快照加结局，一个事务
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

启动时，每个没有结局的 turn 都记 `Lost`：正常重启不会留下没有结局的 turn，剩下的只能是崩溃时正在跑的。它已经发出去的消息还在 ledger 里，靠 turn id 能找到。每个会话的 `seen` 从当时的 `head` 开始，intent 的状态从空开始。

QQ 的网关跨重启 Resume：重启那段时间群里说的话由服务端补发，照常入账、照常经过 intent，所以停机期间 @ Max 的人照样有人回，见 [QQ 官方机器人](#qq-官方机器人)。要再问一次的只有停机那一刻正在回的那条。

崩溃时丢掉的 turn 要不要在群里说一声 **待定**：可以在启动后根据 `Lost` 补发。

### 体积和保留期

- **体积**：推理 blob 每条几 KB 到几十 KB，而且压不小；一个 turn 跑几十轮，大约几百 KB 到几 MB，核心上限给它封了顶。v1 都存在快照的 JSONB 里，交给 Postgres 的 TOAST。以后体积成问题，再把超过阈值的内容统一挪到一张按 sha256 寻址的 blob 表，工具输出和基础上下文同样适用。
- **保留期**：turn 结束 N 天后，清掉快照里的 `opaque` 和基础上下文，保留可读文本和 token 数。之后这个 turn 还能查看，但不能再精确重放。N **待定**。

### 核心和 actor 的测试

- 核心和 intent 用同步单元测试，按剧本喂输入、检查输出，不需要 tokio 和 fake provider；intent 的时间由测试传入。intent 至少覆盖：直接触发立刻叫醒、去抖合并同一个人的几条、攒批、每小时上限和 `/proactive`。核心至少覆盖：输入的送达时机、只有闲聊不调模型、中断时补齐结果、格式不对的工具调用、轮数和 transcript 上限、失败时哪些触发算没处理完。
- 每个核心测试结束时断言 `run == Run::replay(&run.snapshot())`，保证线上路径和重放路径一致。
- 会话 actor 用真的数据库（`#[sqlx::test]`）、剧本模型和只记录的 sender，测取消、停止和它的宽限期、空闲窗口、撞上限、过期事件和 `seen` 对 `Wake` 的过滤；在任意两个事件之间插 `/kill` 的遍历见 [cancellation safety](#cancellation-safety)。2026-10-29 改：actor 测试用真实时间，不用 `start_paused`。actor 在等 Postgres 的时候，暂停的时钟会自动跳到下一个到期时间，空闲窗口和去抖就提前到了。所以测试里的等待都很短，而且有上限；纯时间的逻辑（intent、sender 的额度）照样用 `start_paused`。
- 协议适配层用录下来的 Responses 和 Chat 响应做 fixture，测推理条目和不透明字段原样往返。
- 快照就是核心的输入序列，线上任何一次 turn 都能离线精确复现。

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

2026-10-27 定。参考了 [magic-context](https://github.com/cortexkit/magic-context) 的设计，取了四样：compartment 写一次、几层固定；importance 是衰减率；衰减曲线是确定性的，按序位算、不按墙钟；只在缓存本来就冷的时候发布。没有取它的 tag、`ctx_reduce`、caveman、m[0]/m[1] 那一套，那些是管单会话里跨 turn 堆积的工具输出的；我们的工具输出只活在一个 turn 的 transcript 里，下一个 turn 从 ledger 重新投影，这个问题不存在。

Haskell 版的教训：原始尾巴是按 token 的滑动窗口，填满后每来一条消息就从头挤掉一条；摘要层级每轮按距今天数重算；caption 到了回头改旧行。三件事都让前缀缓存几乎每轮失效。historian 按 token 切段、一段一个摘要，不按话题。"上一轮做了什么"有四套机制（`[recent turns]`、续接摘要、`context_resume`、turn 内压缩），同一行消息有三种 token 算法。

### 请求布局

按变化频率排，每一块都在前一块之后：

1. system：人设、规则、Max 工具的 TypeScript 声明、skill 索引。按会话固定。
2. 工具：`run_code` 和 `shell`，固定不变。
3. 摘要块：活跃摘要按时间顺序，每条按[衰减](#衰减)选一层渲染。
4. 原始尾巴：最新一条活跃摘要之后、到快照位置 `from` 为止的所有消息（第一批里的除外），`[HH:MM 名字 #id]: 文本` 一行一条；换日插日期，间隔久了插间隔标记。Max 自己的消息和别人的一样是一行，发不出去的带标记，见[出站](#出站)。
5. 易变块：现在时间、[名册](#模型看到的)、记忆、引用的消息和转发、第一批输入（触发；闲聊不在这里，在尾巴里）、附图。

基础上下文就是这五块，由会话 actor 在创建核心前投影一次（[运行流程](#运行流程)第 3 步），之后不变；transcript 接在后面。它是（摘要集合，尾巴范围，预算）的确定函数，但只在这一处算，重放读快照里存的那份，所以快照里存渲染结果，不存配方（2026-10-27 定）。

### 后续输入

核心活着的时候，后来的输入在下一次调模型前渲染成一个 `[新消息]` 块，追加在 transcript 末尾，不动前缀：

- 消息行和尾巴同一种格式，触发的行标上"@你""回复你的 #123"，其它不标。第一次出现的人补一行名册。
- job 结果是 `[job#3 完成] …`，自动化是 `[自动化 m#2 触发] …`。
- **单条上限**（2026-10-27 定）：消息、job 结果、自动化结果共用一个上限，`min(C × 15%, 25k)` token，最低 2k；尾巴和第一批里的消息同样适用。超过的只渲染开头约 2,000 字，加一行"全文见 `#123`"，模型用读全文的工具 `context_read` 取，所以它是 v1 第一个开放的工具。它按页取，一页不超过单条上限，读一条超长消息不会一下把核心撑到上限。原文本来就在 ledger 或 job 记录里，不另存。VM 起不来时没有工具，模型只能看到摘录。`run_code` 和 `shell` 的结果也按这个上限截，全文写成 VM 里的文件，结果里给路径，下一次调用自己读。现在两个都先按字节截：超过 16 KiB 只留头尾各 8 KiB，全文在 `/work/.max/out/<unit>.txt`；`run_code` 的 console 输出另外截，全文在 `<unit>.log`。
- 参考（2026-10-27 查）：Claude Code 的 Bash 输出约 3 万字符、Read 每次 2.5 万 token；Codex 的工具输出 1 万 token；OpenCode 和 pi 2,000 行或 50 KiB；Gemini CLI 4 万字符；Hermes 每条 10 万字符，按窗口缩到 15%。超出时它们都把全文留着，给模型路径或句柄。用户自己发的内容基本都不截。
- **放不下就认输**：不按条数折叠。攒着的输入连同 transcript 超过核心的上限，就在这个边界结束这次运行，记 `ContextExhausted`，见[核心](#核心)和[运行流程](#运行流程)。
- 系统提示里说清：一批里可能有几件要回应，也可能都不用，不用就什么都不输出；回应多个人时各自 reply。

### 前缀稳定的规则

目标：两次发布之间，前四块逐字节相同。

- **尾巴的起点只在发布时移动。** 平时尾巴只增长。超过硬上限（高水位的两倍）才强制截断，那只在 historian 连续失败时发生；截断时一次截回低水位，不一条一条往外挤，否则又成了每来一条消息缓存就失效一次的滑动窗口。投影每次都从头算，不记上一次的起点，所以切点从最新一条摘要往后按固定的长度（硬上限减低水位）数，不从末尾往前数：起点在新消息进来时不动，尾巴再涨过硬上限才往后跳一段（2026-10-28 定）。
- **层级在发布时选定。** 衰减的三个输入（序位、importance、预算压力）都只在发布时变。`/model` 换了窗口会重算一次。
- **不等 caption。** 有什么渲染什么；caption 到了那一行就变，接受这一次失效。不阻塞。Haskell 版会轮询等媒体 worker，图片最多 30 秒、视频 60 秒。
- **一个会话同时只有一个 turn**，不需要藏起在途的触发消息。
- 变的东西都在易变块里。

### 预算

默认值按窗口 C 推，封顶；配置可改，数值在 v1 里调：

| 块 | 默认 |
|---|---|
| 尾巴高水位 | `min(C / 8, 32k)` |
| 尾巴低水位 | 高水位的一半 |
| 摘要块 | `min(C / 32, 8k)` |
| 记忆块 | 2k |

Haskell 版尾巴是 W/2，26 万的窗口上约 10 万 token 原始群聊，每轮都付。token 估算只有一个函数（tiktoken-rs，在 `max` 里），所有地方共用；核心只拿算好的数，见[核心](#核心)。

### historian

- **一个[派生数据 worker](#三种角色)**（2026-10-27 定；10-29 挪到 worker 驱动器上，owner 选的）：和会话 actor 没有共享状态。它的邮箱收每一行入账（只看群）和 `/compact`（带回信通道），token 数在 capture 时从库里算：读未覆盖的行，用和投影同一个渲染函数和估算函数，不在内存里累加。单元是哪个群、为什么写：群里入账一行，排一个压力检查（`Throttle` 一分钟）和一个安静检查（`Debounce` 十分钟）；`/compact` 是 `Urgent`。同一个群一次只跑一个 capture，`/compact` 只等这个群在跑的那个。同时最多 2 个，一次最多 11 分钟（两次模型调用各 5 分钟，加读和发布）。失败了这个群的这一种检查歇 10 分钟再试一次，再失败就放弃，等下一行入账；`/compact` 失败直接回错，不再试。`summaries` 只有它一个写者，所以不需要 cursor 表、staged 状态和 CAS。和主体共用的只有数据库、消息行的渲染函数、token 估算和 LLM 客户端；正在跑的 turn 从 `turns` 表查（未结束的 turn 的 `trigger` 里最早的消息），不问会话 actor。模型由 `[llm] historian = {model, effort}` 选；不配就不写摘要，尾巴只靠两倍高水位的硬截断。
- **水位按会话的主模型算**：会话设置的模型，没设或已不在配置里就用默认模型，和投影用的窗口一样。
- **触发**：
  - 安静：会话 10 分钟没入账，且可压的部分（未覆盖的减去低水位的尾巴）至少是低水位的一半。一段安静只看一次，再入账才重来。
  - 压力：入账后一分钟查一次，这一分钟里再入账不另排；未覆盖的超过高水位就压。
  - `/compact`。
  - 启动不扫：一个群重启后入账第一行就回到 historian 眼里，在那之前也没人读它的摘要。
- **范围**：从 cursor 往后，留出低水位的尾巴，一次最多 24k token（至少一行），更长的分几次。cursor 是最新一条活跃摘要的 `last_message_id`，和 `/clear --all` 的水位取大的，水位之前的消息不进提示，也就不用再压；不含正在跑的 turn 的触发消息及其之后的（capture 开始时查一次，之后开始的 turn 不管）。`/compact` 不留尾巴。
- **输入**：现在的时间；最近 4 条摘要的 p2（没有 p2 的用 p1）；这一段里的人，`[mention#N] 名字`，Max 标成"就是 Max"，因为 historian 自己不是 Max；这一段消息（和投影一样的行，带 `#id` 和时间）。记忆 v1 不做，所以没有现有记忆。
- **输出**：JSON，`compartments[{first, last, title, kind, importance, p1, p2, p3}]`，以及记忆提案（v1 不做）。边界由模型定，一段里可以有多个。kind 沿用 Haskell 的六种（max_interaction、ambient、mixed、decision、support、social），导入的摘要不用改。
- **校验**：按这一段的行序，一段接一段、不重叠、合起来覆盖整段；kind 在六种里；importance 1 到 100；title 40 字、p1 4000 字、p2 1500 字、p3 150 字以内，超了就算错，不截断。失败重试一次：答错了把它的答案和错在哪里一起给回去；调用本身失败就原样再调一次。
- **discard-last**：至少两个时丢掉最后一个，下次连着后文重读，因为它没有后文、边界不可靠。只有安静触发丢，`/compact` 和压力触发不丢。
- **发布**：一个事务写 `summaries` 和 `summary_runs`。每次模型调用都记一行 `summary_runs`，失败的也记，带错误；用量照常记在 `llm_usage`，purpose 是 historian。发布不影响正在跑的 turn，它的基础上下文已经固定；下一个 turn 投影时自然读到新摘要。关机时在途的 capture 直接 drop，事务回滚，什么都不留，下次重读。
- **私聊不写摘要。**

### 衰减

三层（2026-10-27 定）：p1 全文、p2 简述、p3 一行。写一次，不再改。p3 值得留：模型知道"10 月 3 日聊过 X"就能 `context_read` 展开。渲染时每条选一层，用 magic-context 的曲线：

```
H = 24 · 2^((importance − 50) / 25) / max(p, 0.1)
z = 序位 / H          序位从最新数起，最新是 0
z < Z1 → p1；z < Z2 → p2；z < Z3 → p3；否则归档
```

`p` 是预算压力：按压力 1 算出的总成本除以摘要块预算。成本用每条摘要各层实际的 token 数，不用平均值。阈值 Z 取相邻两层实测平均 token 的几何平均，要按我们自己的层重算；v1 先用 magic-context 的值（Z1 = 0.201、Z2 = 0.729，归档 2.587），我们的一行层占它的第三、四层。归档的不渲染，还能搜、还能 `context_read`。缺层的（导入的单摘要只有 p1）向上取最近的一层。

渲染：摘要块以 `[早先的聊天，摘要]` 开头，每条一个头 `[summary#45 2026-10-03 周六 14:02–16:30]`。p1、p2 在头后面接标题，下一行是正文；p3 只有头和那一行。易变块依次是 `[现在] 2026-10-28 周三 14:05`、`[上下文里的人]`、`[引用的消息]`、`[新消息]`（第一批），空的不出现。基础上下文是 system 加上每个非空块各一个条目。

### summaries 表

id、会话、`first_message_id`、`last_message_id`、`started_at`、`ended_at`（取自消息）、title、kind、importance（1–100）、p1、p2、p3、模型、`created_at`、status（active、superseded）、`superseded_by`。活跃的范围不重叠，用排他约束。模型句柄 `summary#<id>`。

### 命令

- `/compact`（群主、管理员）：立即 capture 到当前，尾巴留 0。会话 actor 不等 historian：它把请求交出去，在 `side` 里 spawn 一个小任务等回信，拿到结果后回一句"整理成了 N 段摘要""没有要整理的"或"没整理成"，和别的命令一样不引用命令。一次最多 24k token，再长的要发几次。私聊里回"私聊不写摘要"。
- `/clear --all`：只是消息 id 水位，之前的摘要和消息不进提示。

### 砍掉的

- `[recent turns]` 摘要、续接摘要、`context_resume` 和 turn 内的定位符压缩。turn 内也不裁旧工具输出，太大就结束这次运行，见[核心](#核心)。以后要看上一轮做了什么，加一个读 turn 快照的 `turn_read(t#N)` 工具。
- 自动注入检索结果。记忆只注入群记忆和触发者的个人记忆，其它靠模型调 `context_search`、`context_read`。这条沿用 Haskell。

## 媒体

2026-10-29 定，在 v1 之后第一个做（owner 选的）。参考了 Haskell 版，它的教训写在各条后面。

- **节点和句柄**：入站时 QQ 附件的下载地址写进节点，`Media { media: Some(Remote(url)) }`。ledger 只追加，下载的结果记在 `message_media`（消息、序号、sha256）。序号是这条消息里第几个媒体，从 0 数；给模型的句柄是 `image#消息id.序号`，`video#`、`audio#`、`file#` 同理。Haskell 版的 `[image#id]` 指的是消息，不是哪张图，一条消息最多 20 个媒体，后来才改成两段（ADR 004）。
- **内容库**：`/var/lib/maxx/media/objects/<sha256 前两位>/<sha256>`，只读权限，先写临时文件再 rename，已有的不再写。和 Haskell 版同一种布局，导入时直接搬。不做 GC。
- **下载**：一个[派生数据 worker](#三种角色)，入账通知触发，同时最多 4 个下载，每个 60 秒超时，单个超过 64 MiB 的只记元数据、不下。失败重试两次（1 秒、4 秒）就放弃，只记日志，不留失败表。启动时只补最近 1 小时没下完的：QQ 的地址会过期，Haskell 版每次重启都把几百个过期链接重排一遍，刷半小时警告（9f27fa7）。图、表情包、视频、语音、文件都下，`/chat` 和以后的工具要用。
- **给模型的版本**：下载时做一次，`media` 里记它的 sha256。长边超过 1568 像素或者超过 1 MiB 的图，重编码成长边 1568 的 JPEG；GIF 取第一帧；其它用原图。Haskell 版一开始发多 MB 的原图，base64 纯属浪费（0a2addb）。
- **caption**：配置 `[llm] caption`，没配就不写。存在它自己的 `media_captions` 表里，`media` 是下载 worker 的。只写 14 天内第一次见到的图，按 sha256 一张一个，表情包重发不重写（975eb59）。一到两句中文，截图说明是什么、关键文字原样摘录，存 300 字以内。失败两次就放弃，记成空 caption，不再试。视频、文件不写；语音用腾讯给的识别文本。
- **模型看到的**：
  - 尾巴和摘要里只有文字：`[image#123.0: caption]`，还没有 caption 就是 `[image#123.0]`。历史里的图不发图：Haskell 版的教训是它们抢注意力（0ec5752）。caption 到了，那一行就变，接受这一次缓存失效，见[前缀稳定的规则](#前缀稳定的规则)。
  - 附图：第一批输入和它们引用的消息里的图和表情包，作为真正的图片输入跟在易变块后面，每张标上句柄；后续输入里的图跟在 `[新消息]` 块后面。一次运行最多 8 张，多的只留文字。每张先按 1200 token 估，之后以 provider 报的用量为准。
  - 不支持看不了图的模型（2026-10-29 owner 定）：Max 用的模型都当作能看图，不设 `input` 配置，也不做纯文字的降级。意图分类和 historian 只读文字，不受影响。
  - 想看历史里的图，在程序里调 `max.image('image#123.0')`，见[多模态结果](#多模态结果)。
- **请求里**：条目只存引用（原则 7）。`User` 条目带一个 `images` 列表，每项是"哪条消息的第几个媒体"，不是 sha256：消息一入账就要展示，那时图通常还没下完。每次调模型前，`max` 查 `message_media` 和 `media` 找到给模型的版本，从内容库读出来，编成 base64 的 data URL 交给 `max-llm`。Responses 降成 `input_image`，Chat 降成 `image_url`，每张前面一段文字写句柄。入账不到 10 秒、还没下完的图就等它，在调模型的任务里等，不卡会话 actor；更早的、下不来的、读不出的直接不发，只记警告，句柄还在文字里。不传 QQ 的地址，它会过期，provider 也未必访问得到。
- **`/chat`**：VM 里只读挂一个这个会话的媒体视图，`/chat/<消息id>.<序号>.<扩展名>`，硬链接到内容库，下载时建，起 VM 时补齐。

分四小步做：

1. 内容库、`media` 和 `message_media`、下载 worker；入站节点带上地址。
2. 模型的 `input`、条目里的图、两种协议的降级、附图和句柄。
3. caption worker。
4. `/chat` 和 `max.image()`。

## schema

2026-10-27 定：不沿用 Haskell 版的 schema，重新设计，上线时用导入程序一次性迁移。Haskell 版经过 135 个迁移，留下两套会话键（`conversation_id` 和 QQ 群号 `legacy_group_id`，后者没有外键，却被约 25 个模块当主键用）、三套消息 id、四份正文、31 张没有代码读的表，和互相撤销的迁移。只能从头来。

### 约定

- **一个实体一个键。** 会话只有 `conversation_id`，QQ 群号只出现在 `endpoints.native_id`。消息只有 `id`，同一个会话里就是入账顺序（见[时间线](#时间线)），模型句柄 `#id` 用它；平台原生 id 是属性，`(endpoint_id, native_id)` 唯一，入站的在 `messages`，Max 发出的在 `deliveries`。人只有 `principal_id`，平台账号在 `identities`。
- **JSONB 只放三种**：`nodes`、`raw`，和按设计整体存取的 blob（turn 快照、`opaque`、工具输出）。其它结构都是列。
- ledger 和 turn 记录只追加（[原则](#原则) 1）；摘要、记忆是派生数据，允许 `status` 列。
- 命名：PK 叫 `id`，外键 `<表>_id`，时间列用 `timestamptz`、叫 `*_at`。
- 迁移从 1 号开始，上线前随意合并，上线后只追加。
- 不做 source hash，不做 CAS cursor。Haskell 版的 `conversation_source_hash` 对 IR 做 sha256，IR 格式一改就要全库重打。
- id 列都是 `generated by default as identity`，导入程序可以写旧 id。
- 查询都在 `max-db` 里，接受 `&mut PgConnection`，由调用方决定哪些写在同一个事务里；要几条语句一致的查询自己开事务，调用方已经在事务里时就是 savepoint。
- `.sqlx` 离线元数据在 `crates/max-db/.sqlx`，Nix 构建设 `SQLX_OFFLINE=true`。改了迁移或查询，跑 `scripts/prepare-queries`：按迁移重建开发库，重新生成这份元数据。

### v1 的表

| 区域 | 表 | 说明 |
|---|---|---|
| 平台 | `conversations` | kind（group、direct）、标题 |
| | `endpoints` | 会话、平台、`self_identity_id`（Max 用哪个账号）、`native_id`。v1 一个会话一个端点；镜像时一个会话多个。现在就分开（2026-10-27 定），免得再迁移。`native_id` 是适配器自己的字符串：QQ 是 `group:<group_openid>` 或 `c2c:<user_openid>`，导入的老 QQ 端点（平台 `qq_legacy`）是 `group:<群号>` 或 `private:<QQ 号>` |
| | `principals`、`identities` | 人，和他在各平台的账号。多个写者：各会话 actor 入账时建，见[身份](#身份)的"写者" |
| | `conversation_settings` | `/model`、`/effort`、`/persona`、`/proactive`、`/clear --all` 的消息 id 水位。可变 |
| ledger | `messages` | 会话、端点、`sender_identity_id` 和发送者名字、角色的快照（见[身份](#身份)）、`native_id`、`sent_at`、`received_at`、kind（chat、command、event）、`reply_to`、`nodes`、`raw`、`text`（渲染后的文本，给搜索和全文索引）；Max 自己的消息带 `turn_id` 和段号。撤回、编辑是 `kind = event` 的行，`event` 列说是哪种（edit、unsend），带 `target_id` 和文本兜底；编辑的新内容在 `nodes`。只有会话 actor 写 |
| | `deliveries` | 出站回执：消息、端点、平台 id 或错误、状态（sent、failed、unknown）、时间。平台 sender 是唯一的写者，只追加。镜像时一个端点一行，见[出站](#出站) |
| 媒体 | `media` | 按 sha256 寻址：mime、大小、宽高、第一次见到的时间、给模型的版本的 sha256。种类在消息的节点里：同样的字节可能这条是图、那条是表情包。见[媒体](#媒体) |
| | `media_captions` | sha256、caption（放弃了就是空的）、写它的模型、时间。caption worker 是唯一的写者 |
| | `message_media` | 消息、序号、sha256。入站节点里是下载地址，下载完记在这里；程序交的图（`max.image()`）节点里直接是 sha256 |
| turn | `turns`、`turn_snapshots`、`turn_outcomes` | 见 [turn 记录](#turn-记录)。`t#N` 是 `turns.ordinal`，每个会话从 1 数 |
| | `llm_usage` | turn（可空）、用途（turn、intent、historian、caption）、provider、模型、强度、token（含缓存命中数，按 provider 看命中率、调空闲窗口；还有其中的推理 token）、费用。token 用 bigint；费用 `cost_micros` 是百万分之一美元，用整数，不要 decimal，价格未知时为空 |
| 上下文 | `summaries` | 见 [summaries 表](#summaries-表) |
| | `summary_runs` | historian 的每次模型调用：范围、原因（quiet、pressure、compact）、模型、原始输出、错误。用量在 `llm_usage`。有保留期 |
| 记忆 | `memories` | v1 不做记忆，表先定：scope（会话或 principal）、类别、内容、importance、status、来源 summary、证据消息范围 |

以后随功能加：`automations`、`stickers`、`lingo_*`、`bungie_*`、`destiny_*`、embedding 表（pgvector）。

### 旧表的去向

- `platform_events`：原始 payload 进 `messages.raw`。
- `message_deliveries`、`message_delivery_parts`：换成 `deliveries`。
- `message_projections`、`message_hook_*`、`agent_messages` 视图：hook 不做了。
- `execution_journal`、`llm_calls`：turn 快照里就是模型的全部输入和输出。
- `platform_ids`：没有兼容 id。
- `conversation_cursors`：cursor 从 `summaries` 推出来。
- `compartment_evidence`、`episode_memory_proposals`、`episode_memory_reviews`：搜索直接搜正文；记忆提案在 `summary_runs` 的输出里。
- `memory_versions`、`memory_mutations`、`memory_evidence`：压成 `memories` 加一张只追加的 `memory_history`。
- `skills`、`skill_versions`：skill 是文档，放文件。
- `sandboxes`：VM 的生命周期在进程里。
- `admin_timeline_revisions` 和那几个 NOTIFY 触发器：admin 以后再说。
- 31 张死表（durable task、plan、workflow、browser workspace 等）：不导。

### 导入

- **消息 id 沿用旧的 `canonical_message_id`**（2026-10-27 定），新消息从最大值加一接着编。旧摘要和记忆正文里的 `#123`、`[image#123.0]` 句柄因此还有效。导入时校验它和 `ingest_seq` 的顺序一致；不一致就另加一列记顺序。
- **全部消息都导**（2026-10-27 定），包括被 hook 忽略过的（`message_projections.context_visible = false`）。库里忠实保留群里的所有事实。
- `canonical_content` 的 v2 nodes 转成新 `Node`；`raw` 从 QQ 的 `segments` 列取，Matrix 从 `platform_events.raw_payload` 取；`text` 重新渲染。老的 Matrix 消息导成哪个平台 **待定**：Matrix 先不做，代码里的 `Platform` 暂时没有它，库的约束还认 `matrix`。
- 老 QQ 的账号和端点导成平台 `qq_legacy`：官方接口给的是 openid，和 QQ 号、群号不在一个命名空间，对不上。新群用 `/bind <老群号>` 接到老会话上，时间线连续，见 [QQ 官方机器人](#qq-官方机器人)。
- 老 QQ 号的人按昵称自动接上（2026-10-29 定，原来是各算各的人、不合并）：导入时留下每个老账号在每个老群里最后用的 QQ 昵称（旧 `messages` 的 `sender_nickname`，不是群名片）；表在做导入时定。接到老会话上的群里，一个新的 `member_openid` 第一次出现时，拿它的 `username`（官方接口给的也是 QQ 昵称）去对这个老群的老成员：恰好一个老成员的昵称一样，而且他还没被别的新账号认领，就把新账号并进他的 principal，保留老 id，旧摘要和记忆里的 `[mention#N]` 都接得上。重名、封号后改过昵称的不并，只记日志，先算新人；并错了可以撤，合并只是别名。冒名的风险（有人改成别人的昵称再第一次说话）接受。拿不到全群成员，没说过话的老成员要等他们第一次说话才接上，见 [QQ 官方机器人](#qq-官方机器人)的"没有的"。
- 老的 reaction、戳一戳事件不导。
- Max 自己的消息：`agent_turn_id` 加 `turn_chunk_index` 变成 turn id 和段号；它们的平台 id 写进 `deliveries`，状态 sent。否则 sender 启动时会把它们都补记成结果未知。旧 `agent_turns` 导成 `turns` 加 `turn_outcomes`，保留 `t#N`，没有快照。
- `conversation_compartments` 只导 `active` 的；群号换成会话 id；importance 0..1 换成 1..100；单摘要时期的行只有 `summary`，放进 p1，其它层空着。句柄从 `episode:<uuid>` 换成 `summary#<id>`。
- `principals` 和 `principal_identities` 直接搬，id 不变，旧摘要和记忆里的 `[mention#N]` 因此还有效；改名之前写的 `[@#N]` 导入时改写成 `[mention#N]`。旧表按 Max 的账号（`platform_account_id`）区分 identity，每个平台一个账号，直接换成平台：QQ 的换成 `qq_legacy`。`sender_name` 从旧 `messages` 的 `sender_card`、`sender_nickname` 取，群名片优先；旧库没有角色，`sender_role` 留空。`endpoint_known_identities` 不导。
- `sessions` 按[配置](#配置)里说的映射 profile 名；`memories` 只导 active 和 permanent 的当前版本。
- 各群 VM 的 `/work` 也迁（2026-10-27 定）：按群号找到对应的会话，把这个群当前沙箱卷里的 `work` 拷到新卷，属主改成 `maxx`（见 [VM 进程](#vm-进程)）。`nix.img`（guest 里可写的 Nix store，存的是装过的包）提议不迁，用到时重新装。旧卷在 root 所有的目录下，读它要 root。
- 自动化、贴纸、lingo、Destiny 等各自功能做到时再导。
- 导入写了旧 id 的表，最后要把它们的 identity 序列调到最大值之后（`setval`），否则新行会撞旧 id。
- 规模：2026-09-05 有 149,395 条消息，每天增加 2–2.5k；导入是分钟级的事。

## 身份

2026-10-27 定。沿用 [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md) 的三条判断：

- **模型面对人，ledger 存账号。** 人是 principal，平台账号是 identity。消息的发送者和提及节点存 identity，因为平台认证的是那个账号；渲染给模型时再查到 principal。合并因此不碰 ledger。
- **principal 只是"这几个账号是同一个人"的断言**，只能由人显式声明（以后的 `/link`，v1 只有 QQ 的 `/bind` 合并 owner 自己的账号），不从名字推断。唯一的例外是老 QQ 号按昵称接上新 openid（2026-10-29 定），见[导入](#导入)。除此之外 v1 一人一个账号；Haskell 版的 239 个 principal 也都是一人一个账号。
- **合并是别名，不改写。** `principals.merged_into` 指向保留的那个，被合并的行留作墓碑；读的时候用 `coalesce(merged_into, id)`，链深固定为 1，可以撤销。

### 表

| 表 | 列 | 说明 |
|---|---|---|
| `principals` | `display_name`、`merged_into`（可空） | 人。`display_name` 建行时取第一次见到的名字，只在这个人在当前端点没有发言快照时用 |
| `identities` | `principal_id`、platform、`native_user_id` | 账号，`(platform, native_user_id)` 唯一。Max 自己也是一个 principal，它在各平台的账号是 identity，不另设账号表 |
| `endpoints` | `self_identity_id` | 这个端点用 Max 的哪个账号收发。"是不是 Max 说的"就是 `sender_identity_id = self_identity_id` |
| `messages` | `sender_identity_id`、`sender_name`、`sender_role` | 发送时的快照。名字 QQ 取事件里的 `username`，为空时写"某人"（导入的老消息群名片优先，空则取昵称）。角色是 owner、admin、member，QQ 取事件里的 `member_role`；私聊为空 |

没有成员表。Haskell 版的 `endpoint_known_identities` 记谁在哪个端点出现过，这里由 ledger 推出来。名字和角色都是消息自带的快照，不向平台查，也不缓存。

**写者**（2026-10-28 定）：别的表都只有一个写者（见[运行时结构](#运行时结构)的图），`principals` 和 `identities` 是例外。会话 actor 入账时遇到没见过的账号（发送者，或者被提及的人）就建 identity 和它的 principal；同一个新人同时在两个群说话，两个 actor 会一起建。启动时解析 owners、`/link` 设 `merged_into` 也写这两张表。规则：

- 只插不改，`merged_into` 除外。
- 建之前先不加锁查一次，查到就用。查不到，就在入账事务里按（平台，账号）取 `pg_advisory_xact_lock`，再查一次，还没有才建。同一个新账号因此只会建出一个 principal；见过的账号不用锁，所以平时各会话的入账互不等待。

### 模型看到的

- 人的句柄是 `[mention#12]`，和 `#123`、`[image#123.0]`、`summary#45`、`t#42` 同一套语法，见[回复的写法](#回复的写法)。ADR 004 推迟的带类型前缀写法这次也不做，没观察到不同命名空间的号码被混用。
- 尾巴每行 `[HH:MM 名字 #id]`，名字用 `sender_name` 快照，所以有人改名，旧行也不变，前缀不受影响。正文里的提及渲染成 `[mention#12]`。
- **名册**在创建核心时随基础上下文一起投影，放在易变块（2026-10-27 定）。范围是上下文里出现的人：尾巴的发送者和被提及的人、渲染出的摘要里的 `[mention#N]`、第一批输入的发送者。一人一行，如 `[mention#12] 名字（管理员）`；名字和角色取这个人在本端点最新一条消息的快照，没发过言的取 `principals.display_name`。一次 `DISTINCT ON` 查询，走 `messages (endpoint_id, sender_identity_id, id)` 索引。
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
- **命令以 `/` 开头**（2026-10-29 定，owner 的意思）：`/` 或全角 `／` 后面跟命令名；`!` 不再是命令前缀，`/nix/store` 这类也不是命令。QQ 官方机器人的指令面板（`/v2/panels` 或管理端的「高级设置」）只把指令填进输入框，用户自己按发送，bot 收到的是普通消息，所以面板和手打走同一条路。面板写不了参数提示，而且全群可见。面板就是命令列表，所以没有 `/help`（2026-10-29 定）。2026-10-29 用 `POST /v2/panels` 登记了一个群面板（`scope: group`、`target_type: all`）：`status`（模型、人设、在跑的回复）所有人能点，`compact`（把聊天整理成摘要）、`kill`（停下正在跑的回复）、`persona`（看人设，后接文字可换）`only_admin`。名字不带 `/`，QQ 填进输入框时自己加。名字最多 7 个汉字，说明最多 15 个；每个面板最多 20 项，一个 bot 最多 20 个面板。改面板用 `PUT /v2/panels/{panel_id}`，不写进代码。以后做 Matrix 时再看：Element 会拦截 `/` 开头的消息。
- **`/status`** 是 Haskell 版 `!version` 那样的小名片，`!version` 并进来，不显示版本号（2026-10-29 定）：一行一项，前面一个 emoji，行间单个换行：QQ 的 Markdown 见换行就断行，行尾再加两个空格会多空一行（2026-10-29 实测）。全用英文，依次是 maxx 和构建它的 commit（flake 在 `max` 包上设 `MAX_COMMIT`，cargo 自己构建的写 dev）、系统和架构、主动接话、在跑的 turn、清过的话加上下文水位、maxx 和主机的运行时长。模型和人设不放（owner 定），看 `/model`、`/persona`。不用列表和粗体：QQ 把列表项排得很松，粗体后面的空格会被吃掉。
- 命令的权限沿用 Haskell 版（2026-10-29 定）：查看类（`/status`、不带参数的 `/model` 等、`/model list`）谁都能用；只影响这个会话的（`/kill`、改人设、`/clear --all`）要群主、管理员或 owner；花钱或影响全局的（换模型、`/effort`、`/proactive`、`/bind`）只有 owner。没权限的回一句"这个命令只有……能用"。`/kill` 不回话。

### v1 不做、位置留好的

- `/link`：设 `merged_into`，保留较小的 id，显示名由人定。QQ 的 `/bind` 已经用到合并，但只合并 owner 自己的账号。命令消息本身就在 ledger 里，算审计记录。合并后，提及这个人的旧行渲染出来的 principal 会变，前缀失效一次，可以接受。
- 跨平台的记忆和权限都跟着 `/link` 走，不单独做。

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
- **输入和输出**：人设的前 500 字、最近 15 条消息作上下文（和尾巴同一种行格式）、待判的消息。输出一行 JSON：`trigger` 和不超过 20 字的 `reason`。提示词里写了该接话的三种情形（没打 @ 的点名、Max 参与的对话有了后续、它能给出具体有用东西的话题）和不该接的（成员之间的闲聊、只是提到 Max、嫌 Max 烦、别的机器人），拿不准就不接。分类任务自己读库拼输入；拼提示词和解析输出都是 `max-core` 里的纯函数。
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
- **跨重启 Resume**（2026-10-29 定）：关机时把网关的 session id 和最后的序号存进库，启动时先拿它们 Resume，不新建会话，这样重启那几秒里群里发的消息由服务端补发。新建会话不会补发（实测丢过一条）。实测（2026-10-29）：停 2 分钟和停 10 分钟都 Resume 上了，期间的消息都补发了；更长的没测。超出窗口就只能新建会话，那段消息丢掉。补发的消息可能已经过了被动回复的窗口，见下面的"出站"。实现（2026-10-29）：`qqbot` 把事件送进无界通道，丢掉连接的 future 时不会有已经计入序号、却还没送出的事件，所以接入停下后读完通道里剩下的，`Session::resumable` 的序号就是该接着的地方。补发的消息可能和停机前已经入账的重复，actor 按平台 id 丢掉已经入账的。为这个拆出一个常驻的平台进程、或者加 Redis 这类队列，都不划算：拆进程能换来的只有连接不断，Resume 做到了同样的事。
- **进哪些群**：个人主体的机器人只能由创建者拉进他当群主或管理员的群。2026-10-28 定：只进这样的群，而且群主要在群设置里打开两个开关：
  - "接收群内全部消息"：所有消息都走 `GROUP_MESSAGE_CREATE`，@ Max 的也是，是不是 @ 看 `mentions`。不开只收 @。
  - "机器人主动发言"：Max 随时能发。不开只能在消息到达后 5 分钟内被动回复，每条最多 5 次，跑得久的 turn 发不出去。
- **私聊**：个人主体的机器人暂时只能和管理端"开发设置"里加的体验用户私聊（实测）。这份名单就是私聊白名单，QQ 不用 `private_file`。被动回复的有效期 60 分钟、每条 4 次。
- **身份**：没有 QQ 号和群号，只有按机器人分配的 openid。群是 `group_openid`；群成员是 `member_openid`，同一个人在不同群里不一样；私聊是 `user_openid`，又是另一个。所以 QQ 上一个 identity 是一个群里的一个人，或者一个私聊对象。跨群认人本来就不做，记忆也按会话隔离；能跨群的 `union_openid` 要单独申请，不申请。只有 owner 要认出来，靠 `/bind`。
- **端点**：`native_id` 是 `group:<group_openid>` 或 `c2c:<user_openid>`。老库的 QQ 端点和账号导成另一个平台 `qq_legacy`，两边的号码不在一个命名空间，`qq_legacy` 也没有适配器。
- **`/bind`**：新群一开始没绑定，消息直接丢掉，不建会话，和名单外的群一样（见[运行流程](#运行流程)第 1 步）。绑定分两步：
  1. owner 私聊 Max 发 `/bind <老群号>`，或者不带群号的 `/bind`（新开一个会话）。Max 回一个 6 位码，10 分钟有效。
  2. owner 在新群里发 `/bind <码>`。这个群的端点挂到老群号对应的会话上（`qq_legacy` 端点所在的会话），时间线接着老消息往下走；同时把发令人在这个群的 identity 并进 owner 的 principal（设 `merged_into`），之后在这个群里认得出 owner。

  码在内存里，重启就失效。一个群只绑一次，不支持改绑。没绑定的群里只认 `/bind <码>` 这一条命令；码不对就丢掉，只记日志，因为没有端点可以回话。绑上的那条 `/bind` 由会话表交给 actor（`Event::Bound`），照常入账，回一句"绑好了"，不当命令执行。一段老记录只能接到一个群上（2026-10-29 定）：一个会话只能有一个适配器在服务的端点，否则会有两个 actor 写同一条时间线。所以发码时查一次，用码时再查一次（同一个老群发过两个码的情况）。owners 文件里 QQ 只写私聊的 `user_openid`：第一次私聊 Max 后从库里的 `c2c:` 端点取。
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
  - 被动优先：回复的消息发出不到 5 分钟、还没回满 5 次，就带它的 `id` 和递增的 `msg_seq` 发被动回复；否则发主动消息。实测第 6 次回 40034128。5 分钟按消息自己的发送时间算，留 10 秒余量，不按 Max 收到的时间（2026-10-29 改）：停机 10 分钟后 Resume 补发的消息，按收到的时间算还在窗口里，QQ 却回 40034005"回复消息msg_id已过期"，回答发不出去（实测）。
  - 额度：主动消息整个机器人每分钟 60 条，每个群每分钟 20 条、每天 1000 条。sender 按群排队，超了就等，不丢。
  - 格式：纯文本，或者原生 Markdown（`msg_type = 2`，2026-04-23 起群聊和私聊都开放，不用申请模板）。2026-10-29 实测：标题、粗体、斜体、删除线、行内代码、嵌套列表、有序列表、引用块、代码块（带语法高亮和复制按钮）、表格都能渲染，`<` 和 `&` 不用转义。单个换行就断行，行尾两个空格会多空一行；粗体后面的空格会被吃掉。LaTeX 的 `$…$`、`\(…\)`、`$$…$$` 和 `math` 代码块能渲染，`\[…\]` 不行，发之前换成 `$$…$$`。Markdown 链接和裸链接都能点；纯文本里的网址也没被拒，同样能点（文档说的 40054010 没碰到）。Markdown 里的图片只显示 QQ 自己域名上的，外站的图裂开。长度上限还没测。2026-10-29 定：一律发 Markdown，省掉判断，Markdown 被拒时退回纯文本。
  - @：`<qqbot-at-user id="<member_openid>" />`，实测在 Markdown 里显示成 @群名片。
  - 表情（实测）：发不出去，`<faceType=…>` 和 `<emoji:id>` 都原样显示。2026-10-29 定：Max 不发表情，见[回复的写法](#回复的写法)。
  - 引用：`message_reference.message_id` 填被引用消息的 `msg_idx` 或 `ref_idx`，实测可行。
  - 撤回：自己的消息 2 分钟内能撤（实测）；Max 是管理员时也能撤别人的。
  - 媒体要先上传拿 `file_info`，再发 `msg_type = 7`。实测可以直接传 base64，`file_info` 一天有效；`content` 是图片下面的说明文字，和图在同一条消息里。发文件（`file_type = 4`）实测回 50015014，发不了。v1 不做媒体。
  - 平台审核：内容违规会被拒（40034006），记成 `deliveries` 里的失败。机器人被封"暂不支持解封"。
- **没有的**：reaction、戳一戳、编辑、群名片、发表情和文件；也没找到"有人撤回了消息"的事件，别人撤回的消息时间线上看不出来。禁言、群成员列表的接口 2026-08 才加，第三方反馈多数要白名单，v1 不用。实测（2026-10-29）：成员列表 `GET /v2/groups/{group_openid}/members` 和单个成员 `…/members/{member_openid}` 都回 11253（应用无接口访问权限），maxx 不在白名单上，所以拿不到不说话的人的 openid。

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
- **程序里调 Max 的工具**：`tools.<名字>(args)` 返回 Promise，`Promise.all` 就是并发。沿用 Haskell 版 SDK 的形状：`max.raw` 拿完整的成败结果，`max.cancel` 和 `max.race` 取消调用，`agent()` 派后台 agent。做成的（2026-10-29）：`tools.x()` 失败抛 `ToolError`；`max.raw` 不抛，返回 `{ok: true, value}` 或 `{ok: false, error: {code, message}}`；`max.cancel` 中止那次请求，`max.race` 取先完成的、取消其余的；没 await 就读字段会直接报错，提示先 await。`agent()` 等后台 agent 做了再加。
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

- 和后台 pi 共享 `/work`，交接任务只要留文件；能直接读 `/chat` 里的图片和文件。
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
- **起 VM**：主进程选一个空闲槽位（没有就关掉闲置最久、没在用的那个），在 `/var/lib/maxx/vm/<会话 id>/` 下准备 `work` 和 `nix.img`，起两个 virtiofsd（只读的 store、读写的 `/work`）和 cloud-hypervisor，都是 `kill_on_drop` 的子进程。然后每 100 ms 试一次 SSH，连上就算起好了，不另做就绪通知。会话的媒体视图 `chat` 等有了媒体再加。
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
- **协议**（2026-10-29）：rmcp 3.8，协议版本 2026-07-28，无状态，回复用 JSON 不用 SSE。这个版本每个请求都要带 `MCP-Protocol-Version`、`Mcp-Method`、`Mcp-Name` 头，`_meta` 里也要有协议版本和客户端能力。runner 自己用 fetch 拼，不装 MCP 的 SDK。
- **会话**：每次 `run_code`、每个后台 job 各开一个，记着 token、所属的群和 turn、允许的工具、在途的调用。现在只有 `run_code` 的会话，能用全部 Max 工具，也就是 `context_read`；会话还记着每个工具调了几次、失败几次，附在结果后面。

  | 会话 | 能用的工具 | 生命周期 |
  |---|---|---|
  | `run_code` | 这个 turn 的工具，由 `RunSpec` 定 | 这一次运行 |
  | 后台 job | 只读工具 | 这个 job |

- **鉴权**：`Authorization: Bearer <token>`。token 所属的群必须和连进来的 VM 是同一个群。`tools/list` 只列出这个会话允许的工具。
- **吊销是同步的**：从内存表里删掉会话，它在途调用的 future 一起 drop，所以可以放进 `Drop`。会话只存在内存里，Max 重启或崩溃后旧 token 全部失效，不需要过期时间。
- **执行器**：所有调用都经过同一个执行器，负责 schema 校验、单次调用的超时、并发上限 64、输出大小上限，以及按会话限制有副作用的调用次数（代码里可以循环发送、撤回、禁言）。做成的：单次 60 秒，每个会话同时 64 个，多的排队；参数由每个工具自己的参数结构体校验，不另做 JSON Schema 校验。输出上限和副作用次数等有了会产生大输出或有副作用的工具再加，`context_read` 自己分页。
- **结果**：工具声明 `outputSchema`，成功结果放在 `structuredContent` 里，`tools.x()` 拿到的就是 JSON。失败设 `isError`，`max.raw` 需要的 outcome（rejected、failed-before-effect、outcome-unknown）和 retry 分类也放进 `structuredContent`。取消用 `notifications/cancelled`。做成的：失败的 `structuredContent` 是 `{code, message}`，outcome 和 retry 分类等第一个有副作用的工具。无状态的 HTTP 里取消就是断开连接，rmcp 会取消那次调用，`max.cancel` 就是中止 fetch。
- **工具注册表**：每个工具有名字、描述、参数类型（schemars 从参数结构体生成）、返回类型、副作用分类（只读、幂等、有副作用）和执行函数。副作用分类决定能不能重试、能不能给后台 job、中断后算不算"结果未知"。系统提示里的 TypeScript 声明也从注册表生成。做成的：工具还少，名字、描述、两个 schema 和 TypeScript 声明都手写在 max-core 的 `MAX_TOOLS` 里，和模型的两个工具一样，没上 schemars；执行函数在 max 里。副作用分类等第一个有副作用的工具。

### 多模态结果

参考了 Codex、pi 和 Hermes 的做法。

- **程序显式交图**，学 Codex code mode 的 `image()`：`max.image(src, {detail})`、`max.video(src, {start, end})`。`src` 是 VM 里的路径（`/work/…`、`/chat/…`）或消息句柄（`image#123.0`），不接受 http 地址。只有交了的才进上下文；截图、下载这类操作只产出文件。不需要单独的 `view_image` 工具。
- **宿主自己取文件，不经过 MCP**：`/work` 是 virtiofs 共享，`/chat` 是内容库的硬链接，宿主都能直接读。宿主校验能否解码、按模型的上限缩放，按 hash 存进内容库，turn 记录里只存引用（原则 7）。要复制一份，是因为 `/work` 里的文件之后可能被改或被删。
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

### 网页搜索

2026-10-29 定，排在媒体第 1 小步之后（owner 选的）。`web_search` 当天做完：配置 `[search] api_key_file`，不配就回 `unavailable`；所有群合计同时最多 4 个搜索；没有单独的超时，MCP 执行器的 60 秒管着；每个 Max 工具可以声明一次运行最多调几次（`per_run`），超了回 `too_many`。

- **`web_search(query, limit?)`**：Max 的工具，宿主上经 MCP 调 Exa 的 REST 接口（`type: auto`，带 highlights），key 留在宿主，sops 里沿用 Haskell 版的 `search-exa-api-key`。返回前几条的标题、链接、摘要和发布时间，`limit` 1 到 10，默认 5；标题 200 字、摘要 800 字封顶。失败回 `{code, message}`，不做 Haskell 版那套免 key 的 MCP 优先、冷却和重试。一次运行最多调 20 次。Exa 走 tank 的日本出口，中文结果一般；以后不够用，在同一个签名后面换博查或智谱，它们国内直连。
- 工具常驻在系统提示的声明里，不藏进 skill：Haskell 版藏进 `web` skill 以后，模型不搜了，凭记忆答错剧情和价格（a51424d）。
- **抓网页不做成宿主工具**：宿主连得到 tailnet 里的服务，做成工具就是 SSRF 的口子。VM 镜像里加一个 `webread <url>` 命令：Python 加 trafilatura 抽正文、转 Markdown，PDF 用 `pdftotext`（2026-10-29 做完；原打算用 Node 的 Readability 加 turndown，trafilatura 少一套 npm 打包，也认得 GBK 这类老编码）；跟 5 次跳转、20 秒、10 MB 封顶，打印开头 1.2 万字，全文写进 `/work/.max/web/`，`--offset` 从存下的全文接着读。测试在本机用 dev shell 的 Python 跑这个脚本，接本地的 HTTP 服务。nft 本来就不让 VM 碰内网。要跑 JS 或登录的页面等[浏览器](#浏览器)。
- 不做：答案合成、模型 API 自带的搜索（工具数组固定不变，结果程序也拿不到）、结果缓存、图片搜索。

### 浏览器

v1 不做。

- camoufox 搬进群 VM，不再是单独的容器。它不在 nixpkgs 里，照 Haskell 版的打包方式移植（发行包加 autoPatchelf，camoufox-js 和 playwright-core 一起钉住版本）；坏了就退到 nixpkgs 的 Playwright Firefox。guest 的 store 是宿主的，镜像变大只占宿主的盘，每个 VM 不多占。2026-10-29 改：每次运行用到时现起，经管道连，运行结束连进程树一起没，不用 Playwright server 模式，VM 里不留常驻进程。
- 不再有 navigate、click 这类浏览器工具，程序里直接用 Playwright 连这个浏览器。SDK 附带一个快照助手，把页面上可交互的元素列成带 CSS 选择器的清单，沿用 Haskell 版 snapshot 的形状。
- 每次运行开自己的 browser context，互不影响。登录状态（2026-10-29 定，owner 选的）：只给 Max 自己的小号用，用 Playwright 的 storageState 存到 `/work`，写明全群的程序都读得到；不做个人登录，Haskell 版那种按人加密、程序看不到 cookie 的做法要宿主侧的工具，以后再说。
- 截图和下载直接落到 `/work`，要看就 `max.image`。

### 待定事项

- v1 开放哪几个 Max 工具。
- ~~调 VM 用 `ssh` 命令还是 russh~~：已定（2026-10-27），russh，见 [VM 进程](#vm-进程)。
- 每次运行最多交几张图、视觉 token 预算多大。
- 代码转义的问题（2026-10-27 记下，暂不决定）：要不要让 GPT 用 Responses 的 custom（freeform）工具直接写原文，Codex 的 code mode 就是这么做的，cliproxy 也已支持；Gemini 过度转义要不要在 runner 里兜底，比如原文解析失败、去掉多余转义后能解析时才用修正版。先看 v1 里转义出错的频率。

## 后台 agent

v1 之后做。

- 每个 job 驱动群 VM 里的一个 pi 进程，通过 stdio 上的 RPC JSONL 通信。
- Max 定义自己的 `AgentBackend` 接口：开任务、steer、中断、事件流、结束报告。按 codex app-server 也能实现的标准设计，但只实现 pi。
- 领域工具走 Max 的 MCP 服务，见 [MCP 通道](#mcp-通道)。每个 job 开一个会话，只开放只读工具，比如 `context_search`、`context_read`、`memory_list`；job 结束时吊销。pi 在 VM 里也能跑 codemode 的 runner，用 job 自己的会话批量调这些工具。
- 会影响群的动作（发消息、发文件、撤回、禁言、建自动化）不给后台 agent。它的结果是一种输入（`JobResult`）：会话有核心在跑就喂给它，没有就作为触发起一个；由前台的模型决定怎么说。job 中途提问同样处理，人的回答再由前台用工具 steer 回去。

pi 适配器要处理的行为：

- `steer` 不打断正在跑的工具，要等这一轮工具调用都跑完、下一次 LLM 调用之前才送达。默认是 `one-at-a-time`，要改成 `all`。
- `abort` 不清队列。要让 pi 体面地停下（收尾路径）时，先发 `clear_queue` 再发 `abort`；取消路径直接杀进程。
- pi 读到 stdin EOF 会不会自己退出，要实测。这决定了能不能把它的生命周期直接绑在 stdio 上。
- `agent_end` 不代表结束，要等 `agent_settled`。
- stdout 只按 LF 切行，不能用会把 U+2028 当换行的读行器。
- pi 1.0 默认可能把 MCP 工具放在 codemode 后面，要配成 `direct`。这条还没在官方文档里确认。

pi 2026-04 被 Earendil 收购，仓库搬到了 `earendil-works/pi`，几乎每天发补丁，RPC 协议没有版本字段。所以在 Nix 里钉版本，录几段真实的 JSONL 做适配器回放测试，升级前先跑这些测试。

## crate 划分

2026-10-27 定。拆 crate 只认三个理由：强制依赖方向（编译器替你挡住违规 import）、隔离重依赖的编译时间、单独复用或发布。"这是一个功能"不算：historian、lingo、embedder 都要用库、LLM 客户端和消息渲染，各拆一个只会多出一堆 Cargo.toml 和一张互相依赖的网，什么都没挡住。

| crate | 内容 | 拆开的理由 |
|---|---|---|
| `qqbot` | QQ 官方机器人接口：token、网关（心跳、Resume、重连）、事件和 REST 的类型、发送和撤回，发图时再加上传。不认识 Max：没有 Node，没有会话 | 依赖方向：协议层不能长成 Max 的形状。也是唯一值得复用的一块 |
| `max-core` | 所有纯逻辑：Node/Message/Draft/Item 类型、核心和 intent 两个状态机、请求构造、分段器、衰减曲线、historian 输出的校验、给模型看的渲染。只依赖 serde、serde_json、thiserror，以及不开 `clock` 特性的 chrono（渲染 `HH:MM`、换日、间隔标记要用） | 依赖方向：sans-I/O 靠编译器保证 |
| `max-db` | schema、迁移、全部 sqlx 查询和行类型 | 编译时间；`.sqlx` 离线元数据集中在一处 |
| `max-llm` | Responses 和 Chat 适配、流式解析、推理透传、多模态降级 | 协议细节都关在这里，用录下来的响应单独测 |
| `max` | 二进制：配置、CLI、services、会话 actor 和 I/O 任务、平台 sender、QQ 适配、投影、historian、lingo、worker 框架、VM、MCP 服务、工具、命令 | 其余都是业务，放一起 |
| `max-import` | 二进制：旧库导入 | 旧 schema 的代码只在这里，切换后整个删掉 |
- 依赖只能往下：`qqbot` 和 `max-core` 在底层，互不依赖；`max-db`、`max-llm` 依赖 `max-core`；`max` 依赖全部。QQ 事件到 Node 的映射在 `max` 里，不在 `qqbot`。
- `max-core` 的依赖白名单写进 CI：`cargo tree -p max-core -e normal` 里只能出现那四个库。CI 再单独跑一次 `cargo check -p max-core`：只构建这一个包时，chrono 的特性不会和 `max` 合并，核心里调 `Utc::now` 就编不过。
- intent 的状态机和拼分类提示词、解析输出在 `max-core`；分类任务（读库、调小模型）是 `max` 里的 I/O 任务。historian 在 `max/src/historian.rs`，以后的 worker 也各一个模块；它们的纯逻辑（提示词、范围校验、衰减）放 `max-core`，不起库就能测。
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
5. **`max-llm`**（2026-10-29 完成）：Responses 和 Chat 两种协议的请求降级和流式解析，解析器不做 I/O。客户端一次只发一次，用 `Error::retryable` 给错误分类；重不重试由 `max` 的模型调用任务决定，因为只有它知道有没有已经说出去的文字。录了四家的真实响应做回放测试：cliproxy 的 gpt-5.6-luna 走 Responses，加密推理原样回传；cliproxy 的 Gemini、DeepSeek、taipan 上的 Qwen 走 Chat，带 `reasoning_content`。录的时候发现两件事：一是 Responses 默认把函数工具设成 strict，会把可选参数全变成必填，所以显式发 `strict: false`；二是 Gemini 会报推理 token 却不给推理内容，这部分不算进任何条目，因为条目的 token 是它下次再发时的花费。NInfer 的缓存断点做成 Chat 的选项：后面紧跟另一个 user 条目的 user 条目打断点，也就是基础上下文里易变块之前的那几块，已在 taipan 上验证。工具结果里的图片在第 9 步之前先降成"[图片省略]"。
6. **tank 上的 `maxx`**（2026-10-29 完成）：`nixosModules.maxx` 按名字生成用户、Postgres 角色和库、目录、slice、target 和服务，配置文件在构建时跑 `max check-config`；`nixosModules.max` 是同一个 module 换成上线后的名字。`max` 现在只做三件事：迁移数据库，用 QQ 凭据问一次自己是谁，等 SIGTERM。QQ 的 AppID 和 secret 在 sops 的 `maxx/` 下。module 有一个 VM 测试，用和 tank 一样的 Postgres 16。部署时遇到两件事：一是 sqlx 0.9 不认 `postgresql://max@/max?host=…`（有用户名就不能是空主机），改成 `postgresql:///max?host=/run/postgresql&user=max`；二是 tank 的集群建在 glibc 2.40 上，系统现在是 2.42，`template1` 的 collation 版本对不上，新建库就失败，所以刷新了 `template1` 的版本记录（它里面没有用户对象）。同一天按 owner 的意思，把 `postgres`、`luckperms`、`minecraft`、`matrix-synapse` 几个库 `REINDEX DATABASE CONCURRENTLY` 加 `REINDEX SYSTEM` 后也刷新了。
7. **`max`**（2026-10-29 完成，测试群里实测过）：配置、会话表和会话 actor、I/O 任务、平台 sender 和 `deliveries`、QQ 适配和 `/bind`、命令、intent。做完第一次实机：测试群里纯文字对话，顺便实测 [QQ 官方机器人](#qq-官方机器人)里标了实测的几项。工具在第 9 步之前一律回错误"工具还没接上，现在用不了。"。实测结果：`/bind` 接上测试群；@ 的对话和闲聊经 intent 判定都正常；停服务 2 分钟和 10 分钟，网关都 Resume 上了，停机期间的 @ 补发过来并且回答了。10 分钟那次回答被 QQ 拒了（40034005），被动回复的窗口改成按消息的发送时间算。同一天按 owner 的意思做了一轮减法：核心撞上限就认输，不再交接（见[运行流程](#运行流程)第 4 步）；重启时给宽限期再中断，不再挂起恢复（见[重启](#重启)）；intent 只留去抖、小模型判定和每小时上限（见 [intent](#intent)）；Max 不发表情；Matrix 先不做。这一步定下的：命令输出留在同一个会话（见[出站](#出站)）、命令权限（见[权限](#权限)）、actor 测试用真实时间（见[核心和 actor 的测试](#核心和-actor-的测试)）、一段老记录只接一个群（见 [QQ 官方机器人](#qq-官方机器人)）。tank 上的主模型是经 cliproxy 的 Gemini 3.8 Flash（Chat 协议），intent 用 h610 上的 qwen3.5-4b。
8. ~~**Matrix**，带加密房间和 `matrix-bootstrap`~~：2026-10-29 删，先不做，见 [Matrix](#matrix)。
9. **VM、MCP、codemode runner**。[VM 进程](#vm-进程)里要先在 tank 上验证的几件事 2026-10-29 验证完了。同一天做完第一段：VM 服务、`shell` 工具、module 里的 tap、nft 和加固，`max vm-check` 和嵌套的 NixOS 测试，测试在 tank 上通过。地址改走内核命令行，不用 DHCP。部署到 tank 后在测试群里实测过：模型调 `shell`，群的 VM 3 秒多起好，结果回到模型。第一次没调成，因为系统提示里还留着第 7 步那句"工具还没接上，别调用"。同一天按 owner 的意思，提示词里改叫 maxx（以前叫 Max）。tank 上的 Haskell 版同日删掉，数据留给导入。第二段同日做完：MCP 服务、guest 里的 runner、`run_code` 和第一个开放的工具 `context_read`，做法见 [MCP 通道](#mcp-通道)。runner 的测试在本机用 Node 跑，接真的 MCP 服务；嵌套测试里 `vm-check` 跑一个程序，经 MCP 服务查到数据库。
10. **historian**（2026-10-29 做完）：capture、`summary_runs`、`/compact`，当天挪到 worker 驱动器上。tank 上配了 `[llm] historian`，到 10-29 一次都还没跑：两个群一共一百来条消息，没到水位，也没人 `/compact`。
11. ~~**重启恢复**~~：2026-10-29 删，重启时给宽限期再中断，见[重启](#重启)。
12. **媒体**（2026-10-29 开始）：v1 之后第一块，分四小步，见[媒体](#媒体)。第 1 小步当天做完、上了 tank，测试群里的一张图入账后半秒内下载好。第 2 小步当天做完：媒体句柄、条目里的图、两种协议的降级、附图；owner 定了不支持看不了图的模型。
13. **网页搜索**（2026-10-29 做完，插在媒体第 1 小步之后）：`web_search` 和 VM 里的 `webread`，见[网页搜索](#网页搜索)。

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
11. ~~身份模型~~：已定（2026-10-27），见[身份](#身份)。跨平台合并（`/link`）和镜像一起做。
12. [工具和 codemode](#工具和-codemode) 一节末尾的待定项：v1 开放哪几个 Max 工具、图片预算、代码转义。调 VM 已定用 russh。
