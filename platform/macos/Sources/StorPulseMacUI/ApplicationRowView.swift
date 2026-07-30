import SwiftUI

struct ApplicationRowView: View {
    let application: RealtimeApplication
    let processes: [RealtimeProcess]
    let ratesAreTrustworthy: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(processes) { process in
                    processRow(process)
                    if process.id != processes.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.vertical, 4)
        } label: {
            applicationRow
        }
        .accessibilityLabel(
            "\(application.displayName)，\(application.processCount) 个进程，\(application.helperCount) 个辅助进程"
        )
    }

    private var applicationRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(processSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            metricPair(title: "当前", rate: trusted(application.current))
            metricPair(title: "一分钟", rate: application.averageLastMinute)
            VStack(alignment: .trailing, spacing: 2) {
                Text("读 \(IOPresentation.bytes(application.runReadBytes))")
                Text("写 \(IOPresentation.bytes(application.runWriteBytes))")
            }
            .font(.system(.caption, design: .monospaced))
            .frame(width: 130, alignment: .trailing)
            Text(IOPresentation.duration(
                milliseconds: application.continuousIODurationMilliseconds
            ))
            .font(.caption.monospacedDigit())
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func processRow(_ process: RealtimeProcess) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(process.executableName)
                    if process.isHelper {
                        Text("Helper")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(processRelationship(process))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
            metricPair(title: "当前", rate: trusted(process.current))
            metricPair(title: "一分钟", rate: process.averageLastMinute)
            VStack(alignment: .trailing, spacing: 2) {
                Text("读 \(IOPresentation.bytes(process.runReadBytes))")
                Text("写 \(IOPresentation.bytes(process.runWriteBytes))")
            }
            .font(.system(.caption2, design: .monospaced))
            .frame(width: 130, alignment: .trailing)
            Text("PID \(process.identity.pid)")
                .font(.caption2.monospacedDigit())
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func metricPair(title: String, rate: IORate?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("读 \(IOPresentation.rate(rate?.readBytesPerSecond))")
            Text("写 \(IOPresentation.rate(rate?.writeBytesPerSecond))")
        }
        .font(.system(.caption, design: .monospaced))
        .frame(width: 132, alignment: .trailing)
        .accessibilityLabel(
            "\(title)读取 \(IOPresentation.rate(rate?.readBytesPerSecond))，写入 \(IOPresentation.rate(rate?.writeBytesPerSecond))"
        )
    }

    private var processSummary: String {
        if application.helperCount == 0 {
            return "\(application.processCount) 个进程"
        }
        return "\(application.processCount) 个进程 · \(application.helperCount) 个 Helper"
    }

    private func processRelationship(_ process: RealtimeProcess) -> String {
        if process.isHelper { return "归并到当前应用" }
        if let launcher = process.launchedByApplicationID, launcher != process.applicationID {
            return "由 \(launcher) 启动，统计保持独立"
        }
        return "独立进程身份：PID + 启动时间"
    }

    private func trusted(_ rate: IORate?) -> IORate? {
        ratesAreTrustworthy ? rate : nil
    }
}
