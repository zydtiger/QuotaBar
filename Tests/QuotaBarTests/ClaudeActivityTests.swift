import XCTest
@testable import QuotaBar

final class ClaudeQuotaTests: XCTestCase {
    func testParsesEveryReportedWindowWithoutNamingModels() throws {
        let body = """
        {"five_hour":{"utilization":12.5,"resets_at":"2026-11-11T23:00:00.123+00:00"},
         "seven_day":{"utilization":40,"resets_at":"2026-11-15T00:00:00Z"},
         "seven_day_fable":{"utilization":71,"resets_at":null},
         "seven_day_opus":null,
         "seven_day_oauth_apps":{"utilization":null},
         "extra_usage":{"is_enabled":false},
         "new_window":{"utilization":3}}
        """
        let windows = try parseClaudeWindows(Data(body.utf8))
        XCTAssertEqual(windows.map(\.name), ["5-hour", "Weekly · All models", "Weekly · Fable", "New Window"])
        XCTAssertEqual(windows.map(\.used), [12.5, 40, 71, 3])
        XCTAssertEqual(windows[0].limit, 100)
        XCTAssertEqual(windows[1].resetAt, instant("2026-11-15T00:00:00Z"))
        XCTAssertNotNil(windows[0].resetAt)
        XCTAssertNil(windows[2].resetAt)
    }

