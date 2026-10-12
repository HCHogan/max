# Destiny 攻略表格快照

四份公开工作簿按分页保存为 UTF-8 CSV，供后续宿主侧 `index/read/find` 工具使用。
`index.json` 列出来源、分页名称和 ID、相对路径、获取方式、行列数、校验和、
原表链接，以及原始列坐标和可识别的表头。资料包在构建时嵌入 Max，加载
destiny skill 后通过 `destiny_guide` 查阅，不依赖 sandbox、联网或个人账号授权。

## 宿主工具

- `action=index` 分页列出表格、来源说明和 schema，可按 source 或 sheet 限定。
- `action=read` 按 CSV 记录分页读取，附相关批注、链接、文字格式和合并单元格原文。
- `action=find` 用 POSIX 扩展正则匹配非空单元格，默认忽略大小写；返回原表行号和来源。
  同时检索中英文，同一行只返回一次，matched_languages 说明在哪种语言命中。
  默认排除历史/ignore/隐藏页，显式 sheet 或 include_legacy 可查询这些分页。
- offset 从 0 起，read 计 CSV 记录，find 计匹配记录。按 next_offset 继续；响应预算
  只缩短页长，不截断单元格。columns 使用原表 A/B/AA 等列坐标。
- 获取日期、快照哈希与原表标注的适用版本共同用于判断资料是否合适；目录中
  unspecified 的分页不能据此认定适用于当前补丁。

## 数据格式

- 原版 CSV 路径保持不变；`zh-chs/<source>/*.csv` 是对应的中文副本，行列坐标完全相同。
  工具默认返回中文及 original_cells 英文，language=en 返回英文；language 不限制搜索语言。
- `zh-chs/index.json` 绑定每份译文和原文的 SHA-256，并记录官方 Manifest 版本、翻译方法和时间。
  官方名称按同 hash 配对；`zh-chs/glossary.json` 保存用到的定义类型和 hash。无法消除的同名歧义
  不强行选官方名称。status=terms-only 表示术语草稿，社区说明仍有英文；status=complete 才表示
  完成全部文字的机器翻译。完整译文不是官方攻略译本；以英文原文核对条件。
- 自动检查原文哈希、空单元格、行列、数字、链接、换行和占位符。中文说明保留数值和未知值标记；
  原始批注、链接文字和 rich_text 仍为英文，工具标明 original_details_language=en。

- CSV 保留原表网格：第一个 CSV 记录对应原表第 1 行，第一列对应 A 列，
  不添加合成表头或行号列。仅裁掉末尾空行。
- 说明中的换行和逗号按 CSV 规则转义。读取时必须使用 CSV 解析器，
  不能把文件物理行号当成原表行号。
- 合并单元格的文字只保存在左上角；合并范围在同名 `.metadata.json` 中。
  HTML 未渲染的行保留为空行，`rendered_rows` 记录实际读取的行。
- XLSX 来源保存公式的缓存计算结果，日期转换为 ISO 日期；数值未重新计算，
  百分数、缩放和单位应结合原表表头理解。公式、可获取的批注和链接另存元数据。
- HTML 来源保存公开页面显示的文字、链接、图片地址和行内文字格式。
  HTML 无法提供全部公式和批注；图片和图表的内容不在 CSV 中。
- `schema.layout=raw_spreadsheet_grid` 表示原始网格，并不是归一化实体表。
  `header_rows` 是按表头词识别的导航提示；并排表格、分节标题和原始说明仍需读取。

## 版本与资料状态

所有公开可发现的分页都会保存，包括隐藏页、旧版、历史数据和 `ignore` 页。
`source_status` 只根据分页名称标记 `historical`、`ignore` 或 `unspecified`；
`unspecified` 不保证资料适用于当前游戏版本。`fetched_at` 是获取时间，
原表标注的更新日期和测试版本仍以表格内容为准。

Endgame Analysis 的 Status 页解释了各分页更新状态。不同武器类别的 Tier
不能直接横向比较，两列推荐 perk 也不能按行序直接配对。Boss Damage 的
Sustained、Swap 和 Bosses 页应连同测试条件阅读。

## 更新

宿主运行 `scripts/fetch-destiny-guides.py`，需要 Python 3、curl、openpyxl
和 beautifulsoup4。程序优先下载公开 XLSX；无法导出时读取公开 HTML 分页。
原始下载缓存位于 Git 忽略的 `var/destiny-guides-import/`。全部分页获取、
解析成功后才更新本目录。更新后需要重新构建并部署 Max，运行中的快照保持不变。

```sh
python3 scripts/fetch-destiny-guides.py
python3 scripts/translate-destiny-guides.py
python3 scripts/translate-destiny-guides.py --check
```

翻译生成器使用 Python 标准库和 curl，缓存位于 Git 忽略的 var/destiny-guides-translation。
它仅在资料生成时联网；默认公共翻译接口可能限流，可用 --llm-config 配置文件路径 --profile 名称
切换到已配置的 Max 模型（需要 PyYAML），或用 --llm-env 读取 MAX_LLM_* 环境变量；不会打印密钥。
--terms-only 可先生成明确标注的术语草稿。运行时直接检索内嵌的两种语言。更新英文后须重新生成中文，
宿主会拒绝原文哈希不一致的旧译文。新的 Manifest 可删除缓存中的 manifest.json 后重新获取。
