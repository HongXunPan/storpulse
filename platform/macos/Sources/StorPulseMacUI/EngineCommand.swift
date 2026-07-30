import Foundation

public enum EngineCommand: Encodable, Equatable, Sendable {
    case startObservation(sessionID: String, startedAt: String, monotonicNanoseconds: UInt64)
    case stopObservation(endedAt: String, monotonicNanoseconds: UInt64)

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "sessionId"
        case startedAt
        case endedAt
        case monotonicNanoseconds
    }

    private enum Kind: String, Encodable {
        case startObservation = "start_observation"
        case stopObservation = "stop_observation"
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
        }
    }
}
