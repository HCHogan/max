# 2026-09-09：记忆 P0 与生产健康验收

本轮完成 [研究报告](2026-09-09-context-memory-hermes-openclaw.md) 的两个 P0 项，以及 [#15](https://github.com/HCHogan/max/issues/15) 的终态审计处置和生产验收。P1 的完整工具轮预算、历史压缩和召回调整，以及 P2 的自动维护与经验候选，尚未实施。

## 版本与发布边界

- Max：`ba7387d2ea916af851651efe797861646a0a0dae`，包含 `bae96c8` 的主体修复、提案重评、债务审计及 iMessage 发送前探测，`5955df6` 的历史投影兼容修正，以及 JSON 数值序列化兼容修正。
- nix-config：`e506529`，h610 激活的系统闭包为 `/nix/store/3m620nd7f81sk3a7lg21lxmjavz81sxc-nixos-system-h610-26.05.20260622.3426825`。
- 实际服务与全部最终验收命令使用 `/nix/store/bp3y7dhiqbsbslf1x8khbzff7yk05px2-max-0.18.0/bin/` 中的可执行文件；构建环境记录 `MAX_GIT_REV=ba7387d`。
- 部署前截止时间为 **2026-09-09 06:43:55 UTC**；新 Max 于 **06:44:07 UTC** 启动，migration 102/103 分别于 06:44:07.717513 / 06:44:07.737979 UTC 应用。
- 本次使用独立 Nix worktree，保留 h610 原有 Max/Nix 工作目录的未提交修改；系统闭包差异仅为已有待同步的 gaojibot 包及本轮 Max 包。

## 实现与真实数据修复

Historian schema 2 使用 `expected_version`，模型复制看到的版本，数据库生成下一版；旧 `version` 字段进入原有的一次格式修复流程。真实并发冲突和 permanent 保护保持生效。新的个人记忆必须指向当前会话可引用的 canonical principal。

摘要发布和失败提案重评使用独立状态。`memory review` 重新验证原始来源、会话、引用、当前版本和生命周期，另写不可修改的审计记录。本阶段由操作员逐条重评，没有自动重放旧提案。

| 生产记忆 | 修复前 | 修复后 | 证据与审计 |
|---|---|---|---|
| 534 | 主体 2783846439，v1，permanent | principal 982，v2，permanent | 唯一平台身份映射与原始消息作者一致；`backfill` mutation 记录原、新主体，正文不变 |
| 536 | 主体 3526452465，v1，permanent | principal 784，v2，permanent | 同样经过唯一身份、来源、版本、容量和重复检查，正文不变 |
| 579 | 停留在 9 月 5 日的招新信息，v1 | 采用 9 月 8 日更正，v2，active | 重读 162781、162856、163088、163653、163654；capture 1461 的重评应用成功 |

memory 579 的六条更早提案（1276、1339、1352、1406、1415、1440）经过内容比较后记为 dismissed，防止旧状态覆盖新状态；原提案、摘要、引用和 Historian cursor 均保留。memory 595 涉及持续变化的沙盒部署状态，仍待结合当前事实重评，没有直接把旧的机器人自述写成今天的事实。

## 本地、CI 与快照演练

- `cabal build all`、1103 个单元测试、357 个真实 PostgreSQL 测试通过；数据库为本机独立的 `max_memory_health_20260909`。
- HLint、`cabal check`、架构边界检查、prompt-flow 生成及 `--check`、`git diff --check` 通过。每次提交前均运行 prompt-flow 所需命令。
- Darwin Nix 打包通过，干净导出与最终所有跟踪文件逐字节一致；Linux Nix 包及 h610 系统闭包构建通过。同步上游 Nix 配置后，17 个 NixOS host 均完成 evaluation。
- [CI 34319841967](https://github.com/HCHogan/max/actions/runs/34319841967) 全部通过，包括 PostgreSQL 升级、数据库健康门禁、沙盒网络与桥接测试。
- h610 生产库 `max` 的 custom-format dump 经 `pg_restore --list` 检查，恢复到独立库 `max_memory_health_rehearsal_20260909`，含 **164728 条消息**。备份保存在 h610 私有目录 `/var/lib/max/release-rehearsal-20260909/production.dump`，未对演练库启动任何会发送消息的 Max worker。
- 演练应用 migration 102/103，验证三个定向记忆修复，并成功审计接受 3468 条快照终态。原始终态数量未改变。最终快照 `verify` 的投影与 schema 一致性通过；健康仅剩 **1 条 snapshot 中无人续租的 delivery lease**，按预期保持失败，没有用审计接受隐藏运行中的租约问题。

演练暴露并修复了两个只有真实数据能充分覆盖的边界：

1. system reaction/redaction 的空正文应按关系生成事件标记；历史 debug 消息和内部 reaction receipt 则沿用正文投影。原来的 3019 条 system 标记与 6654 条历史 debug 差异均不需要改写生产消息，最终未执行生产 `reproject`。
2. PostgreSQL JSONB 文本保留 `.100000` 这样的数值精度，JSON 编码器可能写成等值的 `.1`。审计把指纹视为数据库提供的不透明版本，并对完整观察值核对当前记录或不可修改的既有审计，避免对重编码 JSON 做错误校验；修改内容、指纹、范围和过期批次仍被拒绝。

## Historian 真实模型回放

使用生产配置的 `gpt-5.6-luna`，只发送已提交的脱敏 fixture，不访问或修改生产数据库：

| 回放 | 结果 | provider 调用 / 格式修复 | provider prompt / completion tokens |
|---|---|---|---|
| 已有记忆更正案例，3 次 | 3/3 | 6 / 3 | 9332 / 3586 |
| 最终部署版本，全部 9 个案例 | 9/9 | 10 / 1 | 14234 / 7402 |

最终九案例平均每 capture 1581.6 prompt tokens、822.4 completion tokens，每 provider 调用平均 16.576 秒。离线 fixture/schema 9/9、确定性 recall fixture 7/7 通过；该 recall 策略仍未接入生产注入。受限格式修复仍有成本，这些结果不代表生产每个未来提案都能首次成功。

## 生产终态处置

所有批次范围显式为 `all`，截止 **06:43:55 UTC**，按 kind 导出确切 ID、会话、观察时间、状态/attempt 和指纹。决定为 **accepted**：明确接受历史未决结果；没有声称未知副作用已成功，没有重发旧消息、重跑请求、重置源表状态或删除沙盒数据。

| 类别 | 部署前原始数量 | 决定依据 |
|---|---:|---|
| delivery outcome_unknown | 3050 | iMessage 3038、Matrix 7、QQ 2、WeChat 3；历史连接/响应超时、过期租约或连接中断，结果不能靠重发核实 |
| dispatch outcome_unknown | 11 | 8 月 9 日至 9 月 6 日的过期 dispatch ownership；保留未知执行结果 |
| parked media | 385 | 最晚 8 月 27 日；包括 284 条明确过期 URL，以及 DNS/连接、重定向/超时和大小限制失败；接受历史附件缺失 |
| failed request | 43 | 9 月 5 日至 9 月 9 日 02:56 UTC 的 deadline、无进展、显式取消、流中断、连接超时或重试耗尽；保留失败结果 |
| sandbox outcome_unknown | 1 | s12 的原 Docker 容器已停止，旧工作卷仍保留；接受迁移前遗留生命周期债务，未删除或声称已迁移该卷 |

原始导出与补全审查理由的 JSON 均保存在 h610 `/var/lib/max/operational-review-20260909/`，权限仅授予服务用户/管理员。审计记录保存在 `operational_debt_reviews`，通过追加 `reopened` 可撤回接受。后续 attempt、状态或观察版本变化不会继承旧接受。

生产审计在 **06:50:01.533631–06:50:03.794402 UTC** 完成：delivery 的 review ID 为 **1–3050**，dispatch 为 **3051–3061**，media 为 **3062–3446**，request 为 **3447–3489**，sandbox 为 **3490**。总计 3490 个不可修改的审计事件；五类原始数量全部保持不变，当前未审查终态均为 0。

## 两次带流量验收

均显式连接生产库 `max`，使用 `default_transaction_read_only=on` 和最终部署闭包的 maintenance 程序，依次运行 `verify` 与 `health`。第二轮开始距第一轮结束 **137 秒**，超过投递 lease 的 120 秒。

| UTC 时间 | messages / deliveries | 一致性与健康 |
|---|---|---|
| 06:52:11–06:52:16 | 164986 / 171367 | `ADR 003 verification PASSED (schema, IR, projections, and ledger)`；独立 `health` 也通过 |
| 06:54:33–06:54:38 | 164997 / 171378 | `verify` 与独立 `health` 再次通过 |

两轮检查中，delivery/dispatch/frontend/monitor/task 的过期所有权、task overdue deadline、活跃未知 journal 副作用以及所有 `*_unreviewed` 均为 **0**。终态总量保持 3490，**部署前截止时间之后新增或变化的终态为 0**。

截至 06:54:37 UTC，部署后已有 **148 次 QQ 投递确认**；两轮之间消息数增长 11，证明检查期间有实际流量。服务持续 active，`NRestarts=0`，启动时间和系统闭包均未变化。

队列指标单独保留：delivery/dispatch retryable 为 0，活跃 durable task 为 0，`request_pending=291`（281 waiting、10 delegated，均为部署前记录）。这些请求没有被清零或认定为已完成；该信息指标不等于 291 个正在运行的任务，也不证明所有历史请求都已妥善回答。

iMessage 在 06:45:38、06:47:09 UTC 仍记录 bridge 连接超时并等待恢复；截至 06:54:37，部署后没有 iMessage send part 被启动或更新，没有新增 iMessage ambiguity。本窗口验证了隔离及债务没有增长，未覆盖恢复后的真实 iMessage 发信；发送前探测的行为另由测试覆盖。

## 操作边界

使用 [operational-debt runbook](../runbooks/operational-debt.md) 中的受支持命令完成上述检查和修复。数据库一致性、已审查的历史终态与平台可达性分别记录：iMessage bridge 在本轮验收时仍有连接超时，Max 处于等待恢复状态；这不证明 iMessage 可以正常收发，也没有因此关闭 #13。

## 后续证据勘误

P1/P2 取样复核发现，先前对 memory 579 的“没有更晚消息”检查误把 legacy group ID 用于 `messages.conversation_id`。该群的 canonical conversation ID 为 46749，正确查询应使用 `messages.group_id=1090284918` 或 canonical ID。9 月 9 日已有后续的初试/复试讨论；9 月 8 日更正的五条原始证据仍成立，但不能将它称作截至验收时的最新完整状态。此前审计理由中的这一句也有此局限，不能改写不可变审计来掩盖。后续回放必须同时标注 legacy/canonical ID，并检查更晚的人类消息；本轮修正文档及测试，不改生产数据。
