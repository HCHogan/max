# plan-eval — ADR 002 计划核心的离线评测

> [ADR 008](../docs/adr/008-durable-tasks-conversation-coordination.md) 已退役
> model-authored Plan DSL / adaptive elaboration 的发展路线；现有 plan 执行与
> 恢复路径在迁移完成前仍保留，所以这里继续承担旧语法与内核的回归检查。
> 候选解析率、准入率及返回类型检查不是新 task 接口的端到端质量验收。

E5 的 exit gate。跑一遍:

```
cabal run max-plan-eval                       # 默认 plan-eval/fixtures/segments.jsonl
cabal run max-plan-eval -- path/to/other.jsonl
cabal run max-plan-eval -- --prompt           # 打印模型会看到的那份 elaboration prompt
```

退出码在每条 fixture 的实际结果都符合其 `expect` 时为 0,所以它可以当回归测试挂在 CI 上。

## 它测什么

不连 LLM、不连数据库、不发网络请求、不产生任何效果。每条 fixture 是一段候选 DSL,依次过
**parse**(`Max.Plan.Parse`)→ **kernel**(`Max.Plan.Validate`)→ **preview**
(`Max.Plan.Interpret`),用的就是生产路径会用的同一批模块。

> **这批 fixture 绝大多数是手写的,不是录的。**(例外已在该行 `note` 里标明
> RECORDED——第一条录进来的是 deepseek-flash 写的私密值外泄计划,当时内核放行了。)
>
> 它们是照着内核的行为反向编出来的,所以当然全中。`parse rate 81%` 的意思是「我写了
> 19% 的畸形样本」,仅此而已。这让它成为一个**回归门**——改坏解析器或校验器会立刻红——
> 但它**不是**「模型能写出合法计划」的证据。那部分现在由 `max-plan-live` 采集真实
> profile 的候选来测；生产的 durable plan 工具、worker、fork/join 与恢复路径也已经接通。
> 这里仍只是一道确定性的解析器/内核回归门，别把三类证据读混。

输出的指标对应 ADR 002 step 8 点名的那几项:

| 指标 | 含义 |
|---|---|
| parse rate | 候选里有多少能被整段解析 |
| validation rate | 有多少通过内核;同时给出占已解析的比例 |
| expectation agreement | 实际结果与 fixture 声明的期望是否一致 |
| context occupancy | 候选表面的估算 token 对 horizon-1 基线的占比 |
| total tree cost | 所有表达式的静态开销之和,也就是校验器拿去对上限的那个数 |
| expected deoptimizations | 遗留的 hole 数 + 被拒数,每一个都是生产环路要额外付的一轮 |

## 它测不了什么

**答案质量。** 这里没有任何东西产生答案。"计划是否给出了结果、还是把活儿交回一个
hole"只是结构代理,`holes` 一列就是它,不要当质量读。

答案质量由 `max-plan-live` 的多模型重复采样和生产回放另行评估；执行器是否接入已不再是
这里的前置缺口。离线 fixture 只回答语法、校验和静态成本有没有回归。

## fixture 格式

每行一个 JSON:

```json
{
  "name": "search then answer",
  "expect": "admitted",
  "source": "let hits = search_web@3({ query: \"x\" })\ndone hits[0].title ?? \"\"",
  "baseline_tokens": 420,
  "note": "可选,说明这条为什么值得留着"
}
```

- `expect`:`admitted` / `refused` / `unparsed`
- `baseline_tokens`:可选。horizon-1 环路走到同一步花掉的 token。**没有它就没有
  occupancy 可言**,所以汇总只对提供了基线的 fixture 求和,不会替其余的编分母。

工具目录、goal 的预算与授权都写在 `Main.hs` 里,不在 fixture 中——fixture 记录的是
模型写了什么,环境是宿主的事。

## `--prompt`

`Max.Plan.Prompt` 从同一个 `ValidationEnv` 渲染模型看到的那份指令,所以「告诉模型的」和
「内核会检查的」是同一个值,不会各自漂移:目录里没有的工具不会出现在提示里,提示里出现的
类型也一定是解析器收得下的写法(有测试盯着)。`--prompt` 把那份文本原样打出来——多模型
实测要发的就是它,现在先能读。

## 多模型实测(`max-plan-live`)

离线那半测的是「内核对不对」,fixture 是人写的。这半测的是「模型写不写得出来」,
候选来自真实 profile:

```
cabal run max-plan-live -- --profiles a,b,c --dry-run          # 先看会发多少个请求
cabal run max-plan-live -- --profiles a,b,c --repeat 3 --out /tmp/candidates.jsonl
```

配置走和 max-bot 完全一样的 yaml/env/flags,所以在仓库根目录跑就行。任务表默认
`plan-eval/fixtures/tasks.jsonl`,一行一个 `{"name":..., "task":...}`;task 会成为 goal
的 objective——也就是模型在「本轮目标」里读到的那句话,和内核检查的是同一个值。

判定用的是 `Harness` 里那套环境,和离线门一模一样,所以两边的差别只可能来自候选本身。
三类东西分开计:

- **传输失败**不计入任何比率。请求超时说明不了模型会不会写语法。
- **``` 代码块 / 直接调工具**算「没照做」,不算「不会写」。提示明确要求裸计划;fence
  单独计数,然后剥掉再判里面的内容——先剥再算会把两个完全不同的问题混成一个。
- **拒绝类别按模型分列**。「这个模型老是撞哪道墙」才是能拿来改的数,单一通过率不是。

`--repeat` 默认 1,但一个样本的成功率是噪音;真要下结论至少 3。

## 加新 case

值得加的是**会让人看走眼的**那种。例如现有的
「a recalled note quietly widening its audience」:它没有读任何不该读的东西,每一项计数都在预算内,
唯独信息流是错的——正是评审会挥手放过的那种计划。
