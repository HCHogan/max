把已验证的 codemode 工作流保存为本群可复用技能：草稿、隔离测试、发布和版本检查。

先把工作流做成明确的输入、输出和固定工具集合，再保存；不要把一次性回答、聊天原文、密钥或运行结果塞进技能。这里四个工具已经完整加载，不需要逐项发现。自建技能只在当前群可见；不得使用内置名字或 learned-task- 前缀。

1. `skill_inspect({name})` 查看最近 10 个草稿、校验和发布记录；`revision` 可选，指定后才返回那一版完整内容和相对上一草稿的变更摘要。草稿版本和已发布版本是两套编号。
2. `skill_save({draft, expected_revision})` 保存不可变草稿。首次为 0，修改必须用刚观察到的草稿版本。不会加入技能目录，不会自动运行。
3. 先用 `use_skill` 完整加载 package.dependencies 中的每个技能（以及隐含的 codemode）；然后 `skill_validate({name, revision})`。它在独立 Wasm 中只运行模拟工具，返回 validation_id 和报告。失败时改源码/fixture，再保存新版本。每个 workflow 至少一个 fixture；同时覆盖空结果、部分失败等实际分支。
4. `skill_publish({name, revision, validation_id, expected_revision})` 发布通过校验的精确版本；expected_revision 是已发布版本，首次为 0。依赖、工具契约或当前已发布版本变化时必须检查并重新校验。只可更新本路径发布且未被其他管理入口改动的技能。
5. 发布成功后 `use_skill({name})`，再 `run_code({workflow:"name/entry",args:{...}})`。当前任务若已加载旧版本会继续使用旧版，需新任务才能加载新版。发布不会继承你的权限，后续调用始终使用当时调用者的权限。

`draft` 的完整格式（所有键都必填）：
```json
{
  "name": "double-value",
  "description": "把输入整数乘二的可复用工作流。",
  "body": "需要整数加倍时运行 double-value/run，传入 value。",
  "package": {
    "dependencies": [],
    "workflows": {
      "run": {
        "description": "将 value 乘二",
        "source": "return {value: args.value * 2};",
        "input": {"type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false},
        "output": {"type":"object","properties":{"value":{"type":"integer"}},"required":["value"],"additionalProperties":false},
        "tools": []
      }
    }
  },
  "fixtures": [{"entry":"run","args":{"value":3},"calls":[],"expected":{"value":6}}]
}
```

source 是异步函数体，可使用 args、tools.<工具名>(参数)、max.raw、max.batch、max.value。所有输入必须参数化；不要拼接 JS 源码。返回简洁 JSON，不发送聊天正文。input/output 支持 type、description、enum；object 的 properties/required/布尔 additionalProperties；array 的 items/minItems/maxItems；string 的 minLength/maxLength；number/integer 的 minimum/maximum。其他 JSON Schema 关键字不支持。

有工具的 fixture.calls 按提交顺序写完整调用，例如：
```json
{"tool":"web_search","args":{"query":"example"},"result":{"results":[]}}
```
失败分支使用 `"error":"simulated failure"` 替代 result（只能选一个）。模拟器按真实工具的效果元数据分类成功/失败；不会联网或真的执行写入。参数必须精确匹配，漏调用、多调用、未消耗的模拟调用或输出不相等都失败。batch 的模拟按输入顺序运行；这不测试线上并发时序。校验成功只证明这些 fixture，不证明未覆盖分支或线上操作一定成功。

每包最多 8 个 workflow，固定依赖 16 个；每个 source ≤64 KiB；包 ≤256 KiB；完整 draft ≤512 KiB；每群最多 32 个草稿名、每名 128 版；每版最多 16 个 fixture、每个 32 次模拟调用、每版最多 32 条校验报告。fixture 单次有燃料、64 MiB 内存和 5 秒运行上限。依赖必须真实存在并可完整加载，不允许自循环。自建 workflow 不能调用 use_skill、run_code、skill_*、task_* 或结束/切换模型循环的工具。长任务仍使用原有任务系统。

save/publish 发生结果不明时先 inspect，不要盲目重复提交或自动重跑整段。没有明确可复用的工作流时，无需创建技能。
