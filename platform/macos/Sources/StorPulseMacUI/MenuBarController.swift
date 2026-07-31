import AppKit
import Combine

@MainActor
struct StorPulseMenuBarActions {
    let showModule: (StorPulseWorkspaceModule) -> Void
}

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let monitor: RealtimeMonitor
    private let actions: StorPulseMenuBarActions
    private var assembly: StatusMenuAssembly!
    private var cancellables: Set<AnyCancellable> = []

    init(
        monitor: RealtimeMonitor,
        actions: StorPulseMenuBarActions
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.monitor = monitor
        self.actions = actions
        super.init()

        assembly = StatusMenuFactory(monitor: monitor).makeAssembly(
            target: self,
            toggleObservationAction: #selector(toggleObservation),
            showRealtimeAction: #selector(showRealtime),
            showHistoryAction: #selector(showHistory),
            terminateAction: #selector(terminateApplication)
        )
        assembly.menu.delegate = self
        statusItem.menu = assembly.menu
        configureStatusItem()
        observeMonitor()
        refreshPresentation()
    }

    func menuWillOpen(_: NSMenu) {
        refreshPresentation()
    }

    func dismissStatusMenuForWindowPresentation() {
        assembly.menu.cancelTracking()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "externaldrive.badge.timemachine",
            accessibilityDescription: "StorPulse"
        )
        button.image?.isTemplate = true
        button.toolTip = "StorPulse 磁盘 I/O 观察"
        button.setAccessibilityLabel("StorPulse")
    }

    private func observeMonitor() {
        monitor.objectWillChange
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.refreshPresentation()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshPresentation() {
        assembly.refreshSummarySize()
        refreshTopApplications()
        refreshObservationItem()
        refreshStatusItemAccessibility()
    }

    private func refreshTopApplications() {
        guard let submenu = assembly.topApplicationsItem.submenu else { return }
        submenu.removeAllItems()

        let applications = topApplications
        assembly.topApplicationsItem.badge = applications.isEmpty
            ? nil
            : NSMenuItemBadge(string: "\(applications.count)")

        guard !applications.isEmpty else {
            let placeholder = NSMenuItem(
                title: topApplicationsPlaceholder,
                action: nil,
                keyEquivalent: ""
            )
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            return
        }

        for application in applications {
            let totalRate = application.current.map {
                $0.readBytesPerSecond + $0.writeBytesPerSecond
            }
            let item = NSMenuItem(
                title: "\(application.displayName) — \(IOPresentation.rate(totalRate)) · \(IOPresentation.duration(milliseconds: application.continuousIODurationMilliseconds))",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.toolTip = [
                "读取 \(IOPresentation.rate(application.current?.readBytesPerSecond))",
                "写入 \(IOPresentation.rate(application.current?.writeBytesPerSecond))",
                "连续 \(IOPresentation.duration(milliseconds: application.continuousIODurationMilliseconds))",
            ].joined(separator: "，")
            submenu.addItem(item)
        }
    }

    private func refreshObservationItem() {
        let isObserving = monitor.snapshot?.activeObservationSession != nil
        assembly.observationItem.title = isObserving ? "结束记录…" : "开始记录"
        assembly.observationItem.image = NSImage(
            systemSymbolName: isObserving ? "stop.circle" : "record.circle",
            accessibilityDescription: assembly.observationItem.title
        )
        assembly.observationItem.image?.isTemplate = true
        assembly.observationItem.isEnabled = monitor.snapshot != nil
    }

    private func refreshStatusItemAccessibility() {
        guard let button = statusItem.button else { return }
        let state = monitor.samplingState.title
        guard monitor.ratesAreTrustworthy, let rate = monitor.snapshot?.deviceRate else {
            button.toolTip = "StorPulse · \(state)"
            button.setAccessibilityValue(state)
            return
        }
        let summary = "读取 \(IOPresentation.rate(rate.readBytesPerSecond))，写入 \(IOPresentation.rate(rate.writeBytesPerSecond))"
        button.toolTip = "StorPulse · \(state)\n\(summary)"
        button.setAccessibilityValue("\(state)，\(summary)")
    }

    private var topApplications: [RealtimeApplication] {
        guard monitor.ratesAreTrustworthy else { return [] }
        return Array(
            IOPresentation.sorted(
                monitor.snapshot?.applications ?? [],
                by: .current
            )
            .filter { $0.current != nil }
            .prefix(5)
        )
    }

    private var topApplicationsPlaceholder: String {
        if monitor.snapshot == nil { return "等待采样" }
        if !monitor.ratesAreTrustworthy { return monitor.samplingState.title }
        return "当前没有持续 I/O"
    }

    @objc
    private func toggleObservation() {
        let isObserving = monitor.snapshot?.activeObservationSession != nil
        Task { [weak self] in
            guard let self else { return }
            if isObserving {
                if await monitor.stopObservation() != nil {
                    dismissStatusMenuForWindowPresentation()
                    actions.showModule(.realtime)
                }
            } else {
                await monitor.startObservation()
            }
            refreshPresentation()
        }
    }

    @objc
    private func showRealtime() {
        dismissStatusMenuForWindowPresentation()
        actions.showModule(.realtime)
    }

    @objc
    private func showHistory() {
        dismissStatusMenuForWindowPresentation()
        actions.showModule(.historyAndReminders)
    }

    @objc
    private func terminateApplication() {
        NSApplication.shared.terminate(nil)
    }
}
