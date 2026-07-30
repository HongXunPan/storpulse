import Foundation
import StorPulseMacAdapter

public protocol SnapshotSource: Sendable {
    func collect() async -> RawSnapshot
}

public struct MacOSSnapshotSource: SnapshotSource {
    public init() {}

    public func collect() async -> RawSnapshot {
        let snapshot = await Task.detached(priority: .utility) {
            MacOSCollector().collect()
        }.value
        return await MainActor.run {
            ApplicationMetadataEnricher().enrich(snapshot)
        }
    }
}
