通过 SSH 管理 fleet：查看日志、修改 Nix、部署并验收；仅在已开启运维功能的群使用

# 连接与权限

本技能自动加载 sandbox；工作区、装包、文件和命令执行的通用用法见 sandbox。
本群的 sandbox 已接入 Max 专用 Tailscale 内网，直接使用 `ssh hostname`。
SSH 默认登录 `max`，有完整免密 sudo；群内成员均可发起运维。
传输文件与代码使用普通 scp、rsync、Git。若内网/DNS 不可用，报告实际错误。
`maxops` 是专用客户端和网络的名字，不是运维服务器；目标填实际 fleet 主机名。
当前运维入口是本技能和 shell/SSH。历史里的 maxops 技能、Hub API、远端 job 句柄均已退役，
不能当成当前工具或待重放命令；旧任务继续按原目标，通过实际主机、服务和日志取证。

# 告警与巡检

fleet 的 Alertmanager 在 h610 和 tank，本机 HTTP 端口都是 9093；通过 SSH 查询，例如：

```sh
ssh h610 'curl -fsS http://127.0.0.1:9093/api/v2/status'
ssh h610 'curl -fsS "http://127.0.0.1:9093/api/v2/alerts?active=true&silenced=true&inhibited=true"'
```

Alertmanager 使用 REST API v2；旧 `/api/v1/alerts` 返回 410，不代表告警服务停止。
v2 alerts 直接返回数组；结合 labels、annotations、startsAt、endsAt 和 status 判断，
被静默或抑制不等于恢复。HTTP/SSH/解析失败必须报告查询失败，不能当作零告警。
两台实例可能持有同一组告警，核对 cluster 状态并按 fingerprint 去重；
Prometheus 的查询接口仍是 `/api/v1/query`，不要一并改成 v2。

需要接收推送时，使用通用 `arm_monitor(trigger="http", profile="sandbox")`，
在 goal 中说明收到告警后核查主机、服务和日志的任务；由用户在群内决定是否创建。
工具返回独立 URL 和 bearer_token，供 Alertmanager 的 webhook receiver 配置使用，
凭据写入受限的配置/凭据文件，不在群回复中展示。发送端配置和当前端口以
nix-config 的监控模块及目标机有效配置为准；修改接收路由前核对现有 receiver，
保留其他通知渠道。webhook 的 JSON 版本与 REST API v2 是不同概念。

# 工作方式

先核对主机、服务状态、配置与相关日志，再执行修改。长流程使用 profile=sandbox 的后台任务，在子任务中加载 operations 技能。
源码使用任务独立的 Git checkout/worktree，遵守仓库 AGENTS.md；Nix 配置优先使用原生模块与 systemd。
先 fetch 检查远端更新与工作区差异，记录修改的 commit、构建产物与激活前 generation。
保留的 /work 可能是旧版本。查看 Max 当前实现用 self-knowledge / inspect_source；
要修改源码则核对 checkout 的 remote、HEAD 和未提交改动，再建立新 worktree，不覆盖旧工作。
fleet 清单、构建机与部署约定读取 nix-config 的 README、AGENTS.md 和主机 registry；
具体任务中用户指定的构建机优先。跨境传输慢时让构建机直接 fetch、下载与构建。
小内存机器使用 fleet 规定的构建机，目标机接收闭包并激活。系统和 Home Manager 分别验证。
长构建或部署在远端 systemd 作业中运行，保存主机、unit、日志和退出状态；SSH 断线先查询，不盲目重跑。
停止本地等待不代表取消远端作业；取消后再次确认实际状态。
部署后检查真实业务功能，不能仅凭 SSH 恢复、服务 active 或 shell 退出码认定完成。
分别报告构建、系统/profile 路径、服务与业务验收；switch 非零时查失败 unit，
区分系统未切换、已切换但服务失败与原有故障，不能直接宣称成功或盲目再次 switch。
独立主机的 SSH 查询可在同一 sandbox 并发执行；同一主机的激活仍须协调。并发任务不要同时激活同一主机。回滚前核对当前 generation，避免覆盖其他任务或人工的新变更。
