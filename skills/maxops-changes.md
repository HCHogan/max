执行 fleet 诊断、受控命令、服务变更、配置工作区和部署；需要写操作时按需加载

本技能依赖 maxops 的授权、回执和证据规则。只加载当前权限内的变更工具，
观察权限不会因加载而升级。先观察并明确目标，再提交操作。

# 诊断与受控命令

重复诊断先 resources_list(kind=diagnostic_probes,host=...) 发现配置好的探针，再用
诊断采集工具 diagnostics_collect(probes=[...]) 一次采集；不要每轮重拼同一套 shell。
每个探针有独立状态与退出结果，job.evidence_status 为 complete/partial/failed；
missing_evidence 列出未完成项。大证据通过 jobs_result(pointer=/diagnostic) 按
next_offset 分页，不能把缺失当健康。
诊断命令使用 diagnostic 普通用户；先读取 execution_profiles 的 path、interpreter、
user、privileged、working_roots，不继承登录 shell。缺命令先报告环境缺项，不要为补
PATH 换 root profile。确需脚本时，先 command -v 检查工具并核对 CLI 参数，保留每项
退出码；不能用管道或 || true 掩盖必要步骤失败。exec_run 回传只证明进程退出，
所属 operations 任务须根据证据判断目标是否完成。

# 服务和部署

服务变更只接受授权的 .service 单元；从 resources_list(kind=units,host=...) 选择。
maxops_deploy_prepare 冻结可复核的变更计划；随后 maxops_deploy_run 用 change_id 和
expected_revision 执行固定流程：until=built 只构建，until=verified 构建、激活并验收。
需要独立控制时仍可使用 build/activate/verify/rollback，各阶段遵守相同前置条件。
工作区和部署使用精确 revision 与冻结计划；发生冲突时先重新判断，不更新前置条件
强行重试。人工 push、手动 rebuild 和其他管理工具可能在任务执行期间改变系统。
取消远端作业要用专用控制入口，不能把停止宿主观察当作取消成功。
