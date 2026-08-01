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
                applicationID: "com.example.editor",
                applicationName: "编辑器",
                launchedByApplicationID: "com.example.launcher",
                readBytes: 100,
                writeBytes: 200,
                userTimeNanoseconds: 10,
                systemTimeNanoseconds: 20,
                residentBytes: 300,
                physicalFootprintBytes: 400
            ),
        ],
        devices: [
            DeviceIOSample(
                deviceID: "macos:ioreg:7",
                readBytes: 500,
                writeBytes: 600,
                readOperations: 5,
                writeOperations: 6
            ),
        ],
        summary: CollectionSummary(
            discoveredProcesses: 1,
            readableProcesses: 1,
            restrictedProcesses: 0,
            exitedProcesses: 0,
            deviceCount: 1,
            collectionDurationNanoseconds: 20
        )
    )

    let data = try SnapshotEncoder.encode(snapshot)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\":2"))
    #expect(text.contains("\"parentPid\":1"))
    #expect(text.contains("\"applicationId\":\"com.example.editor\""))
    #expect(text.contains("\"launchedByApplicationId\":\"com.example.launcher\""))
    #expect(text.contains("\"deviceId\":\"macos:ioreg:7\""))
    #expect(!text.contains("\"parentPID\""))
    #expect(!text.contains("\"applicationID\""))
    #expect(!text.contains("\"launchedByApplicationID\""))
    #expect(!text.contains("registryEntryId"))
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
