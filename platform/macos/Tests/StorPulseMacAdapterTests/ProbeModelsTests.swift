import Foundation
import Testing
@testable import StorPulseMacAdapter

@Test("快照编码不包含敏感字段")
func snapshotEncodingExcludesSensitiveFields() throws {
    let snapshot = RawSnapshot(
        capturedAt: Date(timeIntervalSince1970: 0),
        monotonicNanoseconds: 10,
        freshness: .fresh,
        completeness: .partial,
        processes: [
            ProcessIOSample(
                identity: ProcessIdentity(pid: 42, startTimeTicks: 9),
                parentPID: 1,
                executableName: "示例进程",
                readBytes: 100,
                writeBytes: 200,
                userTimeNanoseconds: 10,
                systemTimeNanoseconds: 20,
                residentBytes: 300,
                physicalFootprintBytes: 400
            ),
        ],
        devices: [],
        summary: CollectionSummary(
            discoveredProcesses: 1,
            readableProcesses: 1,
            restrictedProcesses: 0,
            exitedProcesses: 0,
            deviceCount: 0,
            collectionDurationNanoseconds: 20
        )
    )

    let data = try SnapshotEncoder.encode(snapshot)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\":1"))
    #expect(!text.contains("path"))
    #expect(!text.contains("command"))
    #expect(!text.contains("username"))
}

@Test("当前进程拥有稳定身份并能被采集")
func liveCollectorIncludesCurrentProcess() {
    let snapshot = MacOSCollector().collect()
    let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
    let current = snapshot.processes.first { $0.identity.pid == currentPID }

    #expect(snapshot.schemaVersion == RawSnapshot.schemaVersion)
    #expect(snapshot.freshness == .fresh)
    #expect(current != nil)
    #expect(current?.identity.startTimeTicks ?? 0 > 0)
    #expect(snapshot.summary.readableProcesses > 0)
}
