import Foundation
import StorPulseSQLiteBridge

extension SQLiteHistoryStore {
    func counts() throws -> HistoryCounts {
        HistoryCounts(
            minuteBuckets: try count(table: "minute_buckets"),
            activities: try count(table: "activities"),
            observationSessions: try count(table: "observation_sessions")
        )
    }

    func export(generatedAt: String) throws -> HistoryExport {
        HistoryExport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            minuteBuckets: try exportedMinuteBuckets(),
            activities: try exportedActivities(),
            observationSessions: try exportedSessions()
        )
    }

    func observationRecords(limit: Int = 200) throws -> [ObservationRecordSummary] {
        let boundedLimit = max(1, min(limit, 500))
        let statement = try prepare("""
        SELECT session_id, name, started_at, ended_at, duration_ms, read_bytes,
               write_bytes, peak_read, peak_write, completeness,
               top_application_ids_json
        FROM observation_sessions
        ORDER BY ended_at DESC, session_id DESC
        LIMIT \(boundedLimit);
        """)
        defer { sqlite3_finalize(statement) }

        var records: [ObservationRecordSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let topData = Data(text(statement, 10).utf8)
            let topIDs = (try? JSONDecoder().decode([String].self, from: topData)) ?? []
            let storedName = text(statement, 1)
            records.append(
                ObservationRecordSummary(
                    sessionID: text(statement, 0),
                    name: storedName.isEmpty ? "未命名记录" : storedName,
                    startedAt: text(statement, 2),
                    endedAt: text(statement, 3),
                    durationMilliseconds: unsigned(statement, 4),
                    readBytes: unsigned(statement, 5),
                    writeBytes: unsigned(statement, 6),
                    peak: IORate(
                        readBytesPerSecond: sqlite3_column_double(statement, 7),
                        writeBytesPerSecond: sqlite3_column_double(statement, 8)
                    ),
                    completeness: text(statement, 9),
                    topApplications: topIDs.map {
                        ObservationRecordApplicationSummary(
                            applicationID: $0,
                            displayName: $0,
                            readBytes: nil,
                            writeBytes: nil
                        )
                    }
                )
            )
        }
        return records
    }

    func renameObservationRecord(sessionID: String, name: String) throws {
        let statement = try prepare("""
        UPDATE observation_sessions SET name = ? WHERE session_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(name, to: 1, in: statement)
        try bind(sessionID, to: 2, in: statement)
        try stepDone(statement)
    }

    private func count(table: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table);")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteHistoryStoreError.step(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func exportedMinuteBuckets() throws -> [ExportedMinuteBucket] {
        let statement = try prepare("""
        SELECT bucket_started_at, application_id, read_bytes, write_bytes,
               metric_source, completeness
        FROM minute_buckets
        ORDER BY bucket_started_at, record_key;
        """)
        defer { sqlite3_finalize(statement) }
        var records: [ExportedMinuteBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(
                ExportedMinuteBucket(
                    bucketStartedAt: text(statement, 0),
                    applicationID: optionalText(statement, 1),
                    readBytes: unsigned(statement, 2),
                    writeBytes: unsigned(statement, 3),
                    metricSource: text(statement, 4),
                    completeness: text(statement, 5)
                )
            )
        }
        return records
    }

    private func exportedActivities() throws -> [ExportedActivity] {
        let statement = try prepare("""
        SELECT application_id, started_at, ended_at, duration_ms, read_bytes, write_bytes
        FROM activities
        ORDER BY ended_at, application_id;
        """)
        defer { sqlite3_finalize(statement) }
        var records: [ExportedActivity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(
                ExportedActivity(
                    applicationID: text(statement, 0),
                    startedAt: text(statement, 1),
                    endedAt: text(statement, 2),
                    durationMilliseconds: unsigned(statement, 3),
                    readBytes: unsigned(statement, 4),
                    writeBytes: unsigned(statement, 5)
                )
            )
        }
        return records
    }

    private func exportedSessions() throws -> [ExportedObservationSession] {
        let statement = try prepare("""
        SELECT session_id, started_at, ended_at, duration_ms, read_bytes, write_bytes,
               completeness, top_application_ids_json
        FROM observation_sessions
        ORDER BY ended_at, session_id;
        """)
        defer { sqlite3_finalize(statement) }
        var records: [ExportedObservationSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let topData = Data(text(statement, 7).utf8)
            let topIDs = (try? JSONDecoder().decode([String].self, from: topData)) ?? []
            records.append(
                ExportedObservationSession(
                    sessionID: text(statement, 0),
                    startedAt: text(statement, 1),
                    endedAt: text(statement, 2),
                    durationMilliseconds: unsigned(statement, 3),
                    readBytes: unsigned(statement, 4),
                    writeBytes: unsigned(statement, 5),
                    completeness: text(statement, 6),
                    topApplicationIDs: topIDs
                )
            )
        }
        return records
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    private func unsigned(_ statement: OpaquePointer, _ column: Int32) -> UInt64 {
        let value = sqlite3_column_int64(statement, column)
        return value > 0 ? UInt64(value) : 0
    }
}
