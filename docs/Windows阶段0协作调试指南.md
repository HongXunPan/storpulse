# Windows 阶段 0 协作调试指南

## 1. 这份产物能做什么

GitHub Actions 会构建一个无需安装 Rust、Visual Studio 或 .NET 的 Windows x64 原生诊断包。它用于在真实 Windows 上验证：

- 标准用户或“性能日志用户”组成员能否启动和消费系统 ETW DiskIo 会话；
- 管理员权限是否改变 ETW 可用性；
- DiskIo 读写事件能否通过线程事件归因到 PID；
- `GetProcessIoCounters` 的广义进程 I/O 覆盖率和受限比例；
- 顺序读写、小文件和短命进程负载能否产生可解释的诊断证据；
- 探针自身 CPU、内存和广义 I/O 增量是否可接受。

它不是 StorPulse Windows 应用，也不能证明 Windows 阶段 0 已通过。GitHub 托管 runner 只完成编译、测试、结构化日志冒烟和打包；Windows 10/11 的权限、ETW 与真实负载仍需实机协作者验证。

## 2. 协作机器要求

首轮候选环境：

- Windows 10 22H2 x64，系统内部版本建议为 19045；
- 至少 1 GB 可用磁盘空间；
- 能主动运行一次标准用户诊断；
- 若协作者同意，再主动运行一次管理员诊断并接受 UAC；
- 测试期间暂时关闭会大量读写磁盘的个人任务，避免污染结果。

Windows Server、早期 Windows 10 和 Windows 11 也可以返回探索性日志，但不能互相替代最终平台门禁。Windows 11 正式门禁必须在真实 Windows 11 标准用户环境单独完成。

## 3. 下载和完整性

1. 在 GitHub Actions 的“Windows 阶段 0 诊断包”运行中下载名称以 `storpulse-windows-stage0-x64-` 开头的 artifact。
2. 解压 ZIP；不要直接在压缩包预览器中运行。
3. 保留以下文件在同一目录：
   - `storpulse-windows-probe.exe`
   - `package-manifest.json`
   - `SHA256SUMS.txt`
   - `scripts/collect.ps1`、`scripts/collect-environment.ps1`、`scripts/invoke-probe.ps1` 与 `scripts/launch-admin.ps1`
   - 三个中文 `.cmd` 入口
4. 诊断脚本会在运行前比较 EXE 的 SHA-256；不匹配时不会启动探针。

当前诊断包未做发行签名，Windows SmartScreen 可能提示未知发布者。只应从项目对应 GitHub Actions 运行下载，不应从聊天附件或第三方网盘转发；正式签名不属于本阶段。

## 4. 非管理员诊断

### 4.1 标准用户

1. 确认当前命令窗口或文件管理器不是以管理员身份运行。
2. 双击 `收集标准用户日志.cmd`。
   不要直接双击 `storpulse-windows-probe.exe`；EXE 需要由采集脚本传入输出目录并完成哈希、权限和环境校验。
3. 等待约 15–30 秒；期间会创建并删除约 64 MiB 顺序文件、使用按扇区对齐且绕过 Windows 系统文件缓存的方式读取该文件、创建 500 个小文件，并启动 40 个探针子进程分别执行 1 MiB 不缓存读取。
4. 看到完成提示后按回车退出。
5. 在 `diagnostics` 目录找到最新的 `storpulse-diagnostics-*.zip`。

标准用户结果是产品默认权限边界的首要证据。即使 ETW 被拒绝，脚本也会保留环境、Win32 错误码和受限进程计数，因此不要只发截图。

### 4.2 性能日志用户

仅在标准用户结果稳定显示 `StartTraceW=5` 后执行这个可选对照；不要为了首轮测试预先改组成员：

1. 由机器管理员把专用测试账户手工加入 Windows 内置“性能日志用户”（`S-1-5-32-559`）组；诊断包不会自动修改账户或本地组。
2. 测试账户注销并重新登录，使新的组令牌生效；保持当前命令窗口和文件管理器不是管理员身份。
3. 双击 `收集性能日志用户日志.cmd`，返回新生成的 ZIP。

该入口会同时验证“非管理员”和“性能日志用户组成员”两个条件，不能用管理员窗口代替。它用于判断最小权限组是否足以启用 ETW，不代表 StorPulse 会在安装时自动改组或要求该权限。

## 5. 管理员对照诊断

