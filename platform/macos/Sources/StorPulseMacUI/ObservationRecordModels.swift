import Foundation

public struct ObservationRecord: Equatable, Identifiable, Sendable {
    public let session: ObservationSession
    public private(set) var name: String

    public var id: String { session.sessionID }

    public init(name: String, session: ObservationSession) {
        self.session = session
        self.name = Self.normalizedName(
            name,
            fallback: Self.defaultName(startedAt: session.startedAt)
        )
    }

    public func renamed(to candidate: String) -> ObservationRecord {
        ObservationRecord(
            name: Self.normalizedName(candidate, fallback: name),
            session: session
        )
    }

    public var summary: ObservationRecordSummary {
        ObservationRecordSummary(
            sessionID: session.sessionID,
            name: name,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationMilliseconds: session.durationMilliseconds,
            readBytes: session.readBytes,
            writeBytes: session.writeBytes,
            peak: session.peak,
            completeness: session.completeness,
            topApplications: session.topApplications.map {
                ObservationRecordApplicationSummary(
                    applicationID: $0.applicationID,
                    displayName: $0.displayName,
                    readBytes: $0.readBytes,
                    writeBytes: $0.writeBytes
                )
            }
        )
    }

    public static func defaultName(at date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents(
            [.month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "区间记录 %02d-%02d %02d:%02d:%02d",
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    public static func normalizedName(
        _ candidate: String,
        fallback: String
    ) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        return String(resolved.prefix(80))
    }

    private static func defaultName(startedAt: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: startedAt) else {
            return "未命名记录"
        }
        return defaultName(at: date)
    }
}

public struct ObservationRecordSummary: Equatable, Identifiable, Sendable {
    public let sessionID: String
    public let name: String
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64
    public let peak: IORate
    public let completeness: String
    public let topApplications: [ObservationRecordApplicationSummary]

    public var id: String { sessionID }
}

public struct ObservationRecordApplicationSummary: Equatable, Identifiable, Sendable {
    public let applicationID: String
    public let displayName: String
    public let readBytes: UInt64?
    public let writeBytes: UInt64?

    public var id: String { applicationID }
}
