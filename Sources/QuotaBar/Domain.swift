import Foundation

enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex = "Codex"
    case zcode = "ZCode"

    var id: String { rawValue }
}

enum ProviderHealth: String, Codable, Sendable {
    case loading, fresh, stale, disabled, unavailable, authenticationRequired

    var label: String {
        switch self {
        case .loading: "Loading"
        case .fresh: "Connected"
        case .stale: "Stale"
        case .disabled: "Disabled"
        case .unavailable: "Unavailable"
        case .authenticationRequired: "Sign in required"
        }
    }
}

struct QuotaWindow: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let used: Double
    let limit: Double
    let resetAt: Date?
    let unit: String

    var fraction: Double { limit > 0 ? min(max(used / limit, 0), 1) : 0 }
}

struct DailyUsage: Codable, Sendable, Equatable, Identifiable {
    let day: Date
    let tokens: Double
    /// A provider-defined calendar day that must not be reinterpreted as an instant.
    let dateLabel: String?

    var id: Date { day }

    init(day: Date, tokens: Double, dateLabel: String? = nil) {
        self.day = day
        self.tokens = tokens
        self.dateLabel = dateLabel
    }
}

struct ProviderSnapshot: Codable, Sendable, Equatable {
    let provider: ProviderID
    let dailyUsage: [DailyUsage]
    let lifetimeTokens: Double
    let quotaWindows: [QuotaWindow]
    let health: ProviderHealth
    let updatedAt: Date
    let coverage: String
    let detail: String?

    static func disabled(_ provider: ProviderID, now: Date = .now) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [], health: .disabled, updatedAt: now, coverage: "Disabled", detail: nil)
    }
}

struct ProviderDiagnosticsPresentation: Equatable, Sendable, Identifiable {
    let provider: ProviderID
    let health: ProviderHealth?
    let coverage: String
    let updatedAt: Date?
    let detail: String?

    var id: ProviderID { provider }
    var stateLabel: String { health?.label ?? "No account snapshot" }

    static func make(provider: ProviderID, enabled: Bool, snapshot: ProviderSnapshot?) -> ProviderDiagnosticsPresentation {
        if let snapshot {
            if snapshot.health == .disabled {
                return ProviderDiagnosticsPresentation(
                    provider: provider,
                    health: .disabled,
                    coverage: "Disabled",
                    updatedAt: nil,
                    detail: nil
                )
            }
            return ProviderDiagnosticsPresentation(
                provider: provider,
                health: snapshot.health,
                coverage: snapshot.coverage,
                updatedAt: snapshot.updatedAt,
                detail: snapshot.detail
            )
        }
        return ProviderDiagnosticsPresentation(
            provider: provider,
            health: enabled ? nil : .disabled,
            coverage: enabled ? "No account snapshot" : "Disabled",
            updatedAt: nil,
            detail: nil
        )
    }
}

struct ProviderTotals: Equatable, Sendable {
    let today: Double
    let sevenDays: Double
    let lifetime: Double
}

enum UsageMath {
    static func totals(for snapshot: ProviderSnapshot, now: Date, calendar: Calendar) -> ProviderTotals {
        let start = calendar.startOfDay(for: now)
        let today = tokens(for: snapshot, on: start, calendar: calendar)
        let sevenDays = (0..<7).reduce(0) { total, offset in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: start)!
            return total + tokens(for: snapshot, on: day, calendar: calendar)
        }
        return ProviderTotals(today: today, sevenDays: sevenDays, lifetime: snapshot.lifetimeTokens)
    }

    static func tokens(for snapshot: ProviderSnapshot, on day: Date, calendar: Calendar) -> Double {
        snapshot.dailyUsage.filter { matches($0, calendarDay: day, calendar: calendar) }.reduce(0) { $0 + $1.tokens }
    }

    static func matches(_ usage: DailyUsage, calendarDay: Date, calendar: Calendar) -> Bool {
        if let dateLabel = usage.dateLabel {
            return dateLabel == calendarDateLabel(for: calendarDay, calendar: calendar)
        }
        return calendar.isDate(usage.day, inSameDayAs: calendarDay)
    }

    static func calendarDateLabel(for day: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func aggregate(_ snapshots: [ProviderSnapshot], enabled: (ProviderID) -> Bool, now: Date, calendar: Calendar) -> ProviderTotals {
        snapshots.filter { enabled($0.provider) }.map { totals(for: $0, now: now, calendar: calendar) }
            .reduce(ProviderTotals(today: 0, sevenDays: 0, lifetime: 0)) { partial, next in
                ProviderTotals(today: partial.today + next.today, sevenDays: partial.sevenDays + next.sevenDays, lifetime: partial.lifetime + next.lifetime)
            }
    }
}

struct BackoffPolicy: Sendable, Equatable {
    let base: TimeInterval
    let cap: TimeInterval

    init(base: TimeInterval = 300, cap: TimeInterval = 3_600) {
        self.base = base
        self.cap = cap
    }

    func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return base }
        return min(base * pow(2, Double(failures)), cap)
    }
}

enum UsageExport {
    static func snapshots(_ snapshots: [ProviderSnapshot], preferences: AppPreferences) -> [ProviderSnapshot] {
        snapshots.filter { preferences.enabled($0.provider) }.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    static func records(_ snapshots: [ProviderSnapshot], preferences: AppPreferences, now: Date) -> [UsageExportRecord] {
        self.snapshots(snapshots, preferences: preferences).flatMap { snapshot in
            let totals = UsageMath.totals(for: snapshot, now: now, calendar: preferences.calendar)
            let metadata = UsageExportRecord.snapshot(snapshot, totals: totals)
            let daily = snapshot.dailyUsage.map { UsageExportRecord.daily($0, snapshot: snapshot) }
            let quotas = snapshot.quotaWindows.map { UsageExportRecord.quota($0, snapshot: snapshot) }
            return [metadata] + daily + quotas
        }
    }

    static func json(_ snapshots: [ProviderSnapshot], preferences: AppPreferences, now: Date = .now) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(records(snapshots, preferences: preferences, now: now))
    }

