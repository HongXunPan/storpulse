# Windows 持续采集实机验证指南

## 1. 验证范围

本指南用于在 Windows 10 22H2 x64 上验证 StorPulse 产品服务的持续协议、真实 ETW 聚合、普通用户启动、正常停止、客户端断开、连接超时和客户端强杀清理。它是 Windows 阶段 1 实机门禁，不等于 Windows 11、休眠恢复、WinUI、签名安装、长期运行或正式发布已经通过。

测试包由 GitHub Actions 构建；本机不需要 Rust、Visual Studio、.NET 或“性能日志用户”组。安装和卸载会请求 UAC，两个采集入口必须保持普通用户权限。

## 2. 操作步骤

1. 从成功的 GitHub Actions `Windows 开发者预览服务` 中下载名称以 `storpulse-windows-stage1-x64-` 开头的 artifact，完整解压到普通目录。
2. 双击 `安装 StorPulse 按需服务.cmd`，允许一次 UAC。看到绿色安装成功和外层窗口的 `exit_code=0` 后再关闭窗口。
3. 确认文件管理器或当前终端没有“以管理员身份运行”，然后双击 `验证持续采集.cmd`。窗口会保持打开，完成后生成：

   ```text
   diagnostics\storpulse-diagnostics-windows-stage1-continuous-validation-*.zip
   ```

4. 双击 `收集断连清理.cmd`。它会在服务报告就绪后主动断开客户端并等待服务退出，生成：

   ```text
   diagnostics\storpulse-diagnostics-windows-stage1-disconnect-cleanup-*.zip
   ```

5. 双击 `验证连接超时清理.cmd`。服务会在无人连接时等待约 30 秒并自行退出，生成：

   ```text
   diagnostics\storpulse-diagnostics-windows-stage1-connect-timeout-cleanup-*.zip
   ```

6. 双击 `验证客户端强杀清理.cmd`。测试客户端会在 ETW 启动后立即硬终止，脚本等待服务清理，再自动执行一次 5 秒恢复采集，生成：

   ```text
   diagnostics\storpulse-diagnostics-windows-stage1-client-termination-cleanup-*.zip
   ```

7. 把四个 ZIP 放到约定的反馈目录或在 `反馈问题.url` 打开的 GitHub Issues 页面中自行上传。浏览器不会自动读取或上传文件。
8. 双击 `卸载 StorPulse 按需服务.cmd`，允许 UAC；看到绿色清理成功和 `exit_code=0` 后再删除解压目录。

若任一步显示 `exit_code=1`，不要手工启动 EXE、覆盖安装、修改服务权限或反复运行。保留窗口输出和已经生成的阶段化 ZIP，直接反馈。

## 3. 结果判读

持续采集 ZIP 的 `summary.json` 至少应满足：

- `status=completed`、`protocolCompleted=true`、`serviceStopped=true`；
- `clientElevated=false`，服务名为 `StorPulseCollector`；
- 至少 3 个连续快照，最终停止序号与客户端接收序号闭环；
- 32 MiB 不缓存读取负载完成并清理；
- 能观察到客户端进程和设备读取累计量；
- `unmappedDiskEvents`、`eventsLost`、`buffersLost` 均为 0。

受保护进程会使快照标记为 `partial`；包会记录 `maxRestrictedProcesses`，但不会要求该值为 0，也不会用零值补齐不可读进程。

断连清理 ZIP 至少应满足 `status=completed`、`disconnectCleanupConfirmed=true`、`serviceStopped=true`。任一结果为 `restricted` 或 `failed` 都只表示当前环境未通过；不要用管理员直跑或其他 Windows 版本结果替代。

连接超时 ZIP 至少应满足：

- `status=completed`、`connectTimeoutConfirmed=true`、`serviceStopped=true`；
- `serviceWin32ExitCode=1066`、`serviceSpecificExitCode=1460`；
- 没有启动负载或生成快照。

客户端强杀 ZIP 至少应满足：

- `status=completed`、`clientTerminationCleanupConfirmed=true`、`serviceStopped=true`；
- 初始客户端以固定测试退出码 `197` 结束，且没有伪造正常协议闭环；
- `recovery.status=completed`、`recovery.protocolCompleted=true`、`recovery.serviceStopped=true`；
- 恢复采集至少生成 3 个快照，且 `eventsLost`、`buffersLost` 均为 0。

强杀入口故意终止测试客户端，但不终止桌面、PowerShell 或其他进程；恢复采集失败时不要手工重启服务或继续叠加测试。

## 4. 隐私与反馈边界

诊断 ZIP 只包含 `manifest.json`、`capabilities.json`、`summary.json`、`errors.json`、`privacy-check.json` 和 `console.log`。导出前后都会扫描用户名、账户 SID、用户目录、命令行、路径字段、nonce 和令牌；扫描失败时不会保留可提交 ZIP。

ZIP 不包含 EXE、PDB、历史数据库、原始 ETL、崩溃转储、文件内容或自动上传配置。反馈入口只打开公开 GitHub Issues，是否上传以及上传哪个 ZIP 由用户决定。
