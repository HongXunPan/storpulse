import AppKit

@MainActor
final class StorPulsePresentationCoordinator {
    private let monitor: RealtimeMonitor
    private let historyViewModel: HistoryViewModel

    private lazy var mainWindowController = StorPulseMainWindowController(
        monitor: monitor,
        historyViewModel: historyViewModel
    )

    private lazy var menuBarController = MenuBarController(
        monitor: monitor,
        actions: StorPulseMenuBarActions(
            showModule: { [weak self] module in
                self?.showMainWindow(module: module)
            }
        )
    )

    init(
        monitor: RealtimeMonitor,
        historyViewModel: HistoryViewModel
    ) {
        self.monitor = monitor
        self.historyViewModel = historyViewModel

        // 状态栏控制器必须与展示协调器保持相同生命周期。
        _ = menuBarController
    }

    func showCurrentMainWindow() {
        menuBarController.dismissStatusMenuForWindowPresentation()
        mainWindowController.showCurrentModule()
    }

    func showMainWindow(module: StorPulseWorkspaceModule) {
        menuBarController.dismissStatusMenuForWindowPresentation()
        mainWindowController.show(module: module)
    }
}
