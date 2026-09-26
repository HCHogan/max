用 JavaScript 组合多次工具调用、筛选大结果，减少模型往返；适合批量查询、条件流程和数据汇总。

加载后下一轮可使用 `run_code({code: "..."})`。`code` 是 async 函数体，使用
`return` 返回 JSON；没有 return 则返回 null。必须把 run_code 作为该轮唯一调用。
工具参数遵循本轮工具列表提供的完整 schema；这里只改变组合方式。

完整 SDK（所有调用都返回 Promise，先 `await` 再取字段）：

- `await tools.<工具名>(args)`：调用本轮可见工具，成功得到返回值，失败抛出 ToolError。
  每个工具描述末尾的「返回：」就是这个值的类型，可以直接按字段取用，不必先返回原文看结构。
  也可写 `tools[工具名](args)`。参数省略时为 `{}`。
- 并发就用原生写法：同时发起的调用按工具元数据并发执行，各自完成就各自恢复，例如 `const [a, b] = await Promise.all([tools.x(p), tools.y(q)])`。
  依次 `await` 的调用按顺序执行。同一程序最多 64 个在途调用，更多的会在 outbox 等待。
  `Promise.race` 在首个结果返回时恢复，其他调用继续运行，可稍后 await。
- `await max.race(promises)`：首个结果返回后取消其余直接工具 Promise。
  `max.cancel(promise)` 取消一个直接工具调用；派生 Promise 不支持这两种取消。
- `await max.sleep(ms)`：等待毫秒数（最多六小时），可用于 race 超时，不提供时钟读数。
- `await max.raw(name, args)`：返回完整 outcome，不抛出工具失败。
  成功是 `{outcome: "succeeded" | "committed", value}`；失败是
  `{outcome: "rejected" | "failed-before-effect" | "outcome-unknown",
  error: {code, message, retry: "safe" | "idempotent" | "unsafe"}}`。
  配合 `Promise.all` 可以保留每个调用各自的成败。
- `max.value(outcome)`：从上述结构取成功值，否则抛出 ToolError。
  ToolError 带有 `outcome`、`code`、`retry` 和 `message`。
- `max.names`：本次运行可用工具名的完整只读数组。`tools` 与 `max` 不可替换。
- `await agent(args)`（也可写 `max.agent`）：就是 `tools.agent({...args, wait: true})`，
  派一个子 agent 并等它的报告，得到已结束的 Agent：报告在 `result.text`，给了
  `output_contract` 时符合契约的 JSON 在 `result.payload`。参数与 agent 工具相同
  （objective、profile、context、resources、inputs、output_contract）。前台和后台
  都能用：前台等到的报告只回到这次调用，不会再另行转述；程序返回或被取消时，仍在等待的子 agent 及其后代会被取消。
  要让子 agent 独立继续，使用 `await tools.agent({...args, wait:false})` 取得句柄。多个子 agent 并行：
  `await Promise.all(items.map(x => agent({objective: ..., profile: "basic"})))`。
  契约只验证形状，不证明内容正确。
- `await max.phase("阶段说明")`：就是 `tools.agent_progress({summary})`，记录后台
  agent 的内部进度，不向聊天播报；只在有 agent_progress 的后台 agent 中可用。
- `await max.batch([{tool, args} | {agent: {...}}, ...])`：旧写法，等同于对每项
  `max.raw` 再 `Promise.all`。

例如，按一个已可见工具的 schema 构造多份参数后：

```javascript
const results = await Promise.all(inputs.map(args => max.raw(toolName, args)));
return results.map((result, index) => ({index, ...result}));
```

用实际工具名和参数替换示例中的变量。多步浏览网页的写法见 web 手册的"多步浏览写成程序"。可使用普通 JS、数组、对象、正则、
JSON、Promise 和 async/await。没有 Node、浏览器 API、import/require、console、计时器、
网络、文件系统、环境变量或宿主时间/随机源；需要这些能力时调用授权工具。

