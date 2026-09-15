通过 SSH 管理 fleet：查看日志、修改 Nix、部署并验收；仅在已开启运维功能的群使用

# 连接与权限

加载本技能会同时加载 sandbox。先 sandbox_list，复用本群工作区；没有则 sandbox_create。
本群的 sandbox 已接入 Max 专用 Tailscale 内网，直接使用 `ssh hostname`。
SSH 默认登录 `max`，有完整免密 sudo；群内成员均可发起运维。
传输文件与代码使用普通 scp、rsync、Git。若内网/DNS 不可用，报告实际错误。

# 工作方式

先核对主机、服务状态、配置与相关日志，再执行修改。长流程使用 operations 后台任务。
源码使用任务独立的 Git checkout/worktree，遵守仓库 AGENTS.md；Nix 配置优先使用原生模块与 systemd。
先 fetch 检查远端更新与工作区差异，记录修改的 commit、构建产物与激活前 generation。
小内存机器使用 fleet 规定的构建机，目标机接收闭包并激活。系统和 Home Manager 分别验证。
长构建或部署在远端 systemd 作业中运行，保存主机、unit、日志和退出状态；SSH 断线先查询，不盲目重跑。
停止本地等待不代表取消远端作业；取消后再次确认实际状态。
部署后检查真实业务功能，不能仅凭 SSH 恢复、服务 active 或 shell 退出码认定完成。
并发任务不要同时激活同一主机。回滚前核对当前 generation，避免覆盖其他任务或人工的新变更。
