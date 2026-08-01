import Foundation
import StorPulseMacAdapter
@testable import StorPulseMacUI

actor MemoryHistoryPreferences: HistoryPreferences {
    private var settings: HistorySettings

    init(settings: HistorySettings = HistorySettings()) {
        self.settings = settings
    }

    func load() async -> HistorySettings {
        settings
    }

    func save(_ settings: HistorySettings) async {
        self.settings = settings
    }
}

actor RecordingReminderService: ReminderDelivering {
    private(set) var delivered: [ActivitySummary] = []
    let authorizationGranted: Bool

    init(authorizationGranted: Bool = true) {
        self.authorizationGranted = authorizationGranted
    }

    func requestAuthorization() async throws -> Bool {
        authorizationGranted
    }

    func deliver(activity: ActivitySummary) async throws {
        delivered.append(activity)
    }

    func deliveredCount() -> Int {
        delivered.count
    }
}

actor HistoryFixtureEngine: StorPulseEngineClient {
    private var activityResponses: [[ActivitySummary]] = []
    private(set) var configuredPolicies: [ActivityPolicy] = []

    func enqueueActivities(_ activities: [ActivitySummary]) {
        activityResponses.append(activities)
    }

    func ingest(_: RawSnapshot) async throws {}

    func snapshot(at _: UInt64) async throws -> RealtimeSnapshot {
        historySnapshot(
            capturedAt: "2026-07-30T10:00:00Z",
            runReadBytes: 0,
            runWriteBytes: 0
        )
    }

    func execute(_ command: EngineCommand) async throws -> EngineCommandResponse {
        switch command {
        case let .configureActivity(policy):
            configuredPolicies.append(policy)
            return .accepted
        case .drainCompletedActivities:
            return .completedActivities(
                activityResponses.isEmpty ? [] : activityResponses.removeFirst()
            )
        case .startObservation, .stopObservation:
            return .accepted
        }
    }
}

func historyTestDatabaseURL(_ name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: ".codex-tmp/history-tests")
        .appending(path: "\(name)-\(UUID().uuidString)")
        .appending(path: "history.sqlite3")
}

func historySnapshot(
    capturedAt: String,
    runReadBytes: UInt64,
    runWriteBytes: UInt64,
    currentRead: Double = 100,
    currentWrite: Double = 200
) -> RealtimeSnapshot {
    let rate = IORate(
        readBytesPerSecond: currentRead,
        writeBytesPerSecond: currentWrite
    )
    let identity = RealtimeProcessIdentity(pid: 42, startTimeTicks: 9)
    return RealtimeSnapshot(
        schemaVersion: RealtimeSnapshot.schemaVersion,
        capturedAt: capturedAt,
        monotonicNanoseconds: 1,
        metricSource: "fixture.storage",
        metricScope: ["device", "storage_process"],
        freshness: "fresh",
        completeness: "complete",
        devices: [
            RealtimeDevice(
                deviceID: "macos:ioreg:7",
                current: rate,
                runReadBytes: runReadBytes,
                runWriteBytes: runWriteBytes
            ),
        ],
        applications: [
            RealtimeApplication(
                applicationID: "com.example.editor",
                displayName: "编辑器",
                processCount: 1,
                helperCount: 0,
                current: rate,
                averageLastMinute: rate,
                runReadBytes: runReadBytes,
                runWriteBytes: runWriteBytes,
                continuousIODurationMilliseconds: 1_000,
                processIdentities: [identity]
            ),
        ],
        processes: [],
        summary: RealtimeSummary(
            discoveredProcesses: 1,
            readableProcesses: 1,
            restrictedProcesses: 0,
            exitedProcesses: 0,
            collectionDurationNanoseconds: 1,
            lastSuccessfulSampleAt: capturedAt
        ),
        activeObservationSession: nil
    )
}

func historyActivity(
    endedAt: String,
    applicationID: String = "com.example.editor"
) -> ActivitySummary {
    ActivitySummary(
        applicationID: applicationID,
        displayName: "编辑器 /Users/example/private",
        startedAt: "2026-07-30T10:00:00Z",
        endedAt: endedAt,
        durationMilliseconds: 10_000,
        readBytes: 1_000,
        writeBytes: 2_000,
        peak: IORate(readBytesPerSecond: 100, writeBytesPerSecond: 200)
    )
}

func historySession() -> ObservationSession {
    ObservationSession(
        sessionID: "session-1",
        startedAt: "2026-07-30T10:00:00Z",
        endedAt: "2026-07-30T10:05:00Z",
        durationMilliseconds: 300_000,
        readBytes: 10_000,
        writeBytes: 20_000,
        peak: IORate(readBytesPerSecond: 1_000, writeBytesPerSecond: 2_000),
        topApplications: [
            ApplicationContribution(
                applicationID: "com.example.editor",
                displayName: "编辑器",
                readBytes: 10_000,
                writeBytes: 20_000
            ),
        ],
        completeness: "complete"
    )
}

func enabledHistorySettings(reminderEnabled: Bool = false) -> HistorySettings {
    HistorySettings(
        historyEnabled: true,
        retention: .sevenDays,
        reminder: ReminderConfiguration(
            enabled: reminderEnabled,
            readThresholdBytesPerSecond: reminderEnabled ? 1_000 : 0,
            writeThresholdBytesPerSecond: reminderEnabled ? 2_000 : 0,
            minimumDurationSeconds: reminderEnabled ? 5 : 0,
            cooldownSeconds: reminderEnabled ? 60 : 0
        )
    )
}
