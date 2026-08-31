import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot
}

struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

protocol CodexRPCTransport: Sendable {
    func request(method: String, params: [String: AnySendable]?) async throws -> [String: AnySendable]
}

protocol CodexRateLimitNotifying: Sendable {
    func rateLimitUpdates() async -> AsyncStream<Void>
}

enum CodexExecutableResolver {
    static func resolve(
        explicit: URL? = nil,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> URL? {
        if let explicit { return isExecutable(explicit) ? explicit : nil }
        let pathCandidate = path?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }
            .first(where: isExecutable)
        return pathCandidate ?? ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            .map(URL.init(fileURLWithPath:))
            .first(where: isExecutable)
    }
}

actor CodexAppServerTransport: CodexRPCTransport, CodexRateLimitNotifying {
    private struct Pending {
        let continuation: CheckedContinuation<[String: AnySendable], Error>
        let timeout: Task<Void, Never>
    }

    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: Pending] = [:]
    private var startupTask: Task<Void, Error>?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private let timeout: Duration
    private let executableURL: URL?
    private var rateLimitUpdateContinuation: AsyncStream<Void>.Continuation?

    init(timeout: Duration = .seconds(15), executableURL: URL? = nil) {
        self.timeout = timeout
        self.executableURL = executableURL
    }

    func rateLimitUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            rateLimitUpdateContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearRateLimitContinuation() }
            }
        }
    }

    func request(method: String, params: [String: AnySendable]? = nil) async throws -> [String: AnySendable] {
        try Task.checkCancellation()
        try await ensureInitialized()
        try Task.checkCancellation()
        return try await requestRaw(method: method, params: params)
    }

    private func ensureInitialized() async throws {
        try Task.checkCancellation()
        if process != nil, startupTask == nil { return }
        if let startupTask { return try await awaitStartup(startupTask) }
        let task = Task { [weak self] in
            guard let self else { throw ProviderError.unavailable }
            try await self.startAndInitialize()
        }
        startupTask = task
        do { try await awaitStartup(task); startupTask = nil }
        catch { startupTask = nil; stop(); throw error }
    }

    private func awaitStartup(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler(operation: {
            try await task.value
            try Task.checkCancellation()
        }, onCancel: {
            task.cancel()
            Task { await self.stop() }
        })
    }

    private func startAndInitialize() async throws {
        guard process == nil else { return }
        try Task.checkCancellation()
        guard let executable = CodexExecutableResolver.resolve(explicit: executableURL) else {
            throw ProviderError.unavailable
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in Task { await self?.processEnded() } }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        try Task.checkCancellation()
        readTask = Task { [weak self] in
            do { for try await line in stdout.fileHandleForReading.bytes.lines { await self?.handle(line: line) } } catch { }
            await self?.processEnded()
        }
        _ = try await requestRaw(method: "initialize", params: ["clientInfo": AnySendable(["name": "QuotaBar", "version": "0.1.0"])])
        try Task.checkCancellation()
        try sendNotification(method: "initialized", params: nil)
    }

    private func requestRaw(method: String, params: [String: AnySendable]?) async throws -> [String: AnySendable] {
        try Task.checkCancellation()
        guard let input else { throw ProviderError.unavailable }
        let id = nextID
        nextID += 1
        var request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { request["params"] = params.mapValues(\.value) }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.timeout ?? .seconds(15))
                    await self?.timeoutRequest(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: timeoutTask)
                do { try input.write(contentsOf: data) }
                catch {
                    let request = pending.removeValue(forKey: id)
                    request?.timeout.cancel()
                    continuation.resume(throwing: ProviderError.unavailable)
                }
            }
        }, onCancel: {
            Task { await self.cancelRequest(id) }
        })
    }

    private func sendNotification(method: String, params: [String: AnySendable]?) throws {
        guard let input else { throw ProviderError.unavailable }
        var notification: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { notification["params"] = params.mapValues(\.value) }
        var data = try JSONSerialization.data(withJSONObject: notification)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["id"] == nil, object["method"] as? String == "account/rateLimits/updated" {
            rateLimitUpdateContinuation?.yield()
            return
        }
        guard let rawID = object["id"] as? NSNumber,
              let request = pending.removeValue(forKey: rawID.intValue) else { return }
        request.timeout.cancel()
        if object["error"] != nil { request.continuation.resume(throwing: ProviderError.unavailable) }
        else if let result = object["result"] as? [String: Any] { request.continuation.resume(returning: result.mapValues(AnySendable.init)) }
        else { request.continuation.resume(throwing: ProviderError.malformedResponse) }
    }

    private func timeoutRequest(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: ProviderError.unavailable)
    }

    private func cancelRequest(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func processEnded() {
        let requests = pending.values
        pending.removeAll()
        for request in requests { request.timeout.cancel(); request.continuation.resume(throwing: ProviderError.unavailable) }
        input = nil
        process = nil
        readTask?.cancel()
        readTask = nil
    }

    private func clearRateLimitContinuation() { rateLimitUpdateContinuation = nil }

    private func stop() { process?.terminate(); processEnded() }
}

