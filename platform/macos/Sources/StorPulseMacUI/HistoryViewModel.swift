@preconcurrency import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class HistoryViewModel: ObservableObject {
    @Published public var settings = HistorySettings()
    @Published public private(set) var counts = HistoryCounts.empty
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isWorking = false

    private let coordinator: HistoryCoordinator

    public init(coordinator: HistoryCoordinator) {
        self.coordinator = coordinator
    }

    public func bootstrap() async {
        await coordinator.bootstrap()
        settings = await coordinator.currentSettings()
        await refreshCounts()
    }

    public func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.updateSettings(settings)
            settings = await coordinator.currentSettings()
            errorMessage = nil
            statusMessage = "设置已保存"
            await refreshCounts()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    public func clearHistory() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await coordinator.clearHistory()
            counts = .empty
            errorMessage = nil
            statusMessage = "本机历史已清理"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    public func exportHistory() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await coordinator.exportJSON()
            let panel = NSSavePanel()
            panel.title = "导出 StorPulse 摘要"
            panel.nameFieldStringValue = "storpulse-summary.json"
            panel.allowedContentTypes = [UTType.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            errorMessage = nil
            statusMessage = "摘要已导出"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
    }

    public func refreshCounts() async {
        do {
            counts = try await coordinator.counts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
