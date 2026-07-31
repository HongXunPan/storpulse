import SwiftUI

struct StatusMenuSummaryView: View {
    @ObservedObject private var monitor: RealtimeMonitor

    init(monitor: RealtimeMonitor) {
        self.monitor = monitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
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

            Divider()

            LabeledContent {
                Text(IOPresentation.rate(trustedDeviceRate?.readBytesPerSecond))
                    .monospacedDigit()
            } label: {
                Label("设备读取", systemImage: "arrow.down.circle")
            }

            LabeledContent {
                Text(IOPresentation.rate(trustedDeviceRate?.writeBytesPerSecond))
                    .monospacedDigit()
            } label: {
                Label("设备写入", systemImage: "arrow.up.circle")
            }

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: StatusMenuLayout.contentWidth)
    }

    private var trustedDeviceRate: IORate? {
        monitor.ratesAreTrustworthy ? monitor.snapshot?.deviceRate : nil
    }
}