protocol ProviderUpdateNotifying: Sendable {
    func updates() async -> AsyncStream<ProviderID>
}

struct CodexProvider: UsageProvider, ProviderUpdateNotifying {
    let id: ProviderID = .codex
    let transport: any CodexRPCTransport

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        async let usage = transport.request(method: "account/usage/read", params: nil)
        async let limits = transport.request(method: "account/rateLimits/read", params: nil)
        let (usageResult, limitsResult) = try await (usage, limits)
        try Task.checkCancellation()
        return ProviderSnapshot(provider: .codex, dailyUsage: try parseCodexDaily(usageResult), lifetimeTokens: try parseCodexLifetime(usageResult), quotaWindows: try parseCodexWindows(limitsResult), health: .fresh, updatedAt: now, coverage: "Codex account estimate", detail: nil)
    }

    func updates() async -> AsyncStream<ProviderID> {
        guard let notifier = transport as? any CodexRateLimitNotifying else {
            return AsyncStream { $0.finish() }
        }
        let source = await notifier.rateLimitUpdates()
        return AsyncStream { continuation in
            let task = Task {
                for await _ in source { continuation.yield(.codex) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct ZCodeCredential: Sendable {
    let token: String
    let baseURL: URL
}

protocol ZCodeCredentialDiscovering: Sendable { func credential() async throws -> ZCodeCredential }

struct LocalZCodeCredentialDiscovery: ZCodeCredentialDiscovering {
    let consent: @Sendable () -> Bool
    let configURL: URL

    init(consent: @escaping @Sendable () -> Bool, configURL: URL? = nil) {
        self.consent = consent
        self.configURL = configURL ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zcode/v2/config.json")
    }

    func credential() async throws -> ZCodeCredential {
        try Task.checkCancellation()
        guard consent() else { throw ProviderError.credentialUnavailable }
        guard let credential = try readCodingPlanCredential(at: configURL) else { throw ProviderError.credentialUnavailable }
        try Task.checkCancellation()
        return credential
    }

    private func readCodingPlanCredential(at url: URL) throws -> ZCodeCredential? {
        guard let data = try? Data(contentsOf: url),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["provider"] as? [String: Any],
              let plan = providers["builtin:zai-coding-plan"] as? [String: Any],
              plan["enabled"] as? Bool == true,
              let options = plan["options"] as? [String: Any],
              let token = options["apiKey"] as? String, !token.isEmpty,
              let rawURL = options["baseURL"] as? String,
              let baseURL = URL(string: rawURL) else { return nil }
        return ZCodeCredential(token: token, baseURL: baseURL)
    }

}

protocol HTTPClient: Sendable { func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) }

struct URLSessionHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ProviderError.unavailable }
        return (data, http)
    }
}

struct ZCodeProvider: UsageProvider {
    let id: ProviderID = .zcode
    let store: any UsageStore
    let credentials: any ZCodeCredentialDiscovering
    let http: any HTTPClient
    private let providerCalendar: Calendar

