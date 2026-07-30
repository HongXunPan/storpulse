import Dispatch
import Foundation

public struct MacOSCollector: Sendable {
    private let processCollector: ProcessCollector
    private let deviceCollector: DeviceCollector

    public init(
        processCollector: ProcessCollector = ProcessCollector(),
        deviceCollector: DeviceCollector = DeviceCollector()
    ) {
        self.processCollector = processCollector
        self.deviceCollector = deviceCollector
    }

    public func collect() -> RawSnapshot {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let capturedAt = Date()
        let processes = processCollector.collect()
        let devices = deviceCollector.collect()
        let finishedAt = DispatchTime.now().uptimeNanoseconds

        let completeness: Completeness
        if processes.samples.isEmpty && devices.isEmpty {
            completeness = .unsupported
        } else if processes.restrictedCount > 0 {
            completeness = .restricted
        } else if processes.exitedCount > 0 || devices.isEmpty {
            completeness = .partial
        } else {
            completeness = .complete
        }

        return RawSnapshot(
            capturedAt: capturedAt,
            monotonicNanoseconds: startedAt,
            freshness: processes.samples.isEmpty && devices.isEmpty ? .failed : .fresh,
            completeness: completeness,
            processes: processes.samples,
            devices: devices,
            summary: CollectionSummary(
                discoveredProcesses: processes.discoveredCount,
                readableProcesses: processes.samples.count,
                restrictedProcesses: processes.restrictedCount,
                exitedProcesses: processes.exitedCount,
                deviceCount: devices.count,
                collectionDurationNanoseconds: finishedAt - startedAt
            )
        )
    }
}

public enum SnapshotEncoder {
    public static func encode(_ snapshot: RawSnapshot, prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}
