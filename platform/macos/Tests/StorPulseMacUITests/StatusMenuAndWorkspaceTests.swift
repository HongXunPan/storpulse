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

@Test("实时表格与检查器宽度遵守窗口预算")
func realtimeTableAndInspectorWidthsFitWindowBudget() {
    #expect(
        RealtimeApplicationLayout.minimumRequiredWidth
            <= RealtimeApplicationLayout.minimumDetailWidth
    )
    #expect(
        RealtimeApplicationLayout.inspectorMinimumWidth
            <= RealtimeApplicationLayout.inspectorIdealWidth
    )
    #expect(
        RealtimeApplicationLayout.inspectorIdealWidth
            <= RealtimeApplicationLayout.inspectorMaximumWidth
    )
}

@Test("实时表格重排后按应用身份恢复选择")
func realtimeTableRestoresSelectionByApplicationIdentity() {
    let first = RealtimeApplicationTableSnapshot(
        applications: [
            realtimeApplicationFixture(id: "com.example.a"),
            realtimeApplicationFixture(id: "com.example.b"),
        ],
        ratesAreTrustworthy: true
    )
    let reordered = RealtimeApplicationTableSnapshot(
        applications: [
            realtimeApplicationFixture(id: "com.example.b"),
            realtimeApplicationFixture(id: "com.example.a"),
        ],
        ratesAreTrustworthy: true
    )

    #expect(first.index(of: "com.example.a") == 0)
    #expect(reordered.index(of: "com.example.a") == 1)
    #expect(reordered.index(of: "com.example.missing") == nil)
}

@MainActor
@Test("实时表格列头使用原生排序描述符映射")
func realtimeTableColumnsUseNativeSortDescriptors() throws {
    for column in RealtimeApplicationTableColumn.allCases {
        let descriptor = column.sortDescriptorPrototype
        let order = try #require(
            RealtimeApplicationTableColumn.sortOrder(from: descriptor)
        )

        #expect(order.criterion == column.sortCriterion)
        #expect(order.ascending == (column == .application))
    }

    let currentAscending = ApplicationSortOrder(
        criterion: .current,
        ascending: true
    )
    let descriptor = RealtimeApplicationTableColumn.sortDescriptor(
        for: currentAscending
    )
    #expect(descriptor.key == RealtimeApplicationTableColumn.current.rawValue)
    #expect(descriptor.ascending)
}

@MainActor
private final class StatusMenuActionTarget: NSObject {
    @objc func performAction() {}
}

private func realtimeApplicationFixture(id: String) -> RealtimeApplication {
    RealtimeApplication(
        applicationID: id,
        displayName: id,
        processCount: 1,
        helperCount: 0,
        current: IORate(
            readBytesPerSecond: 1_024,
            writeBytesPerSecond: 2_048
        ),
        averageLastMinute: nil,
        runReadBytes: 4_096,
        runWriteBytes: 8_192,
        continuousIODurationMilliseconds: 1_000,
        processIdentities: []
    )
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