    init(store: any UsageStore, credentials: any ZCodeCredentialDiscovering, http: any HTTPClient = URLSessionHTTPClient()) {
        self.store = store
        self.credentials = credentials
        self.http = http
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        providerCalendar = calendar
    }

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        let credential = try await credentials.credential()
        try Task.checkCancellation()
        let sealed = try await store.sealedMonths()
        try Task.checkCancellation()
        let start = providerCalendar.date(from: DateComponents(year: 2025, month: 1, day: 1))!
        let currentMonth = monthKey(now, calendar: providerCalendar)
        var cursor = start
        while cursor < now {
            try Task.checkCancellation()
            let month = monthKey(cursor, calendar: providerCalendar)
            let next = providerCalendar.date(byAdding: .month, value: 1, to: cursor)!
            if month == currentMonth || !sealed.contains(month) {
                let end = month == currentMonth ? now : next.addingTimeInterval(-1)
                let usage = try await fetchUsage(start: cursor, end: end, credential: credential)
                try Task.checkCancellation()
                try await store.saveMonth(month, usage: usage, sealed: month != currentMonth)
            }
            cursor = next
        }
        try Task.checkCancellation()
        let daily = try await store.monthUsage()
        let quotas = try await fetchQuotas(credential: credential)
        try Task.checkCancellation()
        return ProviderSnapshot(provider: .zcode, dailyUsage: daily, lifetimeTokens: daily.reduce(0) { $0 + $1.tokens }, quotaWindows: quotas, health: .fresh, updatedAt: now, coverage: "ZCode account total since 2025-01-01", detail: "Usage timestamps are interpreted as UTC")
    }

    private func fetchUsage(start: Date, end: Date, credential: ZCodeCredential) async throws -> [DailyUsage] {
        try Task.checkCancellation()
        var components = URLComponents(url: endpoint("api/monitor/usage/model-usage", baseURL: credential.baseURL), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "startTime", value: zcodeDateString(start)), URLQueryItem(name: "endTime", value: zcodeDateString(end))]
        let data = try await request(components.url!, credential: credential)
        try Task.checkCancellation()
        return try parseZCodeUsage(data)
    }

    private func fetchQuotas(credential: ZCodeCredential) async throws -> [QuotaWindow] {
        try Task.checkCancellation()
        let data = try await request(endpoint("api/monitor/usage/quota/limit", baseURL: credential.baseURL), credential: credential)
        try Task.checkCancellation()
        return try parseZCodeQuotas(data)
    }

    private func request(_ url: URL, credential: ZCodeCredential) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        switch response.statusCode { case 200..<300: return data; case 401, 403: throw ProviderError.authenticationRequired; default: throw ProviderError.unavailable }
    }

    private func endpoint(_ path: String, baseURL: URL) -> URL {
        ZCodeEndpoint.originEndpoint(baseURL: baseURL, path: path)
    }
}

enum ZCodeEndpoint {
    static func originEndpoint(baseURL: URL, path: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.url ?? baseURL
    }
}

private func parseCodexLifetime(_ result: [String: AnySendable]) throws -> Double {
    guard let summary = result["summary"]?.value as? [String: Any], let lifetime = number(in: summary, keys: ["lifetimeTokens"]) else { throw ProviderError.malformedResponse }
    return lifetime
}

private func parseCodexDaily(_ result: [String: AnySendable]) throws -> [DailyUsage] {
    guard let raw = result["dailyUsageBuckets"] else { return [] }
    guard let buckets = raw.value as? [[String: Any]] else { throw ProviderError.malformedResponse }
    return try buckets.map { bucket in
        guard let label = bucket["startDate"] as? String, let date = DateFormatter.yyyyMMdd.date(from: label), let tokens = number(in: bucket, keys: ["tokens"]) else { throw ProviderError.malformedResponse }
        return DailyUsage(day: date, tokens: tokens, dateLabel: label)
    }
}

