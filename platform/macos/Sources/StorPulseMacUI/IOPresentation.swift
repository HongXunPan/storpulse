import Foundation

public enum ApplicationSort: String, CaseIterable, Identifiable, Sendable {
    case current = "当前速度"
    case recentAverage = "一分钟均值"
    case runTotal = "本次累计"
    case duration = "持续时长"

    public var id: String { rawValue }
}

public enum IOPresentation {
    public static func sorted(
        _ applications: [RealtimeApplication],
        by sort: ApplicationSort
    ) -> [RealtimeApplication] {
        applications.sorted { lhs, rhs in
            switch sort {
            case .current:
                return totalRate(lhs.current) > totalRate(rhs.current)
            case .recentAverage:
                return totalRate(lhs.averageLastMinute) > totalRate(rhs.averageLastMinute)
            case .runTotal:
                return lhs.runReadBytes + lhs.runWriteBytes
                    > rhs.runReadBytes + rhs.runWriteBytes
            case .duration:
                return lhs.continuousIODurationMilliseconds
                    > rhs.continuousIODurationMilliseconds
            }
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
}

private extension Int64 {
    init(clamping value: UInt64) {
        self = value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
