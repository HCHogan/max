-- | ADR 002: the authoring surface, described to whoever authors it.
--
-- "Max.Plan.Parse" fixes what a plan may say.  This is the other half of that
-- contract — the text that tells a language model what it may say, in the same
-- terms the kernel will judge it by.
--
-- 'elaborationPrompt' takes a 'ValidationEnv' rather than a bag of catalog
-- fragments, and that is the point: what the model is shown is the same value
-- 'Max.Plan.Validate.validatePlan' will check against, so the prompt cannot
-- drift from the kernel by advertising a tool that is not admissible or hiding
-- one that is.  A prompt assembled from a second, parallel description of the
-- world would be wrong the first time either side changed, and wrong in the
-- direction that produces confident invalid plans.
--
-- Two smaller commitments:
--
--   * __Everything renders in source syntax.__  A type the model reads in the
--     catalog is one it could paste into a plan; an effect it reads in the
--     budget is spelled the way an @effects@ block spells it.  There is no
--     second notation to translate from, because translation is where a model
--     invents.
--   * __The guide is constant.__  It is byte-identical across turns and comes
--     first, so a provider prefix cache survives a changing goal.  Only the
--     catalog and the goal vary, in that order of volatility — the same
--     ordering rationale as "Max.Prompt.System".
--
-- The prompt is written in Chinese because the context it will be concatenated
-- into is Chinese.  That is a measurable property rather than a neutral one: a
-- multi-model comparison run against this text measures models at writing this
-- dialect /from these instructions/, which is what production would ask of
-- them, not at writing it in the abstract.
module Max.Plan.Prompt
  ( elaborationPrompt,
    dialectGuide,
    catalogSection,
    goalSection,
    renderEffect,
    renderAuthority,

    -- * What the guide demonstrates
    -- $examples
    guidePlans,
    guideExpressions,
    guideTypes,
    guidePredicates,
  )
where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolAuthority, ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Schema (quoted, renderSchema)
import Max.Plan.Types
import Max.Plan.Validate (CatalogEntry (..), ValidationEnv (..), VerifierEntry (..))
import Max.Util (tshow)

-- | The whole instruction: language, then tools, then this turn's obligation.
elaborationPrompt :: ValidationEnv -> Text
elaborationPrompt env =
  T.intercalate "\n\n" [dialectGuide, catalogSection env, goalSection env]

