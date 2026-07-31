@preconcurrency import AppKit
import SwiftUI

@MainActor
final class RealtimeApplicationTableSortBridge {
    var binding: Binding<ApplicationSortOrder>

    private var writeGeneration = 0

    init(binding: Binding<ApplicationSortOrder>) {
        self.binding = binding
    }

    func invalidate() {
        writeGeneration += 1
    }

    func synchronize(
        _ order: ApplicationSortOrder,
        in tableView: NSTableView
    ) {
        let nextDescriptor = RealtimeApplicationTableColumn.sortDescriptor(
            for: order
        )
        if
            tableView.sortDescriptors.count == 1,
            let currentDescriptor = tableView.sortDescriptors.first,
            currentDescriptor.key == nextDescriptor.key,
            currentDescriptor.ascending == nextDescriptor.ascending
        {
            return
        }
        tableView.sortDescriptors = [nextDescriptor]
    }

    func scheduleWrite(_ nextOrder: ApplicationSortOrder) {
        writeGeneration += 1
        let generation = writeGeneration
        // 排序回调结束后再驱动 SwiftUI 重排，避免重入 NSTableView。
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                generation == self.writeGeneration,
                self.binding.wrappedValue != nextOrder
            else {
                return
            }
            self.binding.wrappedValue = nextOrder
        }
    }
}
