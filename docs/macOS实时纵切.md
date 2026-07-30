# macOS 实时纵切

## 1. 当前范围

阶段 2 提供 macOS Intel 开发者预览的实时观察纵切：

- AppKit 管理 `NSStatusItem`、`NSPopover`、主窗口和退出生命周期。
- SwiftUI 展示设备实时读写、Top 应用、全部应用、进程展开和观察会话。
- Rust 共享引擎负责差值、重置、stale、聚合、一分钟均值、累计量和持续时长。
- Swift 只补充当前运行应用的公开元数据；不会把平台采样规则复制到界面层。

当前不包含数据库、历史、提醒、签名、Sandbox、安装包或发布能力。

## 2. 运行边界

Swift 通过 `StorPulseFFIBridge` 动态装载 Rust `cdylib`，再使用版本化 JSON 批量交换数据。动态库查找顺序为：

1. `STORPULSE_ENGINE_LIBRARY` 显式路径；
2. 仓库 `.codex-tmp/cargo-target/debug/`；
3. 仓库 `.codex-tmp/cargo-target/debug/deps/`。

该路径只用于当前无签名开发者预览。正式应用包的 Frameworks 嵌入、签名和运行时搜索路径留待发行阶段验证。

## 3. 采样与状态

- 默认每秒采集一次；libproc 与 IOKit 在 utility 任务执行，主线程只接收批量结果。
- 第一个样本用于建立累计计数器基线，不伪造实时速度。
- 任一次采样失败后立即停止信任旧速率；连续三次失败显示 stale。
- 受限、部分覆盖和过期分别展示，不把未知数据写成零。
- 关闭主窗口只关闭展示；状态栏和采样继续运行。退出应用才停止采样。

## 4. 应用与进程关系

- Helper 只有在名称明确包含 Helper 且能关联到自身或父应用时才归并。
- 普通子任务不因父 PID 自动并入父应用；界面单独展示“由某应用启动”。
- 展开行保留 PID 与启动时间联合身份，避免 PID 复用串账。
- 文件路径、命令行、用户名和文件内容不进入快照、界面或测试 fixture。

## 5. 界面约束

- 使用系统字体、系统色和 SF Symbols，跟随浅色、深色与辅助功能设置。
- 数值使用等宽数字；速度不可用时显示破折号，不沿用旧值。
- 状态栏提供当前设备速度和主要应用，详细窗口提供排序、进程展开和观察会话。
- 观察会话必须由用户主动开始和停止；本阶段不写入磁盘。

## 6. 验证层级

已通过 Rust 格式、check、test、Clippy，Swift Package 测试，以及 Swift → C 桥 → Rust 的往返测试。当前本机 Xcode 不把裸 Swift Package 目录识别为 project、workspace 或 package，`xcodebuild -list` 因而退出 66；未重复执行同义命令。

上述结果证明源码与跨语言契约可由测试编译并运行，不等于应用已执行正式 build、启动、状态栏交互或人工视觉验收。
