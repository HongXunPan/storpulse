@preconcurrency import AppKit
import SwiftUI

@MainActor
public final class StorPulseApplicationDelegate: NSObject, NSApplicationDelegate {
    public let monitor: RealtimeMonitor
    public let historyCoordinator: HistoryCoordinator
    public let historyViewModel: HistoryViewModel

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var dashboardController: NSWindowController?
    private var historyController: NSWindowController?
    private var terminationTask: Task<Void, Never>?

    public override init() {
        let engine: any StorPulseEngineClient
        do {
            engine = try RustEngineClient()
        } catch {
            engine = UnavailableEngineClient(message: error.localizedDescription)
        }
        let databaseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "StorPulse/history.sqlite3")
        historyCoordinator = HistoryCoordinator(databaseURL: databaseURL, engine: engine)
        historyViewModel = HistoryViewModel(coordinator: historyCoordinator)
        monitor = RealtimeMonitor(engine: engine, observers: [historyCoordinator])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()
    }

    public func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        monitor.start()
        Task { await historyViewModel.bootstrap() }
    }

    public func applicationWillTerminate(_: Notification) {
        monitor.stop()
    }

    public func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        monitor.stop()
        terminationTask = Task { [historyCoordinator] in
            try? await historyCoordinator.flushForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "externaldrive.badge.timemachine", accessibilityDescription: "StorPulse")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "StorPulse 磁盘 I/O 观察"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(
                monitor: monitor,
                openDashboard: { [weak self] in self?.showDashboard() },
                openHistory: { [weak self] in self?.showHistory() },
                quitApplication: { NSApp.terminate(nil) }
            )
        )
    }

    private func showDashboard() {
        popover.performClose(nil)
        if dashboardController == nil {
            let hostingController = NSHostingController(
                rootView: DashboardView(
                    monitor: monitor,
                    openHistory: { [weak self] in self?.showHistory() }
                )
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "StorPulse 实时观察"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 640))
            window.minSize = NSSize(width: 880, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            dashboardController = NSWindowController(window: window)
        }
        dashboardController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showHistory() {
        popover.performClose(nil)
        if historyController == nil {
            let hostingController = NSHostingController(
                rootView: HistorySettingsView(model: historyViewModel)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = "StorPulse 历史与提醒"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 680, height: 620))
            window.minSize = NSSize(width: 620, height: 560)
            window.center()
            window.isReleasedWhenClosed = false
            historyController = NSWindowController(window: window)
        }
        Task { await historyViewModel.refreshCounts() }
        historyController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
