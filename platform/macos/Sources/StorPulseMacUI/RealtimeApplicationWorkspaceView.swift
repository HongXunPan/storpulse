import SwiftUI

struct RealtimeApplicationWorkspaceView: View {
    private struct ProcessSelection: Equatable {
        let applicationID: String
        let displayName: String
    }

    let applications: [RealtimeApplication]
    let processes: [RealtimeProcess]
    let ratesAreTrustworthy: Bool
    let hasSnapshot: Bool

    @State private var processSelection: ProcessSelection?

    var body: some View {
        VSplitView {
            applicationList
                .frame(minHeight: 220)

            if let processSelection {
                ApplicationProcessesDetailView(
                    displayName: selectedApplication?.displayName
                        ?? processSelection.displayName,
                    application: selectedApplication,
                    processes: selectedProcesses,
                    ratesAreTrustworthy: ratesAreTrustworthy,
                    close: { self.processSelection = nil }
                )
                .frame(minHeight: 170, idealHeight: 240, maxHeight: 360)
            }
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            applicationHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(applications) { application in
                        ApplicationRowView(
                            application: application,
                            ratesAreTrustworthy: ratesAreTrustworthy,
                            showProcesses: {
                                processSelection = ProcessSelection(
                                    applicationID: application.applicationID,
                                    displayName: application.displayName
                                )
                            }
                        )
                        .padding(
                            .horizontal,
                            RealtimeApplicationLayout.horizontalInset
                        )

                        Divider()
                            .padding(
                                .leading,
                                RealtimeApplicationLayout.horizontalInset
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .overlay {
                if !hasSnapshot {
                    ContentUnavailableView(
                        "等待采样",
                        systemImage: "waveform.path.ecg",
                        description: Text("至少需要两个采样点才能计算实时速度。")
                    )
                } else if applications.isEmpty {
                    ContentUnavailableView(
                        "没有可显示的应用",
                        systemImage: "externaldrive",
                        description: Text("当前采样可能受限或暂时没有进程 I/O。")
                    )
                }
            }
        }
    }

    private var applicationHeader: some View {
        RealtimeApplicationColumns {
            Text("应用")
        } currentRate: {
            Text("当前速率")
        } recentAverage: {
            Text("一分钟均值")
        } runTotal: {
            Text("本次累计")
        } trailing: {
            Text("持续时长")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, RealtimeApplicationLayout.horizontalInset)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "应用数据列：应用、当前速率、一分钟均值、本次累计、持续时长"
        )
    }

    private var selectedApplication: RealtimeApplication? {
        guard let processSelection else { return nil }
        return applications.first {
            $0.applicationID == processSelection.applicationID
        }
    }

    private var selectedProcesses: [RealtimeProcess] {
        guard let selectedApplication else { return [] }
        let identities = Set(selectedApplication.processIdentities)
        return processes
            .filter { identities.contains($0.identity) }
            .sorted { lhs, rhs in
                if lhs.isHelper != rhs.isHelper { return !lhs.isHelper }
                return lhs.executableName.localizedStandardCompare(rhs.executableName)
                    == .orderedAscending
            }
    }
}
