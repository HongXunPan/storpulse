# StorPulse 贡献指南

## 开发前提

- macOS 阶段 0：macOS 14 或更高版本、Xcode 26.5 当前 SDK。
- Rust：由 `rust-toolchain.toml` 固定；当前环境可通过 `rustup run` 调用。
- Windows 自动构建：GitHub Actions `windows-2025` runner，只证明 Windows x64 编译、测试、脚本结构和打包。
- Windows 实机：Windows 10 22H2 x64 已完成持续采集、异常清理、传统待机（S3）恢复和服务后备记录门禁；桌面诊断、WinUI、长期运行与 Windows 11 仍需分别验证。

## 最小验证

```bash
bash scripts/validate.sh
```

阶段 0 macOS 实机校验：

```bash
bash scripts/validate_stage0_macos.sh
```

Windows runner 校验：

```powershell
./scripts/validate_stage0_windows.ps1
```

WinUI 3 阶段 2A 壳层由 GitHub Actions 使用固定 .NET SDK 和 NuGet 版本发布为自包含 x64 artifact；macOS 本机不替代 Windows XAML 构建，也不尝试启动该产物。实机操作见[Windows WinUI 最小壳层实机指南](docs/WindowsWinUI最小壳层实机指南.md)。

阶段 0 成品包生成后，Actions 会用 Windows PowerShell 5.1 执行 `scripts/validate_stage0_windows_package.ps1`。阶段 1 持续采集包由 `scripts/validate_windows_preview_package.ps1` 检查服务权限、二进制哈希、UTF-8 BOM、标准用户采集入口、服务后备记录合成回归、阶段化 ZIP 与显式反馈渠道；CI 不以管理员 runner 冒充标准用户实机协议闭环。

Windows 协作者只使用 Actions 产物，不需要安装开发环境；阶段 0 操作见[Windows 阶段 0 协作调试指南](docs/Windows阶段0协作调试指南.md)，阶段 1 操作见[Windows 持续采集实机验证指南](docs/Windows持续采集实机验证指南.md)。

脚本会把缓存、测试负载和报告放在 `.codex-tmp/`，完成后清理负载文件。报告包含宿主环境和聚合指标，不包含文件路径、命令行或用户名。

## macOS Debug 启动

当前 macOS Intel 开发者预览由 SwiftPM 编译后组装为独立 Debug `.app`。默认使用本机 Apple Development 身份签名，固定 Bundle ID 为 `com.HongXunPan.StorPulse.Debug`。

首次启动前，在仓库根目录创建不会提交到 Git 的 `Config.local.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = 你的 Apple Developer Team ID
```

如果钥匙串内存在多个 Apple Development 身份，再追加 `CODE_SIGN_IDENTITY = Apple Development: 证书名称`；只有一个时不需要填写。

然后执行：

```bash
bash scripts/debug_macos.sh
```

需要进入 LLDB 时使用 `bash scripts/debug_macos.sh --lldb`。没有开发证书时可显式传入 `--adhoc`，脚本不会静默改变签名身份；切换签名方式可能导致系统通知权限需要重新授权。

脚本只把编译产物、模块缓存和 Debug 应用写入 `.codex-tmp/debug-macos/`；传入 `--clean` 可在启动前清理该目录，传入 `--prepare-only` 可只组装不启动。Development 签名只用于本机 Debug 身份和系统能力验证，不代表签名发行门禁已通过；脚本不执行 archive、发布签名、发布打包、公证或发布。

## 验证层级

- 单元测试：证明数据模型、编码和错误状态稳定。
- 集成测试：证明 macOS 公共 API 可在当前宿主环境读取。
- 阶段 0 证据：证明当前 macOS 26.5 Intel 环境的方向、累计量、受限范围和自身开销；不等于 Apple Silicon、旧系统或签名发行已通过。
- Windows 自动化：证明固定工具链能校验安全诊断事件与后备记录、产出 x64 服务、标准用户客户端和结构可校验的实机测试包；不替代 Windows 10/11 服务、ETW、日志写入或界面实机门禁。
- Windows 协作诊断：Windows 10 结果只作为候选兼容性证据，不能代替真实 Windows 11 标准用户门禁。

## 禁止事项

- 未经明确指令不运行 build、archive、签名、打包或发布；`debug_macos.sh` 的本机 Debug 签名是用户明确授权的例外。
- 不提交 `.codex-tmp/`、`.build/`、`target/`、DerivedData、数据库或原始诊断。
- 不把广义进程 I/O、设备总量或文件事件统一标成真实磁盘写入。