仅在协作者明确同意权限提升后执行：

1. 双击 `收集管理员日志.cmd`。
2. 核对 UAC 请求来自 `powershell.exe`，然后选择允许。
3. 等待完成，并返回新生成的第二个 ZIP。

管理员结果只用于解释标准用户失败是否为权限差异，不会把管理员权限改成默认产品要求。不要只运行管理员版本。

## 6. 需要返回什么

至少返回标准用户和管理员两个 ZIP；若执行了性能日志用户对照，再返回第三个 ZIP，并标注每个权限模式：

- `storpulse-diagnostics-<时间>-<随机标识>.zip`
- 同一台协作机器上其余已执行权限模式各自生成的 ZIP

如果脚本显示失败，也要返回 ZIP。采集器会从初始化阶段开始记录脱敏失败阶段、异常类型和 HRESULT；失败包仍会包含 `collector-result.json`、`environment.json`、`console.log`，以及探针成功写出时的报告。异常消息、用户名、命令行和本机路径不会写入失败日志。

如果 `diagnostics` 下只出现空目录而没有 JSON、日志或 ZIP，说明成品包采集入口没有通过最低日志门禁；不要改为直接运行 EXE，应返回该现象并换用修复后的新产物。

不需要返回：整个解压目录、EXE、PDB、Windows 事件日志、ETL、截图或手工抄写的系统信息。

## 7. ZIP 内容和判读顺序

| 文件 | 用途 |
| --- | --- |
| `collector-result.json` | 权限入口、哈希、探针退出码、诊断流程状态、ETW 能力结果、失败阶段、异常类型和 HRESULT |
| `environment.json` | Windows 产品、版本、内部版本、架构、权限与包 commit |
| `summary.json` | ETW、进程覆盖、自身开销、负载和限制的主报告 |
| `errors.json` | 原生 API 阶段、API 名、错误码和稳定分类 |
| `timeline.ndjson` | 从启动到报告写出的相对时间线 |
| `workload.json` | 三类测试负载是否完整、顺序读取模式、逻辑/物理扇区大小及是否清理成功 |
| `console.log` | 探针最小控制台输出，不包含调用参数 |

开发者收到日志后按以下顺序判断：

1. `hashMatches`、`modeMatches` 和 `probeExitCode` 是否正常；`status=completed` 只表示诊断流程完成，不能代替 `probeOutcome` 和 ETW 能力判断；
2. Windows 版本、x64、管理员身份与性能日志用户组成员身份是否符合本轮目标；
3. `sessionStarted`、`consumerStarted` 和 `errors.json` 是否显示权限或会话冲突；
4. `eventsLost`、`unmappedDiskEvents`、`shortPayloadEvents` 是否影响可信度；
5. 三类负载是否完成，`sequentialReadMode` 是否为 `windows_unbuffered_file`，40 个短命子进程的启动、结束和读取归因是否全部匹配；
6. 标准用户、性能日志用户与管理员之间的差异能否稳定复现；
7. 自身空闲写入、CPU、内存是否触发停止条件。

## 8. 隐私、清理与门禁边界

诊断包默认不采集或持久化：

- 用户名和账户 SID；
- 进程名称、完整路径和命令行；
- 文件路径、文件内容和原始 ETL；
- 设备序列号、网络信息或其他 Windows 事件日志。

报告只保留 PID、聚合计数、Windows 版本、权限布尔值、错误码和相对时间。PID 只用于同一次短时诊断，不作为稳定身份。

负载目录正常情况下会在探针结束时删除，采集脚本还会再执行一次兜底清理。协作者确认 ZIP 已返回后，可以删除整个解压目录和 `diagnostics` 目录。

当前门禁边界：

- Windows 10 22H2 结果：可判断候选兼容性与权限差异，不等于 Windows 11 正式门禁。
- Windows Server / GitHub runner 结果：只证明自动构建与日志结构，不证明桌面系统行为。
- `GetProcessIoCounters`：始终标记为广义进程 I/O，不作为磁盘专属归因。
- 不缓存读取：只绕过 Windows 系统文件缓存，不声称绕过硬件缓存；访问大小和缓冲区必须分别满足逻辑与物理扇区对齐要求。
- ETW DiskIo：如果标准权限无法稳定取得、丢失率过高或线程归因无法解释，应停止 Windows“磁盘进程归因”实现并重新确认产品口径。
