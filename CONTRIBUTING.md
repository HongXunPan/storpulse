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

## 验证层级

- 单元测试：证明数据模型、编码和错误状态稳定。
- 集成测试：证明 macOS 公共 API 可在当前宿主环境读取。
- 阶段 0 证据：证明当前 macOS 26.5 Intel 环境的方向、累计量、受限范围和自身开销；不等于 Apple Silicon、旧系统或签名发行已通过。

## 禁止事项

- 未经明确指令不运行 build、archive、签名、打包或发布。
- 不提交 `.codex-tmp/`、`.build/`、`target/`、DerivedData、数据库或原始诊断。
- 不把广义进程 I/O、设备总量或文件事件统一标成真实磁盘写入。