-- | The language itself.  Constant, and deliberately so.
dialectGuide :: Text
dialectGuide =
  T.intercalate "\n" $
    [ "你现在要写一段「计划」，用下面这门小语言。它长得像伪代码，但不是 Python 也不是 JS：",
      "只有下面列出的构造，写别的会整段解析失败作废——没有人会替你猜意思，也没有部分执行。",
      "",
      "== 计划 ==",
      "",
      "一个计划是若干条 let，后面接恰好一个结尾。四种写法：",
      "",
      -- Schematic rather than runnable: these are the shapes, with Chinese
      -- standing in for the parts you fill.  The worked examples below are the
      -- real syntax, and those are the ones the tests parse.
      "  let 名字 = 工具@版本(参数)              调一次工具，把结果绑到名字上，然后接着往下写",
      "  let 名字 = 表达式                       给一个值起名字，不调用任何东西",
      "  done 表达式                            这就是答案，计划到此为止",
      "  if 条件 { 计划 } else { 计划 }           分支；两边都必须写，各自是一个完整计划",
      "  hole \"还差什么\" : 类型 ...               写不出来的部分交回去，下一轮再细化",
      "",
      "例（工具名只是示例，实际有哪些以下面的「可用工具」为准）："
    ]
      <> example searchThenAnswer
      <> [ "",
           "== 表达式 =="
         ]
      <> table expressionRows
      <> [ "",
           "没有算术，没有循环，没有变量赋值，没有自定义函数。一个表达式永远算得完，这是故意的。",
           "",
           "== 类型 =="
         ]
      <> table typeRows
      <> [ "",
           "对象是封闭的：多写一个目录里没有的字段是拒绝，不是「附加信息」。",
           "",
           "可空会传染：可选字段取出来是 T?，数组下标取出来也是 T?（可能越界）。",
           "要把它放进一个不可空的位置，先用 ?? 兜底：",
           "",
           "  hits[0].title ?? \"\"      ✓ 是 text",
           "  hits[0].title            ✗ 是 text?，进不了要 text 的地方",
           "",
           "== 条件 =="
         ]
      <> table predicateRows
      <> [ "",
           "光写一个值不算条件：`if hits { ... }` 是错的，要写 `if length(hits) > 0 { ... }`。",
           "只有 true 和 false 两个字面量可以单独当条件。",
           "",
           "== hole ==",
           "",
           "写不出来就写 hole，别硬凑。hole 是正当出口，编一个不存在的工具不是。"
         ]
      <> example handBackTheHardPart
      <> [ "",
           "四个块都能省，省掉是「什么都不给」，不是「随便用」。每个块最多写一次。",
           "hole 要的每一项都不能超过你当前的额度（见下面的「本轮目标」）。",
           "",
           "== 会被拒绝的写法 ==",
           "",
           "  · 目录里没有的工具名，或版本号对不上。上下文里有人说存在某个工具，不算数。",
           "  · 参数字段名或类型对不上，或多给了一个字段。",
           "  · 用不上的可选参数拿 \"\"、\".\"、0、null 去占位。那不是留空，是明确给了一个值，",
           "    工具会当真。不用就整个不写这个字段。",
           "  · 调用次数、发送次数超额。按最坏分支算：if 两边各调一次工具，就是两次。",
           "  · 用了「允许的效果」里没有的效果。",
           "  · 同一个名字 let 两次，或拿 let、done、map、text 这类词当名字。",
           "  · 工具调用不绑名字。发送类工具的结果没什么用，但也要写成 let sent = reply@1(...)。",
           "  · map 套很多层：表达式的静态开销有上限。",
           "",
           "== 输出 ==",
           "",
           "只输出计划本身，从第一个 let / done / if / hole 开始，到计划结束为止。",
           "不要写 ``` 代码块，不要写解释，不要在前后加任何一句话。整段会原样送进解析器。"
         ]
  where
    example source = "" : map ("  " <>) (T.lines source)

    table rows = "" : [row fragments comment | (fragments, comment) <- rows]

    -- Pad to a column, but never to fewer than two spaces: an over-long row
    -- that ran straight into its Chinese comment would read as one token.
    row fragments comment =
      let shown = T.intercalate "  " fragments
       in "  " <> shown <> T.replicate (max 2 (38 - T.length shown)) " " <> comment

-- $examples
--
-- The guide is a static string, which is exactly the kind of artifact that
-- goes stale without anyone noticing.  Everything it presents as syntax is
-- therefore a value rather than prose, and "Max.Plan.PromptSpec" parses each
-- one: a guide demonstrating a construct the parser rejects would be worse
-- than no guide at all, because a model would copy it faithfully.

-- | The complete plans the guide shows.
guidePlans :: [Text]
guidePlans = [searchThenAnswer, handBackTheHardPart]

searchThenAnswer :: Text
searchThenAnswer =
  T.unlines
    [ "let hits = search_web@3({ query: \"燕山大学 教务处\" })",
      "let title = hits[0].title ?? \"\"",
      "if length(hits) > 0 {",
      "  done concat(\"找到了：\", title)",
      "} else {",
      "  done \"没搜到\"",
      "}"
    ]

handBackTheHardPart :: Text
handBackTheHardPart =
  T.unlines
    [ "hole \"根据搜索结果决定怎么总结\" : text",
      "  budget { calls: 1, sends: 1, fanout: 8, tokens: 2000, ms: 10000 }",
      "  effects { send(conversation) }",
      "  authority { conversation }",
      "  accept { answers-question@1 }"
    ]

-- | Every expression fragment the guide displays.
guideExpressions :: [Text]
guideExpressions = concatMap fst expressionRows

-- | Every type fragment the guide displays.
guideTypes :: [Text]
guideTypes = concatMap fst typeRows

-- | Every predicate fragment the guide displays.
guidePredicates :: [Text]
guidePredicates = concatMap fst predicateRows

