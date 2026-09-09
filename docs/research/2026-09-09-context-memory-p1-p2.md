# 上下文与记忆 P1 / P2：本地实现与验收

本轮继续 [原审计报告](2026-09-09-context-memory-hermes-openclaw.md) 的 P1/P2。**未部署，未修改 h610 生产数据，也未使用已关机的 b650。** P0 和 issue #15 的生产验收不自动覆盖这些新代码。上一轮有关 memory 579 的会话列错误已在 [原验收记录](2026-09-09-memory-health-release.md) 勘误。

## P1：逐轮工作上下文

- 每次普通工具轮和强制收尾调用都检查完整 messages、动态工具 schema、媒体预留。`maxInputTokens` 已排除输出预留，不重复扣除 output；`toolRoundReserve` 是提前压缩的水位。保留材料可以占用这部分余量，但不能超过扣除媒体后的输入硬上限。
- LLM 返回本次调用的真实 usage。锚点只在模型 profile、配置 generation、限额、工具 schema 和消息前缀都一致时有效；新增 assistant 内容至少按上轮实际 completion 用量计入。修改历史、加载新工具、切换模型或重启后不会套用旧锚点。
- 超水位先缩短旧工具结果，再按完整工具轮移出历史。原始目标、用户更正、宿主技能说明、最新工具配对保留；直接加载已有完整说明时不重复注入；单个最新结果过大时保留配对和恢复入口。连受保护材料也装不下时，明确终止该模型调用。
- 工作记录是有界、确定性的证据摘要，包含操作参数预览、结果预览、未证实事项提示与恢复句柄。它不是任务状态，也不能认定副作用失败或重新执行。原始 journal 不删改。
- migration 104 保存工作记录。写入与 task admission fence 在同一事务内；重启可读当前 turn 或同一 task revision 的前次 attempt，换目标 revision 不继承旧记录。
- `context_expand` 支持 `t#n:rm` 完整结果以及 `t#n + call_id`，包括 spilled blob 的 JSON 文本分页。每次读取重查会话和 clear 边界。重复 call id 拒绝歧义定位，先读 turn trace，再用其中唯一结果句柄；不会重放工具。

[Working](../../src/Max/Context/Working.hs)、[Agent](../../src/Max/Effects/Agent.hs)、[LLM](../../src/Max/Effects/LLM.hs)、[恢复读取](../../src/Max/DB/AgentTurn.hs)。

## P1：常驻历史与召回

默认 raw tail 的低/高水位从 16,384/32,768 调为 8,192/16,384 估算 token；摘要 materialization 上限为 8,192。只有最近两个、七天内且有足够置信度的分区默认用 P1，其余按 P2/P3/P4 展示。policy 升到 v4，复用稳定 materialization，不每轮重写。

最终渲染后重新核算预算，若包装开销使其超限就继续删减可选材料，直到满足限额或只剩受保护来源。这覆盖原报告中最终多出 54 token 的问题类型。

按需召回保持 SQL 会话过滤；完整短语和有限查询词在同一次 SQL 中打分，支持中文片段、英文多词、URL 和配置键。精确标识要求字面证据；明确索要仓库链接时优先直接链接，不再靠来源配额塞入人物记忆。内容相近的结果做相关性优先的多样化排序；同一证据产生的不同记忆断言各自保留身份，跨人物不合并。记忆结果带可用的原始消息或 episode 入口。

语义分数不是置信概率，没有新增 `cosine < 0.6` 的删除规则。纯语义弱结果按本次候选的相对信号过滤；自动 recall 注入仍关闭。

[Prompt](../../src/Max/Prompt.hs)、[Policy](../../src/Max/Context/Policy.hs)、[Recall](../../src/Max/Recall.hs)、[配对 fixture](../../context-eval/fixtures/recall-p1.jsonl)。

## P2：按事实变化维护

原先“夜间、近期更新且至少 15 条”筛选改为每五分钟发现新的精确人类引文。migration 105 将当前记忆版本与 message evidence、已应用 Historian proposal/review 的原文引用相连；排除 Max 自己的消息、synthetic 消息、转发子消息及仅有维护说明的来源。即使 namespace 只有一条也进入队列。唯一键使重复发现惰性，不增加权重、置信度或更新时间。

同一 namespace 合并为一次维护请求，附带记忆之后的近期人类讨论，避免把已知旧结论称为最新状态。调用失败保留队列并退避；请求受当前配置 generation 的模型预算约束。变更使用持久 lease/fence：

- `supersede` 必须同时匹配旧、新两条已观察版本、相同主体/来源会话和新项的更晚人类原文。重复引用同一条消息不算新证据。
- 到期必须在原文和记忆中都找到明确期限及 `YYYY-MM-DD` 日期。按配置时区在该日结束后执行；到期前版本变化或原始引文被编辑会使计划失效。
- 自动维护不能改 permanent，不再接受自由文本理由驱动的 update/archive。事实替代的语义判断仍由模型提出，版本、作用域、时间顺序和引用资格由宿主检查。

