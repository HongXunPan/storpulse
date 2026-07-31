import SwiftUI

struct ApplicationProcessesDetailView: View {
    private enum MetricScope: String, CaseIterable, Identifiable {
        case current = "当前"
        case recentAverage = "一分钟"
        case runTotal = "累计"

        var id: String { rawValue }
    }

    let displayName: String
    let hasSelection: Bool
    let application: RealtimeApplication?
    let processes: [RealtimeProcess]
    let ratesAreTrustworthy: Bool

    @State private var metricScope: MetricScope = .current

    var body: some View {
        VStack(spacing: 0) {
            if !hasSelection {
                selectionPrompt
            } else {
                inspectorHeader
                Divider()
                if application == nil {
                    unavailableContent
                } else {
                    metricPicker
                    processSectionHeader
                    Divider()
                    processContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .help(displayName)
            Text(processCoverage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var selectionPrompt: some View {
        ContentUnavailableView(
            "选择一个应用",
            systemImage: "sidebar.trailing",
            description: Text("从实时表格选择应用以查看它的进程。")
        )
    }

    private var metricPicker: some View {
        Picker("进程指标", selection: $metricScope) {
            ForEach(MetricScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var processSectionHeader: some View {
        HStack {
            Text("进程")
                .font(.headline)
            Spacer()
            Text("\(processes.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var processContent: some View {
        if processes.isEmpty {
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
                        if process.id != processes.last?.id {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var unavailableContent: some View {
        ContentUnavailableView(
            "应用已离开当前采样",
            systemImage: "xmark.circle",
            description: Text("该应用可能已经退出；请从应用表格选择其他项目。")
        )
    }

    private func processRow(_ process: RealtimeProcess) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                Text(processContext(process))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            processMetric(process)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(processAccessibilityLabel(process))
    }

    private var processCoverage: String {
        guard let application else { return "应用已离开当前采样" }
        if application.helperCount == 0 {
            return "\(processes.count) 个可见进程"
        }
        return "\(processes.count) 个可见进程 · \(application.helperCount) 个 Helper"
    }

    private func processContext(_ process: RealtimeProcess) -> String {
        if process.isHelper { return "PID \(process.identity.pid)" }
        if let launcher = process.launchedByApplicationID, launcher != process.applicationID {
            return "独立子任务 · PID \(process.identity.pid)"
        }
        return "PID \(process.identity.pid)"
    }

    @ViewBuilder
    private func processMetric(_ process: RealtimeProcess) -> some View {
        switch metricScope {
        case .current:
            RealtimeRatePairView(
                title: "当前",
                rate: ratesAreTrustworthy ? process.current : nil,
                textStyle: .caption
            )
        case .recentAverage:
            RealtimeRatePairView(
                title: "一分钟",
                rate: process.averageLastMinute,
                textStyle: .caption
            )
        case .runTotal:
            RealtimeTotalPairView(
                readBytes: process.runReadBytes,
                writeBytes: process.runWriteBytes,
                textStyle: .caption
            )
        }
    }

    private func processAccessibilityLabel(_ process: RealtimeProcess) -> String {
        let prefix = "\(process.executableName)，PID \(process.identity.pid)"
        switch metricScope {
        case .current:
            let rate = ratesAreTrustworthy ? process.current : nil
            return "\(prefix)，当前读取 \(IOPresentation.rate(rate?.readBytesPerSecond))，写入 \(IOPresentation.rate(rate?.writeBytesPerSecond))"
        case .recentAverage:
            return "\(prefix)，一分钟读取 \(IOPresentation.rate(process.averageLastMinute?.readBytesPerSecond))，写入 \(IOPresentation.rate(process.averageLastMinute?.writeBytesPerSecond))"
        case .runTotal:
            return "\(prefix)，累计读取 \(IOPresentation.bytes(process.runReadBytes))，写入 \(IOPresentation.bytes(process.runWriteBytes))"
        }
    }
}
