import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

protocol UsageStore: Sendable {
    func cachedSnapshot(for provider: ProviderID) async throws -> ProviderSnapshot?
    func allSnapshots() async throws -> [ProviderSnapshot]
    func save(snapshot: ProviderSnapshot) async throws
    func sealedMonths() async throws -> Set<String>
    func saveMonth(_ month: String, usage: [DailyUsage], sealed: Bool) async throws
    func monthUsage() async throws -> [DailyUsage]
}

/// Per-source local activity rows. Kept apart from provider snapshots so activity never
/// enters account totals.
protocol ActivityStore: Sendable {
    /// Atomically replaces the source's rows from `report.since` onward and records the run.
    func replaceActivity(source: UUID, report: ActivityReport) async throws
    func activitySources() async throws -> [UUID: ActivitySourceRecord]
    func activityRows(since: Date) async throws -> [UUID: [ActivityRow]]
    func deleteActivity(source: UUID) async throws
}

actor SQLiteUsageStore: UsageStore, ActivityStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ProviderError.unavailable }
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS snapshots (provider TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS zcode_months (month TEXT PRIMARY KEY, payload BLOB NOT NULL, sealed INTEGER NOT NULL)")
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS activity_sources (source TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS activity_rows (source TEXT NOT NULL, bucket REAL NOT NULL, metric TEXT NOT NULL, session TEXT NOT NULL, mirror INTEGER NOT NULL, labels BLOB NOT NULL, value REAL NOT NULL)")
        try Self.execute(db, sql: "CREATE INDEX IF NOT EXISTS activity_rows_source_bucket ON activity_rows(source, bucket)")
    }

    deinit { sqlite3_close(db) }

    func cachedSnapshot(for provider: ProviderID) throws -> ProviderSnapshot? {
        let statement = try prepare("SELECT payload FROM snapshots WHERE provider = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return try decoder.decode(ProviderSnapshot.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }

    func allSnapshots() throws -> [ProviderSnapshot] {
        try ProviderID.allCases.compactMap { try cachedSnapshot(for: $0) }
    }

    func save(snapshot: ProviderSnapshot) throws {
        let statement = try prepare("INSERT OR REPLACE INTO snapshots(provider, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        let payload = try encoder.encode(snapshot)
        sqlite3_bind_text(statement, 1, snapshot.provider.rawValue, -1, sqliteTransient)
        payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), sqliteTransient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProviderError.unavailable }
    }

    func sealedMonths() throws -> Set<String> {
        let statement = try prepare("SELECT month FROM zcode_months WHERE sealed = 1")
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let month = sqlite3_column_text(statement, 0) { values.insert(String(cString: month)) }
        return values
    }

    func saveMonth(_ month: String, usage: [DailyUsage], sealed: Bool) throws {
        let statement = try prepare("INSERT OR REPLACE INTO zcode_months(month, payload, sealed) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        let payload = try encoder.encode(usage)
        sqlite3_bind_text(statement, 1, month, -1, sqliteTransient)
        payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(payload.count), sqliteTransient) }
        sqlite3_bind_int(statement, 3, sealed ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProviderError.unavailable }
    }

    func monthUsage() throws -> [DailyUsage] {
        let statement = try prepare("SELECT payload FROM zcode_months")
        defer { sqlite3_finalize(statement) }
        var daily: [Date: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) {
            let values = try decoder.decode([DailyUsage].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            for item in values { daily[item.day, default: 0] += item.tokens }
        }
        return daily.map { DailyUsage(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day }
    }

    func replaceActivity(source: UUID, report: ActivityReport) throws {
        try Self.execute(db, sql: "BEGIN IMMEDIATE")
        do {
            let delete = try prepare("DELETE FROM activity_rows WHERE source = ? AND bucket >= ?")
            defer { sqlite3_finalize(delete) }
            sqlite3_bind_text(delete, 1, source.uuidString, -1, sqliteTransient)
            sqlite3_bind_double(delete, 2, report.since.timeIntervalSince1970)
            guard sqlite3_step(delete) == SQLITE_DONE else { throw ProviderError.unavailable }

            let insert = try prepare("INSERT INTO activity_rows(source, bucket, metric, session, mirror, labels, value) VALUES (?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            for row in report.rows where row.bucket >= report.since {
                sqlite3_reset(insert)
                let labels = try encoder.encode(row.labels)
                sqlite3_bind_text(insert, 1, source.uuidString, -1, sqliteTransient)
                sqlite3_bind_double(insert, 2, row.bucket.timeIntervalSince1970)
                sqlite3_bind_text(insert, 3, row.metric, -1, sqliteTransient)
                sqlite3_bind_text(insert, 4, row.session, -1, sqliteTransient)
                sqlite3_bind_int(insert, 5, row.mirror ? 1 : 0)
                _ = labels.withUnsafeBytes { sqlite3_bind_blob(insert, 6, $0.baseAddress, Int32(labels.count), sqliteTransient) }
                sqlite3_bind_double(insert, 7, row.value)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw ProviderError.unavailable }
            }

            let record = try encoder.encode(ActivitySourceRecord(device: report.device, generatedAt: report.generatedAt, metrics: report.metrics))
            let upsert = try prepare("INSERT OR REPLACE INTO activity_sources(source, payload) VALUES (?, ?)")
            defer { sqlite3_finalize(upsert) }
            sqlite3_bind_text(upsert, 1, source.uuidString, -1, sqliteTransient)
            _ = record.withUnsafeBytes { sqlite3_bind_blob(upsert, 2, $0.baseAddress, Int32(record.count), sqliteTransient) }
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw ProviderError.unavailable }
            try Self.execute(db, sql: "COMMIT")
        } catch {
            try? Self.execute(db, sql: "ROLLBACK")
            throw error
        }
    }

    func activitySources() throws -> [UUID: ActivitySourceRecord] {
        let statement = try prepare("SELECT source, payload FROM activity_sources")
        defer { sqlite3_finalize(statement) }
        var records: [UUID: ActivitySourceRecord] = [:]
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0), let bytes = sqlite3_column_blob(statement, 1) {
            guard let id = UUID(uuidString: String(cString: text)) else { continue }
            records[id] = try decoder.decode(ActivitySourceRecord.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1))))
        }
        return records
    }

    func activityRows(since: Date) throws -> [UUID: [ActivityRow]] {
        let statement = try prepare("SELECT source, bucket, metric, session, mirror, labels, value FROM activity_rows WHERE bucket >= ? ORDER BY bucket")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        var rows: [UUID: [ActivityRow]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = sqlite3_column_text(statement, 0).flatMap({ UUID(uuidString: String(cString: $0)) }),
                  let metric = sqlite3_column_text(statement, 2), let session = sqlite3_column_text(statement, 3),
                  let labelBytes = sqlite3_column_blob(statement, 5) else { continue }
            let labels = try decoder.decode([String: String].self, from: Data(bytes: labelBytes, count: Int(sqlite3_column_bytes(statement, 5))))
            rows[source, default: []].append(ActivityRow(
                metric: String(cString: metric),
                bucket: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                session: String(cString: session),
                mirror: sqlite3_column_int(statement, 4) != 0,
                labels: labels,
                value: sqlite3_column_double(statement, 6)
            ))
        }
        return rows
    }

    func deleteActivity(source: UUID) throws {
        for sql in ["DELETE FROM activity_rows WHERE source = ?", "DELETE FROM activity_sources WHERE source = ?"] {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, source.uuidString, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ProviderError.unavailable }
        }
    }

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ProviderError.unavailable }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ProviderError.unavailable }
        return statement
    }
}

