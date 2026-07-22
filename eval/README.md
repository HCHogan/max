# Intent-classifier eval

回归测试主动触发分类器（`Max.Intent`）：改分类器 prompt、换模型、调
persona 之前，先跑一遍 fixture 确认判决没有退化。这是唯一一个"判错了
会直接烦到群友"的 LLM 决策点，所以最先给它配了 eval。

## 工作流

1. **从生产日志捞素材**（prod 机器上，行为数据都在 journald 里）：

   ```sh
   scripts/extract-intent-fixture.sh '3 days ago' > eval/fixtures/intent.jsonl
   ```

2. **人工核对标签**。脚本把模型当时的判决预填进 `expect_trigger` /
   `expect_kind`，原始判决留在 `note` 里。逐行看一遍，把模型判错的
   案例改成正确标签——没有这一步 fixture 只是在测"模型是否复读自己"。

3. **回放**（在有 max.yaml / 环境变量的机器上，正常加载 bot 配置）：

   ```sh
   cabal run max-intent-eval -- --fixture eval/fixtures/intent.jsonl
   # 换个模型对比：
   cabal run max-intent-eval -- --eval-profile some-other-profile
   # 当回归门禁用：
   cabal run max-intent-eval -- --min-accuracy 0.9
   ```

## Fixture 格式

JSONL，一行一个 case：

```json
{"context": ["[07-22 14:01] 小明: 这段 haskell 怎么报错了"], "new": ["[07-22 14:03] 小明: max帮我看看"], "expect_trigger": true, "expect_kind": "called", "note": "无@叫名"}
```

- `context`：分类器看到的近期群聊行（可空）；`new`：待判定的新消息行。
  行格式与 `Max.Prompt.renderHistoryLine` 一致（提取脚本产出的天然一致）。
- `expect_trigger`：应不应该接话。`expect_kind`（可选）：
  `called` / `followup` / `topic`，仅在双方都判定触发时比对。
- `note`（可选）：给报告里的失败行看的备注。

`eval/fixtures/example.jsonl` 是手写的最小示例，可以先拿它验证接线。
