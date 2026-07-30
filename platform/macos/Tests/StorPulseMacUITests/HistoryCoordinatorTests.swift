import Foundation
@testable import StorPulseMacUI
import Testing

@Test("历史默认关闭且启动时不创建数据库")
func historyDisabledDoesNotCreateDatabase() async {
    let databaseURL = historyTestDatabaseURL("disabled")
    let coordinator = HistoryCoordinator(
        databaseURL: databaseURL,
        engine: HistoryFixtureEngine(),
        preferences: MemoryHistoryPreferences(),
        reminderService: RecordingReminderService()
    )

    await coordinator.bootstrap()

    #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    #expect((try? await coordinator.counts()) == .empty)
}

@Test("启用后分钟桶只在显式刷新时批量写入")
func minuteBucketsFlushAsBatch() async throws {
    let databaseURL = historyTestDatabaseURL("batch")
    let coordinator = HistoryCoordinator(
        databaseURL: databaseURL,
        engine: HistoryFixtureEngine(),
        preferences: MemoryHistoryPreferences(),
        reminderService: RecordingReminderService()
    )
    await coordinator.bootstrap()
    try await coordinator.updateSettings(enabledHistorySettings())

    await coordinator.realtimeSnapshotProduced(
        historySnapshot(capturedAt: "2026-07-30T10:00:00Z", runReadBytes: 1_000, runWriteBytes: 2_000)
    )
    await coordinator.realtimeSnapshotProduced(
        historySnapshot(capturedAt: "2026-07-30T10:00:01Z", runReadBytes: 5_096, runWriteBytes: 10_192)
    )
    #expect(try await coordinator.counts() == .empty)

    try await coordinator.flushForTermination()
    let counts = try await coordinator.counts()
    #expect(counts.minuteBuckets == 2)
    #expect(FileManager.default.fileExists(atPath: databaseURL.path))
}

@Test("提醒必须完整配置并按应用执行冷却")
func remindersRequireConfigurationAndCooldown() async throws {
    let engine = HistoryFixtureEngine()
    let reminder = RecordingReminderService()
    let coordinator = HistoryCoordinator(
        databaseURL: historyTestDatabaseURL("reminder"),
        engine: engine,
        preferences: MemoryHistoryPreferences(),
        reminderService: reminder
    )
    await coordinator.bootstrap()

    var invalid = HistorySettings()
    invalid.reminder.enabled = true
    await #expect(throws: HistoryCoordinatorError.incompleteReminderConfiguration) {
        try await coordinator.updateSettings(invalid)
    }

    var valid = enabledHistorySettings(reminderEnabled: true)
    valid.historyEnabled = false
    try await coordinator.updateSettings(valid)
    await engine.enqueueActivities([historyActivity(endedAt: "2026-07-30T10:01:00Z")])
    await coordinator.realtimeSnapshotProduced(
        historySnapshot(capturedAt: "2026-07-30T10:01:00Z", runReadBytes: 1, runWriteBytes: 1)
    )
    await engine.enqueueActivities([historyActivity(endedAt: "2026-07-30T10:01:30Z")])
    await coordinator.realtimeSnapshotProduced(
        historySnapshot(capturedAt: "2026-07-30T10:01:30Z", runReadBytes: 2, runWriteBytes: 2)
    )

    #expect(await reminder.deliveredCount() == 1)
}

@Test("会话结束落盘且导出不包含展示名和敏感字段")
func privacySafeExportAndSessionFlush() async throws {
    let engine = HistoryFixtureEngine()
    let coordinator = HistoryCoordinator(
        databaseURL: historyTestDatabaseURL("export"),
        engine: engine,
        preferences: MemoryHistoryPreferences(),
        reminderService: RecordingReminderService()
    )
    await coordinator.bootstrap()
    try await coordinator.updateSettings(enabledHistorySettings(reminderEnabled: true))
    await engine.enqueueActivities([historyActivity(endedAt: "2026-07-30T10:05:00Z")])
    await coordinator.realtimeSnapshotProduced(
        historySnapshot(capturedAt: "2026-07-30T10:04:59Z", runReadBytes: 1_000, runWriteBytes: 2_000)
    )
    await coordinator.observationSessionEnded(historySession())

    let data = try await coordinator.exportJSON()
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(text.contains("com.example.editor"))
    #expect(!text.localizedCaseInsensitiveContains("displayName"))
    #expect(!text.localizedCaseInsensitiveContains("/Users/"))
    #expect(!text.localizedCaseInsensitiveContains("command"))
    #expect(!text.localizedCaseInsensitiveContains("username"))
}

@Test("保留期清理和手动清理删除摘要记录")
func retentionAndManualClear() throws {
    let databaseURL = historyTestDatabaseURL("retention")
    let store = try SQLiteHistoryStore(url: databaseURL)
    let old = MinuteBucketRecord(
        bucketStartedAt: "2026-07-01T00:00:00Z",
        applicationID: nil,
        readBytes: 1,
        writeBytes: 2,
        peak: IORate(readBytesPerSecond: 1, writeBytesPerSecond: 2),
        metricSource: "fixture.storage",
        completeness: "complete"
    )
    let current = MinuteBucketRecord(
        bucketStartedAt: "2026-07-30T00:00:00Z",
        applicationID: "com.example.editor",
        readBytes: 3,
        writeBytes: 4,
        peak: IORate(readBytesPerSecond: 3, writeBytesPerSecond: 4),
        metricSource: "fixture.storage",
        completeness: "restricted"
    )
    try store.write(HistoryWriteBatch(minuteBuckets: [old, current]))

    try store.purge(before: "2026-07-29T00:00:00Z")
    #expect(try store.counts().minuteBuckets == 1)
    try store.clear()
    #expect(try store.counts() == .empty)
}
