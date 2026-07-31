@preconcurrency import AppKit

@MainActor
public final class StorPulseApplicationDelegate: NSObject, NSApplicationDelegate {
    public let monitor: RealtimeMonitor
    public let historyCoordinator: HistoryCoordinator
    public let historyViewModel: HistoryViewModel

    private var presentationCoordinator: StorPulsePresentationCoordinator?
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
        super.init()
    }

    public func applicationDidFinishLaunching(_: Notification) {
        presentationCoordinator = StorPulsePresentationCoordinator(
            monitor: monitor,
            historyViewModel: historyViewModel
        )
        monitor.start()
        Task { await historyViewModel.bootstrap() }
    }

    public func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        presentationCoordinator?.showCurrentMainWindow()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    public func applicationWillTerminate(_: Notification) {
        monitor.stop()
    }

    public func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminationTask = Task { [monitor, historyCoordinator] in
            if monitor.snapshot?.activeObservationSession != nil {
                _ = await monitor.stopObservation()
            }
            monitor.stop()
            try? await historyCoordinator.flushForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func showRealtimeObservation() {
        presentationCoordinator?.showMainWindow(module: .realtime)
    }

    public func showHistoryAndReminders() {
        presentationCoordinator?.showMainWindow(module: .historyAndReminders)
    }
}