    func testLimitsArrayProvidesSessionWeeklyAndScopedWindows() throws {
        // Field names follow the live response; values are invented.
        let body = """
        {"five_hour":{"utilization":21.0,"resets_at":"2026-11-12T08:00:00.100000+00:00","used_dollars":null},
         "seven_day":{"utilization":55.0,"resets_at":"2026-11-14T21:00:00.100000+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,
         "extra_usage":{"is_enabled":false,"utilization":null,"monthly_limit":null},
         "seven_day_breakdown":{"as_of":"2026-11-12T03:00:00+00:00","rows":[{"key":"chat","display_name":"Chats","percent":100}]},
         "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":20,"allowance_percent_of_weekly":50}],
         "limits":[
          {"group":"session","kind":"session","scope":null,"severity":"normal","is_active":false,"percent":21,"resets_at":"2026-11-12T08:00:00.100000+00:00"},
          {"group":"weekly","kind":"weekly_all","scope":null,"severity":"warning","is_active":true,"percent":55,"resets_at":"2026-11-14T21:00:00.100000+00:00"},
          {"group":"weekly","kind":"weekly_scoped","scope":{"model":{"id":null,"display_name":"Bard"},"surface":null},"severity":"normal","is_active":false,"percent":40,"resets_at":null}]}
        """
        let windows = try parseClaudeWindows(Data(body.utf8))
        XCTAssertEqual(windows.map(\.name), ["5-hour", "Weekly · All models", "Weekly · Bard"])
        XCTAssertEqual(windows.map(\.used), [21, 55, 40])
        XCTAssertEqual(windows.map(\.id), ["claude-session", "claude-weekly_all", "claude-weekly_scoped-bard"])
        XCTAssertEqual(try XCTUnwrap(windows[1].resetAt).timeIntervalSince1970, instant("2026-11-14T21:00:00Z").timeIntervalSince1970 + 0.1, accuracy: 0.001)
        XCTAssertNil(windows[2].resetAt)
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"limits":{}}"#.utf8)))
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"limits":[{"kind":"session","percent":"21"}]}"#.utf8)))
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"limits":[{"percent":21}]}"#.utf8)))
    }

    func testMissingWindowsAreEmptyAndMalformedWindowsFail() throws {
        XCTAssertEqual(try parseClaudeWindows(Data("{}".utf8)), [])
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"five_hour":{"utilization":"12"}}"#.utf8)))
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"five_hour":{"utilization":true}}"#.utf8)))
        XCTAssertThrowsError(try parseClaudeWindows(Data(#"{"five_hour":{"utilization":1,"resets_at":"soon"}}"#.utf8)))
        XCTAssertThrowsError(try parseClaudeWindows(Data("[]".utf8)))
    }

    func testRequestUsesBearerAndBetaHeader() async throws {
        let http = RecordingHTTP(status: 200, body: #"{"five_hour":{"utilization":1}}"#)
        let provider = ClaudeProvider(credentials: StaticClaudeCredential(expiresAt: .distantFuture), http: http)
        let snapshot = try await provider.refresh(now: .now, calendar: .current)
        XCTAssertEqual(snapshot.health, .fresh)
        XCTAssertEqual(snapshot.lifetimeTokens, 0)
        XCTAssertEqual(snapshot.dailyUsage, [])
        let request = await http.requests.first
        XCTAssertEqual(request?.url, ClaudeProvider.usageURL)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
    }

    func testExpiredTokenRequiresSignInWithoutRequest() async {
        let http = RecordingHTTP(status: 200, body: "{}")
        let provider = ClaudeProvider(credentials: StaticClaudeCredential(expiresAt: Date(timeIntervalSinceNow: -60)), http: http)
        await XCTAssertThrowsProviderError(.authenticationRequired) { _ = try await provider.refresh(now: .now, calendar: .current) }
        let count = await http.requests.count
        XCTAssertEqual(count, 0)
    }

    func testUnauthorizedResponsesRequireSignIn() async {
        for status in [401, 403] {
            let provider = ClaudeProvider(credentials: StaticClaudeCredential(expiresAt: nil), http: RecordingHTTP(status: status, body: "{}"))
            await XCTAssertThrowsProviderError(.authenticationRequired) { _ = try await provider.refresh(now: .now, calendar: .current) }
        }
    }

    func testCredentialRequiresConsentAndNeverReadsWithoutIt() async throws {
        let reads = Counter()
        let denied = KeychainClaudeCredentialDiscovery(consent: { false }, readItem: { await reads.increment(); return Data() })
        await XCTAssertThrowsProviderError(.credentialUnavailable) { _ = try await denied.credential() }
        let readCount = await reads.value
        XCTAssertEqual(readCount, 0)

        let missing = KeychainClaudeCredentialDiscovery(consent: { true }, readItem: { throw ProviderError.credentialUnavailable })
        await XCTAssertThrowsProviderError(.credentialUnavailable) { _ = try await missing.credential() }

        let item = #"{"claudeAiOauth":{"accessToken":"fixture-access","expiresAt":1700000000000,"refreshToken":"fixture-refresh"}}"#
        let allowed = KeychainClaudeCredentialDiscovery(consent: { true }, readItem: { Data(item.utf8) })
        let credential = try await allowed.credential()
        XCTAssertEqual(credential.accessToken, "fixture-access")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertThrowsError(try KeychainClaudeCredentialDiscovery.parse(Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }

    func testAuthenticationFailureKeepsCachedClaudeSnapshotStale() async {
        let store = InMemoryUsageStore()
        let cached = ProviderSnapshot(provider: .claude, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [QuotaWindow(id: "claude-five_hour", name: "5-hour", used: 20, limit: 100, resetAt: nil, unit: "% used")], health: .fresh, updatedAt: .now, coverage: "Claude account quota", detail: nil)
        await store.save(snapshot: cached)
        let provider = ClaudeProvider(credentials: StaticClaudeCredential(expiresAt: nil), http: RecordingHTTP(status: 401, body: "{}"))
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.claude: provider], preferences: AppPreferences(codexEnabled: false, zcodeEnabled: false))
        }
        await model.refresh()
        let result = await MainActor.run { model.snapshots[.claude] }
        XCTAssertEqual(result?.health, .stale)
        XCTAssertEqual(result?.quotaWindows.first?.used, 20)
        XCTAssertTrue(result?.detail?.contains("sign in") == true)
    }
}

final class ActivityTests: XCTestCase {
    func testParserAcceptsSchemaAndRejectsViolations() throws {
        let report = try ActivityReportParser.parse(document())
        XCTAssertEqual(report.device, "fixture-host")
        XCTAssertEqual(report.rows.count, 1)
        XCTAssertEqual(report.rows[0].labels["component"], "output")

        let violations: [[String: Any]] = [
            ["schema": "other"],
            ["version": 2],
            ["since": "2026-11-11T00:30:00Z"],
            ["rows": [row(metric: "undeclared")]],
            ["rows": [row(bucket: "2026-11-11T10:15:00Z")]],
            ["rows": [row(value: -1)]],
            ["rows": [row(value: true)]],
            ["rows": [row(mirror: 1)]],
            ["rows": [row(session: "")]],
            ["rows": "none"],
            ["device": [:]],
        ]
        for violation in violations {
            XCTAssertThrowsError(try ActivityReportParser.parse(document(violation)), "\(violation)")
        }
        XCTAssertThrowsError(try ActivityReportParser.parse(Data("not json".utf8)))
    }

    func testMirroredSessionCountsOnceAndPrefersNativeSource() {
        let mac = UUID(), remote = UUID()
        let bucket = instant("2026-11-11T20:00:00Z")
        let macRows = [
            ActivityRow(metric: "user_messages", bucket: bucket, session: "local", mirror: false, labels: [:], value: 80),
            ActivityRow(metric: "user_messages", bucket: bucket, session: "remote", mirror: true, labels: [:], value: 5),
        ]
        let remoteRows = [ActivityRow(metric: "user_messages", bucket: bucket, session: "remote", mirror: false, labels: [:], value: 5)]
        let deduped = ActivityMath.deduplicated([(mac, macRows), (remote, remoteRows)])
        XCTAssertEqual(deduped[mac]?.map(\.session), ["local"])
        XCTAssertEqual(deduped[remote]?.map(\.session), ["remote"])
        let total = deduped.values.flatMap { $0 }.reduce(0) { $0 + $1.value }
        XCTAssertEqual(total, 85)

        // Without the remote source, the mirror is the only copy and still counts.
        XCTAssertEqual(ActivityMath.deduplicated([(mac, macRows)])[mac]?.count, 2)

        // Two mirrors keep the more complete copy.
        let a = UUID(), b = UUID()
        let small = [ActivityRow(metric: "user_messages", bucket: bucket, session: "s", mirror: true, labels: [:], value: 2)]
        let large = [ActivityRow(metric: "user_messages", bucket: bucket, session: "s", mirror: true, labels: [:], value: 3)]
        let mirrors = ActivityMath.deduplicated([(a, small), (b, large)])
        XCTAssertEqual(mirrors[a], [])
        XCTAssertEqual(mirrors[b], large)
    }

    func testActivityDayBoundaryFollowsCalendar() {
        let rows = [
            ActivityRow(metric: "tokens", bucket: instant("2026-11-12T03:00:00Z"), session: "s", mirror: false, labels: ["component": "output"], value: 10),
            ActivityRow(metric: "tokens", bucket: instant("2026-11-12T03:00:00Z"), session: "s", mirror: false, labels: ["component": "cache_read"], value: 1_000),
            ActivityRow(metric: "tokens", bucket: instant("2026-11-05T06:00:00Z"), session: "s", mirror: false, labels: ["component": "input"], value: 1),
            ActivityRow(metric: "tokens", bucket: instant("2026-11-05T04:00:00Z"), session: "s", mirror: false, labels: ["component": "input"], value: 100),
            ActivityRow(metric: "tokens", bucket: instant("2026-10-13T02:00:00Z"), session: "s", mirror: false, labels: ["component": "output"], value: 10_000),
        ]
        let now = instant("2026-11-12T04:30:00Z") // 23:30 on Nov 11 in New York
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Headline tokens sum every component; the 30-day window starts Oct 13 local, after the oldest row.
        XCTAssertEqual(ActivityMath.totals(rows, metric: "tokens", now: now, calendar: newYork), ActivityTotals(today: 1_010, sevenDays: 1_011, thirtyDays: 1_111))
        XCTAssertEqual(ActivityMath.totals(rows, metric: "tokens", now: now, calendar: utc), ActivityTotals(today: 1_010, sevenDays: 1_010, thirtyDays: 1_111))
        XCTAssertEqual(ActivityMath.totals(rows, metric: "tokens", components: ["cache_read"], now: now, calendar: newYork).today, 1_000)
    }

    func testNextSinceIsHourAlignedWithOverlapAndInitialBackfill() {
        let now = instant("2026-11-11T21:26:40Z")
        XCTAssertEqual(ActivityMath.nextSince(lastGeneratedAt: instant("2026-11-11T21:20:00Z"), now: now), instant("2026-11-11T20:00:00Z"))
        XCTAssertEqual(ActivityMath.nextSince(lastGeneratedAt: nil, now: now), instant("2026-10-12T21:00:00Z"))
    }

    func testCommandLineSplitterRoundTripsWithoutShellExpansion() {
        XCTAssertEqual(CommandLineSplitter.split("ssh -o BatchMode=yes  host python3 -"), ["ssh", "-o", "BatchMode=yes", "host", "python3", "-"])
        XCTAssertEqual(CommandLineSplitter.split(#"cmd "a b" 'c "d"' e\ f $HOME"#), ["cmd", "a b", #"c "d""#, "e f", "$HOME"])
        XCTAssertNil(CommandLineSplitter.split("cmd 'open"))
        let argv = ["/path with space/tool", "it's", "", "plain"]
        XCTAssertEqual(CommandLineSplitter.split(CommandLineSplitter.join(argv)), argv)
    }

    func testStoreReplacesOpenPeriodAndKeepsPastDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteUsageStore(url: directory.appending(path: "cache.sqlite"))
        let source = UUID()
        let old = ActivityRow(metric: "tokens", bucket: instant("2026-11-01T10:00:00Z"), session: "s", mirror: false, labels: ["component": "input", "model": "m"], value: 7)
        let open = ActivityRow(metric: "tokens", bucket: instant("2026-11-11T10:00:00Z"), session: "s", mirror: false, labels: ["component": "input", "model": "m"], value: 1)
        try await store.replaceActivity(source: source, report: report(since: "2026-11-01T00:00:00Z", rows: [old, open]))
        let updated = ActivityRow(metric: "tokens", bucket: open.bucket, session: "s", mirror: false, labels: open.labels, value: 4)
        try await store.replaceActivity(source: source, report: report(since: "2026-11-11T00:00:00Z", rows: [updated]))
        let rows = try await store.activityRows(since: .distantPast)[source] ?? []
        XCTAssertEqual(Set(rows), [old, updated])
        let records = try await store.activitySources()
        XCTAssertEqual(records[source]?.device, "fixture-host")
        try await store.deleteActivity(source: source)
        let afterDelete = try await store.activityRows(since: .distantPast)[source]
        XCTAssertNil(afterDelete)
    }

    func testFailingSourceKeepsPriorDataAsStale() async throws {
        let store = InMemoryUsageStore()
        let runner = ScriptedRunner(results: [
            .success(CommandResult(status: 0, stdout: document(["rows": [row(value: 9, bucket: hourString(Date.now))]]), stderr: Data())),
            .failure(ActivitySourceError.timedOut),
            .success(CommandResult(status: 255, stdout: Data(), stderr: Data("ssh: Could not resolve hostname x".utf8))),
        ])
        let collector = ActivityCollector(runner: runner, collectorScript: Data("script".utf8), resolve: { URL(fileURLWithPath: "/bin/\($0)") })
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(codexEnabled: false, zcodeEnabled: false), activityStore: store, activityCollector: collector)
        }
        let source = ActivitySourceConfig.thisMac.id
        await model.refreshActivity()
        var status = await MainActor.run { model.activityStatus[source] }
        XCTAssertEqual(status?.health, .fresh)
        await model.refreshActivity()
        status = await MainActor.run { model.activityStatus[source] }
        XCTAssertEqual(status?.health, .stale)
        XCTAssertEqual(status?.detail, ActivitySourceError.timedOut.message)
        await model.refreshActivity()
        status = await MainActor.run { model.activityStatus[source] }
        XCTAssertEqual(status?.detail, ActivitySourceError.failed(.hostUnreachable, status: 255).message)
        let rows = await MainActor.run { model.activityRows[source] ?? [] }
        XCTAssertEqual(rows.map(\.value), [9])
        let arguments = await runner.arguments
        XCTAssertEqual(arguments.first?.prefix(2), ["-", "--since"])
        let input = await runner.inputs.first ?? nil
        XCTAssertEqual(input, Data("script".utf8))
    }

    func testChangingCommandStartsFreshHistoryAndDropsOldRows() async throws {
        let store = InMemoryUsageStore()
        let runner = ScriptedRunner(results: [.success(CommandResult(status: 0, stdout: document(["rows": [row(value: 9, bucket: hourString(Date.now))]]), stderr: Data()))])
        let collector = ActivityCollector(runner: runner, collectorScript: Data(), resolve: { URL(fileURLWithPath: "/bin/\($0)") })
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(codexEnabled: false, zcodeEnabled: false), activityStore: store, activityCollector: collector)
        }
        await model.refreshActivity()
        let oldID = ActivitySourceConfig.thisMac.id
        var renamed = ActivitySourceConfig.thisMac
        renamed.name = "Renamed"
        let sameID = await MainActor.run { model.updateActivitySource(renamed) }
        XCTAssertEqual(sameID, oldID)
        var moved = renamed
        moved.argv = ["ssh", "other", "python3", "-"]
        let newID = await MainActor.run { model.updateActivitySource(moved) }
        XCTAssertNotEqual(newID, oldID)
        let (rows, status) = await MainActor.run { (model.activityRows, model.activityStatus[oldID]) }
        XCTAssertNil(rows[oldID])
        XCTAssertEqual(rows[newID], [])
        XCTAssertNil(status)
        for _ in 0..<50 where await store.activitySources()[oldID] != nil { try await Task.sleep(for: .milliseconds(10)) }
        let stored = await store.activityRows(since: .distantPast)[oldID] ?? []
        XCTAssertEqual(stored, [])
    }

    func testPreferencesPersistOnlyToInjectedDefaults() async throws {
        try await MainActor.run {
            let suite = "quotabar-tests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = UsageViewModel(store: InMemoryUsageStore(), providers: [:], defaults: defaults)
            let source = ActivitySourceConfig(id: UUID(), name: "Remote", argv: ["ssh", "host", "python3", "-"], enabled: true, pipesCollector: true)
            model.addActivitySource(source)
            let stored = try JSONDecoder().decode([ActivitySourceConfig].self, from: XCTUnwrap(defaults.data(forKey: "activitySources")))
            XCTAssertEqual(stored, [.thisMac, source])
        }
    }

    func testConcurrentActivityRefreshesNeverOverlap() async {
        let store = InMemoryUsageStore()
        let runner = SlowRunner(output: document(["rows": []]))
        let collector = ActivityCollector(runner: runner, collectorScript: Data(), resolve: { URL(fileURLWithPath: "/bin/\($0)") })
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(codexEnabled: false, zcodeEnabled: false), activityStore: store, activityCollector: collector)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await model.refreshActivity() } }
        }
        let (calls, maxActive) = await (runner.calls, runner.maxActive)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(maxActive, 1)
        let refreshing = await MainActor.run { model.isRefreshingActivity }
        XCTAssertFalse(refreshing)
    }

    func testActivityNeverEntersAccountAggregateOrExportTotals() async throws {
        let store = InMemoryUsageStore()
        let runner = ScriptedRunner(results: [.success(CommandResult(status: 0, stdout: document(["rows": [row(value: 500, bucket: hourString(Date.now))]]), stderr: Data()))])
        let collector = ActivityCollector(runner: runner, collectorScript: Data(), resolve: { URL(fileURLWithPath: "/bin/\($0)") })
        let codex = ProviderSnapshot(provider: .codex, dailyUsage: [DailyUsage(day: .now, tokens: 10)], lifetimeTokens: 100, quotaWindows: [], health: .fresh, updatedAt: .now, coverage: "fixture", detail: nil)
        let claude = ProviderSnapshot(provider: .claude, dailyUsage: [DailyUsage(day: .now, tokens: 999)], lifetimeTokens: 999, quotaWindows: [], health: .fresh, updatedAt: .now, coverage: "Claude account quota", detail: nil)
        await store.save(snapshot: codex)
        await store.save(snapshot: claude)
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(zcodeEnabled: false), activityStore: store, activityCollector: collector)
        }
        await model.loadCachedSnapshots()
        await model.refreshActivity()
        let aggregate = await MainActor.run { model.aggregate }
        XCTAssertEqual(aggregate, ProviderTotals(today: 10, sevenDays: 10, lifetime: 100))

        let records = UsageExport.records([codex, claude], preferences: AppPreferences(zcodeEnabled: false), now: .now, activity: [
            ActivityExportSource(name: "This Mac", device: "fixture-host", generatedAt: .now, health: .fresh, metrics: ["tokens": ActivityMetricInfo(label: "Tokens", unit: "tokens")], rows: [
                ActivityRow(metric: "tokens", bucket: instant("2026-11-11T10:00:00Z"), session: "a", mirror: false, labels: ["component": "output"], value: 3),
                ActivityRow(metric: "tokens", bucket: instant("2026-11-11T10:00:00Z"), session: "b", mirror: false, labels: ["component": "output"], value: 4),
            ])
        ])
        let claudeSnapshot = records.first { $0.provider == .claude && $0.rowType == .snapshot }
        XCTAssertNil(claudeSnapshot?.today)
        XCTAssertNil(claudeSnapshot?.lifetime)
        let activity = records.filter { $0.rowType == .activity }
        XCTAssertEqual(activity.map(\.value), [7])
        XCTAssertEqual(activity.first?.labels, "component=output")
        let csv = String(decoding: UsageExport.csv([codex, claude], preferences: AppPreferences(zcodeEnabled: false), now: .now), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix(UsageExportRecord.csvHeader))
    }

    func testProcessRunnerEnforcesTimeoutOutputLimitAndStatus() async throws {
        let runner = ProcessCommandRunner()
        let started = Date()
        await XCTAssertThrowsActivityError(.timedOut) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], input: nil, timeout: .milliseconds(200), outputLimit: 1_000)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        await XCTAssertThrowsActivityError(.outputTooLarge) {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], input: nil, timeout: .seconds(5), outputLimit: 1_000)
        }
        let echoed = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("hello".utf8), timeout: .seconds(5), outputLimit: 1_000)
        XCTAssertEqual(echoed, CommandResult(status: 0, stdout: Data("hello".utf8), stderr: Data()))
        let failed = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Permission denied (publickey).' >&2; exit 255"], input: nil, timeout: .seconds(5), outputLimit: 1_000)
        XCTAssertEqual(ActivitySourceError.classify(status: failed.status, stderr: failed.stderr), .failed(.sshAuthentication, status: 255))
    }

    func testProcessRunnerCancellationStopsCommand() async {
        let task = Task {
            try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], input: nil, timeout: .seconds(10), outputLimit: 1_000)
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testResolverFindsBareNamesOutsideMinimalPath() {
        let found = ExecutableResolver.resolve("tool", path: "/usr/bin:/bin", fallbackDirectories: ["/opt/x/bin"], isExecutable: { $0.path == "/opt/x/bin/tool" })
        XCTAssertEqual(found?.path, "/opt/x/bin/tool")
        XCTAssertNil(ExecutableResolver.resolve("missing", path: "/usr/bin", fallbackDirectories: [], isExecutable: { _ in false }))
        XCTAssertEqual(ExecutableResolver.resolve("/abs/tool", path: nil, fallbackDirectories: [], isExecutable: { _ in true })?.path, "/abs/tool")
    }

    func testCollectorCountsSyntheticTranscriptsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let native = "11111111-1111-1111-1111-111111111111"
        let mirrored = "22222222-2222-2222-2222-222222222222"
        func user(_ uuid: String, session: String, time: String, content: Any, extra: [String: Any] = [:]) -> [String: Any] {
            ["type": "user", "uuid": uuid, "sessionId": session, "timestamp": time, "message": ["role": "user", "content": content]].merging(extra) { $1 }
        }
        func assistant(_ id: String, request: String, session: String, time: String, output: Int, sidechain: Bool = false) -> [String: Any] {
            ["type": "assistant", "uuid": UUID().uuidString, "sessionId": session, "timestamp": time, "requestId": request, "isSidechain": sidechain,
             "message": ["id": id, "model": "model-a", "usage": ["input_tokens": 3, "output_tokens": output, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0]]]
        }
        let entries: [[String: Any]] = [
            user("u1", session: native, time: "2026-11-11T20:05:00.000Z", content: "synthetic one"),
            user("u1", session: native, time: "2026-11-11T20:05:00.000Z", content: "synthetic one"),
            user("u2", session: native, time: "2026-11-11T20:10:00.000Z", content: [["type": "text", "text": "synthetic two"]]),
            user("u3", session: native, time: "2026-11-11T20:11:00.000Z", content: [["type": "tool_result", "content": "x"]]),
            user("u4", session: native, time: "2026-11-11T20:12:00.000Z", content: "<command-name>/x</command-name>"),
            user("u5", session: native, time: "2026-11-11T20:13:00.000Z", content: "synthetic", extra: ["isMeta": true]),
            user("u6", session: native, time: "2026-11-11T20:14:00.000Z", content: "synthetic", extra: ["isSidechain": true]),
            user("u7", session: native, time: "2026-11-11T20:15:00.000Z", content: "   "),
            user("u0", session: native, time: "2026-11-01T20:15:00.000Z", content: "before since"),
            assistant("m1", request: "r1", session: native, time: "2026-11-11T20:06:00.000Z", output: 10),
            assistant("m1", request: "r1", session: native, time: "2026-11-11T20:06:01.000Z", output: 50),
            assistant("m2", request: "r2", session: native, time: "2026-11-11T21:06:00.000Z", output: 7, sidechain: true),
            // Started before --since: the previous run already counted it.
            assistant("m3", request: "r3", session: native, time: "2026-11-09T23:59:59.000Z", output: 1),
            assistant("m3", request: "r3", session: native, time: "2026-11-10T00:00:02.000Z", output: 900),
        ]
        try write(entries, to: root.appending(path: "project/\(native).jsonl"))
        try write([user("u9", session: mirrored, time: "2026-11-11T20:30:00Z", content: "synthetic mirror")], to: root.appending(path: "ssh-\(mirrored)/\(mirrored).jsonl"))

        let collector = ActivityCollector(runner: ProcessCommandRunner(), collectorScript: try Data(contentsOf: collectorURL), timeout: .seconds(30))
        let source = ActivitySourceConfig(id: UUID(), name: "fixture", argv: ["/usr/bin/python3", "-", "--root", root.path], enabled: true, pipesCollector: true)
        let report = try await collector.collect(source, since: instant("2026-11-10T00:00:00Z"))

        let messages = report.rows.filter { $0.metric == "user_messages" }
        XCTAssertEqual(messages.filter { !$0.mirror }.reduce(0) { $0 + $1.value }, 2)
        XCTAssertEqual(messages.filter(\.mirror).map(\.session), [mirrored])
        let output = report.rows.filter { $0.metric == "tokens" && $0.labels["component"] == "output" }
        XCTAssertEqual(output.map(\.value), [50, 7])
        XCTAssertEqual(output.first?.labels["model"], "model-a")
        XCTAssertEqual(report.rows.filter { $0.labels["component"] == "cache_read" }.reduce(0) { $0 + $1.value }, 200)
        XCTAssertTrue(report.rows.allSatisfy { $0.labels["component"] != "cache_creation" })
        XCTAssertEqual(report.since, instant("2026-11-10T00:00:00Z"))
    }
}

