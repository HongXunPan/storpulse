import Foundation

public enum EngineCommand: Encodable, Equatable, Sendable {
    case startObservation(sessionID: String, startedAt: String, monotonicNanoseconds: UInt64)
    case stopObservation(endedAt: String, monotonicNanoseconds: UInt64)
    case configureActivity(ActivityPolicy)
    case drainCompletedActivities

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case startedAt
        case endedAt
        case monotonicNanoseconds
        case policy
    }

    private enum Kind: String, Encodable {
        case startObservation = "start_observation"
        case stopObservation = "stop_observation"
        case configureActivity = "configure_activity"
        case drainCompletedActivities = "drain_completed_activities"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .startObservation(sessionID, startedAt, monotonicNanoseconds):
            try container.encode(Kind.startObservation, forKey: .type)
            try container.encode(sessionID, forKey: .sessionID)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encode(monotonicNanoseconds, forKey: .monotonicNanoseconds)
        case let .stopObservation(endedAt, monotonicNanoseconds):
            try container.encode(Kind.stopObservation, forKey: .type)
            try container.encode(endedAt, forKey: .endedAt)
            try container.encode(monotonicNanoseconds, forKey: .monotonicNanoseconds)
        case let .configureActivity(policy):
            try container.encode(Kind.configureActivity, forKey: .type)
            try container.encode(policy, forKey: .policy)
        case .drainCompletedActivities:
            try container.encode(Kind.drainCompletedActivities, forKey: .type)
        }
    }
}

public struct ActivityPolicy: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let readThresholdBytesPerSecond: Double
    public let writeThresholdBytesPerSecond: Double
    public let minimumDurationMilliseconds: UInt64

    public init(
        enabled: Bool,
        readThresholdBytesPerSecond: Double,
        writeThresholdBytesPerSecond: Double,
        minimumDurationMilliseconds: UInt64
    ) {
        self.enabled = enabled
        self.readThresholdBytesPerSecond = readThresholdBytesPerSecond
        self.writeThresholdBytesPerSecond = writeThresholdBytesPerSecond
        self.minimumDurationMilliseconds = minimumDurationMilliseconds
    }
}
