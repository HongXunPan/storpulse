import SwiftUI

struct ApplicationProcessesDetailView: View {
    let displayName: String
    let application: RealtimeApplication?
    let processes: [RealtimeProcess]
    let ratesAreTrustworthy: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            processHeader
            Divider()
            processContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var detailHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .help(displayName)
                Text(processCoverage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) {
                Label("关闭进程详情", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("关闭进程详情")
            .accessibilityLabel("关闭 \(displayName) 的进程详情")
        }
        .padding(.horizontal, RealtimeApplicationLayout.horizontalInset)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var processHeader: some View {
        RealtimeApplicationColumns {
            Text("进程")
        } currentRate: {
            Text("当前速率")
        } recentAverage: {
            Text("一分钟均值")
        } runTotal: {
            Text("本次累计")
        } trailing: {
            Text("PID")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, RealtimeApplicationLayout.horizontalInset)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "进程数据列：进程、当前速率、一分钟均值、本次累计、PID"
        )
    }

    @ViewBuilder
    private var processContent: some View {
        if application == nil {
            ContentUnavailableView(
                "应用已离开当前采样",
                systemImage: "xmark.circle",
                description: Text("该应用可能已经退出；关闭详情后可选择其他应用。")
            )
        } else if processes.isEmpty {
            ContentUnavailableView(
                "暂无可读进程",
                systemImage: "lock",
                description: Text("子进程可能已经退出或受到系统权限限制。")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(processes) { process in
                        processRow(process)
                            .padding(
                                .horizontal,
                                RealtimeApplicationLayout.horizontalInset
                            )
                        if process.id != processes.last?.id {
                            Divider()
                                .padding(
                                    .leading,
                                    RealtimeApplicationLayout.horizontalInset
                                )
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private func processRow(_ process: RealtimeProcess) -> some View {
        RealtimeApplicationColumns {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(process.executableName)
                        .lineLimit(1)
                        .help(process.executableName)
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
                    .lineLimit(1)
            }
        } currentRate: {
            RealtimeRatePairView(
                title: "当前",
                rate: trusted(process.current),
                textStyle: .caption2
            )
        } recentAverage: {
            RealtimeRatePairView(
                title: "一分钟",
                rate: process.averageLastMinute,
                textStyle: .caption2
            )
        } runTotal: {
            RealtimeTotalPairView(
                readBytes: process.runReadBytes,
                writeBytes: process.runWriteBytes,
                textStyle: .caption2
            )
        } trailing: {
            Text("\(process.identity.pid)")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private var processCoverage: String {
        guard let application else { return "应用已离开当前采样" }
        if application.helperCount == 0 {
            return "\(processes.count) 个可见进程"
        }
        return "\(processes.count) 个可见进程 · \(application.helperCount) 个 Helper"
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