// MARK: - Helpers

private let collectorURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/QuotaBar/Resources/claude_activity_collector.py")

private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

private func hourString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600))
}

private func row(metric: String = "tokens", value: Any = 12, bucket: String = "2026-11-11T10:00:00Z", mirror: Any = false, session: String = "session-a") -> [String: Any] {
    ["metric": metric, "bucket": bucket, "session": session, "mirror": mirror, "labels": ["component": "output", "model": "model-a"], "value": value]
}

private func document(_ overrides: [String: Any] = [:]) -> Data {
    var root: [String: Any] = [
        "schema": "quotabar.activity", "version": 1,
        "device": ["name": "fixture-host"],
        "generated_at": "2026-11-11T21:26:00Z", "since": "2026-11-01T00:00:00Z",
        "metrics": ["tokens": ["label": "Tokens", "unit": "tokens"], "user_messages": ["label": "User messages", "unit": "messages"]],
        "rows": [row()],
    ]
    root.merge(overrides) { $1 }
    return try! JSONSerialization.data(withJSONObject: root)
}

private func report(since: String, rows: [ActivityRow]) -> ActivityReport {
    ActivityReport(device: "fixture-host", generatedAt: instant("2026-11-11T21:00:00Z"), since: instant(since), metrics: ["tokens": ActivityMetricInfo(label: "Tokens", unit: "tokens")], rows: rows)
}