private func parseCodexWindows(_ result: [String: AnySendable]) throws -> [QuotaWindow] {
    var snapshots: [(id: String, snapshot: [String: Any])] = []
    var legacy: [String: Any]?
    if let rawLegacy = result["rateLimits"]?.value {
        guard let parsedLegacy = rawLegacy as? [String: Any] else { throw ProviderError.malformedResponse }
        legacy = parsedLegacy
        snapshots.append((parsedLegacy["limitId"] as? String ?? "legacy", parsedLegacy))
    }
    if let rawByID = result["rateLimitsByLimitId"]?.value {
        guard let byID = rawByID as? [String: Any] else { throw ProviderError.malformedResponse }
        for (id, raw) in byID.sorted(by: { $0.key < $1.key }) {
            guard let snapshot = raw as? [String: Any] else { throw ProviderError.malformedResponse }
            if id != legacy?["limitId"] as? String { snapshots.append((id, snapshot)) }
        }
    }
    return try snapshots.flatMap { item in
        let label = (item.snapshot["limitName"] as? String) ?? (item.snapshot["limitId"] as? String)
        let preferredKeys = ["primary", "secondary"]
        let metadataKeys: Set<String> = ["credits", "individualLimit", "limitId", "limitName"]
        let otherKeys = item.snapshot.keys
            .filter { !preferredKeys.contains($0) && !metadataKeys.contains($0) }
            .sorted()
        let keys = preferredKeys + otherKeys
        var windows: [QuotaWindow] = []
        for key in keys {
            guard let value = item.snapshot[key] else { continue }
            guard let raw = value as? [String: Any], !raw.isEmpty,
                  let used = number(in: raw, keys: ["usedPercent"]) else { throw ProviderError.malformedResponse }
            let duration = number(in: raw, keys: ["windowDurationMins"])
            let name = label ?? codexWindowName(key: key, duration: duration)
            let reset = number(in: raw, keys: ["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            windows.append(QuotaWindow(id: "codex-\(item.id)-\(key)", name: name, used: used, limit: 100, resetAt: reset, unit: "% used"))
        }
        return windows
    }
}

private func codexWindowName(key: String, duration: Double?) -> String {
    guard let duration else { return key.capitalized }
    if duration == 300 { return "5-hour" }
    if duration == 10_080 { return "Weekly" }
    return "\(Int(duration))-minute \(key)"
}

private func parseZCodeUsage(_ data: Data) throws -> [DailyUsage] {
    let payload = try zcodeDataEnvelope(data)
    guard let times = payload["x_time"] as? [String], let usages = payload["tokensUsage"] as? [Any], times.count == usages.count else { throw ProviderError.malformedResponse }
    return try zip(times, usages).map { time, rawUsage in
        guard let timestamp = DateFormatter.zcodeHour.date(from: time), let tokens = numeric(rawUsage) else { throw ProviderError.malformedResponse }
        return DailyUsage(day: timestamp, tokens: tokens)
    }
}

private func parseZCodeQuotas(_ data: Data) throws -> [QuotaWindow] {
    let payload = try zcodeDataEnvelope(data)
    guard let limits = payload["limits"] as? [[String: Any]] else { throw ProviderError.malformedResponse }
    return try limits.enumerated().map { index, item in
        guard let type = item["type"] as? String,
              let unitValue = number(in: item, keys: ["unit"]),
              let numberRaw = number(in: item, keys: ["number"]),
              let used = number(in: item, keys: ["currentValue"]),
              let limit = number(in: item, keys: ["usage"]), limit > 0,
              let resetRaw = number(in: item, keys: ["nextResetTime"]) else { throw ProviderError.malformedResponse }
        let unit = Int(unitValue)
        let numberValue = Int(numberRaw)
        let isMCP = type.localizedCaseInsensitiveContains("mcp")
        let name: String
        if unit == 3 && numberValue == 5 { name = "5-hour" }
        else if unit == 6 && numberValue == 1 { name = "Weekly" }
        else if isMCP { name = (item["name"] as? String) ?? "MCP" }
        else { name = (item["name"] as? String) ?? "ZCode quota \(index + 1)" }
        return QuotaWindow(id: "zcode-\(index)-\(name)", name: name, used: used, limit: limit, resetAt: Date(timeIntervalSince1970: resetRaw / 1_000), unit: isMCP ? "MCP calls" : "quota")
    }
}

private func zcodeDataEnvelope(_ data: Data) throws -> [String: Any] {
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let code = number(in: envelope, keys: ["code"]) else { throw ProviderError.malformedResponse }
    if code == 401 || code == 403 { throw ProviderError.authenticationRequired }
    guard code == 200, envelope["success"] as? Bool == true,
          let payload = envelope["data"] as? [String: Any] else { throw ProviderError.malformedResponse }
    return payload
}

private func number(in object: [String: Any], keys: [String]) -> Double? { keys.lazy.compactMap { numeric(object[$0]) }.first }
private func numeric(_ value: Any?) -> Double? {
    if let value = value as? NSNumber {
        guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? Int64 { return Double(value) }
    return nil
}
private func monthKey(_ date: Date, calendar: Calendar) -> String { let values = calendar.dateComponents([.year, .month], from: date); return String(format: "%04d-%02d", values.year ?? 0, values.month ?? 0) }
private func zcodeDateString(_ date: Date) -> String { DateFormatter.zcodeQuery.string(from: date) }
private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0); value.dateFormat = "yyyy-MM-dd"; return value }()
    static let zcodeHour: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0); value.dateFormat = "yyyy-MM-dd HH:mm"; return value }()
    static let zcodeQuery: DateFormatter = { let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0); value.dateFormat = "yyyy-MM-dd HH:mm:ss"; return value }()
}