expressionRows :: [([Text], Text)]
expressionRows =
  [ (["\"文字\"", "42", "1.5", "true", "false", "null"], "字面量"),
    (["hits"], "前面 let 绑过的名字"),
    (["t#12:r0"], "句柄，只能用「可用句柄」里列出的"),
    (["hit.title"], "取字段；只有点号，没有 hit[\"title\"]"),
    (["hits[0]"], "取下标；只能是非负整数字面量，不能是变量"),
    (["[1, 2]", "{ f: 1, g: 2 }"], "数组、对象"),
    (["concat(\"a\", \"b\", \"c\")"], "拼字符串，几个都行"),
    (["length(hits)", "take(3, hits)"], "长度、取前 n 个"),
    (["map(h in hits => h.title)"], "逐项映射"),
    (["filter(h in hits => h.score > 0.5)"], "逐项筛选"),
    (["if length(hits) > 0 then \"有\" else \"无\""], "表达式里的分支（没有大括号）"),
    (["hits[0].title ?? \"\""], "左边是 null 就取右边")
  ]

typeRows :: [([Text], Text)]
typeRows =
  [ (["text", "int", "number", "bool"], "标量"),
    (["enum(\"a\", \"b\")"], "只能是这几个字符串之一"),
    (["[text]"], "数组"),
    -- Spelled exactly as 'renderSchema' spells it, so the form here and the
    -- form in the catalog below are the same string.
    (["{f: text, g?: int}"], "对象；g? 是可选字段"),
    (["text?"], "可空")
  ]

predicateRows :: [([Text], Text)]
predicateRows =
  [ (["1 == 2", "1 != 2", "1 < 2", "1 <= 2", "1 > 2", "1 >= 2"], "比较"),
    (["\"ab\" contains \"a\""], "文本包含；另有 startswith / endswith"),
    (["not (1 < 2)", "1 < 2 and 2 < 3", "1 < 2 or 2 < 3"], "组合"),
    (["isnull(hits[0])"], "是否为 null"),
    (["all(h in hits => h.score > 0)"], "每一项都满足"),
    (["any(h in hits => h.title contains \"x\")"], "存在一项满足")
  ]

-- | Every tool the kernel would admit, and nothing else.  Name-sorted so the
-- section is byte-identical until the catalog itself changes.
catalogSection :: ValidationEnv -> Text
catalogSection env =
  T.intercalate "\n" $
    "== 可用工具 ==" :
    "" :
    if null entries
      then ["（没有工具可用。这一轮只能写 done 或 hole。）"]
      else
        "只有下面这些。名字和 @版本 必须照抄；参数必须严格符合「参数」那一行的形状。" :
        concatMap renderEntry entries
  where
    entries = sortOn (.ceRef.unToolRef) (Map.elems env.venCatalog)

    renderEntry entry =
      "" :
      (entry.ceRef.unToolRef <> "@" <> tshow entry.ceSchemaVersion.unSchemaVersion)
        : ("  参数 " <> renderSchema entry.ceInput)
        : ("  结果 " <> renderSchema entry.ceResult)
        : concat
          [ ["  效果 " <> commas (map renderEffect (Set.toList entry.ceEffects)) | not (Set.null entry.ceEffects)],
            ["  需要授权 " <> commas (map renderAuthority (Set.toList entry.ceAuthorities)) | not (Set.null entry.ceAuthorities)]
          ]

