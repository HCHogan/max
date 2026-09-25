沙箱与群文件的完整用法：nix 装包、超时与输出截断、/chat 里的群文件和发文件——用沙箱开工前先取这份

# 生命周期与共享

每个群一个沙箱，第一次用任何沙箱工具时自动启动，不用创建也不用传 id；群里的
`!` 命令也在同一个沙箱里跑。它跨 dispatch 存活，销毁只有三种情况：
sandbox_destroy、群里 !clear --all、连续 14 天没用触发 TTL 清理；销毁后下一次调用会
起一个空的新沙箱。bot 重启后会按数据库记录接回原来的 /work 卷；旧策略或停止的容器
会围着原卷重建。同群的其他并发任务共享这个沙箱；
同一个沙箱支持多条 sandbox_exec 并发，后台任务不会独占整个沙箱。没有数据依赖的
命令可同批提交；命令之间有先后依赖就分轮执行。每条命令的超时、取消、stdout/stderr
各自独立，/work、临时文件和端口仍然共享，同一路径的修改要自己协调。删除或策略重建
会等正在使用它的命令结束；不要靠删除 sandbox 取消某一条命令。文件系统观察可能包含
并发任务的变化，不能把所有变化都归因于当前命令。它是有期限的工作区，不是长期存储：
重要产物尽快发出去。
NixOS 系统和网络是宿主策略，不交给调用者选择：命令固定在
宿主预构建的 NixOS 沙箱里以 uid 1000、无 Linux capability、no-new-privileges 运行，
有 CPU/内存/PID 上限；根文件系统只读，只有 /work 和有大小上限的临时目录可写，
/chat 只读。
普通群的 max-sandbox 网络允许访问公网 IPv4，可以 curl、git clone、调用公开 API、
下载项目依赖；普通群无法访问宿主机、内网、链路本地、Tailscale 地址和其他沙箱，IPv6 关闭。
已开启运维功能的群使用共享 maxops 内网；SSH、fleet 和部署方法见 operations 技能。
共享网络中的临时服务使用动态端口。
加载技能只提供说明和工具，不改变群的网络策略。/work 中的代码和文件跨升级保留，
读取旧 checkout 前先核对版本，不能拿它推断当前 Max 的能力。
联网不等于获得对外写入权限：发布、上传、修改远端数据仍须符合任务授权。
网络写入结果不明时先核实，不能因为命令超时就重复执行。

# 装软件（nix，不是 apt）

NixOS 沙箱预装的是一套接近 Ubuntu 默认的基础环境，直接可用不必再传 packages：
bash/coreutils/sed/awk/grep/find/diff/patch/file/tree/bc、tar/gzip/xz/bzip2/zstd/
zip/unzip、curl/wget/openssl/rsync/socat/nc、ip/ss/ping/dig、ps/top/lsof/pstree、
git/ssh/scp/vim/nano、python3/perl、jq/rg/make。除此之外的工具都按需取。不要 apt/yum
（沙箱里没有这些包管理器的数据库）。要用没预装的工具，把 nixpkgs
attribute 传给 sandbox_exec 的 packages 参数：宿主 broker 根据固定 nixpkgs 版本构建，
为沙箱保存 GC roots，随后把返回的只读 store 路径放进
这一条命令的 PATH，无需安装，一次最多 32 个。真正的 `sh -c` 在有公网访问能力的
非 root 沙箱里执行。沙箱只读共享宿主 /nix/store，没有宿主 Nix daemon socket 或数据库；
不要自行修改共享 store。停止实例保留 /work 和 GC roots，销毁沙箱才移除它们。
attribute 名用 nix_search 查（regex 匹配名字和描述，最多回 30 条，如 'ffmpeg'、
'python.*opencv'、'^nodejs$'；空结果就放宽 regex）。包 store 全沙箱共享：某个包
第一次用要下载，那一次把 timeout_seconds 提到 120-300；下过之后所有沙箱瞬时可用。

宿主开放了 GPU 时沙箱里有 /dev/dri/renderD128（`test -e` 一下）。这时 nixpkgs 的
ffmpeg 可以用 VA-API 硬件编解码：解码加 `-hwaccel vaapi -hwaccel_device
/dev/dri/renderD128 -hwaccel_output_format vaapi`，缩放用 `scale_vaapi`，编码用
`h264_vaapi`/`hevc_vaapi`/`av1_vaapi`，要回到 CPU 滤镜先 `hwdownload,format=nv12`。
硬件帧不会自动按旋转元数据转正，需要时自己加 transpose。硬件路径报错就去掉这些参数走 CPU。

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
不要换着 flag 重跑原命令。工作目录是 /work，相对路径都相对它；所有文件工具的
path 都是沙箱里的真实路径。read_file 读文本文件开头（默认 16KiB、max_bytes 上限
64KiB；二进制文件只报大小），write_file 写 UTF-8 文本（自动建父目录、覆盖写）——
两者只是省一次 sandbox_exec，heredoc、重定向照样能用。

# 群文件进出

进：本群所有文件、图片和视频（表情包除外）都在只读的 /chat 里，名字就是上下文里的
编号——[image#123.0] 是 /chat/123.0.<扩展名>，视频同理；#456 那条消息里的
[file:报告.pdf] 是 /chat/456-报告.pdf（一条消息带多个文件时是 456.0-、456.1-）。
直接 ls、cat、重定向、当命令参数用；要改就先复制到 /work。文件下载完成就会出现在
/chat 里，正在跑的命令也看得到；引用上下文里标着 ready=false 的还在下载，稍后再看。
出：图表/截图这类图片用 send_image 直接贴进聊天（几 MB 以内；caption 参数在图前带
一句话，支持引用/@ 占位符）；其他产物（.csv/.pdf/.zip/.log…）用 send_file 传进群文件
（name 参数改显示名，默认取文件名）。两者都在调用那一刻读取文件并返回新消息的
message_id，之后再改同一路径不会影响已发出的内容。写进任何目录都不会自动发出去。

# 中文字体（画图、转文档，凡是要渲染中文都会踩）

沙箱默认没有中文字体：matplotlib 画图、LibreOffice 转文档、ImageMagick 写字，
中文都会变豆腐块。字体文件走 nix 拿：
在 sandbox_exec 的 packages 中加入 `"noto-fonts-cjk-sans"`；命令内查看 PATH 中
注入的 `/nix/store/…-noto-fonts-cjk-sans-…/bin`，去掉末尾 /bin 后从 share/fonts/
读取字体。包由宿主 broker 构建，沙箱不直接调用共享 store 的 Nix daemon。
走 fontconfig 的程序（LibreOffice、ImageMagick 等）：把字体拷进 ~/.fonts/，
packages 里加 "fontconfig" 跑一次 `fc-cache -f`。
matplotlib 另有一层：字体装了它也不会自动用——先试直接喂文件
`font_manager.fontManager.addfont(<字体文件>)`，然后
`rcParams['font.sans-serif'] = ['Noto Sans CJK SC']`；.ttc 认不了就退回
fontconfig 路线再指定家族名。顺手 `rcParams['axes.unicode_minus'] = False`，
不然负号也是方块。
无论哪条路：**先出一张含中文的小样自查**（画个带中文标题的图 / 转一页出图），
确认没豆腐块再跑正式任务、再发给人。
