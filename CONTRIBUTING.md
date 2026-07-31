# StorPulse 贡献指南

## 开发前提

- macOS 阶段 0：macOS 14 或更高版本、Xcode 26.5 当前 SDK。
- Rust：由 `rust-toolchain.toml` 固定；当前环境可通过 `rustup run` 调用。
- Windows 与其他 macOS 架构当前不属于已验证范围。

## 最小验证

```bash
bash scripts/validate.sh
```

阶段 0 macOS 实机校验：

```bash
bash scripts/validate_stage0_macos.sh
```

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

## 禁止事项

- 未经明确指令不运行 build、archive、签名、打包或发布；`debug_macos.sh` 的本机 Debug 签名是用户明确授权的例外。
- 不提交 `.codex-tmp/`、`.build/`、`target/`、DerivedData、数据库或原始诊断。
- 不把广义进程 I/O、设备总量或文件事件统一标成真实磁盘写入。
