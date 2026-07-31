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
            applicationList
        }
        .frame(minWidth: 700, minHeight: 520)
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
            }
        }
    }

    private var summary: some View {
        GroupBox {
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("数据状态")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TrustBadge(
                        state: monitor.samplingState,
                        completeness: monitor.snapshot?.completeness
                    )
                }
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
                if let session = monitor.snapshot?.activeObservationSession {
                    VStack(alignment: .leading, spacing: 4) {
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
                    }
                }
                Spacer()
                if let message = monitor.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }
        }
        .padding([.top, .horizontal])
    }

    private var applicationList: some View {
        List(sortedApplications) { application in
            ApplicationRowView(
                application: application,
                processes: processes(for: application),
                ratesAreTrustworthy: monitor.ratesAreTrustworthy
            )
            .listRowInsets(
                EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
            )
        }
        .listStyle(.inset)
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
                .font(.headline.monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(width: 170, alignment: .leading)
    }
}
