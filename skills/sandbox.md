沙箱与群文件的完整用法：nix 装包、超时与输出截断、文件进出群——用沙箱开工前先取这份

# 生命周期与共享

sandbox_create 拿到 sandbox_id，之后所有沙箱工具都传它。沙箱跨 dispatch 存活——
先 sandbox_list 看有没有现成的，优先复用，别每次新建。销毁只有三种情况：
sandbox_destroy、群里 !clear --all、bot 重启。同群的其他并发任务共享这些沙箱；
同一个沙箱里的 sandbox_exec 会自动排队串行执行（并发调用不会互相打架），但两个
任务写同一个文件仍要自己协调。沙箱不是持久存储：重要产物尽快发出去。
sandbox_create 的可选参数：network 传 "none" 可断网跑不可信代码（默认 bridge
有网）；image 一般不要动，默认的 max-sandbox:latest 才带下述 nix 环境。

# 装软件（nix，不是 apt）

镜像预装的几乎只有基础 shell 环境和 jq——其他一切工具都按需取。不要 apt/yum
（镜像里没有包管理器数据库，只会浪费一轮）。要用没预装的工具，把 nixpkgs
attribute 传给 sandbox_exec 的 packages 参数：实现是 `nix shell nixpkgs#<attr>
-c sh -c <命令>`，只对这一条命令生效（放进 PATH），无需安装，可以一次传多个。
attribute 名用 nix_search 查（regex 匹配名字和描述，最多回 30 条，如 'ffmpeg'、
'python.*opencv'、'^nodejs$'；空结果就放宽 regex）。包 store 全沙箱共享：某个包
第一次用要下载，那一次把 timeout_seconds 提到 120-300；下过之后所有沙箱瞬时可用。

Python 专门提醒：nixpkgs 的 python3Packages.* 传给 packages 只会把它的命令行
工具放进 PATH，`import` 不到——要用第三方库，正确路子是 packages=["python3"]，
然后 `python3 -m venv /work/venv && /work/venv/bin/pip install <库>`（bridge
网络下可用；大多数库有预编译 wheel，需要源码编译时把 "gcc" 也加进 packages）。
venv 建在 /work 里，同一沙箱后续命令直接复用。

# 跑命令

sandbox_exec 把 command 原样交给 sh -c，timeout(1) 控真实时钟（默认 30s，上限
600；下大包、编译、跑批任务时主动调大，超时的命令会被杀）。exit_code 0 = 成功。
stdout/stderr 各截 ~16KiB；truncated=true 时完整输出已存在 full_output_file 指的
文件里——下一条命令直接 grep/head/tail/wc 那个文件提取要点，不要换着 flag 重跑
原命令。多行脚本先 sandbox_write_file 写进去（自动建父目录、覆盖写）再执行；
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
