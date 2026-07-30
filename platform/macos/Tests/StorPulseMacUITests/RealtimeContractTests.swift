import Foundation
import StorPulseMacAdapter
@testable import StorPulseMacUI
import Testing

@Test("Rust 实时快照可以按版本化契约解码")
func realtimeSnapshotDecoding() throws {
    let data = Data(fixtureJSON.utf8)
    let snapshot = try JSONDecoder().decode(RealtimeSnapshot.self, from: data)

    #expect(snapshot.schemaVersion == 1)
    #expect(snapshot.deviceRate?.writeBytesPerSecond == 2_048)
    #expect(snapshot.applications.first?.applicationID == "com.example.editor")
    #expect(snapshot.processes.first?.identity.pid == 42)
    #expect(snapshot.activeObservationSession?.sessionID == "session-1")
}

@Test("应用排序分别遵守当前速度和累计量")
func applicationSorting() throws {
    let snapshot = try JSONDecoder().decode(
        RealtimeSnapshot.self,
        from: Data(fixtureJSON.utf8)
    )
    let lowCurrent = RealtimeApplication(
        applicationID: "com.example.archive",
        displayName: "归档器",
        processCount: 1,
        helperCount: 0,
        current: IORate(readBytesPerSecond: 1, writeBytesPerSecond: 1),
        averageLastMinute: nil,
        runReadBytes: 999_999,
        runWriteBytes: 999_999,
        continuousIODurationMilliseconds: 1,
        processIdentities: []
    )
    let applications = snapshot.applications + [lowCurrent]

    #expect(IOPresentation.sorted(applications, by: .current).first?.applicationID == "com.example.editor")
    #expect(IOPresentation.sorted(applications, by: .runTotal).first?.applicationID == "com.example.archive")
}

@MainActor
@Test("连续失败进入 stale 且不再信任旧速率")
func staleAfterConsecutiveFailures() async {
    let source = FixtureSnapshotSource()
    let engine = SequencedEngineClient()
    let monitor = RealtimeMonitor(engine: engine, source: source)

    await monitor.sampleOnce()
    #expect(monitor.samplingState == .live)
    #expect(monitor.ratesAreTrustworthy)

    await engine.failFollowingIngests()
    await monitor.sampleOnce()
    #expect(monitor.samplingState == .interrupted(missedSamples: 1))
    #expect(!monitor.ratesAreTrustworthy)
    await monitor.sampleOnce()
    await monitor.sampleOnce()
    #expect(monitor.samplingState == .stale)
    #expect(!monitor.ratesAreTrustworthy)
}

@Test("动态引擎路径支持环境变量和祖先目录查找")
func engineLibraryResolution() throws {
    let explicit = RustEngineClient.defaultLibraryURL(
        environment: ["STORPULSE_ENGINE_LIBRARY": "/example/libengine.dylib"]
    )
    #expect(explicit.path == "/example/libengine.dylib")

    let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let nested = repositoryRoot.appending(path: "platform/macos")
    let resolved = RustEngineClient.defaultLibraryURL(
        environment: [:],
        currentDirectoryURL: nested
    )
    #expect(resolved.lastPathComponent == "libstorpulse_ffi.dylib")
}

@Test("Swift 通过 C 桥摄入快照并取得 Rust 实时结果")
func rustBridgeRoundTrip() async throws {
    let engine = try RustEngineClient()
    let first = fixtureRawSnapshot(
        monotonicNanoseconds: 1_000_000_000,
        readBytes: 1_000,
        writeBytes: 2_000
    )
    let second = fixtureRawSnapshot(
        monotonicNanoseconds: 2_000_000_000,
        readBytes: 5_096,
        writeBytes: 10_192
    )

    try await engine.ingest(first)
    try await engine.ingest(second)
    let snapshot = try await engine.snapshot(at: 2_000_000_001)

    #expect(snapshot.applications.first?.current?.readBytesPerSecond == 4_096)
    #expect(snapshot.applications.first?.current?.writeBytesPerSecond == 8_192)
}

private struct FixtureSnapshotSource: SnapshotSource {
    func collect() async -> RawSnapshot {
        RawSnapshot(
            capturedAt: Date(timeIntervalSince1970: 0),
            monotonicNanoseconds: 1,
            freshness: .fresh,
            completeness: .complete,
            processes: [],
            devices: [],
            summary: CollectionSummary(
                discoveredProcesses: 0,
                readableProcesses: 0,
                restrictedProcesses: 0,
                exitedProcesses: 0,
                deviceCount: 0,
                collectionDurationNanoseconds: 1
            )
        )
    }
}

