import AppKit
import StorPulseMacAdapter
@testable import StorPulseMacUI
import Testing

@MainActor
@Test("状态栏使用原生菜单、真实子菜单和标准命令项")
func statusMenuUsesNativeStructure() throws {
    let monitor = RealtimeMonitor(engine: StatusMenuFixtureEngine())
    let target = StatusMenuActionTarget()
    let assembly = StatusMenuFactory(monitor: monitor).makeAssembly(
        target: target,
        toggleObservationAction: #selector(StatusMenuActionTarget.performAction),
        showRealtimeAction: #selector(StatusMenuActionTarget.performAction),
        showHistoryAction: #selector(StatusMenuActionTarget.performAction),
        terminateAction: #selector(StatusMenuActionTarget.performAction)
    )

    let summaryItem = try #require(assembly.menu.items.first)
    let topApplicationsItem = try #require(
        assembly.menu.items.first { $0.title == "当前主要应用" }
    )
    let realtimeItem = try #require(
        assembly.menu.items.first { $0.title == "打开实时观察" }
    )
    let historyItem = try #require(
        assembly.menu.items.first { $0.title == "历史与提醒…" }
    )

    #expect(summaryItem.view === assembly.summaryViewController.view)
    #expect(summaryItem.submenu == nil)
    #expect(topApplicationsItem.view == nil)
    #expect(topApplicationsItem.submenu != nil)
    #expect(realtimeItem.view == nil)
    #expect(realtimeItem.keyEquivalent == "o")
    #expect(realtimeItem.keyEquivalentModifierMask == [.command])
    #expect(historyItem.keyEquivalent == ",")
    #expect(historyItem.keyEquivalentModifierMask == [.command])
}

@MainActor
@Test("主窗口工作区复用同一选择模型切换模块")
func workspaceModelReusesSelection() {
    let model = StorPulseWorkspaceModel()

    #expect(model.currentModule == .realtime)
    model.select(.historyAndReminders)
    #expect(model.currentModule == .historyAndReminders)
    model.selectedModule = nil
    #expect(model.currentModule == .realtime)
}

@MainActor
private final class StatusMenuActionTarget: NSObject {
    @objc func performAction() {}
}

private actor StatusMenuFixtureEngine: StorPulseEngineClient {
    func ingest(_: RawSnapshot) async throws {}

    func snapshot(at _: UInt64) async throws -> RealtimeSnapshot {
        throw StatusMenuFixtureError.unused
    }

    func execute(_: EngineCommand) async throws -> EngineCommandResponse {
        .accepted
    }
}

private enum StatusMenuFixtureError: Error {
    case unused
}