actor InMemoryUsageStore: UsageStore, ActivityStore {
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]
    private var months: [String: ([DailyUsage], Bool)] = [:]
    private var activity: [UUID: [ActivityRow]] = [:]
    private var activityRecords: [UUID: ActivitySourceRecord] = [:]

    func replaceActivity(source: UUID, report: ActivityReport) {
        activity[source] = activity[source, default: []].filter { $0.bucket < report.since } + report.rows.filter { $0.bucket >= report.since }
        activityRecords[source] = ActivitySourceRecord(device: report.device, generatedAt: report.generatedAt, metrics: report.metrics)
    }
    func activitySources() -> [UUID: ActivitySourceRecord] { activityRecords }
    func activityRows(since: Date) -> [UUID: [ActivityRow]] { activity.mapValues { $0.filter { $0.bucket >= since } } }
    func deleteActivity(source: UUID) { activity[source] = nil; activityRecords[source] = nil }

    func cachedSnapshot(for provider: ProviderID) -> ProviderSnapshot? { snapshots[provider] }
    func allSnapshots() -> [ProviderSnapshot] { Array(snapshots.values) }
    func save(snapshot: ProviderSnapshot) { snapshots[snapshot.provider] = snapshot }
    func sealedMonths() -> Set<String> { Set(months.compactMap { $0.value.1 ? $0.key : nil }) }
    func saveMonth(_ month: String, usage: [DailyUsage], sealed: Bool) { months[month] = (usage, sealed) }
    func monthUsage() -> [DailyUsage] { months.values.flatMap(\.0).sorted { $0.day < $1.day } }
}
