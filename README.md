# StorPulse

StorPulse 是面向 macOS、Windows 和后续 Linux 的本地只读磁盘 I/O 观察器，帮助用户回答“现在谁在持续读写、持续多久、累计多少”。

## 当前状态

- 当前阶段：macOS Intel 开发者预览阶段 3；Windows 阶段 0 协作诊断实现待实机验证。
- 当前能力：macOS 采集、Rust 共享内核、状态栏与实时详细视图，以及默认关闭的低写入历史、显式提醒和隐私摘要导出。
- 未验证：Windows 实机门禁、Apple Silicon、旧版 macOS、App Sandbox、签名、安装包和长期运行。
- 不承诺：文件级精确归因、SSD 剩余寿命、NAND 写放大或自动干预其他应用。

## 隐私与权限

- 默认只使用标准用户权限。
- 文件路径、命令行参数、用户名和文件内容不进入共享内核、数据库或公开导出。
- 不可读取或指标过期会显示受限或未知，不会被写成零值。

## 开发入口

开发环境、验证命令和停机条件见[工程代码技术选型](docs/工程代码技术选型.md)、[共享内核契约](docs/共享内核契约.md)、[macOS 实时纵切](docs/macOS实时纵切.md)、[低写入历史与导出](docs/低写入历史与导出.md)、[Windows 阶段 0 协作调试指南](docs/Windows阶段0协作调试指南.md)与[贡献指南](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)