private func write(_ entries: [[String: Any]], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lines = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func XCTAssertThrowsProviderError(_ expected: ProviderError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? ProviderError, expected, file: file, line: line) }
}

private func XCTAssertThrowsActivityError(_ expected: ActivitySourceError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? ActivitySourceError, expected, file: file, line: line) }
}

private struct StaticClaudeCredential: ClaudeCredentialDiscovering {
    let expiresAt: Date?
    func credential() async throws -> ClaudeCredential { ClaudeCredential(accessToken: "fixture-access", expiresAt: expiresAt) }
}

private actor RecordingHTTP: HTTPClient {
    let status: Int
    let body: String
    private(set) var requests: [URLRequest] = []
    init(status: Int, body: String) { self.status = status; self.body = body }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor SlowRunner: CommandRunning {
    let output: Data
    private(set) var calls = 0
    private(set) var maxActive = 0
    private var active = 0
    init(output: Data) { self.output = output }
    func run(executable: URL, arguments: [String], input: Data?, timeout: Duration, outputLimit: Int) async throws -> CommandResult {
        calls += 1
        active += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(for: .milliseconds(50))
        active -= 1
        return CommandResult(status: 0, stdout: output, stderr: Data())
    }
}

private actor ScriptedRunner: CommandRunning {
    private var results: [Result<CommandResult, Error>]
    private(set) var arguments: [[String]] = []
    private(set) var inputs: [Data?] = []
    init(results: [Result<CommandResult, Error>]) { self.results = results }
    func run(executable: URL, arguments: [String], input: Data?, timeout: Duration, outputLimit: Int) async throws -> CommandResult {
        self.arguments.append(arguments)
        inputs.append(input)
        return try results.removeFirst().get()
    }
}
