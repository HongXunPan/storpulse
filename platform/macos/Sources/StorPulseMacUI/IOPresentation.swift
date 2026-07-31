import Foundation

public enum ApplicationSort: String, CaseIterable, Identifiable, Sendable {
    case application = "应用"
    case current = "当前速度"
    case recentAverage = "一分钟均值"
    case runTotal = "本次累计"
    case duration = "持续时长"

    public var id: String { rawValue }
}

public struct ApplicationSortOrder: Equatable, Sendable {
    public let criterion: ApplicationSort
    public let ascending: Bool

    public init(criterion: ApplicationSort, ascending: Bool) {
        self.criterion = criterion
        self.ascending = ascending
    }

    public static let defaultOrder = ApplicationSortOrder(
        criterion: .current,
        ascending: false
    )
}

public enum IOPresentation {
    public static func filtered(
        _ applications: [RealtimeApplication],
        matching searchText: String
    ) -> [RealtimeApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    public static func sorted(
        _ applications: [RealtimeApplication],
        by sort: ApplicationSort
    ) -> [RealtimeApplication] {
        sorted(
            applications,
            by: ApplicationSortOrder(
                criterion: sort,
                ascending: sort == .application
            )
        )
    }

    public static func sorted(
        _ applications: [RealtimeApplication],
        by order: ApplicationSortOrder
    ) -> [RealtimeApplication] {
        applications.sorted { lhs, rhs in
            let comparison = compare(lhs, rhs, by: order.criterion)
            if comparison == .orderedSame {
                return stableIdentityComparison(lhs, rhs) == .orderedAscending
            }
            return order.ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    public static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        return "\(bytes(UInt64(max(0, bytesPerSecond))))/秒"
    }

    public static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    public static func duration(milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1_000
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分 \(seconds % 60) 秒" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private static func totalRate(_ rate: IORate?) -> Double {
        guard let rate else { return 0 }
        return rate.readBytesPerSecond + rate.writeBytesPerSecond
    }

    private static func compare(
        _ lhs: RealtimeApplication,
        _ rhs: RealtimeApplication,
        by criterion: ApplicationSort
    ) -> ComparisonResult {
        switch criterion {
        case .application:
            lhs.displayName.localizedStandardCompare(rhs.displayName)
        case .current:
            compareValues(totalRate(lhs.current), totalRate(rhs.current))
        case .recentAverage:
            compareValues(
                totalRate(lhs.averageLastMinute),
                totalRate(rhs.averageLastMinute)
            )
        case .runTotal:
            compareValues(totalBytes(lhs), totalBytes(rhs))
        case .duration:
            compareValues(
                lhs.continuousIODurationMilliseconds,
                rhs.continuousIODurationMilliseconds
            )
        }
    }

    private static func compareValues<T: Comparable>(
        _ lhs: T,
        _ rhs: T
    ) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func totalBytes(_ application: RealtimeApplication) -> UInt64 {
        let result = application.runReadBytes.addingReportingOverflow(
            application.runWriteBytes
        )
        return result.overflow ? .max : result.partialValue
    }

    private static func stableIdentityComparison(
        _ lhs: RealtimeApplication,
        _ rhs: RealtimeApplication
    ) -> ComparisonResult {
        let displayNameComparison = lhs.displayName.localizedStandardCompare(
            rhs.displayName
        )
        guard displayNameComparison == .orderedSame else {
            return displayNameComparison
        }
        return lhs.applicationID.localizedStandardCompare(rhs.applicationID)
    }
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
