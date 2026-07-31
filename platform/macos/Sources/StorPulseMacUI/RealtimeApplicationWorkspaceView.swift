import SwiftUI

struct RealtimeApplicationWorkspaceView: View {
    let applications: [RealtimeApplication]
    let ratesAreTrustworthy: Bool
    let hasSnapshot: Bool
    let isSearching: Bool
    @Binding var selection: RealtimeApplication.ID?
    @Binding var sortOrder: ApplicationSortOrder

    var body: some View {
        RealtimeApplicationTableView(
            snapshot: RealtimeApplicationTableSnapshot(
                applications: applications,
                ratesAreTrustworthy: ratesAreTrustworthy
            ),
            selection: $selection,
            sortOrder: $sortOrder
        )
        .overlay {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !hasSnapshot {
            ContentUnavailableView(
                "等待采样",
                systemImage: "waveform.path.ecg",
                description: Text("至少需要两个采样点才能计算实时速度。")
            )
        } else if applications.isEmpty, isSearching {
            ContentUnavailableView(
                "未找到匹配的应用或服务",
                systemImage: "magnifyingglass",
                description: Text("请尝试其他应用或服务名称。")
            )
        } else if applications.isEmpty {
            ContentUnavailableView(
                "没有可显示的应用或服务",
                systemImage: "externaldrive",
                description: Text("当前采样可能受限或暂时没有进程 I/O。")
            )
        }
    }
}
