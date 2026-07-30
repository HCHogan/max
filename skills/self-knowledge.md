你自己的身份、部署与命令用法总览；认真聊实现/部署/命令前取这份，行为细节再取 self-features

# 你是什么

开源 Haskell 项目 max（github.com/HCHogan/max），单二进制，跑在 Hank 的一台 Linux 主机上。
通过 NapCat（OneBot 11 协议）接入 QQ：NapCat 以反向 websocket 主动连到你的进程
（默认 :8080/onebot）。另有实验性的 wechatpad 微信后端（白名单群、纯文本收发）。
状态都在 PostgreSQL（消息、会话、记忆、媒体元数据、权限、用量）和一个按 sha256
内容寻址的 blob 目录（图片/视频/文件原件）。效果系统用 effectful，一个进程里并发跑：
websocket 事件循环、媒体下载 worker、caption worker（给图/视频/表情包写简介）、
embedding worker、提醒调度器、意图分类 worker、admin API、优雅停机 drain worker。

大致流程：消息进来分类（命令 / @你·回复你·私聊·戳一戳直接触发 / 闲聊过意图分类器决定
主动插话）→ 从 DB 重建上下文（水位窗口 + pins + 记忆 + 引用链）→ agent loop 多轮调
工具 → 回复按空行分段发出 → 记忆提取。触发/插话节流/feedback/prompt 形状/表情包这些
行为的完整细节在 self-features（英文）；模块布局和 effect 栈在 self-architecture。

# 技能系统（你正在用的这个）

系统提示末尾的技能对照表每技能一行，use_skill 取全文。来源三种：内置（随二进制发布，
比如这份和 self-features/self-architecture，后两者就是仓库里 docs/ 的原文）、全局 DB
技能、群 DB 技能；同名时群 > DB 全局 > 内置。管理走 admin API /api/skills。

# 命令（! 开头，群里私聊都可；下面就是 !help 的原文）

{{commands}}

权限三层补充：配置里的 owners > 群主/管理员（私聊里自己算管理员）> 普通成员；另有
permissions 表放显式授权（群作用域优先于全局），管理员能转授的只有
persona/clear/kill 三种。

# 部署与运维

NixOS module（nix/module.nix，flake 输出 nixosModules.max）：systemd 服务 max.service，
用户 max-bot，状态目录 /var/lib/max-bot（NapCat 登态、blob store）。配置三选：
services.max.settings 渲染 max.yaml / configFile 手管 / environmentFile 放密钥
（MAX_* 环境变量覆盖 yaml，CLI flag 最优先；--run-settings-check 可审计生效值）。
停机走 SIGTERM 优雅 drain（默认最多等 120s 让在跑的 dispatch 收尾）。
沙箱/浏览器镜像由 one-shot unit 在启动时从 sandbox-image/、browser-image/ 构建
（内容哈希做 tag，没变不重建），nixpkgs store 挂共享 volume。
PostgreSQL 可由 module 本地起（peer 认证）；migrations 在进程启动时自动按文件名
顺序应用，记录在 schema_migrations，库比二进制新时拒绝启动（防降级）。
NapCat 走 docker-compose 单独跑，反向 WS 连进来，可选 access_token 校验。
admin 面板（可选 admin: 配置段）：进程内 warp，默认 127.0.0.1 + bearer token，
看群/记忆/权限/任务/用量/日志/LLM 调用详情，管技能。
日志看 journalctl -u max；LLM token 用量在 llm_usage 表和面板里。

# 配置要点（max.yaml）

llm.profiles 每档：base_url/api_key/model/protocol(openai|anthropic)/stream/
multimodal/history_as_turns。顶级：owners、persona、timezone、history_window/max、
db.url、server(host/port/path/access_token)。可选段开可选功能：intent（主动插话）、
stickers（表情包+识图 profile）、embedding（语义搜索）、search（tavily）、memory
（提取 profile）、admin、browser、wechatpad。找配置文件顺序：--config-file >
./max.yaml > ~/.config/max/config.yaml。
