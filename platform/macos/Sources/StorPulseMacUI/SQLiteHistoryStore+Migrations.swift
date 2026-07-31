import StorPulseSQLiteBridge

extension SQLiteHistoryStore {
    func migrateObservationSessionSchema() throws {
        let statement = try prepare("PRAGMA table_info(observation_sessions);")
        defer { sqlite3_finalize(statement) }

        var hasNameColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnName = sqlite3_column_text(statement, 1) else {
                continue
            }
            if String(cString: columnName) == "name" {
                hasNameColumn = true
                break
            }
        }

        if !hasNameColumn {
            try execute("""
            ALTER TABLE observation_sessions
            ADD COLUMN name TEXT NOT NULL DEFAULT '';
            """)
        }
    }
}