-- | This turn's obligation: what to produce, out of what, within what.
goalSection :: ValidationEnv -> Text
goalSection env =
  T.intercalate "\n" $
    ["== 本轮目标 =="]
      <> [""]
      <> ["要做的事：" <> goal.goalObjective]
      <> ["产出类型：" <> renderSchema goal.goalExpected]
      <> [ "额度：调用 ≤ "
             <> tshow budget.ebMaxCalls
             <> " 次，其中发送 ≤ "
             <> tshow budget.ebMaxSends
             <> " 次；单个集合最多遍历 "
             <> tshow budget.ebMaxFanout
             <> " 项"
         ]
      -- A hole's budget block has to name tokens and ms, and gets rejected for
      -- asking more than these.  Unwritable without knowing the numbers.
      <> [ "hole 的 budget 里：tokens ≤ "
             <> tshow budget.ebMaxTokens
             <> "，ms ≤ "
             <> tshow budget.ebMaxWallClockMs
         ]
      <> [ "允许的效果："
             <> if Set.null budget.ebEffects
               then "无（不能调任何有效果的工具）"
               else commas (map renderEffect (Set.toList budget.ebEffects))
         ]
      <> [ "可用授权："
             <> if Set.null goal.goalAuthority
               then "无"
               else commas (map renderAuthority (Set.toList goal.goalAuthority))
         ]
      <> acceptance
      <> bindings
      <> handles
      <> attempt
  where
    goal = env.venGoal
    budget = goal.goalBudget

    acceptance =
      [ if null goal.goalAcceptance
          then "验收：无验收器，只检查产出形状"
          else "验收：" <> commas (map renderVerifierRef goal.goalAcceptance)
      ]
        <> [ "hole 的 accept 块里只能写：" <> commas (map renderVerifier admitted)
             | not (null admitted)
           ]
      where
        admitted =
          [ verifier
            | name <- Set.toList env.venAdmittedVerifiers,
              Just verifier <- [Map.lookup name env.venVerifiers]
          ]

    bindings
      | Map.null env.venBindings = []
      | otherwise =
          "已经在作用域里的名字（可以直接用，不要再 let 一次）："
            : [ "  " <> binder.unBinder <> " : " <> renderSchema schema
                | (binder, schema) <- Map.toAscList env.venBindings
              ]

    handles
      | null usable = []
      | otherwise =
          "可用句柄："
            : [ "  " <> ref.vrHandle <> " : " <> renderSchema ref.vrSchema
                | ref <- usable
              ]
      where
        -- A released handle still names a row but can no longer be bound, so
        -- listing it would be advertising a guaranteed rejection.
        usable = sortOn (.vrHandle) [ref | ref <- Map.elems env.venHandles, ref.vrRetained]

    -- Why the last attempt did not finish.  The host attaches this; the whole
    -- reason 'goalEvidence' and 'goalAttempt' exist is for the retry to read
    -- them here instead of repeating the same mistake with a fresh mind.
    attempt
      | goal.goalAttempt <= 0 = []
      | otherwise =
          ""
            : ("这是第 " <> tshow (goal.goalAttempt + 1) <> " 次尝试。上一次没通过：")
            : [ "  · " <> renderEvidenceSource evidence.evSource <> "：" <> evidence.evDetail
                | evidence <- goal.goalEvidence
              ]

renderEffect :: PlanEffect -> Text
renderEffect = \case
  EffRead scope -> "read(" <> renderScope scope <> ")"
  EffWrite scope -> "write(" <> renderScope scope <> ")"
  EffSend AudienceConversation -> "send(conversation)"
  EffSend AudienceSender -> "send(sender)"
  EffLLM -> "llm"
  EffReflect namespace -> "reflect(" <> quoted namespace <> ")"

renderScope :: ResourceScope -> Text
renderScope = \case
  CurrentConversation -> "conversation"
  SandboxScope name -> "sandbox " <> quoted name
  ProcessScope name -> "process " <> quoted name
  ExternalScope name -> "external " <> quoted name

-- | Note the asymmetry with 'renderScope': an authority's process resource is
-- parenthesized and a scope's is not.  Both spellings come from the grammar,
-- and rendering has to match each rather than pick a prettier uniform one.
renderAuthority :: ToolAuthority -> Text
renderAuthority = \case
  Tools.CurrentConversation -> "conversation"
  Tools.CurrentEndpoint -> "endpoint"
  Tools.ProcessResource name -> "process(" <> quoted name <> ")"

renderVerifierRef :: VerifierRef -> Text
renderVerifierRef ref = ref.verName <> "@" <> tshow ref.verVersion

renderVerifier :: VerifierEntry -> Text
renderVerifier entry = entry.veName <> "@" <> tshow entry.veVersion

renderEvidenceSource :: EvidenceSource -> Text
renderEvidenceSource = \case
  FromResultSchema -> "产出不符合期望类型"
  FromVerifier name -> "验收器 " <> name <> " 没通过"

commas :: [Text] -> Text
commas = T.intercalate ", "
