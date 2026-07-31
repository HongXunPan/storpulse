import Foundation
import StorPulseMacAdapter
@testable import StorPulseMacUI
import Testing

@MainActor
@Test("区间记录自动命名且结束后可直接改名")
func observationRecordingIsNamedAndRenamed() async {
    let session = observationSessionFixture()
    let observer = ObservationRecordingObserver()
    let monitor = RealtimeMonitor(
        engine: ObservationRecordingEngine(session: session),
        source: ObservationRecordingSnapshotSource(),
        observers: [observer]
    )

    await monitor.startObservation()
    let activeName = monitor.activeObservationName
    #expect(activeName?.hasPrefix("区间记录 ") == true)

    let completed = await monitor.stopObservation()

    #expect(completed?.session == session)
    #expect(completed?.name == activeName)
    #expect(monitor.completedObservationRecord == completed)
    #expect(monitor.observationRecords == [completed])
    let observedRecords = await observer.completedRecords()
    #expect(observedRecords == [completed])

    let renamed = await monitor.renameObservationRecord(
        sessionID: session.sessionID,
        name: "  下载依赖  "
    )
    #expect(renamed)
    #expect(monitor.completedObservationRecord?.name == "下载依赖")
    #expect(await observer.renamedRecords() == [session.sessionID: "下载依赖"])

    monitor.dismissCompletedObservationRecord()
    #expect(monitor.completedObservationRecord == nil)
}

private actor ObservationRecordingEngine: StorPulseEngineClient {
    let session: ObservationSession

    init(session: ObservationSession) {
        self.session = session
    }

    func ingest(_: RawSnapshot) async throws {}

    func snapshot(at _: UInt64) async throws -> RealtimeSnapshot {
        RealtimeSnapshot(
            schemaVersion: 1,
            capturedAt: "2026-07-31T07:00:10Z",
            monotonicNanoseconds: 10_000_000_000,
            metricSource: "fixture",
            metricScope: ["device"],
            freshness: "fresh",
            completeness: "complete",
            devices: [],
            applications: [],
            processes: [],
            summary: RealtimeSummary(
                discoveredProcesses: 0,
                readableProcesses: 0,
                restrictedProcesses: 0,
                exitedProcesses: 0,
                collectionDurationNanoseconds: 1,
                lastSuccessfulSampleAt: "2026-07-31T07:00:10Z"
            ),
            activeObservationSession: nil
        )
    }

    func execute(_ command: EngineCommand) async throws -> EngineCommandResponse {
        switch command {
        case .stopObservation:
            .observationStopped(session)
        default:
            .accepted
        }
    }
}

private actor ObservationRecordingObserver: RealtimeSnapshotObserver {
    private var records: [ObservationRecord] = []
    private var renamed: [String: String] = [:]

    func realtimeSnapshotProduced(_: RealtimeSnapshot) async {}

    func observationRecordEnded(_ record: ObservationRecord) async {
        records.append(record)
    }

    func observationRecordRenamed(sessionID: String, name: String) async {
        renamed[sessionID] = name
    }

    func completedRecords() -> [ObservationRecord] {
        records
    }

    func renamedRecords() -> [String: String] {
        renamed
    }
}

private struct ObservationRecordingSnapshotSource: SnapshotSource {
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

private func observationSessionFixture() -> ObservationSession {
    ObservationSession(
        sessionID: "recording-1",
        startedAt: "2026-07-31T07:00:00Z",
        endedAt: "2026-07-31T07:00:10Z",
        durationMilliseconds: 10_000,
        readBytes: 4_096,
        writeBytes: 8_192,
        peak: IORate(
            readBytesPerSecond: 1_024,
            writeBytesPerSecond: 2_048
        ),
        topApplications: [
            ApplicationContribution(
                applicationID: "com.example.editor",
                displayName: "编辑器",
                readBytes: 4_096,
                writeBytes: 8_192
            ),
        ],
        completeness: "complete"
    )
}
