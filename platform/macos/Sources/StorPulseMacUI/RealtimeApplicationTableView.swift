@preconcurrency import AppKit
import SwiftUI

@MainActor
struct RealtimeApplicationTableView: NSViewRepresentable {
    let snapshot: RealtimeApplicationTableSnapshot
    @Binding var selection: RealtimeApplication.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        configure(tableView)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.attach(tableView)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.enqueue(
            snapshot: snapshot,
            selectedApplicationID: selection
        )
    }

    static func dismantleNSView(
        _: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    private func configure(_ tableView: NSTableView) {
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.rowHeight = 42
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true

        for column in RealtimeApplicationTableColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minimumWidth
            tableColumn.width = column.idealWidth
            tableColumn.maxWidth = column.maximumWidth
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(tableColumn)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private struct PendingUpdate {
            let snapshot: RealtimeApplicationTableSnapshot
            let selectedApplicationID: String?
        }

        var selection: Binding<String?>

        private weak var tableView: NSTableView?
        private var snapshot = RealtimeApplicationTableSnapshot(
            applications: [],
            ratesAreTrustworthy: false
        )
        private var pendingUpdate: PendingUpdate?
        private var updateScheduled = false
        private var applyingSnapshot = false
        private var selectionWriteGeneration = 0

        init(selection: Binding<String?>) {
            self.selection = selection
        }

        func attach(_ tableView: NSTableView) {
            self.tableView = tableView
        }

        func detach() {
            selectionWriteGeneration += 1
            pendingUpdate = nil
            tableView?.delegate = nil
            tableView?.dataSource = nil
            tableView = nil
        }

        func enqueue(
            snapshot: RealtimeApplicationTableSnapshot,
            selectedApplicationID: String?
        ) {
            pendingUpdate = PendingUpdate(
                snapshot: snapshot,
                selectedApplicationID: selectedApplicationID
            )
            guard !updateScheduled else { return }
            updateScheduled = true

            // 只能在当前 SwiftUI/AppKit 回调栈结束后更新 NSTableView。
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingUpdate()
            }
        }

        func numberOfRows(in _: NSTableView) -> Int {
            snapshot.rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard
                snapshot.rows.indices.contains(row),
                let tableColumn,
                let column = RealtimeApplicationTableColumn(
                    identifier: tableColumn.identifier
                )
            else {
                return nil
            }

            let cell = reusableCell(
                in: tableView,
                identifier: column.cellIdentifier
            )
            configure(
                cell,
                column: column,
                row: snapshot.rows[row]
            )
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard
                !applyingSnapshot,
                let tableView = notification.object as? NSTableView
            else {
                return
            }
            let row = tableView.selectedRow
            let selectedID = snapshot.rows.indices.contains(row)
                ? snapshot.rows[row].id
                : nil
            scheduleSelectionWrite(selectedID)
        }

        private func applyPendingUpdate() {
            updateScheduled = false
            guard let tableView, let update = pendingUpdate else { return }
            pendingUpdate = nil

            let previousIDs = snapshot.rows.map(\.id)
            let nextIDs = update.snapshot.rows.map(\.id)
            snapshot = update.snapshot

            applyingSnapshot = true
            if previousIDs == nextIDs {
                tableView.reloadData(
                    forRowIndexes: IndexSet(integersIn: 0 ..< snapshot.rows.count),
                    columnIndexes: IndexSet(
                        integersIn: 0 ..< tableView.tableColumns.count
                    )
                )
            } else {
                tableView.reloadData()
            }
            restoreSelection(
                update.selectedApplicationID,
                in: tableView
            )
            applyingSnapshot = false
        }

        private func restoreSelection(
            _ applicationID: String?,
            in tableView: NSTableView
        ) {
            guard let row = snapshot.index(of: applicationID) else {
                if tableView.selectedRow != -1 {
                    tableView.deselectAll(nil)
                }
                if applicationID != nil {
                    scheduleSelectionWrite(nil)
                }
                return
            }
            guard tableView.selectedRow != row else { return }
            tableView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
        }

        private func scheduleSelectionWrite(_ applicationID: String?) {
            selectionWriteGeneration += 1
            let generation = selectionWriteGeneration
            // delegate 回调内不得回写 SwiftUI 状态，否则会重组表格视图。
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    generation == self.selectionWriteGeneration,
                    self.selection.wrappedValue != applicationID
                else {
                    return
                }
                self.selection.wrappedValue = applicationID
            }
        }

        private func reusableCell(
            in tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier
        ) -> RealtimeApplicationTableCellView {
            if let cell = tableView.makeView(
                withIdentifier: identifier,
                owner: self
            ) as? RealtimeApplicationTableCellView {
                return cell
            }
            let cell = RealtimeApplicationTableCellView(frame: .zero)
            cell.identifier = identifier
            return cell
        }

        private func configure(
            _ cell: RealtimeApplicationTableCellView,
            column: RealtimeApplicationTableColumn,
            row: RealtimeApplicationTableRow
        ) {
            let content = column.content(for: row)
            cell.configure(
                primary: content.primary,
                secondary: content.secondary,
                alignment: column.alignment,
                primaryFont: column.primaryFont,
                secondaryFont: column.secondaryFont,
                accessibilityLabel: content.accessibilityLabel,
                toolTip: column == .application ? row.displayName : nil
            )
        }
    }
}
