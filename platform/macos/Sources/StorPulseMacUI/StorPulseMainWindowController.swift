import AppKit
import SwiftUI

@MainActor
final class StorPulseMainWindowController: NSWindowController {
    private static let initialSize = NSSize(width: 1_080, height: 680)
    private static let minimumSize = NSSize(width: 900, height: 560)
    private static let frameAutosaveName = "StorPulseMainWindow"

    private let workspaceModel: StorPulseWorkspaceModel

    init(
        monitor: RealtimeMonitor,
        historyViewModel: HistoryViewModel
    ) {
        let workspaceModel = StorPulseWorkspaceModel()
        self.workspaceModel = workspaceModel

        let hostingController = NSHostingController(
            rootView: StorPulseWorkspaceView(
                model: workspaceModel,
                monitor: monitor,
                historyViewModel: historyViewModel
            )
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StorPulse"
        window.contentViewController = hostingController
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    func show(module: StorPulseWorkspaceModule) {
        workspaceModel.select(module)
        showCurrentModule()
    }

    func showCurrentModule() {
        NSApplication.shared.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
