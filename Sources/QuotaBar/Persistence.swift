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

actor SQLiteUsageStore: UsageStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ProviderError.unavailable }
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS snapshots (provider TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try Self.execute(db, sql: "CREATE TABLE IF NOT EXISTS zcode_months (month TEXT PRIMARY KEY, payload BLOB NOT NULL, sealed INTEGER NOT NULL)")
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

    private static func execute(_ database: OpaquePointer?, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ProviderError.unavailable }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ProviderError.unavailable }
        return statement
    }
}

actor InMemoryUsageStore: UsageStore {
    private var snapshots: [ProviderID: ProviderSnapshot] = [:]
    private var months: [String: ([DailyUsage], Bool)] = [:]

    func cachedSnapshot(for provider: ProviderID) -> ProviderSnapshot? { snapshots[provider] }
    func allSnapshots() -> [ProviderSnapshot] { Array(snapshots.values) }
    func save(snapshot: ProviderSnapshot) { snapshots[snapshot.provider] = snapshot }
    func sealedMonths() -> Set<String> { Set(months.compactMap { $0.value.1 ? $0.key : nil }) }
    func saveMonth(_ month: String, usage: [DailyUsage], sealed: Bool) { months[month] = (usage, sealed) }
    func monthUsage() -> [DailyUsage] { months.values.flatMap(\.0).sorted { $0.day < $1.day } }
}
