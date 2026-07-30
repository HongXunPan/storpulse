import Foundation

public enum RetentionPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case oneDay = "24 小时"
    case sevenDays = "7 天"
    case thirtyDays = "30 天"

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }
}

public struct ReminderConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var readThresholdBytesPerSecond: Double
    public var writeThresholdBytesPerSecond: Double
    public var minimumDurationSeconds: Double
    public var cooldownSeconds: Double

    public init(
        enabled: Bool = false,
        readThresholdBytesPerSecond: Double = 0,
        writeThresholdBytesPerSecond: Double = 0,
        minimumDurationSeconds: Double = 0,
        cooldownSeconds: Double = 0
    ) {
        self.enabled = enabled
        self.readThresholdBytesPerSecond = readThresholdBytesPerSecond
        self.writeThresholdBytesPerSecond = writeThresholdBytesPerSecond
        self.minimumDurationSeconds = minimumDurationSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    public var hasExplicitThresholds: Bool {
        readThresholdBytesPerSecond > 0
            && writeThresholdBytesPerSecond > 0
            && minimumDurationSeconds > 0
            && cooldownSeconds > 0
    }
}

public struct HistorySettings: Codable, Equatable, Sendable {
    public var historyEnabled: Bool
    public var retention: RetentionPeriod
    public var reminder: ReminderConfiguration

    public init(
        historyEnabled: Bool = false,
        retention: RetentionPeriod = .sevenDays,
        reminder: ReminderConfiguration = ReminderConfiguration()
    ) {
        self.historyEnabled = historyEnabled
        self.retention = retention
        self.reminder = reminder
    }
}

public struct MinuteBucketRecord: Codable, Equatable, Sendable {
    public let bucketStartedAt: String
    public let applicationID: String?
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let peak: IORate
    public let metricSource: String
    public let completeness: String

    public init(
        bucketStartedAt: String,
        applicationID: String?,
        readBytes: UInt64,
        writeBytes: UInt64,
        peak: IORate,
        metricSource: String,
        completeness: String
    ) {
        self.bucketStartedAt = bucketStartedAt
        self.applicationID = applicationID
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.peak = peak
        self.metricSource = metricSource
        self.completeness = completeness
    }
}

public struct HistoryCounts: Equatable, Sendable {
    public let minuteBuckets: Int
    public let activities: Int
    public let observationSessions: Int

    public static let empty = HistoryCounts(
        minuteBuckets: 0,
        activities: 0,
        observationSessions: 0
    )
}

struct HistoryWriteBatch: Sendable {
    var minuteBuckets: [MinuteBucketRecord] = []
    var activities: [ActivitySummary] = []
    var observationSessions: [ObservationSession] = []
    var settings: HistorySettings?

    var isEmpty: Bool {
        minuteBuckets.isEmpty
            && activities.isEmpty
            && observationSessions.isEmpty
            && settings == nil
    }
}

public struct HistoryExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let minuteBuckets: [ExportedMinuteBucket]
    public let activities: [ExportedActivity]
    public let observationSessions: [ExportedObservationSession]
}

public struct ExportedMinuteBucket: Codable, Equatable, Sendable {
    public let bucketStartedAt: String
    public let applicationID: String?
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let metricSource: String
    public let completeness: String
}

public struct ExportedActivity: Codable, Equatable, Sendable {
    public let applicationID: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
}

public struct ExportedObservationSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let completeness: String
    public let topApplicationIDs: [String]
}
