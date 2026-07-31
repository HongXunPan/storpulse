@preconcurrency import AppKit

enum RealtimeApplicationTableColumn: String, CaseIterable {
    case application
    case current
    case recentAverage
    case runTotal
    case duration

    struct Content {
        let primary: String
        let secondary: String?
        let accessibilityLabel: String
    }

    var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(rawValue)
    }

    var cellIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("RealtimeApplicationTableCell.\(rawValue)")
    }

    init?(identifier: NSUserInterfaceItemIdentifier) {
        self.init(rawValue: identifier.rawValue)
    }

    var title: String {
        switch self {
        case .application: "应用与服务"
        case .current: "当前速率"
        case .recentAverage: "一分钟均值"
        case .runTotal: "本次累计"
        case .duration: "持续时长"
        }
    }

    var sortCriterion: ApplicationSort {
        switch self {
        case .application: .application
        case .current: .current
        case .recentAverage: .recentAverage
        case .runTotal: .runTotal
        case .duration: .duration
        }
    }

    var sortDescriptorPrototype: NSSortDescriptor {
        NSSortDescriptor(
            key: rawValue,
            ascending: self == .application
        )
    }

    static func sortDescriptor(
        for order: ApplicationSortOrder
    ) -> NSSortDescriptor {
        let column = RealtimeApplicationTableColumn(
            sortCriterion: order.criterion
        )
        return NSSortDescriptor(
            key: column.rawValue,
            ascending: order.ascending
        )
    }

    static func sortOrder(
        from descriptor: NSSortDescriptor
    ) -> ApplicationSortOrder? {
        guard
            let key = descriptor.key,
            let column = RealtimeApplicationTableColumn(rawValue: key)
        else {
            return nil
        }
        return ApplicationSortOrder(
            criterion: column.sortCriterion,
            ascending: descriptor.ascending
        )
    }

    var minimumWidth: CGFloat {
        switch self {
        case .application:
            RealtimeApplicationLayout.applicationColumnMinimumWidth
        case .current:
            RealtimeApplicationLayout.currentRateWidth
        case .recentAverage:
            RealtimeApplicationLayout.recentAverageWidth
        case .runTotal:
            RealtimeApplicationLayout.runTotalWidth
        case .duration:
            RealtimeApplicationLayout.durationWidth
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .application:
            RealtimeApplicationLayout.applicationColumnIdealWidth
        default:
            minimumWidth
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .application:
            RealtimeApplicationLayout.applicationColumnMaximumWidth
        default:
            minimumWidth * 1.8
        }
    }

    var alignment: NSTextAlignment {
        self == .application ? .left : .right
    }

    var primaryFont: NSFont {
        switch self {
        case .application:
            .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        case .duration:
            .monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
        default:
            .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
        }
    }

    var secondaryFont: NSFont {
        self == .application
            ? .systemFont(ofSize: NSFont.smallSystemFontSize)
            : .monospacedSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
    }

    func content(for row: RealtimeApplicationTableRow) -> Content {
        switch self {
        case .application:
            Content(
                primary: row.displayName,
                secondary: row.processSummary,
                accessibilityLabel:
                    "\(row.displayName)，\(row.processSummary)"
            )
        case .current:
            Content(
                primary: row.currentRead,
                secondary: row.currentWrite,
                accessibilityLabel:
                    "当前\(row.currentRead)，\(row.currentWrite)"
            )
        case .recentAverage:
            Content(
                primary: row.recentRead,
                secondary: row.recentWrite,
                accessibilityLabel:
                    "一分钟\(row.recentRead)，\(row.recentWrite)"
            )
        case .runTotal:
            Content(
                primary: row.totalRead,
                secondary: row.totalWrite,
                accessibilityLabel:
                    "本次累计\(row.totalRead)，\(row.totalWrite)"
            )
        case .duration:
            Content(
                primary: row.duration,
                secondary: nil,
                accessibilityLabel: "持续时长 \(row.duration)"
            )
        }
    }

    private init(sortCriterion: ApplicationSort) {
        switch sortCriterion {
        case .application: self = .application
        case .current: self = .current
        case .recentAverage: self = .recentAverage
        case .runTotal: self = .runTotal
        case .duration: self = .duration
        }
    }
}