[维护流程](../../src/Max/Memory/Maintenance.hs)、[来源与队列](../../migrations/105_causal_memory_maintenance.sql)。

## P2：可复用任务经验

migration 106 和后台 worker 增加“已完成任务 → 方法候选 → 后续任务配对回放 → 审核发布 → 失效”的流程。

候选要求任务确实 succeeded、报告无 unresolved 且有 evidence，成功工具 journal 可核对，没有 started/outcome-unknown；仅写“完成了”不够。候选必须给适用条件、步骤、失效条件和成功结果句柄，保存来源及正文 fingerprint。每个 task/revision 最多一条；未通过回放的候选不会出现在技能索引。

回放使用同会话、同任务 profile、在候选生成之后创建并完成的任务快照。操作员补充至少三个不同问题和 gold 检查，运行真实模型的 baseline/candidate 配对文本回放；两边使用相同冻结证据，不暴露工具或执行副作用，交替调用顺序并记录实际输入用量、耗时和缓存 token。发布要求全部检查无回退，且质量或整批 token/耗时有改善，同时整批成本未超过两倍；保存审阅者和原始报告。文字检查只是回放度量，不能替代真实外部操作验收。

发布只接受最新、通过且 fingerprint 仍匹配的报告，名字由宿主固定为 `learned-task-ID`，限定原会话，不能覆盖 maxops/sandbox 等内置技能，也不授予新工具权限。来源/回放变化或显式 invalidation 会禁用已发布经验；运行中 registry 至多五分钟刷新。适用条件里的外部环境变化仍需回放或操作员判断。

**本轮没有做真实模型的经验收益回放，也没有发布任何生产技能。** 已完成离线评分、数据库生命周期和权限边界验证；上述发布门槛用于防止把尚未证明有效的候选自动上线。

```sh
# 生产库上的任何变更和发布另行执行；本轮只在独立测试库验证。
# 自动 worker 会生成候选；可列出/查看，或从核对后的成功任务手动创建：
cabal run max-adr003-maintenance -- experience list GROUP
cabal run max-adr003-maintenance -- experience show GROUP CANDIDATE
cabal run max-adr003-maintenance -- experience create GROUP TASK CAPSULE_FILE
cabal run max-adr003-maintenance -- experience export GROUP CANDIDATE LATER_TASK replay.json
# 在导出文件中补充 cases: [{prompt, required: [...], forbidden: [...]}]
cabal run max-context-eval -- --experience-fixture replay.json --eval-profile PROFILE --experience-report report.json
cabal run max-adr003-maintenance -- experience review GROUP CANDIDATE LATER_TASK REVIEWER report.json
cabal run max-adr003-maintenance -- experience publish GROUP CANDIDATE REPLAY_ID
cabal run max-adr003-maintenance -- experience invalidate GROUP CANDIDATE '具体失效原因'
```

[经验类型与评分](../../src/Max/Task/Experience.hs)、[生命周期](../../src/Max/DB/Task/Experience.hs)、[回放工具](../../context-eval/Main.hs)。

## 本地配对样例与边界

| 样例 | 原策略结果数 → 新策略 | 片段估算 token → 新策略 | gold |
| --- | ---: | ---: | --- |
| 生产 journal 5317 仓库链接，匿名化 | 8 → 1 | 287 → 38 | 保留直接链接 |
| 配置键与高权重人物记忆 | 2 → 1 | 28 → 24 | 保留精确键 |
| 中文初试/复试更正 | 2 → 2 | 36 → 36 | 新证据在前，保留可核对旧说法 |
| 不同人物的同类事实 | 2 → 2 | 19 → 19 | 主体不合并 |
| 同主体重复措辞 | 3 → 2 | 37 → 29 | 去掉重复 |
| 有效语义分数低于 0.6 | 2 → 1 | 22 → 16 | 保留相对强信号 |

第一例来自本轮对 h610 的只读核查，原链接消息 156097 与请求 5317 的会话范围一致，保留原结果的检索信号和来源类型，替换姓名、项目标识及无关私人细节；其余是针对真实缺陷类型构造的回归。表中 token 是**匿名化片段**的估算量，不是线上真实调用用量。六例全部通过，只能证明这些固定候选的选择行为，不能外推线上准确率、延迟或缓存收益。

## 本地门禁

- `cabal build all` 通过；单元测试 **1,113/1,113**；独立 PostgreSQL/pgvector 数据库 `max_context_p1p2_final_20260909` 集成测试 **372/372**，包含 migrations 104–106。
- 原有 Historian/auto-recall fixture 离线验证，新配对召回 fixture **6/6**。
- HLint、架构边界、`cabal check`、prompt-flow 生成/`--check`、diff 检查和本机 Nix 构建。

最终命令结果见本轮提交说明；线上效果和生产健康待后端恢复及另行部署后验收。本轮没有把本地测试结果写成生产健康证明。
