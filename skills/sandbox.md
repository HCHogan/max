沙箱与群文件的完整用法：nix 装包、超时与输出截断、文件进出群——用沙箱开工前先取这份

# 生命周期与共享

sandbox_create 拿到 sandbox_id，之后所有沙箱工具都传它。沙箱跨 dispatch 存活——
先 sandbox_list 看有没有现成的，优先复用，别每次新建。销毁只有三种情况：
sandbox_destroy、群里 !clear --all、连续 14 天没用触发 TTL 清理。bot 重启后会按数据库
记录接回原来的 /work 卷；旧策略或停止的容器会围着原卷重建。同群的其他并发任务共享这些沙箱；
同一个沙箱里的 sandbox_exec 会自动排队串行执行（并发调用不会互相打架），但两个
任务写同一个文件仍要自己协调。它是有期限的工作区，不是长期存储：重要产物尽快发出去。
sandbox_create 没有参数。镜像和网络是宿主策略，不交给调用者选择：命令固定在
max-sandbox:latest 里以 uid 1000、无 Linux capability、no-new-privileges 运行，
有 CPU/内存/PID 上限；根文件系统只读，只有 /work 和有大小上限的临时目录可写。
固定的 max-sandbox 网络允许访问公网 IPv4，可以 curl、git clone、调用公开 API、
下载项目依赖；宿主机、内网、链路本地、Tailscale 地址和其他沙箱均不可访问，IPv6 关闭。
联网不等于获得对外写入权限：发布、上传、修改远端数据仍须符合任务授权。
网络写入结果不明时先核实，不能因为命令超时就重复执行。

# 装软件（nix，不是 apt）

镜像预装的是一套接近 Ubuntu 默认的基础环境，直接可用不必再传 packages：
bash/coreutils/sed/awk/grep/find/diff/patch/file/tree/bc、tar/gzip/xz/bzip2/zstd/
zip/unzip、curl/wget/openssl/rsync/socat/nc、ip/ss/ping/dig、ps/top/lsof/pstree、
git/vim/nano、python3/perl、jq/rg/make。除此之外的工具都按需取。不要 apt/yum
（镜像里没有包管理器数据库，只会浪费一轮）。要用没预装的工具，把 nixpkgs
attribute 传给 sandbox_exec 的 packages 参数：宿主生成固定 Nix 表达式，短命网络
helper 只负责 `nix build --no-link --print-out-paths`，随后把返回的只读 store 路径放进
这一条命令的 PATH，无需安装，一次最多 32 个。真正的 `sh -c` 在有公网访问能力的
非 root 沙箱里执行；不要自行修改共享 Nix store。
attribute 名用 nix_search 查（regex 匹配名字和描述，最多回 30 条，如 'ffmpeg'、
'python.*opencv'、'^nodejs$'；空结果就放宽 regex）。包 store 全沙箱共享：某个包
第一次用要下载，那一次把 timeout_seconds 提到 120-300；下过之后所有沙箱瞬时可用。

Python 专门提醒：python3 本身已预装，标准库直接跑。第三方库把对应
`python3Packages.<attr>` 放进 packages；宿主会把同一次调用里的这些库收成一个
`python3.withPackages` 环境，所以命令中的 python3 可以直接 import。例如
packages=["python3Packages.openpyxl"]。需要 PyPI 的特定版本时，可以在 /work 中创建
独立 venv 并联网安装；不要修改全局 Python 环境。

# 跑命令

sandbox_exec 把 command 原样交给 sh -c，timeout(1) 控真实时钟（默认 30s，上限
600；下大包、编译、跑批任务时主动调大，超时的命令会被杀）。exit_code 0 = 成功。
stdout/stderr 各截 ~16KiB；truncated=true 时已保存的前段输出在 full_output_file 指的
文件里，但这个 spill 每个流最多保留 8MiB；spill_truncated=true 表示更后面的字节
只计长度和 SHA-256、不再落盘。下一条命令直接 grep/head/tail/wc 现有文件提取要点，
不要换着 flag 重跑原命令。多行脚本先 sandbox_write_file 写进去（自动建父目录、覆盖写）再执行；
看结果文件用 sandbox_read_file（UTF-8 文本，默认 16KiB、max_bytes 上限 64KiB；
二进制文件别用它读，直接用命令处理或发出去）。工作目录是 /work，相对路径都
相对它。

# 群文件进出

进：list_recent_files 列群里最近发的非图片文件（file_id、名字、发送人、大小、
ready；默认 10 条，最多 50）。ready=true 表示 bot 已把字节下载到本地，这时
import_file_to_sandbox 才能把它拷进 /work（dest_path 可改名；ready=false 时
稍等重试）。结果里有 message_id，可以和引用消息对上号（"用户刚回复的那条里的
文件"）。
出：图表/截图这类图片用 send_image_from_sandbox 直接贴进聊天（base64 内联，
几 MB 以内；caption 参数在图前带一句话，支持引用/@ 占位符）；其他产物
（.csv/.pdf/.zip/.log…）用 send_file_from_sandbox 传进群文件（name 参数改
显示名，默认取文件名）。

# 中文字体（画图、转文档，凡是要渲染中文都会踩）

沙箱默认没有中文字体：matplotlib 画图、LibreOffice 转文档、ImageMagick 写字，
中文都会变豆腐块。字体文件走 nix 拿：
`nix build nixpkgs#noto-fonts-cjk-sans --print-out-paths`，输出路径的
share/fonts/ 下就是字体文件。
走 fontconfig 的程序（LibreOffice、ImageMagick 等）：把字体拷进 ~/.fonts/，
packages 里加 "fontconfig" 跑一次 `fc-cache -f`。
matplotlib 另有一层：字体装了它也不会自动用——先试直接喂文件
`font_manager.fontManager.addfont(<字体文件>)`，然后
`rcParams['font.sans-serif'] = ['Noto Sans CJK SC']`；.ttc 认不了就退回
fontconfig 路线再指定家族名。顺手 `rcParams['axes.unicode_minus'] = False`，
不然负号也是方块。
无论哪条路：**先出一张含中文的小样自查**（画个带中文标题的图 / 转一页出图），
确认没豆腐块再跑正式任务、再发给人。
