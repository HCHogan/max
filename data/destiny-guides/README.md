# 命运2 攻略表格（沙箱里是 /data/destiny）

四份公开 Google 表格的只读快照，随 Max 部署更新，不是实时数据。每个分页的获取时间
在 catalog.tsv 的 fetched_at；适用的游戏版本以表格自己的说明为准。

## 先看这两个文件

- `catalog.tsv`：每个分页一行：path、source、title（英文原名）、title_zh、status、rows、
  columns、header_rows（可能的表头行号）、fetched_at、url（原表链接，引用时附上）。
  status 为 current 的是当前分页，hidden/historical/ignore 的在 archive/。
- `names.tsv`：英文 ⇄ 官方中文名。kind 为 item/perk/set/… 的来自官方 Manifest，hash 可交给
  destiny_lookup；frame 是框架短名（High-Impact = 高冲击力）；editorial 是这份资料的通用译法，
  不是官方名称。

## 目录

- `en/<source>/<sheet>.csv`：原文，当前分页。数值、条件、例外以这里为准。
- `zh/<source>/<sheet>.csv`：中文副本，行列坐标与 en 完全相同，同一格可直接对照。
- `archive/{en,zh}/<source>/…`：隐藏、旧版（old/outdated）和 ignore 分页，查历史时才看。
- `meta/<source>/<sheet>.json`：merged_ranges、cell_notes（作者批注）、hyperlinks、formulas、
  hidden_rows，坐标为 A1 写法。

| source | 内容 |
|---|---|
| court | 增伤/减益分类与叠加规则、勇士应对、催化、Banes、微型导弹 |
| compendium | perk、异域武器/护甲、模组、子职业技能和机制的具体数值、触发条件与例外 |
| endgame-analysis | 终局武器评级与推荐 perk、框架 archetypes、套装、技能/神器评价；先看 status.csv 的更新状态 |
| boss-damage | Boss 伤害测试：sustained 持续输出、swap 切枪、fireteam 配队、bosses 的测试条件 |

## CSV 约定

- 原表网格，没有加表头：文件第 N 行就是原表第 N 行，第 1 列是 A 列。`rg -n`、`sed -n 'Np'`
  给出的行号可以直接当原表行号引用。
- 单元格内的换行写成 `\n`，反斜杠写成 `\\`。
- 数值按原表的显示格式写（`26.83%`、`1028.960`），但不带千分位逗号；court 和 compendium
  来自网页，保留网页上的文字。`N/A`、`INF`、`?` 是原表的值。
- 合并单元格的文字只在左上角一格；表格可能并排或分节，表头不一定在第 1 行，先看
  header_rows 或用 `head` 看前几行。图片和图表不在 CSV 里。

## 读法

```sh
cd /data/destiny
rg -i 'cataclysmic' en                          # 文件:行号:内容，一行就是原表一行
sed -n '1,3p;40p' en/endgame-analysis/lfrs.csv  # 表头和第 40 行
```

```python
import csv

def load(path):
    """rows[N-1] 是原表第 N 行，row[0] 是 A 列。"""
    with open(path, encoding="utf-8") as f:
        return [[c.replace("\\\\", "\0").replace("\\n", "\n").replace("\0", "\\") for c in row]
                for row in csv.reader(f)]

def col(letters):
    """'A' -> 0, 'AK' -> 36"""
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1
```

用 pandas 时：`pd.read_csv(path, header=None, dtype=str, keep_default_na=False)`，否则 N/A 会被读成空值。

## 中文译文

- zh/ 里的社区说明是机器翻译，不是官方攻略译本；装备、perk、套装等名称按官方 Manifest 的
  同 hash 中文名替换，框架短名按官方框架名。
- 数值、条件、例外和测试前提以 en 为准，zh 与 en 有出入时以 en 为准。
- boss-damage 的 `e.` 前缀表示强化（Enhanced），`e. Target Lock` 是强化目标锁定；部分旧译文
  把它误译成“例如”。

## 更新（维护者）

```sh
python3 scripts/fetch-destiny-guides.py        # 需要 openpyxl、beautifulsoup4
python3 scripts/translate-destiny-guides.py    # 只翻译新出现的行；--plan 先看要翻译多少
python3 scripts/translate-destiny-guides.py --check
```

fetch 会先把现有中英对照收进 `var/destiny-guides-translation`，没变的行不会重新翻译。
翻译服务默认是 Google 公共接口，质量较差；`--llm-config <Max 配置> --profile <名称>` 或
`--llm-env` 改用 Max 已配置的模型。人工核对过的行写进 `.state/translation-overrides.json`，
优先于机器翻译；`--retranslate REGEX` 重新翻译匹配的行。`.state/` 是生成器的内部记录，
不会挂进沙箱。更新后重新构建并部署 Max，各群沙箱会在下次使用时围着原 /work 重建一次。
