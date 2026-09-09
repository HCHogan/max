# Max 上下文与记忆：生产审计及 Hermes / OpenClaw 对照

调研日期：2026-09-09。结论：保留 Max 的消息账本、会话隔离、分层摘要和版本化存储；先修复记忆写入与主体身份的两个真实缺陷，再补工具轮预算、检索质量和经验积累。换向量库、扩大窗口或另接一个记忆服务，都不会自动解决这两个缺陷。

## 范围与证据

- h610 正在运行 `max-0.18.0`；Nix derivation 的 `MAX_GIT_REV=070d43d`，与本地 `070d43d1a8fd41c45772dd7e0be87dfae86f1bdb` 一致。检查时服务 active、`NRestarts=0`。
- 当前生产库是 `max`。查询设置 read-only、20 秒 statement timeout、2 秒 lock timeout；主要汇总在 repeatable-read 事务中取得。没有修改生产数据、重新执行提案、调用生产模型做实验或部署变更。
- 主要快照：2026-09-09 05:03:02 UTC（悉尼 15:03:02）；“近七天”相对此时。少量定向追查在相邻几分钟进行。数据仍在增长。
- Hermes 源码固定为 [`990473a79c6b0396b0a648fdd85ee8f7a5c267d3`](https://github.com/NousResearch/hermes-agent/tree/990473a79c6b0396b0a648fdd85ee8f7a5c267d3)。
- OpenClaw 源码固定为 [`9636ae49e0018fd24bc9aa1fa73af6bf28e05ec0`](https://github.com/openclaw/openclaw/tree/9636ae49e0018fd24bc9aa1fa73af6bf28e05ec0)。上游变化很快，下面的默认行为以此次源码为准，不把可选插件当作默认实现。
- [可重复执行的 SQL](2026-09-09-context-memory-audit.sql) 只输出汇总和内部标识。报告不保存群聊原文、个人画像内容或凭据。

## 生产上哪些机制已经正常工作

| 项目 | 快照结果 | 意义 |
| --- | ---: | --- |
| 原始消息 | 164,596 | 审计有真实长期历史支撑 |
| 活跃 compartment | 1,406 | 覆盖 164,509 条来源消息，全部已有 embedding |
| Historian capture | 1,406 published，20 abandoned | 当时没有 pending/retry/running 积压；abandoned 是历史记录 |
| Historian cursor 以下未被活跃分区覆盖的消息 | 0 | 此项覆盖检查通过；不等于完成了全部来源 hash 和语义正确性校验 |
| 记忆 | 490 active、7 permanent、14 archived、22 superseded | 533 条均已有 embedding |
| 自动提案 | 250 add 成功、6 update 成功、8 archive 成功；89 拒绝 | 记忆创建在运行，更新明显异常 |

因此，主要问题并不是 Historian 没运行、没有向量，或原始记录被摘要删除。Max 已有的不可变来源、摘要展开、CAS 发布和 scope 边界值得保留。参见 [ADR-001](../adr/001-context-memory-foundations.md)、[ContextMaterialization](../../src/Max/ContextMaterialization.hs)、[EpisodeStore](../../src/Max/EpisodeStore.hs)。

## 1. 确定缺陷：自动记忆更新长期提交错误版本

全部 94 次自动 update 提案中只有 6 次成功，88 次被拒绝，拒绝率 93.6%。与提案提交前的 `memory_versions` 对照：

- 87 次：同一会话、active 记忆，但提交版本恰好等于已有版本加 1。
- 1 次：版本正确，但目标为 permanent，自动 Historian 无权改写；这是预期保护。
- 最后一次成功的 Historian update 是 2026-08-13；拒绝一直持续到 2026-09-08。

这不是只根据当前版本推测。capture `1461 / 1440 / 1415` 对应的实际模型请求 `30328 / 30063 / 29695` 都提供了 `id=579 version=1 lifecycle=active`；模型却返回 `version=2`。记忆 579 在三天内被这样更新七次，仍停在 v1。

一个实际受影响的技术事实是 memory 595：旧记忆仍说 Max 沙盒迁移尚未部署；capture 1390 提议保存“旧、新沙盒均已验收为 systemd-nspawn，vmspawn 仍未生效”的后续状态，但更新被拒绝。这证明更正没有进入语义记忆；它本身不证明该更正描述的宿主状态在现在仍然成立，也不证明 Max 已经因此答错。

原因在模型接口的表达：`Historian` 给字段起名 `version`，示例固定写 2，存储层却将它解释为 `ExpectedVersion`，即更新前的版本。实际输出强烈支持模型把它当成目标版本或照抄示例。数据库 CAS 拒绝是正确行为，不能为提高成功率取消。当前摘要发布和提案应用独立，`rejected_store` 会被记录，但摘要成功发布后没有针对该提案的重新生成流程。参见 [Historian 的 catalog 与 proposal prompt](../../src/Max/Historian.hs)、[applyMemoryProposal](../../src/Max/EpisodeStore.hs)、[runContentUpdate](../../src/Max/MemoryStore.hs)。

建议：

1. 明确使用 `expected_version`，示例写成“提供 id=5、version=1，更新必须提交 expected_version=1；新版本由服务器生成”。更好的接口是返回不透明的观察句柄，由 host 解析成原先观察到的 id/version。
2. 保留真正的并发 CAS；不要自动把错误版本替换成数据库的最新版本，也不要把历史提案全部重新执行。
3. 在已经确认 scope 可见的后台诊断中，区分 stale version、future version、permanent protection；对不可见目标继续统一拒绝，避免泄漏存在性。
4. 为可恢复的提案建立独立重评状态，重新读取当前事实和证据后再生成变更。摘要成功不能代表记忆变更也成功。

Hermes 的借鉴点是**模型友好的编辑闭环**：唯一旧文本匹配、当前容量反馈，以及一次原子 batch 完成替换与新增；不需要模型生成版本号。Max 应借它的交互清晰度，保留自己的并发保护。参见 [Hermes memory tool](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/tools/memory_tool.py) 和 [持久记忆说明](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/)。

## 2. 确定缺陷：两条永久个人记忆挂在错误主体上

memory `534 / 536` 的 `scope_id` 是平台用户号，在 `principals` 中不存在。通过当前平台身份表可分别解析到 principal `982 / 784`。

这两条不是 Historian 提案：execution journal `2685 / 2773` 显示，`memory_save` 曾直接接收平台号并成功创建。当前代码仍然把可选 `user_id` 当作任意整数交给 `subjectNamespace`；入库检查会话、容量和重复，却没有验证这个主体确实是当前 scope 中的 canonical principal。

当前发言者的记忆块按 `authorPrincipalId` 查询，所以这两条不会进入本人的个人记忆块。全会话 `context_search` 按来源会话查 user memories，仍可能找到它们；不能称为彻底不可检索或跨会话泄漏。参见 [MemoryControl](../../src/Max/Effects/MemoryControl.hs)、[subjectNamespace](../../src/Max/Memory/Types.hs)、[listRecentMemories / admitMemory](../../src/Max/MemoryStore.hs)。

建议优先加 host 端主体解析和当前会话可引用性检查，返回可理解的错误或明确的 canonical handle。数据修复只处理身份映射唯一、来源证据可核实的条目，并检查与正确主体下的新记忆是否重复，留下审计记录。Hermes 的 profile 文件隔离不能替代 Max 的多人会话身份规则。

## 3. 优化机会：主要 token 花在常驻历史，工具轮也缺少统一预算

近七天 796 条首轮规划 trace：

| 来源 | 平均估算 token | P95 |
| --- | ---: | ---: |
| 原始历史 | 20,711 | 35,311 |
| 历史分区摘要 | 15,974 | 32,730 |
| 语义记忆 | 1,124 | 2,129 |
| System prompt | 3,838 | 4,017 |
| 完整首轮提示词 | 50,703 | 正常预算内的 795 条为 76,962 |

原始历史和摘要的内容成本约占完整提示词 72.4%。各分块估算不包含所有包装开销，不能把这些分块相加当作精确 wire token。也不能直接把首轮估算与包含后续工具轮的 usage 平均数相减，称为 tokenizer 误差。

真实 API usage 方面，Qwen 普通 `turn` 的 1,211 次调用平均输入 65,875、P95 99,989；`task/turn` 的 298 次调用最大输入 160,505。trace 中的 `max_input_tokens` 是 114,688，另有 16,384 输出限制；无附件首轮可用 98,304，有附件则 81,920。近七天 11 次普通 turn、51 次 task/turn 的实际输入超过默认 114,688。

这些长调用成功了，不能据此说当前后端窗口不足。保留的七天调用记录有两次 context-length 错误，最近一次是 9 月 3 日，其错误显示当时后端限制 80,000；它属于历史端点/窗口不匹配证据，不是当前服务持续溢出的证据。

具体的代码缺口是：首轮 `planContext` 做预算，循环主要依靠 `capToolResults` 的 **60,000 字符**高水位、30,000 字符低水位。它保留最新工具结果和 `use_skill`，但不是覆盖完整 messages、动态工具 schema、媒体及后续输出预留的逐轮预算。最近七天 272 个请求包含旧工具结果截断标记；这是含标记的请求数，不是 272 次新截断事件。另有一条首轮 trace 最终估算 81,974，超其 81,920 预算 54 token，显示最终渲染检查仍可能落在预算外。参见 [Agent loop 与 capToolResults](../../src/Max/Effects/Agent.hs)、[Context / estimator](../../src/Max/Context.hs)、[默认限额](../../src/Max/ModelCatalog/Internal.hs)。

值得借鉴 Hermes 的两点：

- **用量锚点**：记录上次 provider 真实输入/输出用量，只估算新增部分；历史发生变化则丢弃锚点。Max 还应把模型、协议、工具目录 fingerprint、稳定 prompt revision 纳入有效性判断；Hermes 当前边界 fingerprint 并不覆盖所有这些内容。参见 [usage_anchor.py](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/agent/usage_anchor.py)。
- **小的近期尾部 + 可恢复的工作摘要**：保留当前目标、用户更正、未完成事项及精确标识，再用搜索返回被移出上下文的记录。Hermes lean compaction 还会机械提取标识和恢复入口。Max 应把它用于长 agent turn 的 working context，复用 durable task、journal 和 `context_expand`，不要再建一份能独立决定任务是否完成的“记忆状态”。参见 [Hermes compressor](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/agent/context_compressor.py)。

Max 已有按需 skill 加载和高低水位下稳定的 materialization，不能把它描述成每轮全量重写。近七天真正的 materialization 发布只有 24 次 high-water、3 次 projection-change；trace 的 reason 只是保留上次发布原因。不要直接开启每轮压缩：Hermes 自己把 micro-compaction 设为 opt-in，并明确它会打断 prefix cache、增加整理调用。参见 [其 micro-compaction 权衡](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/docs/micro-compaction.md)。

## 4. 优化机会：检索确实在使用，但结果需要更强的相关性控制

近七天 `context_search` 调用了 47 次，来自 28 个回合；全部启用了 semantic，全部返回非空。709 个结果中有 359 个只有 semantic 信号且 cosine similarity <0.6。

0.6 不是经过验证的错误阈值，cosine similarity 也不是置信概率。这个分布只能说明当前系统很容易填满候选，需要检验精度；不能断言这 359 条都是错的，也不能根据调用率认定模型忘了检索。

有一个可人工核对的噪声例子：journal 5317 查询某机器人仓库的 GitHub 链接，八个结果确实包含仓库链接，但也带入“群主经常让机器人写代码项目”的个人记忆。后者无法回答链接问题，消耗上下文，还把人物信息混进技术定位任务。

Max 当前 lexical 是整段 substring / trigram similarity，并非 BM25；semantic 候选、来源配额和较宽松的 `minimumSignal=0.08` 容易保留弱相关记忆。已有精确去重和来源配额，但没有内容层面的 MMR 去冗余。注入端则只是按更新时间取本群和当前发言者各 12 条。497 条有效记忆中 69 条在各自 namespace 的 recent-12 之外；这是设计取舍，不是数据丢失。当前 7 条 permanent 都没有因 recent-12 排名被排除，上文两条失配是主体问题。参见 [Recall](../../src/Max/Recall.hs)、[Prompt 收集](../../src/Max/Prompt.hs)。

可借鉴：

- OpenClaw 的关键词与向量混合检索、相关性优先的 MMR，以及不同类型记忆的时间权重。对 Max 应测试中文、人名、精确 URL/配置键和多词组合，不能直接搬英文分词或默认分数。参见 [Memory search](https://docs.openclaw.ai/concepts/memory-search)。
- 明确的“问以前的事实先检索、再读必要原文”提示；这仍是模型行为约定，不是运行时保证。参见 [OpenClaw tool contract](https://github.com/openclaw/openclaw/blob/9636ae49e0018fd24bc9aa1fa73af6bf28e05ec0/extensions/memory-core/src/memory-tool-contract.ts)。
- OpenClaw 对符合条件的交互轮次，以明确触发短语最多注入三条可信核心记忆。Max 已有只用于离线评估的 `selectDirectAutoHints`，生产注入尚未启用，可以从这个边界做 shadow 实验；群聊与 proactive 不应默认跟着打开。参见 [Max 对应候选策略](../../src/Max/Recall.hs) 和 [评估入口](../../context-eval/Main.hs)。

## 5. 架构机会：事实记忆之外，缺少从任务中积累的可复用经验

数据库 `skills` 为 0，但近七天 `use_skill` 调用了 74 次。这并不矛盾：Max 把内置技能编译进二进制，数据库只承载自定义覆盖项。现有模型工具主要负责加载技能，没有形成“完成任务 → 提出经验 → 验证 → 下次加载”的持续积累流程。参见 [Skills](../../src/Max/Skills.hs) 和 [技能工具](../../src/Max/Tools/Skills.hs)。

Hermes 把这件事区分得更明确：普适身份、偏好等留在很小的 memory/user 存储；任务相关的步骤、陷阱和纠正进入 skill，只有相关任务才加载。它提供 `skill_manage`，并通过复盘提示和 curator 管理技能。这是一条值得 Max 借鉴的机制，不是“自我改进已经在 Max 工作负载上被证明有效”。参见 [Hermes prompt guidance](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/agent/prompt_builder.py)、[Skills System](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills/)、[curator 源码](https://github.com/NousResearch/hermes-agent/blob/990473a79c6b0396b0a648fdd85ee8f7a5c267d3/agent/curator.py)。

适合 Max 的实现是：从已经结束、结果可验证的 task/journal 中生成 **scoped skill candidate**，记录来源 turn、适用条件、成功证据、失效条件和验证时间；先在后续同类任务回放中验证，再成为可加载技能。学习内容不能增加工具权限，也不能自动覆盖跟当前代码绑定的内置 maxops/sandbox 技能。

例如应该学“某类部署后要怎样验收有效配置和真实操作”，而不是把某天的主机在线状态写成长期真理。当前请求只完成研究，没有生成或推广任何生产技能。

## 6. 维护盲区：小 namespace 不参加 dream，缺少按事实变化触发的整理

Max dream 的门槛是 active 数量至少 15，且 namespace 最近 49 小时有更新。快照中 125 个 active namespace 有 119 个不足 15 条；按两个条件合并，当时 123 个不参加 dream。夜间整理在执行，但主要解决容量与重复压力，不会普遍检查小 namespace 的更正和时效。

这不是把旧记忆判作过期的依据。稳定偏好可以长期有效；当前 393 条 active user memory 中 267 条超过 30 天未更新，单凭年龄不能删除。更有价值的是建立“收到更正、出现新证据、重复检索失败、明确有效期结束”的整理触发器。参见 [dreamWorker](../../src/Max/MemoryExtract.hs) 和 [候选 SQL](../../src/Max/MemoryStore.hs)。

OpenClaw 的 dreaming 将召回频次、查询多样性、来源可信度和替代关系纳入整理，并保留人能审阅的变更记录；其当前实现先筛选来源，再让模型选择合并/替代，最终内容受来源证据和保留预算约束。这些机制可以用于 Max 的重评队列。不要只用“被自己多次召回”强化记忆，也不要把 bot 自己复述的旧结论重新当作用户证据。参见 [Dreaming](https://docs.openclaw.ai/concepts/dreaming) 和 [consolidation 实现](https://github.com/openclaw/openclaw/blob/9636ae49e0018fd24bc9aa1fa73af6bf28e05ec0/extensions/memory-core/src/dreaming-consolidation.ts)。

## 上游机制如何落到 Max

| 机制 | 上游处理 | Max 的适配 |
| --- | --- | --- |
| 常驻记忆 | Hermes 默认 MEMORY 2,200 字符、USER 1,375 字符，session 起点形成 snapshot | 保留会话/人物分区；用 token 预算区分核心事实与可检索细节，不能为缓存冻结用户更正 |
| 历史恢复 | Hermes session search 返回原记录并按锚点展开 | Max 已有搜索和 episode/turn 展开；重点改检索质量，并在工具结果 stub 中给明确恢复入口 |
| 压缩前保存 | OpenClaw 在私有上下文副本里做 memory flush，避免整理消息污染用户轮次 | Max Historian 已同时捕捉摘要和记忆，无需再复制一套；长 task 工作状态可从 journal 提炼后再压缩 |
| 工具结果修剪 | OpenClaw 区分 pruning 和 summarizing，保护近期结果并稳定保存修剪投影 | Max 已有水位和字节稳定性；补统一 token 预算、可定位结果句柄和恢复后的预算校验 |
| 自动记忆召回 | OpenClaw 小量可信触发注入；其他资料按需搜索 | 先测试当前私聊 auto-hint 候选，保留群聊、proactive 与 scope 限制 |
| 操作经验 | Hermes 按需 skill + 写入/复盘/整理 | 从成功任务生成可审计、可失效的候选，不扩大执行权限 |

上表中的文件容量和 snapshot 来自 [Hermes memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/)，flush 来自 [OpenClaw memory](https://docs.openclaw.ai/concepts/memory)，pruning 来自 [OpenClaw session pruning](https://docs.openclaw.ai/concepts/session-pruning)。这些系统的单用户/profile 工作区语义不能直接替换 Max 的多人群聊权限矩阵。

## 建议实施顺序与验收

| 优先级 | 变更 | 有意义的验收 |
| --- | --- | --- |
| P0 | 修复 Historian expected-version 契约、分离提案重评状态 | 用上述真实故障形态的脱敏 fixture 验证 v1→v2；真正并发冲突仍拒绝；永久记忆仍受保护；摘要发布与提案结果分别统计 |
| P0 | canonical principal 校验与定向数据修复 | 非 principal 平台号不能直接落库；正确会话人物可保存和注入；跨会话主体拒绝；两条历史数据修复有证据、有审计 |
| P1 | 完整工具轮用量预算 + 可恢复工作摘要 | 长工具循环、技能加载、媒体、模型切换、重启续跑分别验证；保留最新指令/更正/未完成事项及 call-result 配对 |
| P1 | 更紧凑的默认历史与更精确的按需召回 | 以真实任务配对 replay；检查证据召回率、错误人物归属、旧事实压过新事实、引用可展开率、输入 token、延迟和缓存命中 |
| P2 | 按更正/失效触发的记忆维护，任务经验候选 | 检查旧事实被明确 supersede、反复引用不会自我强化、候选技能能改善后续同类任务而不扩大权限 |

建议先手工标注一批涉及历史事实、用户更正、仓库链接和长工具任务的生产样本。对比当前策略与较小 raw/summary 预算，再分别加入检索改进，避免同时改变模型、窗口和提取规则导致无法归因。上线门槛首先是关键证据与更正不丢、scope 不越界，然后才是 token/延迟下降；目前还没有完成这组效果实验。

现有 `max-context-eval` 能复用 Historian 的生产 prompt，也能验证确定性的 recall fixture；它不能单凭现有手写 fixture 证明生产回答质量。实际实现后仍需要适当的 PostgreSQL 集成测试。此次只有研究文档与只读查询文件，不涉及应用逻辑修改或 Git commit。

复查汇总：

```sh
ssh root@h610 'runuser -u postgres -- psql -X -d max -v ON_ERROR_STOP=1 -P pager=off' \
  < docs/research/2026-09-09-context-memory-audit.sql
```

重跑会得到新的时间窗口与计数。此审计仅评价上下文/记忆路径，不等于 Max 全部生产健康检查通过。
