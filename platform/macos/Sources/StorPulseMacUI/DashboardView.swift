import SwiftUI

public struct DashboardView: View {
    @ObservedObject private var monitor: RealtimeMonitor
    @ObservedObject private var historyViewModel: HistoryViewModel
    @State private var sortOrder = ApplicationSortOrder.defaultOrder
    @State private var searchText = ""
    @State private var selectedApplicationID: RealtimeApplication.ID?
    @State private var inspectedDisplayName = "进程详情"
    @State private var inspectorPresented = false

    public init(
        monitor: RealtimeMonitor,
        historyViewModel: HistoryViewModel
    ) {
        self.monitor = monitor
        self.historyViewModel = historyViewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            summary
            RealtimeApplicationWorkspaceView(
                applications: visibleApplications,
                ratesAreTrustworthy: monitor.ratesAreTrustworthy,
                hasSnapshot: monitor.snapshot != nil,
                isSearching: isSearching,
                selection: $selectedApplicationID,
                sortOrder: $sortOrder
            )
        }
        .frame(
            minWidth: RealtimeApplicationLayout.minimumDetailWidth,
            minHeight: 520
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: $inspectorPresented) {
            ApplicationProcessesDetailView(
                displayName: selectedApplication?.displayName
                    ?? inspectedDisplayName,
                hasSelection: selectedApplicationID != nil,
                application: selectedApplication,
                processes: selectedProcesses,
                ratesAreTrustworthy: monitor.ratesAreTrustworthy
            )
            .inspectorColumnWidth(
                min: RealtimeApplicationLayout.inspectorMinimumWidth,
                ideal: RealtimeApplicationLayout.inspectorIdealWidth,
                max: RealtimeApplicationLayout.inspectorMaximumWidth
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                observationButton
                inspectorButton
            }
        }
        .sheet(isPresented: completedObservationRecordPresented) {
            if let record = monitor.completedObservationRecord {
                NavigationStack {
                    ObservationSessionResultView(
                        record: record.summary,
                        historyEnabled: historyViewModel.settings.historyEnabled,
                        onRename: { name in
                            Task {
                                _ = await monitor.renameObservationRecord(
                                    sessionID: record.id,
                                    name: name
                                )
                                await historyViewModel.refreshHistory()
                            }
                        }
                    )
                }
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "搜索应用或服务"
        )
        .onChange(of: selectedApplicationID) { _, applicationID in
            guard let applicationID else { return }
            if let application = visibleApplications.first(where: {
                $0.applicationID == applicationID
            }) {
                inspectedDisplayName = application.displayName
            }
            inspectorPresented = true
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
                Text("区间记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let name = monitor.activeObservationName {
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                }
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
                    Label("开始记录", systemImage: "record.circle")
                }
            } else {
                Button {
                    Task { await monitor.stopObservation() }
                } label: {
                    Label("结束记录", systemImage: "stop.circle")
                }
            }
        }
        .help(
            monitor.snapshot?.activeObservationSession == nil
                ? "开始记录一个手动统计区间"
                : "结束区间并查看本次结果"
        )
    }

    private var completedObservationRecordPresented: Binding<Bool> {
        Binding(
            get: { monitor.completedObservationRecord != nil },
            set: { isPresented in
                if !isPresented {
                    monitor.dismissCompletedObservationRecord()
                }
            }
        )
    }

    private var inspectorButton: some View {
        Button {
            inspectorPresented.toggle()
        } label: {
            Label("进程检查器", systemImage: "sidebar.trailing")
        }
        .help(
            inspectorPresented ? "隐藏进程检查器" : "显示进程检查器"
        )
        .accessibilityLabel(
            inspectorPresented ? "隐藏进程检查器" : "显示进程检查器"
        )
    }

    private var trustedDeviceRate: IORate? {
        monitor.ratesAreTrustworthy ? monitor.snapshot?.deviceRate : nil
    }

    private var visibleApplications: [RealtimeApplication] {
        let filtered = IOPresentation.filtered(
            monitor.snapshot?.applications ?? [],
            matching: searchText
        )
        return IOPresentation.sorted(filtered, by: sortOrder)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedApplication: RealtimeApplication? {
        guard let selectedApplicationID else { return nil }
        return monitor.snapshot?.applications.first {
            $0.applicationID == selectedApplicationID
        }
    }

    private var selectedProcesses: [RealtimeProcess] {
        guard let selectedApplication else { return [] }
        let identities = Set(selectedApplication.processIdentities)
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
        .frame(width: 124, alignment: .leading)
    }
}
