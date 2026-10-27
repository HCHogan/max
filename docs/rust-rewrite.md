# Max Rust 重写

> 状态：草案，2026-10-26 起草，边聊边补。标 **待定** 的条目还没有结论。
>
> 代码在这个仓库的 `rust` 分支上，本地 worktree 是 `~/Development/hs/max-rust`。分支起点打了 tag `haskell-base`（`a5de2e1`）；Haskell 版的代码和文档都在那里，文中指向旧文档的链接固定在这个提交上。

## 目标

1. 用 Rust 重写 Max。上线时 Rust 版要能 drop-in 替换 Haskell 版：功能、数据、部署都接得上，有意删掉的功能除外。
2. 所有代码都要能让人审完。宁可慢一点、少一点，不一次堆上去。
3. 通用的部分交给成熟的库和外部 agent，包括配置解析、数据库、LLM 接入、Matrix、MCP 和后台 coding agent。Max 自己只写群聊运行时和领域逻辑。

不做的事：

- 不逐行移植 Haskell 代码，按现在的理解重新设计。
- 不为 Haskell 版写兼容层。数据一次性导入新 schema（见[上线](#上线drop-in-替换的条件)）。

## 版本

| 版本 | 内容 | 用途 |
|---|---|---|
| v1 | 见 [v1 范围](#v1-范围) | 只做审核和测试，不上线 |
| v1 之后 | 工具、VM、浏览器、codemode、记忆等，怎么切分 **待定** | 同上 |
| 上线 | [功能对齐清单](#功能对齐清单)全部完成，数据导入演练通过 | drop-in 替换 Haskell 版 |

### v1 范围

包含：

- 平台：QQ（NapCat，OneBot v11 reverse WS）和 Matrix。两个一起做，免得[消息格式](#消息格式)长成 OneBot 的形状。
- canonical ledger：入站和出站消息都落 Postgres。
- 会话 actor、前台 turn、流式回复、steer、取消（`!kill`）。
- LLM：Responses 和 Chat Completions 两种协议。
- 自写的 agent loop。v1 带不带工具 **待定**。
- 配置、日志、优雅关闭。

不包含，但上线前都要做：镜像、codemode、浏览器、VM 沙箱、记忆和召回、后台 agent、自动化、媒体、admin。

### 有意删除的功能

- iMessage
- WeChat hook

2026-10-26 讨论时只决定带 QQ 和 Matrix，这两个有人用。其余删除项 **待补**。

### 功能对齐清单

功能按 [features.md](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/features.md) 的条目列。所有没删除的功能，上线前都要完成。v1 一列只是提议，聊的时候再改。

| 功能 | v1 | 备注 |
|---|---|---|
| Conversation lifetime and history | 部分 | turn、队列、发起者反馈；重启后在时效内恢复挂起的 turn，崩溃时正在跑的记为 `Lost`，见[重启恢复](#重启恢复) |
| Automations | — | |
| Sandbox isolation | — | |
| Attachment fan-out and QQ best-effort recovery | — | |
| Persistence | 部分 | 只有 ledger |
| Canonical multi-platform conversations | 部分 | QQ + Matrix 共用一种[消息格式](#消息格式)；镜像 v1 不做，上线前要做 |
| Triggering | ✓ | @ 和回复触发；intent 分类进不进 v1 **待定** |
| Proactive triggering | — | |
| Inbound message hooks | — | 依赖 codemode |
| QQ group allowlist | ✓ | |
| Private chats | ✓ | |
| Agent loop | ✓ | |
| Background agents and feedback | — | pi + MCP，见[后台 agent](#后台-agent) |
| Prompt shape and budget | 部分 | |
| Memory | — | |
| Group lingo | — | |
| Unified recall and vector search | — | |
| Context operations | — | |
| LLM profiles | ✓ | |
| Streaming | ✓ | |
| Share cards | — | |
| Images | — | |
| Group awareness | — | |
| Moderation (QQ groups) | — | |
| Browser | — | |
| Replies | ✓ | |
| Tools | — | |
| Skills | — | turn 中途加载的工具只增不减，见[核心](#核心) |
| Destiny 2 (opt-in) | — | |
| Commands | 部分 | `!kill` 等运行时命令 |
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
| 数据库 | sqlx（postgres、runtime-tokio、macros、migrate、chrono、uuid、json） | 0.9.0 | 编译期检查 SQL；`.sqlx` 离线元数据入库；迁移用 sqlx 自带的 |
| 时间 | chrono | 0.4 | sqlx 0.9 不支持 jiff |
| LLM | async-openai（responses、chat-completion、byot） | 0.42.2 | 只在 LLM 模块里用；破坏性小版本大约每月一个 |
| HTTP/WS 服务 | axum（ws） | 0.8.9 | 接 NapCat 的 reverse WS；以后 admin 和 MCP 也挂在这里 |
| Matrix | matrix-sdk | 0.19.1 | 默认特性带 E2EE 和 sqlite store，要不要关掉 **待定**（见待讨论第 6 条） |
| OneBot v11 | 自写 | — | kovi 是插件框架，形状不对；onebot_v11 2024-09 后停更 |
| agent loop | 自写，sans-I/O | — | 调研结论见[核心](#核心) |
| 测试 | cargo-nextest、insta、tokio test-util、`#[sqlx::test]` | 0.9.149 / 1.49 | |
| 构建 | crane | — | 依赖单独缓存 |

async-openai 和 matrix-sdk 都依赖 reqwest 0.13，不会编出两份 reqwest。

v1 之后再加的：

| 用途 | 选择 | 备注 |
|---|---|---|
| codemode | wasmtime 48 | LTS 版本，支持 24 个月；主线每月 20 号发一个大版本 |
| MCP | rmcp 3.x | 后台 agent 回调用的 MCP 服务，以及 camoufox 客户端 |
| 工具参数 schema | schemars 1.2 | rmcp 本来就依赖它 |
| 向量 | pgvector 0.4.2 | 支持 sqlx < 0.10 |
| 自动化 | croner 4 | |
| token 估算 | tiktoken-rs 0.12 | |
| 后台 agent | pi（`@earendil-works/pi-coding-agent`），`--mode rpc` | 跑在群 VM 里，在 Nix 里钉住版本 |

## 配置

2026-10-27 定。Haskell 版的配置是 CLI、环境变量、YAML 三层逐字段合并：环境变量会悄悄覆盖文件，未知键被静默忽略；线上的配置由三处拼成：sops 模板渲染的整份配置、另一个 sops 模板渲染的 env 文件、module 导出的环境变量。这些都不要了。

### 来源和校验

- **只有一个来源：TOML 文件。** CLI 只有子命令和 `--config`；不读 `MAX_*` 环境变量，日志级别也写在文件里；没有优先级规则。
- **严格解析。** 所有结构体都加 `deny_unknown_fields`；默认值只在代码里写一处；可选功能是 `Option<Section>`，不写就是关闭；启动时做跨字段校验，比如引用的模型必须存在。
- **秘密和私密值只写文件路径。** 密钥用 `api_key_file`、`access_token_file`。不该进公开仓库的标识也一样，比如群白名单、镜像群号、owners，用 `groups_file` 这类字段，一行一个。配置文件本身不含任何敏感内容。启动时读所有秘密文件，缺了就报错退出。
- **不热加载**，改了就重启。

### 和 NixOS 的关系

- module 用 freeform 的 `settings`，经 `pkgs.formats.toml` 生成进 nix store。module 自己管的路径（数据库 socket、媒体目录）用 `mkDefault` 写进 `settings`，不导出环境变量，也没有 `environmentFile`。
- 构建时跑 `max check-config` 校验结构，不读秘密文件。配置写错，`nixos-rebuild build` 就会失败。
- 配置一改，store 路径就变，systemd 自动重启；秘密轮换由 sops-nix 的 `restartUnits` 触发重启。
- tank 的 `max.nix` 里 owners 现在是明文，迁过来时一起挪进 sops。

### 两层：配置文件和运行时设置

配置文件管部署时的基础设施和默认值。`!model`、`!effort`、`!persona`、`!proactive` 这类按会话的覆盖存在数据库里。两者不合并成一套"配置"，代码里也用不同的类型。

### LLM：provider、模型、选用

和 Codex、pi、Hermes 一样分三层。Haskell 版把三层揉成了一层：tank 上 23 个 profile 只有 7 个不同的地址，还有两对是同一个模型只差推理强度。

1. **provider：怎么连。** 地址、协议（`responses` 或 `chat`）、认证、请求头、重试、超时。同一个地址既要 chat 又要 responses，就写成两个 provider。
2. **模型：是什么。** 挂在 provider 下，表名就是发给 API 的模型 id。写上下文窗口、最大输出、输入模态、是否支持推理、默认采样参数。
3. **选用：谁用哪个、怎么用。** 默认模型、各个角色（比如 intent）用的模型和推理强度。引用一律写成 `provider/模型`，按第一个 `/` 切开；provider 名里不能有 `/`。

```toml
[database]
url = "postgresql://max@/max?host=/run/postgresql"

[platforms.qq]
listen = "127.0.0.1:18080"
access_token_file = "/run/secrets/max/server-access-token"
groups_file = "/run/secrets/max/qq-groups"

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

# 第 2 层：是什么（数值只是示例）
[llm.providers.cliproxy.models."gpt-5.6-luna"]
context_window = 400000
max_output = 128000
input = ["text", "image"]
reasoning = true

[llm.providers.local]
base_url = "http://127.0.0.1:8080/v1"
protocol = "chat"

[llm.providers.local.models."qwen3.5-4b"]
context_window = 32768
```

- 流式请求用空闲超时，不用总时长；重试次数放在 provider 上。Haskell 版是每次尝试最多 1800 秒，晚间网络差时再叠上重试会层层放大。
- 不做内置模型目录。启动时对照服务端的 `/models` 检查一遍。
- `!model` 只选 `provider/模型`，`!effort` 只调强度。不再有 `gpt-5.6-luna-medium` 这种只差强度的 profile。
- 数据导入要做名字映射：会话选过的 profile 名、`llm_usage` 里记录的 profile，都换成"模型加强度"。比如 `gpt-5.6-luna-medium` 映射为 `cliproxy/gpt-5.6-luna` 加 `effort = "medium"`。

v1 只定义它用得到的几节：database、qq、matrix、llm。其它节跟着对应功能一起加。

## 运行时结构

任务的父子关系和生命周期见图：<https://claude.ai/artifact/KrciskAXJfMF2qTHF6hDbW>

- root scope 下有两个子 scope：services（接入、平台 sender、MCP 服务等常驻任务）和 conversations（每个会话 actor 一个任务）。
- 会话 actor 持有队列、反馈收件箱和 Job 表，下面挂 turn 和 jobs 两个 scope。turn 同一时刻只有一个；job 挂在 jobs 下，能比发起它的 turn 活得长。
- `Scope` 由 `JoinSet` 和 `CancellationToken` 组成（2026-10-27 去掉了 reaper、defer 和 Background）：
  - `spawn` 给子任务一个子令牌，同一个令牌也返回给调用方，用来单独取消这一个任务。比如 `!kill` 只取消当前 turn。
  - `close(grace)`：先取消，在宽限期内等子任务自己结束；到期调 `JoinSet::shutdown`，也就是 abort 全部，再等它们真正停下。
  - 被 drop 时：`JoinSet` 自己的 Drop 会 abort 全部子任务。这是同步发起的，不等。
  - `close` 到期用 `shutdown` 而不是直接 drop，是为了保证返回时子任务的 future 都已经真正 drop 掉。否则可能服务已经关了，还有残留的 turn 在往它发东西。

规矩：

1. 禁止裸 `tokio::spawn`，用 clippy 的 `disallowed-methods` 拦住。任务只能经 `Scope` 创建。
2. 脱离要显式：后台 agent 挂在会话的 jobs scope 下，不挂在发起它的 turn 下。
3. 副作用交给活得更久的 owner：发送交给平台 sender；只能靠 API 停下的外部资源，停止命令交给持有那条连接的常驻服务。见[资源怎么结束](#资源怎么结束)。

关闭顺序：

1. 停接入，不再产生新消息。
2. 每个会话 actor 关闭自己的 turn 和 jobs scope：turn 停在干净的边界（见[重启恢复](#重启恢复)），宽限期过后 abort。v1 还没有恢复，直接中断。内层的宽限期要比外层短。
3. 排空：平台 sender 发完已提交的消息，有截止时间。
4. root scope 结束。运行时用 `shutdown_timeout` 关，不直接 drop，因为 drop 会一直等 `spawn_blocking` 的线程。最外层由 systemd 的 `TimeoutStopSec` 兜底，到期杀掉整个服务的 cgroup。

### 资源怎么结束

2026-10-27 定。资源有两种结束方式，两种都是正常路径：

- **收尾**：拥有者把活干完，调 `close().await`。它可以等、可以返回错误，有自己的超时策略。
- **取消**：拥有者自己被取消了，比如 `!kill`、超时、关机宽限期到期。拥有者的 future 被 drop，资源跟着 drop，执行 `Drop`。每次 `!kill` 都会走这条路，所以要按正常路径设计和测试。

发起取消全是同步的：drop future、`CancellationToken::cancel()`、关 fd、发 kill 信号、设取消标志。取消真正完成平时没人等，只有关机时由 `Scope::close` 等。

规则：

1. **`Drop` 只同步发起，不阻塞，也不 spawn。** 没有 reaper，也没有 Background。
2. **外部资源优先把生命周期绑在连接或 fd 上。** 连接一断，对端自己收尾；崩溃时内核也会关 fd，所以连崩溃都能覆盖。
   - LLM 请求：drop 掉流就是断开连接。
   - pi：跑在 stdio 上，可以直接杀进程。
   - VM 命令：guest 在连接断开时杀掉命令。
   - 浏览器：CDP 的 `Target.createBrowserContext` 带 `disposeOnDetach`，调试会话断开时销毁 context。
   - 杀进程要杀整棵树，用进程组或 cgroup。只杀直接子进程的话，孙进程还活着，还开着输出管道。
3. **对端只认 API 调用的**：`Drop` 里 `try_send` 一条停止命令给持有那条连接的常驻服务，由它去调 API。它在 services scope 里，关机时按顺序关。
4. **崩溃时 `Drop` 不会执行**：启动时按标签清理孤儿，包括 VM 里的命令和 pi 进程；MCP 的 job token 带过期时间。
5. **只有正常结束时要等结果或要报错的类型才有 `close`**，比如要拿退出码、要把待发消息发完、要提交事务。其它类型只有 `Drop`。
6. **`close` 跟着所有权走。** 谁拥有，谁在自己正常路径的末尾调。拥有需要 close 的字段的结构体，自己也要有 `close`，按创建的反序关字段。`close` 拿 `self`，一个值只会在一个地方被 close。body 里的 `?` 不能跳过 `close`：先拿到结果，再 close，最后才处理结果。
7. **`close` 自己被 drop 也要安全。** 中途任何一个 `await` 被丢掉，`Drop` 都还能按取消路径收拾。"已关完"的标记放在最后一步。
8. **不在 `Drop` 里报警，也不用 drop bomb。** 取消就是 drop，报警只会是噪音。忘了调 `close` 由测试来抓：fake 环境记下"因为连接断开而被杀"的资源数，正常路径的测试断言它为 0。

```rust
pub struct VmCommand {
    conn: GuestConn, // guest 看到连接断开，就杀掉这条命令
}

impl VmCommand {
    pub async fn read_output(&mut self, limit: usize) -> Result<Output>;

    /// 收尾：给命令 grace 时间自己退出，到时间就让 guest 杀掉，再等退出码。
    /// grace 是策略，不是防卡死的保险；卡住时由外层工具调用的超时 drop 掉。
    pub async fn close(self, grace: Duration) -> Result<ExitStatus>;
}
// 没有 Drop impl：取消路径就是 GuestConn 被 drop，socket 关闭

async fn exec(call: ExecCall, vm: &Vm) -> Result<ToolOutput> {
    let mut cmd = vm.spawn(&call.command).await?;
    let output = cmd.read_output(call.limit).await; // 这里先不用 ?
    let status = cmd.close(EXIT_GRACE).await;       // 不管 output 成败，都会走到这一行
    Ok(ToolOutput::exec(output?, status?))
}
```

语言级的 async drop（`#![feature(async_drop)]`）还是 nightly 上的实验特性，没有稳定时间表。就算稳定了，`select!`、`JoinSet` 和运行时都是同步 drop future 的，取消时执行的仍然只是同步的 `Drop`；它能省掉的只是"记得调 close"这一步。不用。

### cancellation safety

用 drop 取消，每个 `await` 都可能是终点。被 drop 的 future 自己的局部变量会跟着消失，没人看得到它们停在一半的样子；要管的只是活过这次 drop 的状态。审查时，在每个拥有 scope 的任务最外层那一处 `select!` 或 `run_until_cancelled`，逐个看被 drop 的 future 从外面借了哪些东西。turn 的情况：

| 活下来的状态 | 可能出的问题 | 规则 |
|---|---|---|
| 核心 | 停在一次状态转移的中间 | 转移是同步的，`await` 只在两次转移之间 |
| 分段器 | 群里已经发了，账上没记 | 交给 sender 之后立刻同步记账，中间没有 `await`。`mpsc::Sender::send` 在等待中被 drop 时，保证消息没发出去 |
| 平台连接 | 一帧写到一半，整条连接坏掉 | 共享连接只由它自己的任务读写，其他人经 channel 交接 |
| steer 通道 | 消息取出来了又丢了 | 只用同步的 `try_recv` |
| 数据库 | 写到一半 | 用事务；查询半途被 drop 的连接，sqlx 下次使用前会先读完残留的响应 |
| turn 记录 | 结束时的写入被打断 | 事务回滚，等同崩溃，启动时记为 `Lost` |

`select!` 循环里只放 cancel-safe 的分支：

- **可以放**：
  - `mpsc::Receiver::recv`、`CancellationToken::cancelled`、`JoinSet::join_next`；
  - `FramedRead` 加 `LinesCodec` 的 `next()`：缓冲区在流里，不在 future 里。`LinesCodec` 只按 `\n` 切，满足 pi 的要求，要设最大行长；
  - `sleep_until(deadline)`，或者在循环外 pin 住、反复使用的 `Sleep`。
- **不能放**：
  - `read_line`、`read_exact`、`write_all`；
  - 每轮新建的 `sleep(dur)`：每次重建都会把计时器重置。

不拿着锁跨 `await` 修改不变量，clippy 的 `await_holding_lock` 能查到一部分。

测试：在每个 poll 点 drop 一次。

1. 用 fake provider 和 fake 工具跑一个 turn，数出它总共被 poll 了 N 次。
2. 再跑 N 遍，第 k 遍在第 k 次 poll 之后 drop。
3. 每次 drop 后检查：
   - 核心等于对自己快照的重放；
   - 分段器记的"已发"，和 fake sender 实际收到的一致；
   - fake 连接没有收到半帧；
   - 没有泄漏的命令。

用 tokio 的 `start_paused`，结果是确定的。

### 超时

上限只设在工作单元的边界上，单元内部的 `await` 不套超时：拥有者一被取消，内部卡住的 future 也跟着被 drop。

| 位置 | 写几次 | 性质 |
|---|---|---|
| `Scope::close(grace)` | `Scope` 里一次 | 关机时防卡死 |
| turn 的墙钟上限 | `run_turn` 的 `select!` 里一个分支 | 防卡死 |
| 工具调用上限 | 工具执行器里一次，具体工具里不写 | 防卡死 |
| 网络客户端 | 配置里一次：LLM 客户端的连接和读超时、sqlx 的 `acquire_timeout` 和 Postgres 的 `statement_timeout`、平台连接的心跳 | 防卡死 |
| 先等再升级 | 按需 | 策略，比如 `close` 先给命令时间自己退出 |
| 常驻服务里的等待表 | 每张表一次 | 防泄漏，比如 OneBot 的 echo 配对表。常驻服务外面没有取消替它兜底 |

审查规则：`timeout(` 和 `sleep(` 只出现在上表这些地方。

前提：上限只对停在 `await` 上的 future 有效。所以：
- async 里不阻塞；
- `spawn_blocking` 配取消标志，因为 abort 对已经开始跑的 blocking 任务无效；
- `Drop` 里不阻塞。

真破了这几条，还有 systemd 的 `TimeoutStopSec` 在最外层兜着。

## 数据和运行模型

2026-10-26 至 10-27 讨论定下。总览：ledger 记录群里说了什么；turn 记录记下 Max 在幕后做了什么；核心是决定 turn 下一步做什么的规则；驱动和会话 actor 负责所有 I/O。

### 原则

1. **库里存事实，只追加。** ledger 和 turn 记录都没有 UPDATE，也没有可变的状态列。
2. **状态由记录推出来，不另存。** turn 处在哪个阶段，看它有哪几种记录就知道。
3. **存输入，不存派生结果。** 核心的序列化就是它的输入日志，transcript 这些派生状态不存。核心合成的东西（比如中断时补的"已取消"结果）也不存，重放时再合成一次。唯一的例外是结局，见 [turn 记录](#turn-记录)。
4. **只有一条代码路径。** 核心的每个输入方法都是"构造一条输入，再 apply"，重放就是对日志逐条 apply。
5. **核心跑的时候不碰库。** 一次运行只写两回：开始时写一个标记；结束或挂起时，把核心整个存成一份快照。崩溃时正在跑的 turn 不恢复，见[重启恢复](#重启恢复)。
6. **上下文只在核心里变。** 基础上下文在创建核心时传入，之后不变；transcript 只追加；裁剪只作用在每次的请求上；协议适配层降级时只删不加。
7. **别处已有的存引用，只在 turn 里有的存本体。** ledger 消息和媒体文件存引用；推理 blob、工具输出和基础上下文存本体。
8. **中立格式，原始数据透传，只在边缘降级。** 平台消息和模型条目用同一种做法：中间是中立的类型化结构，平台或 provider 的原始数据原样带着，有损转换只发生在适配器往外发的那一步。见[消息格式](#消息格式)和[条目](#条目)。

### ledger

ledger 是会话账本：所有平台上、所有人（包括 Max 自己）说过的每一条消息，统一成同一种[消息格式](#消息格式)，按到达顺序只追加。它回答"群里发生了什么"。

- 每条消息：会话、发送者、内容、原始 payload、平台 id、到达序号、时间。
- Max 发出的每一段消息额外带 turn id 和段号。

Max 在幕后做的事（模型怎么想、调了什么工具）不进 ledger。ledger 和 turn 之间只有三处引用：Max 发出的消息指向产生它的 turn；turn 指向触发它的消息；steer 输入引用对应的消息。以后 turn 的基础上下文从 ledger（加上记忆和摘要）投影出来，不读别的 turn 的 transcript。

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

// 入库的统一格式，由 Inbound 在入库事务里转换得到
struct Message { nodes: Vec<Node>, raw: serde_json::Value, /* 会话、发送者等 */ }

enum Node {
    Text(String),
    Mention { target: MentionTarget, display: String }, // 某个 principal，或者全体
    Emote(Emote),                                       // 平台表情，带名字作兜底
    Media { media: Option<MediaRef>, meta: MediaMeta },
    Card(Card),
    Forward(ForwardRef),
    Unsupported(Unsupported),
}

// 模型能写的部分。转发、卡片、不支持这些模型写不了，这里没有对应变体
struct Draft { reply_to: Option<MessageId>, nodes: Vec<DraftNode> }

enum DraftNode {
    Text(String),
    Mention(PrincipalId),
    Emote(EmoteRef),
    Media(OutboundMediaRef), // 引用已有的图片或表情包
}
```

- 发送时每个适配器写自己的 `fn lower(&Draft) -> 原生消息`，没有通用的降级类型。
- 给模型看的文本由一个渲染函数从 `Message` 生成，不是单独的类型。
- 模型用 principal 句柄提及人，发送时再解析成目标平台的账号，沿用 [ADR 004](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/004-canonical-handles-for-the-model.md)。

**镜像**保留，v1 不做，上线前要做。这些东西都等做镜像时再加：

- 能力表：每个端点对每种节点是原生、转文本还是丢弃。
- 降级记录。
- 每个端点的投递回执，以及 echo 对账。

v1 的 ledger 已经存了原始 payload 和文本兜底，到时不用迁移数据。

模型那边的[条目](#条目)是同一个做法：`Item` 的 `kind` 对应节点，`opaque` 对应原始 payload，协议适配层的降级对应发送时的 `lower`。

### turn 记录

一个请求对应一个 turn。turn 在库里有四种记录，全部只追加（2026-10-27 定）：

```rust
// 请求被接受时
struct TurnAccepted { turn, conversation, ordinal /* t#，给模型引用 */, trigger /* 消息或自动化 */, initiator, accepted_at }
// 核心开始跑时，首次或恢复都算一次 attempt。只是个标记
struct TurnStarted { turn, attempt, started_at }
// 这次运行结束时（turn 结束或挂起），把核心整个存下来
struct TurnSnapshot { turn, attempt, run: RunRecord, taken_at }
// 结局
struct TurnFinished { turn, outcome: Outcome, finished_at }

// 核心的序列化：只有输入。反序列化就是重放
struct RunRecord { core_version, spec: RunSpec, base: Context, inputs: Vec<Input> }

enum Input {
    ModelOutput(ModelOutput),                        // 见"条目"
    PartialOutput { text: String },                  // 模型流到一半被打断时，已经发出去的文本
    ToolResult { call: CallId, output: ToolOutput }, // 恢复时补的是"进程重启，结果未知"
    Steer { message: MessageId, item: Item },        // 引用 ledger 消息，同时存核心看到的样子
    Interrupt { reason: String },
    Fail { reason: FailReason },
}

enum Outcome { Answered, Silent, Interrupted, Failed(FailReason), Expired, Lost }
```

写入时机：

| 情况 | 写什么 |
|---|---|
| 开始跑（首次或恢复） | `TurnStarted` |
| turn 结束 | `TurnSnapshot` 加 `TurnFinished`，同一个事务 |
| 正常重启时挂起 | 只写 `TurnSnapshot` |
| 崩溃 | 什么都没写 |

- **为什么接受时就写**：@、回复、命令可以从消息本身重新判断，但 intent 分类和自动化触发不行，所以"接受了这个请求"这件事本身要记下来。
- **只有一种快照**：结束的 turn 和挂起的 turn 存的是同一种 `RunRecord`，区别只在后面有没有跟一条结局。核心不在运行中途写库，所以也没有"库里一份、内存里一份"的问题。
- **状态**：
  - 有 `TurnFinished`：已结束。没回复的请求，就是没有结局的 turn。
  - 没有 `TurnStarted`：还在排队。
  - 最新一次 attempt 有快照：挂起中。
  - 最新一次 attempt 有 `TurnStarted`、没有快照：在当前进程里跑着；启动时看到这种，就是崩溃时正在跑。
- **为什么要 attempt**：恢复之后如果又崩了，不能再从旧快照重来一遍，因为恢复后它可能已经发过言、跑过工具。按 attempt 看，最新一次有开始、没快照，就说明是崩了。
- **结局**：唯一存下来的派生结果。它本来也能从输入推出来，但查"哪些请求还没回复"要靠它，所以写下来；重放时校验它和核心算出来的一致。`Expired` 和 `Lost` 例外，它们由启动流程直接写：`Expired` 表示这个 turn 没有再跑，`Lost` 表示崩溃时它正在跑。
- Max 回复的正文在 ledger 里，不在结局里。

### 条目

基础上下文、transcript 和请求都由条目组成：

```rust
struct Item {
    kind: ItemKind,
    source: Option<ModelTag>,          // 模型产生的条目，记下协议和模型
    opaque: Option<serde_json::Value>, // provider 附带的不透明字段，核心只搬运不解读
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

自写，sans-I/O（2026-10-26 定）。2026-10 调研过 rig、yoagent、adk-rust、autoagents、swiftide-agents、aisdk、genai，以及 pi-agent（第三方的 Rust 移植，官方仓库里没有这份代码）。它们的共同问题是自带 provider 层或 session 层，和 async-openai、ledger 冲突；体量也远大于我们要用的部分：rig-core 加 rig-agent 约 13 万行，yoagent 约 3.9 万行。自写预计 1.2k–1.5k 行，包含两种协议的适配。借鉴两处：rig-agent 的 `AgentRun`，把 loop 写成 sans-I/O 状态机；pi 和 yoagent 的 steer 语义。

核心是纯状态机：方法都是同步的，每次调用是一次完整的状态转移；不 `await`、不 spawn、不读时钟、不碰网络。草图，签名 **待定**：

```rust
struct Run {
    spec: RunSpec,            // 不变：模型档、上限、基础工具、token 估算函数
    base: Context,            // 不变：创建时传入的基础上下文
    transcript: Vec<Item>,    // 本 turn 产生的条目，只追加
    phase: Phase,             // 等模型、等工具、已结束
    round: u32,
    outstanding: Vec<CallId>, // 还没回结果的工具调用
    pending_steer: Vec<Item>, // 等下一次调模型前注入
    log: Vec<Input>,          // 喂过的所有输入
}

enum Step {
    CallModel(Request),       // 请求由核心完整构造，驱动不再改动
    RunTools(Vec<ToolCall>),
    Finished(Outcome),
}

impl Run {
    fn new(spec: RunSpec, base: Context) -> Self;
    fn replay(record: &RunRecord) -> Result<Self, ReplayError>; // 核心版本不同也算错误
    fn resume(record: &RunRecord) -> Result<Self, ReplayError>; // 重放，再补"结果未知"
    fn snapshot(&self) -> RunRecord;
    fn next_step(&mut self) -> Step;
    fn model_output(&mut self, out: ModelOutput);
    fn partial_output(&mut self, text: String);
    fn tool_result(&mut self, call: CallId, out: ToolOutput);
    fn steer(&mut self, message: MessageId, item: Item); // 随时可塞，核心决定何时生效
    fn interrupt(&mut self, reason: String);
    fn fail(&mut self, reason: FailReason);
}
```

核心负责的规则：

- **构造请求**：请求由基础上下文、transcript 和当前活动工具组成。超出预算时，按确定的规则裁掉较早的工具输出；裁剪只作用在这一次请求上，不改 transcript。基础上下文在创建时已经裁到预算内。
- **活动工具集**：spec 里的基础工具，加上 transcript 里已经加载的 skill 工具包。只增不减，由日志推出来，所以重放结果一致。格式不对或还没放开的工具调用，直接回错误结果，不交给驱动执行。
- **轮数和 token 上限。**
- **steer 的时机**：等这一批工具结果都回来之后、下一次调模型之前。
- **中断**：给还没回结果的工具调用补一条"已取消"的结果，保证历史合法。Responses 要求每个 `function_call` 都有对应的 output。
- **恢复**：`resume` 先重放，再给还在等结果的工具调用各补一条 `ToolResult`"进程重启，结果未知"，交给模型判断。这几条走正常的输入方法、进日志，否则从最终快照重放时会出现"调用还没结果，后面却跟着下一次模型输出"。快照的日志允许以"还在等结果"结尾，这是合法的挂起状态，只有 `resume` 能从这里接着走。挂起时不补：快照只记停下那一刻的事实，没恢复的 turn 也就不会留下编出来的结果。
- **结束判断**：模型这一轮只输出文本、没有工具调用，就算结束；连文本也没有，结局就是 `Silent`。

### 驱动和协议适配

驱动是 turn 任务，跑在 turn scope 里。它持有模型客户端、工具执行器、steer 接收端、分段器和数据库连接，负责：

- 把核心给的请求交给协议适配层降级成线上格式，用 async-openai 发出去、读流；可重试的错误由驱动重试。
- 流式文本交给分段器，由 sender 发到群里，每段都落进 ledger。
- 并发执行工具，把结果喂回核心。
- 处理取消信号、停止信号和墙钟超时。
- 这次运行结束时，写快照和结局，或者只写快照。

协议适配层是无状态的，两次调用之间什么也不保留。降级只删条目或调整形状，不添加内容：

- `source` 和当前模型对不上的 `opaque` 直接丢掉。turn 内的模型由 spec 固定，正常情况下总能对上，这条只是兜底。
- **Responses**：本 turn 内的推理条目全部回传。skill 加载用客户端执行的 `tool_search`，需要 gpt-5.4 及以后的模型：`use_skill` 对应 `tool_search_call`，回 `tool_search_output` 时带上工具包。这几个条目和推理一样，作为不透明条目原样按位置回传。新工具注入在上下文末尾，缓存不受影响。
- **Chat**：同一轮的几个条目拼回一条 assistant 消息；`reasoning_content` 在本 turn 的工具调用循环里回传。Chat 没有 tool search，skill 加载时只能把 tools 数组加长，每加载一次缓存失效一次；另一个选择是用固定的元工具 `call_tool(name, args)`。选哪个 **待定**，做工具时实测。

### 会话 actor

会话 actor 是普通的 async 代码，状态不持久化（2026-10-26 定）。它持有没回复请求的内存队列、当前 turn 的句柄和 steer 发送端、job 表，负责判定一条消息是不是请求、反馈交给谁、下一个开哪个 turn。

排队顺序不存。它由"没回复的请求"加上排队规则（比如用户请求排在自动化前面）算出来，运行中和重启后用同一套规则。重启会丢掉这些：

- 已经路由给 turn、但核心还没消费的反馈。
- 后台 job。pi 的会话文件还留在 VM 里，但不会自动接上。
- 计数，比如 intent 每小时上限，重启后清零。

### 运行流程

1. **消息进来**：适配器归一化，写进 ledger，交给会话 actor。
2. **判定**：触发规则包括 @、回复、命令和 intent 分类；自动化触发也走这个入口。
   - 是请求：写 `TurnAccepted`，放进内存队列。
   - 是当前 turn 发起者的反馈：交给 turn 的 steer 通道。
   - 都不是：它只作为上下文存在。
3. **开始 turn**：没有 turn 在跑时，按排队规则取下一个没回复的请求：
   1. 从 ledger 加上记忆和摘要，投影出基础上下文，裁到预算内。
   2. 写 `TurnStarted`（attempt 1）。
   3. 调 `Run::new(spec, base)`，在 turn scope 里起驱动。
4. **循环**：驱动先取空 steer 通道，然后问 `next_step`。循环中途不写 turn 记录：
   - `CallModel`：发请求、读流，文本边流边分段发出；流结束后调 `model_output`。
   - `RunTools`：并发执行，每个结果调一次 `tool_result`。
   - `Finished`：在一个事务里写快照和 `TurnFinished`，通知 actor 开下一个。
5. **取消（`!kill`）**：见[取消](#取消)。
6. **正常重启和启动**：见[重启恢复](#重启恢复)。

### 取消

取消靠 drop，每个 turn 只在最外层等信号：取消（`!kill`）、墙钟上限，以及正常重启时停止宽限期到期。`drive` 被 drop 时，正在读的 HTTP 流和整批工具 future 会一起被丢掉。核心的每次调用都是一次完整的状态转移，所以 drop 无论发生在哪个 `await` 点，核心都处在合法状态。之后驱动把被打断的那次模型调用已经发出去的文本喂成 `partial_output`，再调 `interrupt` 补齐结果。

steer 也不用在每个 `await` 点盯着：驱动每次问 `next_step` 之前把通道里的消息取空就行。工具批次跑着的时候，steer 消息先留在通道里，等这批结束后再进核心，效果和核心的规则一致。loop 结束时通道里还剩的消息，由会话 actor 当作下一个 turn 的输入。

```rust
enum End { Finished(Outcome), Suspended }

async fn run_turn(mut run: Run, cx: &mut TurnCx, sig: &Signals) -> Result<()> {
    let end = tokio::select! {
        end = drive(&mut run, cx, sig) => end?,
        _ = sig.cancel.cancelled() => {
            if let Some(text) = cx.segmenter.take_published() {
                run.partial_output(text); // 被打断的那次模型调用已经发出去的文本
            }
            run.interrupt(sig.cancel_reason());
            End::Finished(Outcome::Interrupted)
        }
        _ = sig.turn_deadline() => { // 墙钟上限
            if let Some(text) = cx.segmenter.take_published() {
                run.partial_output(text);
            }
            run.fail(FailReason::Timeout);
            End::Finished(Outcome::Failed(FailReason::Timeout))
        }
        _ = sig.stop_deadline() => { // 停止信号之后，宽限期到了这一步还没跑完
            if let Some(text) = cx.segmenter.take_published() {
                run.partial_output(text);
            }
            End::Suspended // 没跑完的工具调用保持未完成，恢复时再补结果
        }
    };
    // 被打断后也要写完，靠 scope 的宽限期
    match end {
        End::Finished(outcome) => cx.turn_log.finish(run.snapshot(), outcome).await?, // 一个事务
        End::Suspended => cx.turn_log.suspend(run.snapshot()).await?,
    }
    Ok(())
}

async fn drive(run: &mut Run, cx: &mut TurnCx, sig: &Signals) -> Result<End> {
    loop {
        if sig.stop.is_cancelled() {
            return Ok(End::Suspended); // 正常重启：在下一次问 next_step 之前停下
        }
        while let Ok(msg) = cx.steer_rx.try_recv() {
            run.steer(msg.id, msg.item);
        }
        match run.next_step() {
            Step::CallModel(req) => {
                match stream_model(&cx.client, req, &mut cx.segmenter).await {
                    Ok(out) => run.model_output(out),
                    Err(e) => run.fail(e.into()),
                }
            }
            Step::RunTools(calls) => {
                let mut batch: FuturesUnordered<_> =
                    calls.into_iter().map(|c| cx.tools.execute(c)).collect();
                while let Some((id, out)) = batch.next().await {
                    run.tool_result(id, out); // 同一批里先跑完的，挂起时也已经记下
                }
            }
            Step::Finished(outcome) => return Ok(End::Finished(outcome)),
        }
    }
}
```

`tokio::select!` 在执行分支体之前会先 drop 所有分支的 future，所以分支体里可以再用 `run` 和 `cx`。信号单独放在 `Signals` 里，因为 `drive` 正可变借用着 `cx`。

只靠 drop 不够、需要多做一步的地方：

- **每个拥有 scope 的任务的最外层**：一处 `run_until_cancelled` 或 `select!`。
- **有外部副作用、drop 不会自动停下的**：比如 VM 里的命令、pi 进程。生命周期绑在连接上，`Drop` 里只同步发起，见[资源怎么结束](#资源怎么结束)。
- **不能只做一半的**：发消息交给平台 sender；数据库写入用事务，sqlx 的事务没提交就被 drop 会回滚。其余见 [cancellation safety](#cancellation-safety)。
- **没有 `await` 点的长时间 CPU 计算**：drop 不掉。放进 scope 的 `spawn_blocking`，配一个取消标志；wasm 用 epoch 中断。

### 重启恢复

2026-10-26 定：重启后在时效窗口内恢复 turn，超过窗口就不再跑。这改变了 Haskell 版"重启中断 turn"的规则。10-27 收窄为只恢复正常重启时挂起的 turn：核心跑的时候不写库，崩溃时正在跑的 turn 没有可以恢复的东西。窗口长度 **待定**，提议 5 分钟。v1 不实现恢复，但记录按这一节设计。

- **正常重启（部署、SIGTERM）**：用单独的停止信号，不走取消。驱动在下一次问 `next_step` 之前停下。当前这一步（模型调用或工具批次）有宽限期；到期还没跑完就 drop：
  - 已经发到群里的文本记成 `PartialOutput`；
  - 同一批里已经跑完的工具，照常记结果；
  - 没跑完的工具调用保持未完成，不补结果。

  然后写快照，不写结局。
- **崩溃**：什么都不写。部署走正常重启，崩溃很少，正在跑的 turn 丢了也能接受。

启动时，对每个没有结局的 turn：

- **没有 `TurnStarted`**：还在排队。窗口内按排队规则重新排队，窗口外写 `Expired`。
- **最新一次 attempt 有快照**：挂起中。窗口内写下一次 attempt 的 `TurnStarted`，调 `Run::resume`，起驱动接着跑；窗口外写 `Expired`。快照的核心版本和当前不同，也写 `Expired`，不做格式兼容。
- **最新一次 attempt 有 `TurnStarted`、没有快照**：崩溃时正在跑。写 `Lost`，不重跑。它已经发出去的消息还在 ledger 里，靠 turn id 能找到。
- 恢复和重新排队时，都重新校验发起者的权限。

expired、lost 的请求和丢掉的 job 要不要在群里说一声 **待定**。正常重启时，actor 可以在排空阶段通过 sender 发一条说明；崩溃时，可以在启动后根据 `Lost` 和 `Expired` 的 turn 补发。

### 体积和保留期

- **体积**：推理 blob 每条几 KB 到几十 KB，而且压不小；一个 turn 跑几十轮，大约几百 KB 到几 MB。v1 都存在快照的 JSONB 里，交给 Postgres 的 TOAST。以后体积成问题，再把超过阈值的内容统一挪到一张按 sha256 寻址的 blob 表，工具输出和基础上下文同样适用。
- **恢复过的 turn 有多份快照**：前面的都是最后一份的前缀。这种情况很少，不单独处理。
- **保留期**：turn 结束 N 天后，删掉最后一份以外的快照，清掉最后一份里的 `opaque` 和基础上下文，保留可读文本和 token 数。之后这个 turn 还能查看，但不能再精确重放。N **待定**。

### 测试

- 核心用同步单元测试，按剧本喂输入、检查输出，不需要 tokio 和 fake provider。至少覆盖：steer 的送达时机、中断时补齐结果、恢复时补"结果未知"、格式不对和还没放开的工具调用、轮数上限、活动工具集只增不减。
- 每个核心测试结束时断言 `run == Run::replay(&run.snapshot())`，保证线上路径和重放路径一致。
- 挂起和恢复：在每个阶段（等模型、工具批次跑到一半）做快照再 `resume`，断言结果补齐、能接着跑；恢复后的最终快照也要能从头重放。
- 驱动用 tokio 的 `start_paused` 加 fake provider，测取消、停止、超时和宽限期。
- 协议适配层用录下来的 Responses 和 Chat 响应做 fixture，测推理条目和不透明字段原样往返。
- 快照就是核心的输入序列，线上任何一次 turn 都能离线精确复现。

### 同一模式的其它地方

判断标准：有协议状态、规则复杂、需要精确测试。符合的有：

- 流式分段器：喂入文本增量，吐出可以发送的段落。
- pi RPC 适配器：在途命令、`agent_settled` 的判定、`clear_queue` 和 `abort` 的顺序。
- OneBot 的 echo 关联：请求和响应的配对、超时。
- 镜像投递（v1 不做）：回执和 echo 对账。

会话 actor 主要在编排 I/O，保持普通的 async 代码。

### 待定

- 基础上下文怎么存：存渲染后的内容，还是存"配方"（引用了哪些 ledger 条目、哪些摘要版本）加哈希、恢复时重算校验。我倾向前者，最简单，也不要求上下文投影可以复现。
- 保留期 N。
- 裁剪规则：裁哪些工具输出、裁成什么样。
- Chat 协议上 skill 加载用哪种方式。
- 恢复窗口多长；expired、lost 的请求和丢掉的 job 要不要在群里说一声。

## 后台 agent

v1 之后做。

- 每个 job 驱动群 VM 里的一个 pi 进程，通过 stdio 上的 RPC JSONL 通信。
- Max 定义自己的 `AgentBackend` 接口：开任务、steer、中断、事件流、结束报告。按 codex app-server 也能实现的标准设计，但只实现 pi。
- 领域工具走 MCP 回调。job 启动时登记一个绑定群和任务的 token，结束时吊销。MCP 服务按 token 鉴权，只开放只读工具，比如 `context_search`、`context_read`、`memory_list`。
- 会影响群的动作（发消息、发文件、撤回、禁言、建自动化）不给后台 agent。它的结果作为报告交回前台 turn，由前台决定怎么说。

pi 适配器要处理的行为：

- `steer` 不打断正在跑的工具，要等这一轮工具调用都跑完、下一次 LLM 调用之前才送达。默认是 `one-at-a-time`，要改成 `all`。
- `abort` 不清队列。要让 pi 体面地停下（收尾路径）时，先发 `clear_queue` 再发 `abort`；取消路径直接杀进程。
- pi 读到 stdin EOF 会不会自己退出，要实测。这决定了能不能把它的生命周期直接绑在 stdio 上。
- `agent_end` 不代表结束，要等 `agent_settled`。
- stdout 只按 LF 切行，不能用会把 U+2028 当换行的读行器。
- pi 1.0 默认可能把 MCP 工具放在 codemode 后面，要配成 `direct`。这条还没在官方文档里确认。

pi 2026-04 被 Earendil 收购，仓库搬到了 `earendil-works/pi`，几乎每天发补丁，RPC 协议没有版本字段。所以在 Nix 里钉版本，录几段真实的 JSONL 做适配器回放测试，升级前先跑这些测试。

## 审阅性约束

- 直接依赖集中写在 workspace 根 `Cargo.toml` 的 `[workspace.dependencies]` 里。新增依赖单独提交，并在提交里写理由。
- 用 cargo-deny 检查许可证、安全公告和重复版本。
- 每个提交都要能单独审完。行数上限 **待定**。
- crate 数量保持少，按需再拆。初始划分 **待定**。
- 不写 legacy 和兼容代码，要删就删干净。
- ADR 只记真正的取舍。
- `timeout(` 和 `sleep(` 只出现在[超时](#超时)一节列出的地方；`select!` 循环里只放 cancel-safe 的分支，见 [cancellation safety](#cancellation-safety)。

## 测试

- 用 cargo-nextest 跑全部测试。
- 纯逻辑用 fake provider 和 fake 平台测；超时和宽限期用 tokio 的 `start_paused`。
- 取消：在每个 poll 点 drop 一次，见 [cancellation safety](#cancellation-safety)；正常路径的测试断言没有资源是因为连接断开而被杀的，以此抓漏调的 `close`。
- 数据库测试用 `#[sqlx::test]`，每个测试一个临时库；本地用 devenv 起的 Postgres。
- prompt 渲染用 insta 快照。是否取代 `max-prompt-flow` 生成的文档 **待定**。
- 平台层用录下来的 NapCat 和 Matrix 事件做 fixture。fixture 里只用假的 QQ 号和 Matrix ID。

## 上线：drop-in 替换的条件

- [功能对齐清单](#功能对齐清单)全部完成。
- 写一个数据导入程序，把 Haskell 版数据库一次性导入新 schema。它要能重复跑，上线前先演练。
- NixOS module 的接口不保持兼容，tank 的 nix-config 跟着改，见[配置](#配置)。
- 切换：在 `rust` 分支上 `git merge -s ours main`，保留 main 期间的 Haskell 历史、内容全部用 Rust 的；然后 main 快进到 `rust`，不 force push。main 最后一个 Haskell 提交打 tag `haskell-final`。
- 回滚：Haskell 版保留到 Rust 版稳定为止；Rust 版上线后产生的新数据怎么处理 **待定**。

## 待讨论

1. ~~代码放在哪~~：已定（2026-10-27），放在这个仓库的 `rust` 分支，见文首。
2. 初始 crate 划分。
3. v1 带不带工具；@ 以外的 intent 分类进不进 v1。
4. 新 schema 的设计，以及从旧库导入的映射。
5. ~~NixOS module 的接口要不要保持不变~~：已定（2026-10-27），不保持，见[配置](#配置)。
6. Matrix 加密房间要不要支持。Haskell 版目前不支持，这决定了要不要开 matrix-sdk 的 E2EE 和 sqlite 特性。
7. v1 的测试环境：测试用 QQ 号、测试群和测试 Matrix 房间。NapCat 能不能同时连两个 WS 客户端还没验证。
8. Rust 工具链版本和 edition。
9. 每个提交的大小上限。
10. [数据和运行模型](#数据和运行模型)一节末尾的待定项：基础上下文的存法、保留期、裁剪规则、Chat 上的 skill 加载方式、恢复窗口和通知。
11. 身份模型：principal 和各平台账号怎么对应。v1 的发送者和提及就要用到它；跨平台合并同一个人和镜像一起做。
