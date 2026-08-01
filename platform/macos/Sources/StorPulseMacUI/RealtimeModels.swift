import Foundation

public struct IORate: Codable, Equatable, Sendable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
    }
}

public struct RealtimeDevice: Codable, Equatable, Sendable {
    public let deviceID: String
    public let current: IORate?
    public let runReadBytes: UInt64
    public let runWriteBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case current
        case runReadBytes
        case runWriteBytes
    }
}

public struct RealtimeApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: String { applicationID }

    public let applicationID: String
    public let displayName: String
    public let processCount: Int
    public let helperCount: Int
    public let current: IORate?
    public let averageLastMinute: IORate?
    public let runReadBytes: UInt64
    public let runWriteBytes: UInt64
    public let continuousIODurationMilliseconds: UInt64
    public let processIdentities: [RealtimeProcessIdentity]

    private enum CodingKeys: String, CodingKey {
        case applicationID = "applicationId"
        case displayName
        case processCount
        case helperCount
        case current
        case averageLastMinute
        case runReadBytes
        case runWriteBytes
        case continuousIODurationMilliseconds = "continuousIoDurationMilliseconds"
        case processIdentities
    }
}

public struct RealtimeProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startTimeTicks: UInt64
}

public struct RealtimeProcess: Codable, Equatable, Identifiable, Sendable {
    public var id: RealtimeProcessIdentity { identity }

    public let identity: RealtimeProcessIdentity
    public let parentPID: Int32?
    public let executableName: String
    public let applicationID: String
    public let applicationName: String
    public let isHelper: Bool
    public let launchedByApplicationID: String?
    public let current: IORate?
    public let averageLastMinute: IORate?
    public let runReadBytes: UInt64
    public let runWriteBytes: UInt64
    public let continuousIODurationMilliseconds: UInt64
    public let physicalFootprintBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case identity
        case parentPID = "parentPid"
        case executableName
        case applicationID = "applicationId"
        case applicationName
        case isHelper
        case launchedByApplicationID = "launchedByApplicationId"
        case current
        case averageLastMinute
        case runReadBytes
        case runWriteBytes
        case continuousIODurationMilliseconds = "continuousIoDurationMilliseconds"
        case physicalFootprintBytes
    }
}

public struct RealtimeSummary: Codable, Equatable, Sendable {
    public let discoveredProcesses: Int
    public let readableProcesses: Int
    public let restrictedProcesses: Int
    public let exitedProcesses: Int
    public let collectionDurationNanoseconds: UInt64
    public let lastSuccessfulSampleAt: String
}

public struct ObservationSessionProgress: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let peakReadBytesPerSecond: Double
    public let peakWriteBytesPerSecond: Double

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case startedAt
        case durationMilliseconds
        case readBytes
        case writeBytes
        case peakReadBytesPerSecond
        case peakWriteBytesPerSecond
    }
}

public struct RealtimeSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let capturedAt: String
    public let monotonicNanoseconds: UInt64
    public let metricSource: String
    public let metricScope: [String]
    public let freshness: String
    public let completeness: String
    public let devices: [RealtimeDevice]
    public let applications: [RealtimeApplication]
    public let processes: [RealtimeProcess]
    public let summary: RealtimeSummary
    public let activeObservationSession: ObservationSessionProgress?

    public var deviceRate: IORate? {
        let current = devices.compactMap(\.current)
        guard !current.isEmpty else { return nil }
        return IORate(
            readBytesPerSecond: current.reduce(0) { $0 + $1.readBytesPerSecond },
            writeBytesPerSecond: current.reduce(0) { $0 + $1.writeBytesPerSecond }
        )
    }
}

public struct ApplicationContribution: Codable, Equatable, Sendable {
    public let applicationID: String
    public let displayName: String
    public let readBytes: UInt64
    public let writeBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case applicationID = "applicationId"
        case displayName
        case readBytes
        case writeBytes
    }
}

public struct ObservationSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let peak: IORate
    public let topApplications: [ApplicationContribution]
    public let completeness: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case startedAt
        case endedAt
        case durationMilliseconds
        case readBytes
        case writeBytes
        case peak
        case topApplications
        case completeness
    }
}

public struct ActivitySummary: Codable, Equatable, Sendable {
    public let applicationID: String
    public let displayName: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let peak: IORate

    private enum CodingKeys: String, CodingKey {
        case applicationID = "applicationId"
        case displayName
        case startedAt
        case endedAt
        case durationMilliseconds
        case readBytes
        case writeBytes
        case peak
    }
}

public enum EngineCommandResponse: Codable, Equatable, Sendable {
    case accepted
    case observationStopped(ObservationSession)
    case completedActivities([ActivitySummary])

    private enum CodingKeys: String, CodingKey {
        case type
        case session
        case activities
    }

    private enum Kind: String, Codable {
        case accepted
        case observationStopped = "observation_stopped"
        case completedActivities = "completed_activities"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .accepted:
            self = .accepted
        case .observationStopped:
            self = .observationStopped(
                try container.decode(ObservationSession.self, forKey: .session)
            )
        case .completedActivities:
            self = .completedActivities(
                try container.decode([ActivitySummary].self, forKey: .activities)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accepted:
            try container.encode(Kind.accepted, forKey: .type)
        case let .observationStopped(session):
            try container.encode(Kind.observationStopped, forKey: .type)
            try container.encode(session, forKey: .session)
        case let .completedActivities(activities):
            try container.encode(Kind.completedActivities, forKey: .type)
            try container.encode(activities, forKey: .activities)
        }
    }
}