private actor SequencedEngineClient: StorPulseEngineClient {
    private var shouldFail = false

    func failFollowingIngests() {
        shouldFail = true
    }

    func ingest(_: RawSnapshot) async throws {
        if shouldFail { throw FixtureError.failed }
    }

    func snapshot(at _: UInt64) async throws -> RealtimeSnapshot {
        try JSONDecoder().decode(RealtimeSnapshot.self, from: Data(fixtureJSON.utf8))
    }

    func execute(_: EngineCommand) async throws -> EngineCommandResponse {
        .accepted
    }
}

private enum FixtureError: Error {
    case failed
}

private func fixtureRawSnapshot(
    monotonicNanoseconds: UInt64,
    readBytes: UInt64,
    writeBytes: UInt64
) -> RawSnapshot {
    RawSnapshot(
        capturedAt: Date(timeIntervalSince1970: Double(monotonicNanoseconds) / 1_000_000_000),
        monotonicNanoseconds: monotonicNanoseconds,
        freshness: .fresh,
        completeness: .complete,
        processes: [
            ProcessIOSample(
                identity: ProcessIdentity(pid: 42, startTimeTicks: 9),
                parentPID: 1,
                executableName: "Editor",
                applicationID: "com.example.editor",
                applicationName: "编辑器",
                readBytes: readBytes,
                writeBytes: writeBytes,
                userTimeNanoseconds: 0,
                systemTimeNanoseconds: 0,
                residentBytes: 0,
                physicalFootprintBytes: 0
            ),
        ],
        devices: [],
        summary: CollectionSummary(
            discoveredProcesses: 1,
            readableProcesses: 1,
            restrictedProcesses: 0,
            exitedProcesses: 0,
            deviceCount: 0,
            collectionDurationNanoseconds: 1
        )
    )
}

private let fixtureJSON = """
{
  "schemaVersion": 1,
  "capturedAt": "2026-07-30T10:00:00Z",
  "monotonicNanoseconds": 2000000000,
  "metricSource": "fixture",
  "metricScope": ["device", "storage_process"],
  "freshness": "fresh",
  "completeness": "restricted",
  "devices": [{
    "registryEntryId": 7,
    "current": {"readBytesPerSecond": 1024, "writeBytesPerSecond": 2048},
    "runReadBytes": 4096,
    "runWriteBytes": 8192
  }],
  "applications": [{
    "applicationId": "com.example.editor",
    "displayName": "编辑器",
    "processCount": 1,
    "helperCount": 0,
    "current": {"readBytesPerSecond": 100, "writeBytesPerSecond": 200},
    "averageLastMinute": {"readBytesPerSecond": 50, "writeBytesPerSecond": 75},
    "runReadBytes": 1000,
    "runWriteBytes": 2000,
    "continuousIoDurationMilliseconds": 3000,
    "processIdentities": [{"pid": 42, "startTimeTicks": 99}]
  }],
  "processes": [{
    "identity": {"pid": 42, "startTimeTicks": 99},
    "parentPid": 1,
    "executableName": "Editor",
    "applicationId": "com.example.editor",
    "applicationName": "编辑器",
    "isHelper": false,
    "launchedByApplicationId": null,
    "current": {"readBytesPerSecond": 100, "writeBytesPerSecond": 200},
    "averageLastMinute": {"readBytesPerSecond": 50, "writeBytesPerSecond": 75},
    "runReadBytes": 1000,
    "runWriteBytes": 2000,
    "continuousIoDurationMilliseconds": 3000,
    "physicalFootprintBytes": 4096
  }],
  "summary": {
    "discoveredProcesses": 10,
    "readableProcesses": 8,
    "restrictedProcesses": 2,
    "exitedProcesses": 0,
    "collectionDurationNanoseconds": 1000,
    "lastSuccessfulSampleAt": "2026-07-30T10:00:00Z"
  },
  "activeObservationSession": {
    "sessionId": "session-1",
    "startedAt": "2026-07-30T10:00:00Z",
    "durationMilliseconds": 1000,
    "readBytes": 100,
    "writeBytes": 200,
    "peakReadBytesPerSecond": 100,
    "peakWriteBytesPerSecond": 200
  }
}
"""