每次程序是独立环境，不保存 JS 变量。单次源码和返回值各最多 64 KiB，Wasm
内存 256 MiB（JS 堆 192 MiB），每个 guest 计算步骤最多 60 秒，等待仍受 agent
截止时间和工具自身 deadline 约束。计算有 fuel 上限：用尽时整段程序终止、返回值丢失，只剩已完成调用
的回执。在大文本上别用 `[^"]{0,60}关键词` 这类回溯很重的正则，先 indexOf 定位再切片。
单个工具结果最多 4 MiB，每次恢复最多传入 16 MiB；超出部分留待后续恢复。
请在 JS 内筛选、聚合后返回必要信息。单次程序最多 4096 次宿主调用，
工具调用还受共享额度约束。全局最多 32、每棵 agent 树最多 16 个活跃程序；
超限会在执行前拒绝，可稍后重试或改用原生工具。

程序返回时会取消仍在途的调用；未提交的 outbox 调用直接丢弃。需要完成的工作必须 await。
取消已开始的副作用可能留下部分效果，按 outcome-unknown 处理。

## 翻聊天上下文

`context_search` 找位置，`context_read` 读原文，`context_resume` 读旧工作回合。
ref 和所有消息 ID 都用字符串。把搜索结果的 `read`、页面的 `prev`/`next` 或
条目的 `more` 原样传给 `context_read`；不要自己拆解 cursor。episode 是定位点，
可以跨边界翻页；显式日期范围则不会越界。`more` 接长正文，`next` 接后面的消息。

```javascript
const hits = await tools.context_search({query: "上次讨论的部署方案"});
if (!hits.results.length) return {found: false};
let page = await tools.context_read(hits.results[0].read);
const rows = [...page.items];
if (page.next) {
  page = await tools.context_read(page.next);
  rows.push(...page.items);
}
return {rows: rows.map(x => ({ref: x.ref, text: x.text, more: x.more})), next: page.next};
```

需要大范围阅读时在 JS 中筛选后返回，遵守 64 KiB 返回值上限；不要无界收集整个群。
读完整单条原文时，循环跟随该条目的 `more`；是否完整以 `complete` 为准。
接续旧工作用 `tools.context_resume({turn: "t#42"})`，它只读记录，不重跑历史动作。

所有叶子调用沿用原生工具的权限、调用额度和持久化 journal。代码不获得新
权限，不能递归 run_code。在代码里加载技能只对下一模型回合生效，当前程序
仍使用启动时的工具集合。取消或收到待处理反馈时，宿主可以终止程序，之后代码不执行。

失败不会回滚先前的效果。工具和整段代码都不会自动重试；遇到 committed 或
outcome-unknown 时先查明现状，不能直接重跑整段程序。宿主返回部分调用回执，
用于区分已经完成、拒绝和结果不明的调用。图片、文件和技能激活走原有宿主通道，
无需通过 JS 返回值重新发送。
语法错误等发生在提交任何叶子调用之前的失败，以及所有叶子调用都明确在
副作用前失败或被拒绝的情况，会标为 failed-before-effect，可以修正后重新
提交；已提交调用但未收到回执不属于这种情况。

已保存工作流：先 use_skill 加载目标技能及完整依赖，再在下一轮使用
`run_code({workflow:"技能名/入口名", args:{...}})`。参数遵循加载结果中的完整
输入契约；宿主读取固定版本的源码，不必复制或重新生成代码。此格式与 `{code}`
二选一。保存流程只能调用其声明且当前仍获授权的工具；契约变化会在执行前拒绝。
结果包含 run_ref 和工作流版本。输出契约错误也不会撤销已完成的工具效果。

每次调用 agent 都派出新的子 agent，包括重跑同一段程序。等待中的子 agent 也能运行 run_code。子 agent 和等待只在当前进程内存在；重启不会续跑或重放。
后台 agent 等待时收到 steering，agent 调用返回 `feedback_pending`，宿主在这里停止
程序，由下一模型回合读取收件箱；已派出的子 agent 继续运行，可以通过
agent_status/agent_wait 收集它们，避免重复派出。
