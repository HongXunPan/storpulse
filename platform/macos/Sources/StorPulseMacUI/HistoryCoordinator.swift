import Foundation

public enum HistoryCoordinatorError: LocalizedError, Equatable {
    case incompleteReminderConfiguration
    case notificationPermissionDenied
    case historyDisabled

    public var errorDescription: String? {
        switch self {
        case .incompleteReminderConfiguration:
            "启用提醒前必须设置读取阈值、写入阈值、持续时间和冷却时间"
        case .notificationPermissionDenied:
            "系统没有授予 StorPulse 通知权限"
        case .historyDisabled:
            "历史尚未启用"
        }
    }
}

public actor HistoryCoordinator: RealtimeSnapshotObserver {
    private let databaseURL: URL
    private let engine: any StorPulseEngineClient
    private let preferences: any HistoryPreferences
    private let reminderService: any ReminderDelivering
    private let now: @Sendable () -> Date

    private var settings = HistorySettings()
    private var store: SQLiteHistoryStore?
    private var accumulator = MinuteBucketAccumulator()
    private var pendingActivities: [ActivitySummary] = []
    private var pendingSessions: [ObservationRecord] = []
    private var lastFlushAt: Date?
    private var lastReminderAt: [String: Date] = [:]

    public init(
        databaseURL: URL,
        engine: any StorPulseEngineClient,
        preferences: any HistoryPreferences = UserDefaultsHistoryPreferences(),
        reminderService: any ReminderDelivering = SystemReminderService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.engine = engine
        self.preferences = preferences
        self.reminderService = reminderService
        self.now = now
    }

    public func bootstrap() async {
        let loaded = await preferences.load()
        settings = loaded.reminder.enabled && !loaded.reminder.hasExplicitThresholds
            ? HistorySettings(
                historyEnabled: loaded.historyEnabled,
                retention: loaded.retention,
                reminder: ReminderConfiguration()
            )
            : loaded
        if settings.historyEnabled {
            store = try? SQLiteHistoryStore(url: databaseURL)
            lastFlushAt = now()
        }
        try? await configureActivityPolicy()
    }

    public func currentSettings() -> HistorySettings {
        settings
    }

    public func updateSettings(_ newSettings: HistorySettings) async throws {
        if newSettings.reminder.enabled && !settings.reminder.enabled {
            guard newSettings.reminder.hasExplicitThresholds else {
                throw HistoryCoordinatorError.incompleteReminderConfiguration
            }
            guard try await reminderService.requestAuthorization() else {
                throw HistoryCoordinatorError.notificationPermissionDenied
            }
        }

        if newSettings.historyEnabled && store == nil {
            store = try SQLiteHistoryStore(url: databaseURL)
            lastFlushAt = now()
        }
        if settings.historyEnabled && !newSettings.historyEnabled {
            try flush(includeCurrentMinute: true)
        }

        settings = newSettings
        try await configureActivityPolicy()
        await preferences.save(settings)

        if let store {
            try store.write(HistoryWriteBatch(settings: settings))
            let cutoff = now().addingTimeInterval(-settings.retention.seconds)
            try store.purge(before: Self.formatDate(cutoff))
        }
        if !settings.historyEnabled {
            store = nil
        }
    }

    public func realtimeSnapshotProduced(_ snapshot: RealtimeSnapshot) async {
        if settings.historyEnabled {
            accumulator.ingest(snapshot)
        }
        await drainCompletedActivities()

        let current = now()
        if lastFlushAt == nil {
            lastFlushAt = current
        }
        if settings.historyEnabled,
           current.timeIntervalSince(lastFlushAt ?? current) >= 5 * 60
        {
            try? flush(includeCurrentMinute: false)
        }
    }

    public func observationRecordEnded(_ record: ObservationRecord) async {
        if settings.historyEnabled {
            pendingSessions.append(record)
            try? flush(includeCurrentMinute: true)
        }
    }

    public func observationRecordRenamed(
        sessionID: String,
        name: String
    ) async {
        guard settings.historyEnabled else { return }
        pendingSessions = pendingSessions.map { record in
            record.id == sessionID ? record.renamed(to: name) : record
        }
        try? store?.renameObservationRecord(
            sessionID: sessionID,
            name: name
        )
    }

    public func flushForTermination() throws {
        guard settings.historyEnabled else { return }
        try flush(includeCurrentMinute: true)
    }

    public func clearHistory() throws {
        guard let store else { throw HistoryCoordinatorError.historyDisabled }
        accumulator = MinuteBucketAccumulator()
        pendingActivities.removeAll()
        pendingSessions.removeAll()
        try store.clear()
    }

    public func counts() throws -> HistoryCounts {
        guard let store else { return .empty }
        return try store.counts()
    }

    public func observationRecords() throws -> [ObservationRecordSummary] {
        guard let store else { return [] }
        return try store.observationRecords()
    }

    public func renameObservationRecord(
        sessionID: String,
        name: String
    ) throws {
        guard let store else { throw HistoryCoordinatorError.historyDisabled }
        let normalized = ObservationRecord.normalizedName(
            name,
            fallback: "未命名记录"
        )
        try store.renameObservationRecord(
            sessionID: sessionID,
            name: normalized
        )
    }

    public func exportJSON() throws -> Data {
        guard let store else { throw HistoryCoordinatorError.historyDisabled }
        try flush(includeCurrentMinute: true)
        let value = try store.export(generatedAt: Self.formatDate(now()))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private func configureActivityPolicy() async throws {
        let reminder = settings.reminder
        let durationMilliseconds = UInt64(
            min(reminder.minimumDurationSeconds * 1_000, Double(UInt64.max))
        )
        _ = try await engine.execute(
            .configureActivity(
                ActivityPolicy(
                    enabled: reminder.enabled,
                    readThresholdBytesPerSecond: reminder.readThresholdBytesPerSecond,
                    writeThresholdBytesPerSecond: reminder.writeThresholdBytesPerSecond,
                    minimumDurationMilliseconds: durationMilliseconds
                )
            )
        )
    }

    private func drainCompletedActivities() async {
        guard settings.reminder.enabled else { return }
        guard let response = try? await engine.execute(.drainCompletedActivities),
              case let .completedActivities(activities) = response
        else {
            return
        }
        if settings.historyEnabled {
            pendingActivities.append(contentsOf: activities)
        }
        for activity in activities where shouldDeliverReminder(for: activity) {
            try? await reminderService.deliver(activity: activity)
        }
    }

    private func shouldDeliverReminder(for activity: ActivitySummary) -> Bool {
        let endedAt = Self.parseDate(activity.endedAt) ?? now()
        if let last = lastReminderAt[activity.applicationID],
           endedAt.timeIntervalSince(last) < settings.reminder.cooldownSeconds
        {
            return false
        }
        lastReminderAt[activity.applicationID] = endedAt
        return true
    }

    private func flush(includeCurrentMinute: Bool) throws {
        guard let store else { return }
        let current = now()
        let buckets = includeCurrentMinute
            ? accumulator.drainAll()
            : accumulator.drainFinished(before: current)
        let batch = HistoryWriteBatch(
            minuteBuckets: buckets,
            activities: pendingActivities,
            observationSessions: pendingSessions,
            settings: settings
        )
        try store.write(batch)
        pendingActivities.removeAll()
        pendingSessions.removeAll()
        let cutoff = current.addingTimeInterval(-settings.retention.seconds)
        try store.purge(before: Self.formatDate(cutoff))
        lastFlushAt = current
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
