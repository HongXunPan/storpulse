import SwiftUI

public struct StatusPopoverView: View {
    @ObservedObject private var monitor: RealtimeMonitor
    private let openDashboard: @MainActor () -> Void
    private let quitApplication: @MainActor () -> Void

    public init(
        monitor: RealtimeMonitor,
        openDashboard: @escaping @MainActor () -> Void,
        quitApplication: @escaping @MainActor () -> Void
    ) {
        self.monitor = monitor
        self.openDashboard = openDashboard
        self.quitApplication = quitApplication
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            deviceRate
            topApplications
            coverage
            Divider()
            actionBar
        }
        .padding(16)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("StorPulse")
                    .font(.headline)
                Text("本地只读磁盘 I/O 观察")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TrustBadge(
                state: monitor.samplingState,
                completeness: monitor.snapshot?.completeness
            )
        }
    }

    private var deviceRate: some View {
        HStack(spacing: 24) {
            rateMetric(
                title: "设备读取",
                symbol: "arrow.down.circle.fill",
                value: trustedDeviceRate?.readBytesPerSecond
            )
            rateMetric(
                title: "设备写入",
                symbol: "arrow.up.circle.fill",
                value: trustedDeviceRate?.writeBytesPerSecond
            )
        }
    }

    private var topApplications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前主要应用")
                .font(.subheadline.weight(.semibold))
            if topApplicationsValue.isEmpty {
                Text(monitor.snapshot == nil ? "等待第二个采样点" : "当前没有持续 I/O")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                ForEach(topApplicationsValue.prefix(4)) { application in
                    HStack {
                        Text(application.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(IOPresentation.rate(application.current.map {
                            $0.readBytesPerSecond + $0.writeBytesPerSecond
                        }))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var coverage: some View {
        Group {
            if let summary = monitor.snapshot?.summary {
                Text(
                    "可读 \(summary.readableProcesses) / 已发现 \(summary.discoveredProcesses)；受限 \(summary.restrictedProcesses)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "进程覆盖：可读 \(summary.readableProcesses)，已发现 \(summary.discoveredProcesses)，受限 \(summary.restrictedProcesses)"
                )
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("打开详细视图") { openDashboard() }
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
            Button("退出") { quitApplication() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.large)
    }

    private var trustedDeviceRate: IORate? {
        monitor.ratesAreTrustworthy ? monitor.snapshot?.deviceRate : nil
    }

    private var topApplicationsValue: [RealtimeApplication] {
        guard monitor.ratesAreTrustworthy else { return [] }
        return IOPresentation.sorted(monitor.snapshot?.applications ?? [], by: .current)
            .filter { $0.current != nil }
    }

    private func rateMetric(title: String, symbol: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(IOPresentation.rate(value))
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
