import SwiftUI

struct ApplicationRowView: View {
    let application: RealtimeApplication
    let ratesAreTrustworthy: Bool
    let showProcesses: () -> Void

    var body: some View {
        RealtimeApplicationColumns {
            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .help(application.displayName)
                Button(action: showProcesses) {
                    Label(
                        processSummary,
                        systemImage: "list.bullet.rectangle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(application.processCount == 0)
                .help("在下方查看 \(application.displayName) 的进程详情")
                .accessibilityLabel(
                    "查看 \(application.displayName) 的 \(application.processCount) 个进程"
                )
            }
        } currentRate: {
            RealtimeRatePairView(
                title: "当前",
                rate: trusted(application.current)
            )
        } recentAverage: {
            RealtimeRatePairView(
                title: "一分钟",
                rate: application.averageLastMinute
            )
        } runTotal: {
            RealtimeTotalPairView(
                readBytes: application.runReadBytes,
                writeBytes: application.runWriteBytes
            )
        } trailing: {
            Text(IOPresentation.duration(
                milliseconds: application.continuousIODurationMilliseconds
            ))
            .font(.caption.monospacedDigit())
            .lineLimit(1)
            .help(
                "持续 \(IOPresentation.duration(milliseconds: application.continuousIODurationMilliseconds))"
            )
        }
        .padding(.vertical, 7)
    }

    private var processSummary: String {
        if application.helperCount == 0 {
            return "\(application.processCount) 个进程"
        }
        return "\(application.processCount) 个进程 · \(application.helperCount) 个 Helper"
    }

    private func trusted(_ rate: IORate?) -> IORate? {
        ratesAreTrustworthy ? rate : nil
    }
}