    static func csv(_ snapshots: [ProviderSnapshot], preferences: AppPreferences, now: Date) -> Data {
        let rows = [UsageExportRecord.csvHeader] + records(snapshots, preferences: preferences, now: now).map(\.csvRow)
        return Data(rows.joined(separator: "\n").utf8)
    }
}

enum UsageExportRowType: String, Codable, Sendable, Hashable {
    case snapshot
    case dailyUsage
    case quotaWindow
}

struct UsageExportRecord: Codable, Sendable, Hashable {
    let rowType: UsageExportRowType
    let provider: ProviderID
    let updatedAt: Date
    let health: ProviderHealth
    let coverage: String
    let detail: String?
    let today: Double?
    let sevenDays: Double?
    let lifetime: Double?
    let day: Date?
    let dateLabel: String?
    let tokens: Double?
    let quotaID: String?
    let quotaName: String?
    let quotaUsed: Double?
    let quotaLimit: Double?
    let quotaResetAt: Date?
    let quotaUnit: String?

    static func snapshot(_ snapshot: ProviderSnapshot, totals: ProviderTotals) -> UsageExportRecord {
        UsageExportRecord(rowType: .snapshot, provider: snapshot.provider, updatedAt: snapshot.updatedAt, health: snapshot.health, coverage: snapshot.coverage, detail: snapshot.detail, today: totals.today, sevenDays: totals.sevenDays, lifetime: totals.lifetime, day: nil, dateLabel: nil, tokens: nil, quotaID: nil, quotaName: nil, quotaUsed: nil, quotaLimit: nil, quotaResetAt: nil, quotaUnit: nil)
    }

    static func daily(_ daily: DailyUsage, snapshot: ProviderSnapshot) -> UsageExportRecord {
        UsageExportRecord(rowType: .dailyUsage, provider: snapshot.provider, updatedAt: snapshot.updatedAt, health: snapshot.health, coverage: snapshot.coverage, detail: snapshot.detail, today: nil, sevenDays: nil, lifetime: nil, day: daily.day, dateLabel: daily.dateLabel, tokens: daily.tokens, quotaID: nil, quotaName: nil, quotaUsed: nil, quotaLimit: nil, quotaResetAt: nil, quotaUnit: nil)
    }

    static func quota(_ quota: QuotaWindow, snapshot: ProviderSnapshot) -> UsageExportRecord {
        UsageExportRecord(rowType: .quotaWindow, provider: snapshot.provider, updatedAt: snapshot.updatedAt, health: snapshot.health, coverage: snapshot.coverage, detail: snapshot.detail, today: nil, sevenDays: nil, lifetime: nil, day: nil, dateLabel: nil, tokens: nil, quotaID: quota.id, quotaName: quota.name, quotaUsed: quota.used, quotaLimit: quota.limit, quotaResetAt: quota.resetAt, quotaUnit: quota.unit)
    }

    static let csvHeader = "row_type,provider,updated_at,health,coverage,detail,today,seven_days,lifetime,day,date_label,tokens,quota_id,quota_name,quota_used,quota_limit,quota_reset_at,quota_unit"

    var csvRow: String {
        [rowType.rawValue, provider.rawValue, iso(updatedAt), health.rawValue, coverage, detail ?? "", number(today), number(sevenDays), number(lifetime), day.map(iso) ?? "", dateLabel ?? "", number(tokens), quotaID ?? "", quotaName ?? "", number(quotaUsed), number(quotaLimit), quotaResetAt.map(iso) ?? "", quotaUnit ?? ""].map(csvField).joined(separator: ",")
    }

    private func number(_ value: Double?) -> String { value.map { String($0) } ?? "" }
    private func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private func csvField(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
}

struct AppPreferences: Codable, Sendable, Equatable {
    var codexEnabled = true
    var zcodeEnabled = true
    var refreshInterval: TimeInterval = 300
    var refreshOnOpen = true
    var launchAtLogin = false
    var menuBarText = true
    var timeZoneIdentifier = TimeZone.current.identifier
    var zcodeConsent = false
    var warningThreshold = 0.8
    var criticalThreshold = 0.95

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    func enabled(_ provider: ProviderID) -> Bool { provider == .codex ? codexEnabled : zcodeEnabled }

    mutating func setWarningThreshold(_ value: Double) {
        warningThreshold = min(max(value, 0), criticalThreshold)
    }

    mutating func setCriticalThreshold(_ value: Double) {
        criticalThreshold = max(min(value, 1), warningThreshold)
    }
}

enum QuotaClassification: Equatable, Sendable {
    case normal
    case warning
    case critical

    static func classify(_ fraction: Double, preferences: AppPreferences) -> QuotaClassification {
        if fraction >= preferences.criticalThreshold { return .critical }
        if fraction >= preferences.warningThreshold { return .warning }
        return .normal
    }
}

enum ProviderError: Error, Sendable, Equatable {
    case authenticationRequired
    case unavailable
    case malformedResponse
    case credentialUnavailable

    var health: ProviderHealth {
        switch self {
        case .authenticationRequired, .credentialUnavailable: .authenticationRequired
        case .unavailable, .malformedResponse: .unavailable
        }
    }
}

extension Double {
    var tokenText: String {
        if self >= 1_000_000_000 { return String(format: "%.1fB", self / 1_000_000_000) }
        if self >= 1_000_000 { return String(format: "%.1fM", self / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", self / 1_000) }
        return String(format: "%.0f", self)
    }
}
