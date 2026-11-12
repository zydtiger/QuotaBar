import Foundation

/// A user-configured command that prints the `quotabar.activity` schema.
struct ActivitySourceConfig: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var argv: [String]
    var enabled: Bool
    /// Pipe the bundled collector to standard input and append `--since <instant>`.
    var pipesCollector: Bool

    static let thisMac = ActivitySourceConfig(
        id: UUID(uuidString: "6C6F6361-6C00-4000-8000-000000000001")!,
        name: "This Mac",
        argv: ["python3", "-"],
        enabled: true,
        pipesCollector: true
    )
}

struct ActivityMetricInfo: Codable, Sendable, Equatable {
    let label: String
    let unit: String
}

struct ActivityRow: Codable, Sendable, Hashable {
    let metric: String
    /// UTC hour instant.
    let bucket: Date
    let session: String
    let mirror: Bool
    let labels: [String: String]
    let value: Double
}

struct ActivityReport: Sendable, Equatable {
    let device: String
    let generatedAt: Date
    let since: Date
    let metrics: [String: ActivityMetricInfo]
    let rows: [ActivityRow]
}

/// Last successful run of a source as stored alongside its rows.
struct ActivitySourceRecord: Codable, Sendable, Equatable {
    let device: String
    let generatedAt: Date
    let metrics: [String: ActivityMetricInfo]
}

struct ActivitySourceStatus: Equatable, Sendable {
    var health: ProviderHealth
    var device: String?
    var lastSuccess: Date?
    var detail: String?
}

enum ActivityFailureHint: String, Sendable, Equatable {
    case sshAuthentication, hostUnreachable, pythonMissing, other
}

enum ActivitySourceError: Error, Sendable, Equatable {
    case invalidCommand
    case collectorMissing
    case executableNotFound(String)
    case timedOut
    case outputTooLarge
    case failed(ActivityFailureHint, status: Int32)
    case invalidOutput(String)

    var message: String {
        switch self {
        case .invalidCommand: "The command is empty."
        case .collectorMissing: "The bundled collector is missing from the app."
        case .executableNotFound(let name): "Command not found: \(name). Use an absolute path; apps opened from Finder have a minimal PATH."
        case .timedOut: "The command timed out."
        case .outputTooLarge: "The command printed more output than allowed."
        case .failed(.sshAuthentication, _): "SSH authentication failed. Apps opened from Finder may not see your shell's SSH agent; use a key from ~/.ssh/config or the macOS agent."
        case .failed(.hostUnreachable, _): "The host could not be reached."
        case .failed(.pythonMissing, _): "python3 was not found on the device."
        case .failed(.other, let status): "The command exited with status \(status)."
        case .invalidOutput(let reason): "Invalid activity output: \(reason)."
        }
    }

    /// Classifies a failed command from its standard error without echoing it.
    static func classify(status: Int32, stderr: Data) -> ActivitySourceError {
        let text = String(decoding: stderr.prefix(65_536), as: UTF8.self)
        if text.contains("Permission denied") || text.contains("Host key verification failed") || text.contains("Too many authentication failures") {
            return .failed(.sshAuthentication, status: status)
        }
        if ["Could not resolve hostname", "Connection timed out", "Connection refused", "No route to host", "Network is unreachable", "Operation timed out"].contains(where: text.contains) {
            return .failed(.hostUnreachable, status: status)
        }
        if text.contains("python3: command not found") || text.contains("python3: not found") || (status == 127 && text.contains("python3")) {
            return .failed(.pythonMissing, status: status)
        }
        return .failed(.other, status: status)
    }
}

enum ActivityReportParser {
    static let schema = "quotabar.activity"
    static let version = 1
    static let maxRows = 1_000_000
    static let maxStringLength = 256

    static func parse(_ data: Data) throws -> ActivityReport {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid("not a JSON object") }
        guard root["schema"] as? String == schema else { throw invalid("unknown schema") }
        guard let version = integer(root["version"]), version == self.version else { throw invalid("unsupported version") }
        guard let device = root["device"] as? [String: Any], let deviceName = string(device["name"]) else { throw invalid("missing device name") }
        guard let generatedAt = instant(root["generated_at"]) else { throw invalid("missing generated_at") }
        guard let since = instant(root["since"]), isHour(since) else { throw invalid("missing or unaligned since") }
        guard let rawMetrics = root["metrics"] as? [String: Any] else { throw invalid("missing metrics") }
        var metrics: [String: ActivityMetricInfo] = [:]
        for (key, raw) in rawMetrics {
            guard key.count <= maxStringLength, !key.isEmpty, let info = raw as? [String: Any],
                  let label = string(info["label"]), let unit = string(info["unit"]) else { throw invalid("malformed metric") }
            metrics[key] = ActivityMetricInfo(label: label, unit: unit)
        }
        guard let rawRows = root["rows"] as? [Any], rawRows.count <= maxRows else { throw invalid("missing rows") }
        let rows = try rawRows.map { raw -> ActivityRow in
            guard let row = raw as? [String: Any],
                  let metric = string(row["metric"]), metrics[metric] != nil,
                  let bucket = instant(row["bucket"]), isHour(bucket),
                  let session = string(row["session"]),
                  let mirror = row["mirror"] as? Bool, isBoolean(row["mirror"]),
                  let rawLabels = row["labels"] as? [String: Any], rawLabels.count <= 16,
                  let value = number(row["value"]), value.isFinite, value >= 0 else { throw invalid("malformed row") }
            var labels: [String: String] = [:]
            for (key, rawValue) in rawLabels {
                guard key.count <= maxStringLength, let value = string(rawValue) else { throw invalid("malformed label") }
                labels[key] = value
            }
            return ActivityRow(metric: metric, bucket: bucket, session: session, mirror: mirror, labels: labels, value: value)
        }
        return ActivityReport(device: deviceName, generatedAt: generatedAt, since: since, metrics: metrics, rows: rows)
    }

    private static func invalid(_ reason: String) -> ActivitySourceError { .invalidOutput(reason) }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= maxStringLength else { return nil }
        return value
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value == value.rounded() else { return nil }
        return Int(value)
    }

    private static func instant(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return InstantFormat.plain.date(from: text) ?? InstantFormat.fractional.date(from: text)
    }

    private static func isHour(_ date: Date) -> Bool {
        date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3_600) == 0
    }
}

