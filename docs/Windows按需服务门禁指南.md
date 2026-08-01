# Windows 按需服务门禁指南

## 1. 目标与边界

这是一条只面向 Windows 10 22H2 x64 的最小候选门禁，用于验证“普通用户客户端按需启动 LocalSystem 服务，由服务采集 ETW DiskIo，再把聚合结果返回客户端”是否可行。该门禁已于 2026-08-01 通过；它不改变标准用户 `StartTraceW=5` 的失败结论，也不表示 Windows 阶段 1–3、Windows 11、正式安装或正式发布已经放行。产品化持续协议与日志边界见[Windows 持续采集与诊断契约](Windows持续采集与诊断契约.md)。

本轮只回答四个问题：

1. 普通用户能否在不提升客户端权限的情况下启动预先安装的手动服务；
2. 服务是否确实以 LocalSystem 运行，并能启动和消费固定名称的系统 ETW 会话；
3. 服务能否只接受发起启动的本地普通用户客户端，并完成 40 个短命进程的磁盘读取归因；
4. 正常完成或客户端异常断开后，服务与 ETW 会话能否自动停止。

当前不验证休眠恢复、强杀服务进程、多用户并发、长期运行、服务权限裁剪、签名、升级和正式卸载体验。这些仍是候选路线进入产品实现前的后续门禁。

## 2. 最小实现

- 一个 EXE 同时承载普通诊断客户端和 `--service` 服务入口，不增加第三方运行依赖。
- 服务名固定为 `StorPulseStage0Collector`，安装到 `%ProgramFiles%\StorPulse\Stage0ServiceProbe`，运行身份为 LocalSystem，启动类型为手动；不会开机自启。
- 安装和卸载才请求 UAC；日常采集入口必须由非管理员用户运行。
- 普通用户只有启动和查询服务状态的权限，没有停止、修改或删除服务的权限。
- IPC 使用固定本地命名管道，拒绝远程客户端，只开放单实例；服务核对一次性随机数、命名管道客户端 PID 和客户端非提升状态。
- 服务不接收输出目录、文件路径、命令行、Provider 或任意写文件参数。测试负载和诊断 ZIP 由普通用户客户端创建，服务只返回 PID 与聚合计数。
- 服务完成、协议失败、管道断开、超时、停止或关机时都会停止自身 ETW 会话；ETW 会话对象另有析构兜底。

## 3. 你需要怎么配合

只需要一台 Windows 10 22H2 x64 电脑，不需要安装 Rust、Visual Studio、.NET，也不需要修改“性能日志用户”组。

1. 从 GitHub Actions 下载名称以 `storpulse-windows-stage0-x64-` 开头的 artifact，解压后不要移动内部文件。
2. 双击 `安装按需服务门禁.cmd`；若系统显示 UAC，则允许一次。该步骤只复制经过包内 SHA-256 校验的探针并创建手动服务。
3. 提升窗口会保留安装结果。只有看到绿色“已安装”后才按回车关闭；原 CMD 显示 `exit_code=0` 后再按任意键退出。随后确认文件管理器和当前终端没有“以管理员身份运行”。
4. **先**双击 `验证异常断开清理.cmd`，等待生成 `storpulse-diagnostics-service-disconnect-validation-*.zip`。该入口在服务报告就绪后主动断开客户端。
5. **再**双击 `收集按需服务门禁日志.cmd`，等待约 15–30 秒并生成 `storpulse-diagnostics-service-collection-*.zip`。第二次仍能启动同名 ETW 会话，才可间接证明上一步没有遗留会话。
6. 双击 `卸载按需服务门禁.cmd`，若系统显示 UAC 则允许；看到绿色清理成功和 `exit_code=0` 后再删除解压目录。
7. 把两个 ZIP 返回；文件名已自动标注“异常断开验证”和“正常采集”，无需手工改名。不要发送 EXE、PDB、整个解压目录、截图或 Windows 事件日志。

如果安装或卸载显示红色失败或 `exit_code=1`，不要手工运行 EXE、不要修改服务权限，也不要重复覆盖。保留窗口中的完整错误和已生成的 ZIP，然后停止。

## 4. 最小通过条件

异常断开 ZIP 至少应满足：

- `collector-result.json` 的 `actualAdministrator=false`、`modeMatches=true`；
- `summary.json` 的 `service.serviceLocalSystem=true`、`service.clientProcessIdMatched=true`、`service.clientElevated=false`、`service.clientAuthenticated=true`；
- `service.pipeRejectRemoteClients=true`、`service.disconnectCleanupTest=true`、`service.serviceStopped=true`。

随后生成的正常采集 ZIP 至少应满足：

- 服务身份与客户端认证字段继续全部满足；
- `sessionStarted=true`、`consumerStarted=true`、`eventsLost=0`、`logBuffersLost=0`、`realtimeBuffersLost=0`；
- 40 个短命进程的身份、启动、结束和读取归因全部匹配，读取合计不少于 40 MiB，且未检测到 PID 重用；
- `serviceStopped=true`，探针负载完成且临时负载已清理；
- `service.serviceSelfMeasurements.idleWriteDeltaBytes=0`；服务自身其余开销只作为本轮基线记录，不制造未确认阈值；
- 报告中没有用户名、账户 SID、进程名、完整路径、命令行、文件内容或原始 ETL。

任一条件不满足都只算“候选门禁失败或证据不足”，不能用管理员直跑结果替代。

## 5. 风险与后续门禁

当前产物未签名，而且安装脚本和服务二进制来自解压目录，因此只应使用项目 GitHub Actions 生成的对应 commit artifact。LocalSystem 权限高于产品默认边界；即使本门禁通过，也必须继续完成服务所需权限裁剪、休眠恢复、强杀与超时清理、多用户隔离、长期自身 I/O、签名安装和卸载残留验证，之后才能决定是否采用该服务形态。

若普通用户无法启动服务、服务无法稳定停止、固定 ETW 会话发生冲突、IPC 身份校验不稳定、采样开销过高或报告口径无法解释，应停止该路线并重新确认 Windows 产品范围。
