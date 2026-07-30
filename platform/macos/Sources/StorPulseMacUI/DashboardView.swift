import SwiftUI

public struct DashboardView: View {
    @ObservedObject private var monitor: RealtimeMonitor
    private let openHistory: @MainActor () -> Void
    @State private var sort: ApplicationSort = .current

    public init(
        monitor: RealtimeMonitor,
        openHistory: @escaping @MainActor () -> Void = {}
    ) {
        self.monitor = monitor
        self.openHistory = openHistory
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summary
            Divider()
            applicationList
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("实时观察")
                    .font(.title2.weight(.semibold))
                TrustBadge(
                    state: monitor.samplingState,
                    completeness: monitor.snapshot?.completeness
                )
            }
            Spacer()
            Button {
                openHistory()
            } label: {
                Label("历史与提醒", systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.large)
            observationButton
            Picker("排序", selection: $sort) {
                ForEach(ApplicationSort.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(18)
    }

    private var summary: some View {
        HStack(spacing: 28) {
            summaryMetric(
                title: "设备读取",
                value: trustedDeviceRate?.readBytesPerSecond,
                symbol: "arrow.down.circle.fill"
            )
            summaryMetric(
                title: "设备写入",
                value: trustedDeviceRate?.writeBytesPerSecond,
                symbol: "arrow.up.circle.fill"
            )
            if let session = monitor.snapshot?.activeObservationSession {
                VStack(alignment: .leading, spacing: 4) {
                    Text("观察会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(IOPresentation.duration(milliseconds: session.durationMilliseconds))
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                    Text(
                        "读 \(IOPresentation.bytes(session.readBytes)) · 写 \(IOPresentation.bytes(session.writeBytes))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let message = monitor.lastErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var applicationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sortedApplications) { application in
                    ApplicationRowView(
                        application: application,
                        processes: processes(for: application),
                        ratesAreTrustworthy: monitor.ratesAreTrustworthy
                    )
                    .padding(.horizontal, 18)
                    Divider()
                }
            }
        }
        .overlay {
            if monitor.snapshot == nil {
                ContentUnavailableView(
                    "等待采样",
                    systemImage: "waveform.path.ecg",
                    description: Text("至少需要两个采样点才能计算实时速度。")
                )
            } else if sortedApplications.isEmpty {
                ContentUnavailableView(
                    "没有可显示的应用",
                    systemImage: "externaldrive",
                    description: Text("当前采样可能受限或暂时没有进程 I/O。")
                )
            }
        }
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
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var trustedDeviceRate: IORate? {
        monitor.ratesAreTrustworthy ? monitor.snapshot?.deviceRate : nil
    }

    private var sortedApplications: [RealtimeApplication] {
        IOPresentation.sorted(monitor.snapshot?.applications ?? [], by: sort)
    }

    private func processes(for application: RealtimeApplication) -> [RealtimeProcess] {
        let identities = Set(application.processIdentities)
        return (monitor.snapshot?.processes ?? [])
            .filter { identities.contains($0.identity) }
            .sorted { lhs, rhs in
                if lhs.isHelper != rhs.isHelper { return !lhs.isHelper }
                return lhs.executableName.localizedStandardCompare(rhs.executableName)
                    == .orderedAscending
            }
    }

    private func summaryMetric(title: String, value: Double?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(IOPresentation.rate(value))
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .contentTransition(.numericText())
        }
        .frame(width: 190, alignment: .leading)
    }
}
