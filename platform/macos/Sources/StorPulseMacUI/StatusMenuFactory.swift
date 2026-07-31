import AppKit
import SwiftUI

enum StatusMenuLayout {
    static let contentWidth: CGFloat = 320
}

@MainActor
struct StatusMenuAssembly {
    let menu: NSMenu
    let summaryViewController: NSViewController
    let topApplicationsItem: NSMenuItem
    let observationItem: NSMenuItem
    let refreshSummarySize: () -> Void
}

@MainActor
struct StatusMenuFactory {
    let monitor: RealtimeMonitor

    func makeAssembly(
        target: AnyObject,
        toggleObservationAction: Selector,
        showRealtimeAction: Selector,
        showHistoryAction: Selector,
        terminateAction: Selector
    ) -> StatusMenuAssembly {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let summaryController = makeSummaryController()
        let summaryItem = NSMenuItem()
        summaryItem.view = summaryController.view
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let topApplicationsItem = NSMenuItem(
            title: "当前主要应用",
            action: nil,
            keyEquivalent: ""
        )
        let topApplicationsMenu = NSMenu()
        topApplicationsMenu.autoenablesItems = false
        topApplicationsItem.submenu = topApplicationsMenu
        menu.addItem(topApplicationsItem)

        let observationItem = makeItem(
            title: "开始观察",
            symbol: "record.circle",
            action: toggleObservationAction,
            target: target
        )
        menu.addItem(observationItem)
        menu.addItem(.separator())

        let realtimeItem = makeItem(
            title: "打开实时观察",
            symbol: "waveform.path.ecg",
            action: showRealtimeAction,
            target: target,
            keyEquivalent: "o"
        )
        menu.addItem(realtimeItem)

        let historyItem = makeItem(
            title: "历史与提醒…",
            symbol: "clock.arrow.circlepath",
            action: showHistoryAction,
            target: target,
            keyEquivalent: ","
        )
        menu.addItem(historyItem)
        menu.addItem(.separator())

        let quitItem = makeItem(
            title: "退出 StorPulse",
            symbol: "power",
            action: terminateAction,
            target: target,
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        let refreshSummarySize = {
            let fittingSize = summaryController.sizeThatFits(
                in: CGSize(
                    width: StatusMenuLayout.contentWidth,
                    height: .greatestFiniteMagnitude
                )
            )
            summaryController.view.frame.size = NSSize(
                width: StatusMenuLayout.contentWidth,
                height: max(1, ceil(fittingSize.height))
            )
            summaryController.view.autoresizingMask = [.width]
        }
        refreshSummarySize()

        return StatusMenuAssembly(
            menu: menu,
            summaryViewController: summaryController,
            topApplicationsItem: topApplicationsItem,
            observationItem: observationItem,
            refreshSummarySize: refreshSummarySize
        )
    }

    private func makeSummaryController() -> NSHostingController<StatusMenuSummaryView> {
        let controller = NSHostingController(
            rootView: StatusMenuSummaryView(monitor: monitor)
        )
        controller.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        controller.view.setContentHuggingPriority(.required, for: .vertical)
        controller.view.setContentCompressionResistancePriority(.required, for: .vertical)
        return controller
    }

    private func makeItem(
        title: String,
        symbol: String,
        action: Selector,
        target: AnyObject,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.target = target
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : [.command]
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.image?.isTemplate = true
        return item
    }
}
