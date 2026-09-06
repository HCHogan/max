读写 PDF/Word/Excel/PPT：沙箱里提取、生成、转换、预览文档的路数——碰这类文件先取这份

# 总流程

都在沙箱里做（没读过 sandbox 手册先取那份）。文件进出：list_recent_files →
import_file_to_sandbox 拿进 /work，成品 send_file_from_sandbox 发回群文件；要给人
看效果，转成图片走 send_image_from_sandbox。工具分两档：能用命令行解决就不开
python；要精细读写内容才上 python 库——记住 sandbox 手册里的 Python 规则：把
`python3Packages.<attr>` 直接放进 packages，宿主生成可 import 的 Nix Python 环境，
需要 PyPI 特定版本时，再按 sandbox 手册在 /work 的独立 venv 中安装。

# PDF

读文本：poppler 工具集（attr 用 nix_search 查 'poppler'，含 pdftotext/pdfinfo/
pdftoppm）→ `pdftotext -layout in.pdf out.txt` 保排版；`pdfinfo` 看页数和元数据。
表格抽取 pdftotext 常常糊，packages=["python3Packages.pdfplumber"] 后按页 extract_tables。
拆/合/旋转：packages=["qpdf"] → 截取 `qpdf in.pdf --pages . 1-5 -- out.pdf`；
合并 `qpdf --empty --pages a.pdf b.pdf -- merged.pdf`。
页面转图（预览/给人看）：`pdftoppm -png -r 100 -f 1 -l 1 in.pdf page` →
send_image_from_sandbox。
生成 PDF：不要手写，先产 markdown/docx/pptx 再转（见转换一节）。

# Excel（xlsx）

packages=["python3Packages.openpyxl"]。读：`load_workbook(path, read_only=True, data_only=True)`——
data_only 拿公式的算出值而不是公式本身；大文件必须 read_only，否则内存起飞。
写：`Workbook()` 或 load_workbook 改完 `save()`；公式就写 "=SUM(A1:A10)" 字符串；
基础样式够用：`ws.column_dimensions['A'].width`、`cell.number_format`、字体加粗
`cell.font = Font(bold=True)`。和 csv 互转 python 十行内搞定；只想把内容倒出来
grep，packages=["gnumeric"] 的 `ssconvert in.xlsx out.csv` 更快。

# Word（docx）

packages=["python3Packages.python-docx"]。读：`Document(path)` 遍历 `.paragraphs` 和 `.tables`。
生成：add_heading / add_paragraph / add_table / add_picture，存 .docx。
markdown 起手更省事：packages=["pandoc"] → `pandoc in.md -o out.docx`。
不开 python 快速偷看：docx 就是 zip——packages=["unzip"] →
`unzip -p file.docx word/document.xml` 直接 grep 正文（pptx 在
ppt/slides/slideN.xml、xlsx 在 xl/worksheets/，同理）。

# PPT（pptx）

packages=["python3Packages.python-pptx"]。生成：`Presentation()` →
`prs.slides.add_slide(prs.slide_layouts[i])`（默认模板 0=标题页、1=标题+正文、
6=空白最常用）→ 往 placeholder 填字或 add_textbox / add_picture。
读：同库遍历每页 shapes，has_text_frame 的取 text。页数多的 ppt 逐页处理，
别一次性拼超长字符串。

# 格式互转与中文字体

万能转换器：packages=["libreoffice"] →
`libreoffice --headless --convert-to pdf in.docx --outdir /work`
（docx/xlsx/pptx ↔ pdf 都走它；首次下载非常大，timeout_seconds 直接开 600）。
文档带中文必看 sandbox 手册的中文字体一节（沙箱默认没有中文字体，不装必出
豆腐块）；装好后**先转一页、pdftoppm 出图自查**，再出全量。

# 通用纪律

改别人发来的文件，动手前先读一遍确认结构。任何产物发出去之前自己验一遍：pdf 抽
一页转图看、xlsx 重新 load 抽查几个格、docx 转回文本扫一眼——没打开过的文件不要
甩给群友。转换类操作保留原件，产物用新文件名。
