import Combine
import SwiftUI

enum StorPulseWorkspaceModule: String, CaseIterable, Hashable, Identifiable {
    case realtime
    case recordings
    case historyAndReminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime: "实时观察"
        case .recordings: "区间记录"
        case .historyAndReminders: "历史与提醒"
        }
    }

    var systemImage: String {
        switch self {
        case .realtime: "waveform.path.ecg"
        case .recordings: "record.circle"
        case .historyAndReminders: "clock.arrow.circlepath"
        }
    }
}

@MainActor
final class StorPulseWorkspaceModel: ObservableObject {
    @Published var selectedModule: StorPulseWorkspaceModule? = .realtime

    var currentModule: StorPulseWorkspaceModule {
        selectedModule ?? .realtime
    }

    func select(_ module: StorPulseWorkspaceModule) {
        selectedModule = module
    }
}

struct StorPulseWorkspaceView: View {
    @ObservedObject private var model: StorPulseWorkspaceModel
    private let monitor: RealtimeMonitor
    private let historyViewModel: HistoryViewModel

    init(
        model: StorPulseWorkspaceModel,
        monitor: RealtimeMonitor,
        historyViewModel: HistoryViewModel
    ) {
        self.model = model
        self.monitor = monitor
        self.historyViewModel = historyViewModel
    }

    var body: some View {
        NavigationSplitView {
            List(
                StorPulseWorkspaceModule.allCases,
                selection: $model.selectedModule
            ) { module in
                Label(module.title, systemImage: module.systemImage)
                    .tag(module)
            }
            .listStyle(.sidebar)
            .navigationTitle("StorPulse")
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .navigationTitle(model.currentModule.title)
        }
        .task(id: model.currentModule) {
            if model.currentModule != .realtime {
                await historyViewModel.refreshHistory()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.currentModule {
        case .realtime:
            DashboardView(
                monitor: monitor,
                historyViewModel: historyViewModel
            )
        case .recordings:
            ObservationRecordsView(
                monitor: monitor,
                historyViewModel: historyViewModel
            )
        case .historyAndReminders:
            HistorySettingsView(model: historyViewModel)
        }
    }
}
