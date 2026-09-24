用 JavaScript 组合多次工具调用、筛选大结果，减少模型往返；适合批量查询、条件流程和数据汇总。

加载后下一轮可使用 `run_code({code: "..."})`。`code` 是 async 函数体，使用
`return` 返回 JSON；没有 return 则返回 null。必须把 run_code 作为该轮唯一调用。
工具参数遵循本轮工具列表提供的完整 schema；这里只改变组合方式。

完整 SDK：

- `tools.<工具名>(args)`：调用本轮可见工具，成功返回值，失败抛出 ToolError。
  也可写 `tools[工具名](args)`。参数省略时为 `{}`；`await` 可用于返回值。
- `max.raw(name, args)`：返回完整 outcome，不抛出工具失败。
  成功是 `{outcome: "succeeded" | "committed", value}`；失败是
  `{outcome: "rejected" | "failed-before-effect" | "outcome-unknown",
  error: {code, message, retry: "safe" | "idempotent" | "unsafe"}}`。
- `max.value(outcome)`：从上述结构取成功值，否则抛出 ToolError。
  ToolError 带有 `outcome`、`code`、`retry` 和 `message`。
- `max.batch([{tool: "工具名", args: {...}}, ...])`：一次提交 1–32 个调用，
  按输入顺序返回 outcome 数组。宿主按工具元数据决定并发或顺序执行。
  需要并行时使用此接口；Promise.all 本身不会让同步工具调用并行。
- `max.names`：本次运行可用工具名的完整只读数组。`tools` 与 `max` 不可替换。
- `agent({objective, inputs, profile, output_contract?})`（也可写 `max.agent`）：
  在根后台任务中启动普通子任务并等待报告。profile 为 basic/browser/sandbox，
  只收窄父任务当前权限；SSH 运维使用 sandbox 并加载 operations 技能；inputs 是最多 64 KiB 请求内的显式 JSON 数据。
  返回 `{task,status,text,payload}`。未指定 output_contract 时，子任务直接回答即可。
  指定时使用技能的闭合 JSON Schema 子集；子任务以符合契约的 JSON 作为最终答案，
  宿主验证后放入 payload。契约只验证形状，不证明内容正确。
- `max.batch([{agent:{objective,inputs,profile,output_contract?}}, ...])`：表达独立子任务。
  宿主决定并发，按原顺序返回 outcome。与工具混合的 batch 顺序执行。
  `Promise.all([agent(...),agent(...)])` 不会并发；请使用 max.batch。
- `max.phase("阶段说明")`：记录当前任务内部进度，沿用 task_progress 的去重与父任务通知规则，不向聊天播报。
  只在本轮工具里有 task_progress 的后台任务中可用；前台对话里调用会让整段程序在开头失败。
  保存工作流须在 tools 中声明 task_start（使用 agent）及 task_progress（使用 phase）。

例如，按一个已可见工具的 schema 构造多份参数后：

```javascript
const results = max.batch(inputs.map(args => ({tool: toolName, args})));
return results.map((result, index) => ({index, ...result}));
```

用实际工具名和参数替换示例中的变量。多步浏览网页的写法见 web 手册的"多步浏览写成程序"。可使用普通 JS、数组、对象、正则、
JSON 和 Promise。没有 Node、浏览器 API、import/require、console、计时器、
网络、文件系统、环境变量或宿主时间/随机源；需要这些能力时调用授权工具。

每次程序是独立环境，不保存 JS 变量。单次源码和返回值各最多 64 KiB，Wasm
内存 64 MiB，总时间最多六小时（含子任务/工具等待，且不能越过任务截止时间）；单个工具
仍有自己的 deadline。计算有 fuel 上限：用尽时整段程序终止、返回值丢失，只剩已完成调用
的回执。在大文本上别用 `[^"]{0,60}关键词` 这类回溯很重的正则，先 indexOf 定位再切片。
SDK 会自动分帧读取同一次调用的结果（最多 4 MiB），不会为了读取大结果重复执行工具。
请在 JS 内筛选、聚合后返回必要信息。单次程序最多 1024 次桥接交互（含分帧读取），
叶子调用还受共享额度约束。

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

每次显式调用 agent 都创建新子任务，包括重跑同一段程序。子任务不能再执行
run_code/agent。任务和等待只在当前进程内存在；重启不会续跑或重放。
收到 steering 时宿主在 agent 边界停止程序，由父任务下一模型回合读取收件箱；
已启动的子任务继续运行。可以通过 task_status/task_wait 收集它们，避免重复启动。