enum InstantFormat {
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct ActivityTotals: Equatable, Sendable {
    let today: Double
    let sevenDays: Double
    let thirtyDays: Double
}

enum ActivityMath {
    static let tokens = "tokens"
    static let userMessages = "user_messages"
    static let initialBackfill: TimeInterval = 30 * 86_400
    /// Stored rows loaded for display; covers thirty days in any timezone.
    static let displayWindow: TimeInterval = 32 * 86_400

    /// Counts each session once across sources. A session's rows are kept from a source where it
    /// is not a mirror, else from the source with the largest total; ties keep the earlier source.
    static func deduplicated(_ sources: [(id: UUID, rows: [ActivityRow])]) -> [UUID: [ActivityRow]] {
        struct Claim { let order: Int; let native: Bool; let total: Double }
        var claims: [String: [UUID: Claim]] = [:]
        for (order, source) in sources.enumerated() {
            for row in source.rows {
                let previous = claims[row.session]?[source.id]
                claims[row.session, default: [:]][source.id] = Claim(
                    order: order,
                    native: (previous?.native ?? false) || !row.mirror,
                    total: (previous?.total ?? 0) + row.value
                )
            }
        }
        var owner: [String: UUID] = [:]
        for (session, bySource) in claims where bySource.count > 1 {
            let candidates = bySource.contains { $0.value.native } ? bySource.filter(\.value.native) : bySource
            owner[session] = candidates.min { lhs, rhs in
                lhs.value.total != rhs.value.total ? lhs.value.total > rhs.value.total : lhs.value.order < rhs.value.order
            }?.key
        }
        var result: [UUID: [ActivityRow]] = [:]
        for source in sources {
            result[source.id] = source.rows.filter { owner[$0.session].map { $0 == source.id } ?? true }
        }
        return result
    }

    static func total(_ rows: [ActivityRow], metric: String, components: Set<String>? = nil, from start: Date, to end: Date) -> Double {
        rows.reduce(0) { sum, row in
            guard row.metric == metric, row.bucket >= start, row.bucket < end else { return sum }
            if let components, !components.contains(row.labels["component"] ?? "") { return sum }
            return sum + row.value
        }
    }

    static func totals(_ rows: [ActivityRow], metric: String, components: Set<String>? = nil, now: Date, calendar: Calendar) -> ActivityTotals {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today)!
        return ActivityTotals(
            today: total(rows, metric: metric, components: components, from: today, to: tomorrow),
            sevenDays: total(rows, metric: metric, components: components, from: weekStart, to: tomorrow),
            thirtyDays: total(rows, metric: metric, components: components, from: monthStart, to: tomorrow)
        )
    }

    /// Start of the next run: one hour before the previous run, or the initial backfill.
    static func nextSince(lastGeneratedAt: Date?, now: Date) -> Date {
        let start = lastGeneratedAt.map { $0.addingTimeInterval(-3_600) } ?? now.addingTimeInterval(-initialBackfill)
        return Date(timeIntervalSince1970: (start.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    }
}

/// Splits a command line into argv without invoking a shell. Supports single and double quotes
/// and backslash escapes; it performs no expansion of any kind.
enum CommandLineSplitter {
    static func split(_ text: String) -> [String]? {
        var arguments: [String] = []
        var current = ""
        var inArgument = false
        var quote: Character?
        var escaping = false
        for character in text {
            if escaping {
                current.append(character); escaping = false; inArgument = true
            } else if character == "\\", quote != "'" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; inArgument = true
            } else if character.isWhitespace {
                if inArgument { arguments.append(current); current = ""; inArgument = false }
            } else {
                current.append(character); inArgument = true
            }
        }
        guard quote == nil, !escaping else { return nil }
        if inArgument { arguments.append(current) }
        return arguments
    }

    static func join(_ argv: [String]) -> String {
        argv.map { argument in
            guard argument.isEmpty || argument.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) else { return argument }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
