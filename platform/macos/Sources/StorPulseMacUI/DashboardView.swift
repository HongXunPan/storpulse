import SwiftUI

public struct DashboardView: View {
    @ObservedObject private var monitor: RealtimeMonitor
    @State private var sort: ApplicationSort = .current

    public init(monitor: RealtimeMonitor) {
        self.monitor = monitor
    }

    public var body: some View {
        VStack(spacing: 0) {
            summary
            RealtimeApplicationWorkspaceView(
                applications: sortedApplications,
                processes: monitor.snapshot?.processes ?? [],
                ratesAreTrustworthy: monitor.ratesAreTrustworthy,
                hasSnapshot: monitor.snapshot != nil
            )
        }
        .frame(
            minWidth: RealtimeApplicationLayout.minimumDetailWidth,
            minHeight: 520
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                observationButton
                Picker("排序", selection: $sort) {
                    ForEach(ApplicationSort.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .help("应用排序方式")
            }
        }
    }

    private var summary: some View {
        GroupBox {
            ViewThatFits(in: .horizontal) {
                wideSummary
                compactSummary
            }
        }
        .padding(.horizontal, RealtimeApplicationLayout.horizontalInset)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var wideSummary: some View {
        HStack(spacing: 16) {
            statusSummary
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            summaryDivider
            summaryMetric(
                title: "设备读取",
                value: trustedDeviceRate?.readBytesPerSecond,
                symbol: "arrow.down.circle"
            )
            summaryDivider
            summaryMetric(
                title: "设备写入",
                value: trustedDeviceRate?.writeBytesPerSecond,
                symbol: "arrow.up.circle"
            )
            if monitor.snapshot?.activeObservationSession != nil {
                summaryDivider
                observationSummary
            }
            if monitor.lastErrorMessage != nil {
                errorSummary
            }
        }
        .padding(.vertical, 2)
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusSummary
            HStack(spacing: 20) {
                summaryMetric(
                    title: "设备读取",
                    value: trustedDeviceRate?.readBytesPerSecond,
                    symbol: "arrow.down.circle"
                )
                summaryMetric(
                    title: "设备写入",
                    value: trustedDeviceRate?.writeBytesPerSecond,
                    symbol: "arrow.up.circle"
                )
                Spacer()
            }
            if monitor.snapshot?.activeObservationSession != nil {
                observationSummary
            }
            if monitor.lastErrorMessage != nil {
                errorSummary
            }
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("数据状态")
                .font(.caption)
                .foregroundStyle(.secondary)
            TrustBadge(
                state: monitor.samplingState,
                completeness: monitor.snapshot?.completeness
            )
        }
    }

    @ViewBuilder
    private var observationSummary: some View {
        if let session = monitor.snapshot?.activeObservationSession {
            VStack(alignment: .leading, spacing: 3) {
                Text("观察会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(IOPresentation.duration(milliseconds: session.durationMilliseconds))
                    .font(.headline.monospacedDigit())
                Text(
                    "读 \(IOPresentation.bytes(session.readBytes)) · 写 \(IOPresentation.bytes(session.writeBytes))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var errorSummary: some View {
        if let message = monitor.lastErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .trailing)
                .accessibilityLabel("采样错误：\(message)")
        }
    }

    private var summaryDivider: some View {
        Divider()
            .frame(height: 36)
    }

    private var observationButton: some View {
        Group {
            if monitor.snapshot?.activeObservationSession == nil {
                Button {
                    Task { await monitor.startObservation() }
                } label: {
                    Label("开始观察", systemImage: "record.circle")
                }
            } else {
                Button {
                    Task { await monitor.stopObservation() }
                } label: {
                    Label("停止观察", systemImage: "stop.circle")
                }
            }
        }
        .help(
            monitor.snapshot?.activeObservationSession == nil
                ? "开始记录本次观察会话"
                : "停止并保存本次观察会话摘要"
        )
    }

    private var trustedDeviceRate: IORate? {
        monitor.ratesAreTrustworthy ? monitor.snapshot?.deviceRate : nil
    }

    private var sortedApplications: [RealtimeApplication] {
        IOPresentation.sorted(monitor.snapshot?.applications ?? [], by: sort)
    }

    private func summaryMetric(title: String, value: Double?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(IOPresentation.rate(value))
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(width: 124, alignment: .leading)
    }
}
