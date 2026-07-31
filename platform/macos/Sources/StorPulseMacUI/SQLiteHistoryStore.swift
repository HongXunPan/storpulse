import Foundation
import StorPulseSQLiteBridge

enum SQLiteHistoryStoreError: LocalizedError {
    case open(String)
    case execute(String)
    case prepare(String)
    case bind(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): "无法打开历史数据库：\(message)"
        case let .execute(message): "历史数据库语句失败：\(message)"
        case let .prepare(message): "历史数据库预处理失败：\(message)"
        case let .bind(message): "历史数据库参数失败：\(message)"
        case let .step(message): "历史数据库写入失败：\(message)"
        }
    }
}

final class SQLiteHistoryStore {
    let database: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let handle { sqlite3_close(handle) }
            throw SQLiteHistoryStoreError.open(message)
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute(Self.schema)
            try migrateObservationSessionSchema()
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func write(_ batch: HistoryWriteBatch) throws {
        guard !batch.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for bucket in batch.minuteBuckets {
                try write(bucket)
            }
            for activity in batch.activities {
                try write(activity)
            }
            for session in batch.observationSessions {
                try write(session)
            }
            if let settings = batch.settings {
                try write(settings)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func purge(before date: String) throws {
        for tableAndColumn in [
            ("minute_buckets", "bucket_started_at"),
            ("activities", "ended_at"),
            ("observation_sessions", "ended_at"),
        ] {
            let statement = try prepare(
                "DELETE FROM \(tableAndColumn.0) WHERE \(tableAndColumn.1) < ?;"
            )
            defer { sqlite3_finalize(statement) }
            try bind(date, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    func clear() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try execute("DELETE FROM minute_buckets;")
            try execute("DELETE FROM activities;")
            try execute("DELETE FROM observation_sessions;")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func write(_ bucket: MinuteBucketRecord) throws {
        let sql = """
        INSERT INTO minute_buckets (
            bucket_started_at, record_key, application_id, read_bytes, write_bytes,
            peak_read, peak_write, metric_source, completeness
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bucket_started_at, record_key) DO UPDATE SET
            read_bytes = MIN(9223372036854775807, read_bytes + excluded.read_bytes),
            write_bytes = MIN(9223372036854775807, write_bytes + excluded.write_bytes),
            peak_read = MAX(peak_read, excluded.peak_read),
            peak_write = MAX(peak_write, excluded.peak_write),
            metric_source = excluded.metric_source,
            completeness = excluded.completeness;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bucket.bucketStartedAt, to: 1, in: statement)
        try bind(bucket.applicationID ?? "__device__", to: 2, in: statement)
        try bindOptional(bucket.applicationID, to: 3, in: statement)
        try bind(bucket.readBytes, to: 4, in: statement)
        try bind(bucket.writeBytes, to: 5, in: statement)
        try bind(bucket.peak.readBytesPerSecond, to: 6, in: statement)
        try bind(bucket.peak.writeBytesPerSecond, to: 7, in: statement)
        try bind(bucket.metricSource, to: 8, in: statement)
        try bind(bucket.completeness, to: 9, in: statement)
        try stepDone(statement)
    }

    private func write(_ activity: ActivitySummary) throws {
        let statement = try prepare("""
        INSERT OR REPLACE INTO activities (
            application_id, started_at, ended_at, duration_ms, read_bytes, write_bytes,
            peak_read, peak_write
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        try bind(activity.applicationID, to: 1, in: statement)
        try bind(activity.startedAt, to: 2, in: statement)
        try bind(activity.endedAt, to: 3, in: statement)
        try bind(activity.durationMilliseconds, to: 4, in: statement)
        try bind(activity.readBytes, to: 5, in: statement)
        try bind(activity.writeBytes, to: 6, in: statement)
        try bind(activity.peak.readBytesPerSecond, to: 7, in: statement)
        try bind(activity.peak.writeBytesPerSecond, to: 8, in: statement)
        try stepDone(statement)
    }

    private func write(_ record: ObservationRecord) throws {
        let session = record.session
        let topIDs = session.topApplications.map(\.applicationID)
        let topJSON = String(
            data: try JSONEncoder().encode(topIDs),
            encoding: .utf8
        ) ?? "[]"
        let statement = try prepare("""
        INSERT OR REPLACE INTO observation_sessions (
            session_id, name, started_at, ended_at, duration_ms, read_bytes, write_bytes,
            peak_read, peak_write, completeness, top_application_ids_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { sqlite3_finalize(statement) }
        try bind(session.sessionID, to: 1, in: statement)
        try bind(record.name, to: 2, in: statement)
        try bind(session.startedAt, to: 3, in: statement)
        try bind(session.endedAt, to: 4, in: statement)
        try bind(session.durationMilliseconds, to: 5, in: statement)
        try bind(session.readBytes, to: 6, in: statement)
        try bind(session.writeBytes, to: 7, in: statement)
        try bind(session.peak.readBytesPerSecond, to: 8, in: statement)
        try bind(session.peak.writeBytesPerSecond, to: 9, in: statement)
        try bind(session.completeness, to: 10, in: statement)
        try bind(topJSON, to: 11, in: statement)
        try stepDone(statement)
    }

    private func write(_ settings: HistorySettings) throws {
        let data = try JSONEncoder().encode(settings)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let statement = try prepare("""
        INSERT OR REPLACE INTO settings (key, value_json) VALUES ('history-settings-v1', ?);
        """)
        defer { sqlite3_finalize(statement) }
        try bind(json, to: 1, in: statement)
        try stepDone(statement)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteHistoryStoreError.execute(message)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteHistoryStoreError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else { throw bindError() }
    }

    func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        if let value {
            try bind(value, to: index, in: statement)
        } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
            throw bindError()
        }
    }

    func bind(_ value: UInt64, to index: Int32, in statement: OpaquePointer) throws {
        let bounded = value > UInt64(Int64.max) ? Int64.max : Int64(value)
        guard sqlite3_bind_int64(statement, index, bounded) == SQLITE_OK else {
            throw bindError()
        }
    }

    func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw bindError()
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteHistoryStoreError.step(String(cString: sqlite3_errmsg(database)))
        }
    }

    private func bindError() -> SQLiteHistoryStoreError {
        .bind(String(cString: sqlite3_errmsg(database)))
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS minute_buckets (
        bucket_started_at TEXT NOT NULL,
        record_key TEXT NOT NULL,
        application_id TEXT,
        read_bytes INTEGER NOT NULL,
        write_bytes INTEGER NOT NULL,
        peak_read REAL NOT NULL,
        peak_write REAL NOT NULL,
        metric_source TEXT NOT NULL,
        completeness TEXT NOT NULL,
        PRIMARY KEY (bucket_started_at, record_key)
    );
    CREATE TABLE IF NOT EXISTS activities (
        application_id TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        duration_ms INTEGER NOT NULL,
        read_bytes INTEGER NOT NULL,
        write_bytes INTEGER NOT NULL,
        peak_read REAL NOT NULL,
        peak_write REAL NOT NULL,
        PRIMARY KEY (application_id, started_at, ended_at)
    );
    CREATE TABLE IF NOT EXISTS observation_sessions (
        session_id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL,
        duration_ms INTEGER NOT NULL,
        read_bytes INTEGER NOT NULL,
        write_bytes INTEGER NOT NULL,
        peak_read REAL NOT NULL,
        peak_write REAL NOT NULL,
        completeness TEXT NOT NULL,
        top_application_ids_json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL
    );
    """
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
