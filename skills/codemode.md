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

例如，按一个已可见工具的 schema 构造多份参数后：

```javascript
const results = max.batch(inputs.map(args => ({tool: toolName, args})));
return results.map((result, index) => ({index, ...result}));
```

用实际工具名和参数替换示例中的变量。可使用普通 JS、数组、对象、正则、
JSON 和 Promise。没有 Node、浏览器 API、import/require、console、计时器、
网络、文件系统、环境变量或宿主时间/随机源；需要这些能力时调用授权工具。

每次程序是独立环境，不保存 JS 变量。单次源码和返回值各最多 64 KiB，Wasm
内存 64 MiB，计算有 fuel 上限，总时间最多 30 分钟（含工具等待）；单个工具
仍有自己的 deadline。SDK 会自动分帧读取同一次调用的结果（最多 4 MiB），
不会为了读取大结果重复执行工具。请在 JS 内筛选、聚合后返回必要信息。
单次程序最多 1024 次桥接交互（含分帧读取），叶子调用还受共享额度约束。

所有叶子调用沿用原生工具的权限、调用额度和持久化 journal。代码不获得新
权限，不能递归 run_code。在代码里加载技能只对下一模型回合生效，当前程序
仍使用启动时的工具集合。结束/让出回合由宿主立即终止程序，之后代码不执行。

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
