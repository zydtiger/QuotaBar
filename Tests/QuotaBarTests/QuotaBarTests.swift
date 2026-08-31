import XCTest
@testable import QuotaBar

final class QuotaBarTests: XCTestCase {
    func testTotalsRespectConfiguredDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = date("2026-08-31T04:30:00Z")
        let usage = [
            DailyUsage(day: date("2026-08-31T04:00:00Z"), tokens: 100),
            DailyUsage(day: date("2026-08-30T04:00:00Z"), tokens: 50),
            DailyUsage(day: date("2026-08-24T04:00:00Z"), tokens: 99)
        ]
        XCTAssertEqual(UsageMath.totals(for: snapshot(.codex, daily: usage, lifetime: 900), now: now, calendar: calendar), ProviderTotals(today: 100, sevenDays: 150, lifetime: 900))
    }

    func testAggregateAndExportsUseEnabledPreferences() throws {
        let codex = snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 10)], lifetime: 100)
        let zcode = snapshot(.zcode, daily: [DailyUsage(day: .now, tokens: 20)], lifetime: 200)
        let preferences = AppPreferences(zcodeEnabled: false)
        XCTAssertEqual(UsageMath.aggregate([codex, zcode], enabled: preferences.enabled, now: .now, calendar: .current), ProviderTotals(today: 10, sevenDays: 10, lifetime: 100))
        let json = try UsageExport.json([zcode, codex], preferences: preferences)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([UsageExportRecord].self, from: json)
        XCTAssertEqual(Set(decoded.map(\.provider)), [.codex])
        let csv = String(decoding: UsageExport.csv([zcode, codex], preferences: preferences, now: .now), as: UTF8.self)
        XCTAssertEqual(csv.components(separatedBy: "\n").count, decoded.count + 1)
        for record in decoded {
            XCTAssertTrue(csv.contains("\"\(record.rowType.rawValue)\",\"\(record.provider.rawValue)\""))
        }
    }

    func testBackoffIsCappedAndResets() {
        let policy = BackoffPolicy(base: 300, cap: 1_000)
        XCTAssertEqual(policy.delay(afterFailures: 0), 300)
        XCTAssertEqual(policy.delay(afterFailures: 1), 600)
        XCTAssertEqual(policy.delay(afterFailures: 2), 1_000)
    }

    func testProviderDiagnosticsPresentationUsesSnapshotAndFallbackStates() {
        let updatedAt = date("2026-08-31T12:00:00Z")
        let freshSnapshot = ProviderSnapshot(
            provider: .codex,
            dailyUsage: [],
            lifetimeTokens: 1,
            quotaWindows: [],
            health: .fresh,
            updatedAt: updatedAt,
            coverage: "Codex account estimate",
            detail: "Signed-in account"
        )
        let staleSnapshot = ProviderSnapshot(
            provider: .zcode,
            dailyUsage: [],
            lifetimeTokens: 1,
            quotaWindows: [],
            health: .stale,
            updatedAt: updatedAt,
            coverage: "ZCode account total since 2025-01-01",
            detail: "Cached account snapshot"
        )
        let fresh = ProviderDiagnosticsPresentation.make(provider: .codex, enabled: true, snapshot: freshSnapshot)
        XCTAssertEqual(fresh.stateLabel, "Connected")
        XCTAssertEqual(fresh.coverage, "Codex account estimate")
        XCTAssertEqual(fresh.updatedAt, updatedAt)
        XCTAssertEqual(fresh.detail, "Signed-in account")

        let stale = ProviderDiagnosticsPresentation.make(provider: .zcode, enabled: true, snapshot: staleSnapshot)
        XCTAssertEqual(stale.stateLabel, "Stale")
        XCTAssertEqual(stale.coverage, "ZCode account total since 2025-01-01")

        let disabled = ProviderDiagnosticsPresentation.make(provider: .codex, enabled: false, snapshot: nil)
        XCTAssertEqual(disabled.stateLabel, "Disabled")
        XCTAssertEqual(disabled.coverage, "Disabled")
        XCTAssertNil(disabled.updatedAt)

        let disabledSnapshot = ProviderDiagnosticsPresentation.make(
            provider: .codex,
            enabled: false,
            snapshot: .disabled(.codex, now: updatedAt)
        )
        XCTAssertEqual(disabledSnapshot.stateLabel, "Disabled")
        XCTAssertNil(disabledSnapshot.updatedAt)
        XCTAssertNil(disabledSnapshot.detail)

        let noSnapshot = ProviderDiagnosticsPresentation.make(provider: .zcode, enabled: true, snapshot: nil)
        XCTAssertEqual(noSnapshot.stateLabel, "No account snapshot")
        XCTAssertEqual(noSnapshot.coverage, "No account snapshot")
        XCTAssertNil(noSnapshot.health)
    }

    func testCodexProviderParsesObservedSchema() async throws {
        let provider = CodexProvider(transport: ObservedCodexTransport())
        let result = try await provider.refresh(now: date("2026-08-31T12:00:00Z"), calendar: .current)
        XCTAssertEqual(result.lifetimeTokens, 42_000)
        XCTAssertEqual(result.dailyUsage.count, 2)
        XCTAssertEqual(result.dailyUsage.map(\.dateLabel), ["2026-08-30", "2026-08-31"])
        XCTAssertEqual(result.quotaWindows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(result.quotaWindows.first?.used, 37)
        XCTAssertEqual(result.quotaWindows.first?.unit, "% used")
    }

    func testCodexDateLabelsRemainCalendarBucketsAcrossTimezones() async throws {
        let provider = CodexProvider(transport: ObservedCodexTransport())
        let result = try await provider.refresh(now: date("2026-08-31T12:00:00Z"), calendar: .current)
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(UsageMath.totals(for: result, now: date("2026-08-31T12:00:00Z"), calendar: newYork).today, 34)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(UsageMath.totals(for: result, now: date("2026-08-31T12:00:00Z"), calendar: tokyo).today, 34)
        XCTAssertEqual(result.dailyUsage.map(\.dateLabel), ["2026-08-30", "2026-08-31"])
    }

    func testCodexMissingRequiredSummaryDoesNotProduceZeroSnapshot() async {
        do {
            _ = try await CodexProvider(transport: MalformedCodexTransport()).refresh(now: .now, calendar: .current)
            XCTFail("Expected malformed schema failure")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .malformedResponse)
        } catch { XCTFail("Unexpected error") }
    }

    func testCodexEmptyRateLimitsKeepsValidUsageFresh() async throws {
        let result = try await CodexProvider(transport: EmptyLimitsCodexTransport()).refresh(now: date("2026-08-31T12:00:00Z"), calendar: .current)
        XCTAssertEqual(result.health, .fresh)
        XCTAssertEqual(result.lifetimeTokens, 42_000)
        XCTAssertEqual(result.dailyUsage.map(\.tokens), [12, 34])
        XCTAssertTrue(result.quotaWindows.isEmpty)
    }

    func testCodexMalformedNonemptyRateLimitsStillFails() async {
        do {
            _ = try await CodexProvider(transport: MalformedLimitsCodexTransport()).refresh(now: .now, calendar: .current)
            XCTFail("Expected malformed rate-limit failure")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testCodexEmptyPrimaryWindowIsMalformed() async {
        do {
            _ = try await CodexProvider(transport: EmptyPrimaryCodexTransport()).refresh(now: .now, calendar: .current)
            XCTFail("Expected malformed primary window")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testCodexBooleanTokenIsMalformed() async {
        do {
            _ = try await CodexProvider(transport: BooleanTokenCodexTransport()).refresh(now: .now, calendar: .current)
            XCTFail("Expected Boolean token value to be rejected")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .malformedResponse)
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testZCodeObservedHourlyEnvelopeAndQuotaSchema() async throws {
        let store = InMemoryUsageStore()
        let http = ObservedZCodeHTTP()
        let provider = ZCodeProvider(store: store, credentials: FixedCredential(), http: http)
        let result = try await provider.refresh(now: date("2025-01-02T00:00:00Z"), calendar: .current)
        XCTAssertEqual(result.lifetimeTokens, 30)
        XCTAssertEqual(result.quotaWindows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(result.quotaWindows[0].used, 25)
        XCTAssertEqual(result.quotaWindows[0].limit, 100)
        let query = await http.firstUsageQuery
        XCTAssertEqual(query?["startTime"], "2025-01-01 00:00:00")
        XCTAssertEqual(query?["endTime"], "2025-01-02 00:00:00")
    }

    func testZCodeRejectsHTTP200FailureEnvelope() async {
        let provider = ZCodeProvider(store: InMemoryUsageStore(), credentials: FixedCredential(), http: FailureEnvelopeHTTP())
        do {
            _ = try await provider.refresh(now: date("2025-01-01T01:00:00Z"), calendar: .current)
            XCTFail("Expected schema failure")
        } catch let error as ProviderError { XCTAssertEqual(error, .authenticationRequired) }
        catch { XCTFail("Unexpected error") }
    }

    func testMalformedZCodeQuotaPreservesCachedSnapshot() async {
        let store = InMemoryUsageStore()
        await store.save(snapshot: snapshot(.zcode, daily: [DailyUsage(day: .now, tokens: 12)], lifetime: 12))
        let provider = ZCodeProvider(store: store, credentials: FixedCredential(), http: MalformedQuotaHTTP())
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.zcode: provider], preferences: AppPreferences(codexEnabled: false))
        }
        await model.refresh()
        let result = await MainActor.run { model.snapshots[.zcode] }
        XCTAssertEqual(result?.health, .stale)
        XCTAssertEqual(result?.lifetimeTokens, 12)
    }

    func testZCodeBooleanNumericValuePreservesCachedSnapshot() async {
        let store = InMemoryUsageStore()
        await store.save(snapshot: snapshot(.zcode, daily: [DailyUsage(day: .now, tokens: 12)], lifetime: 12))
        let provider = ZCodeProvider(store: store, credentials: FixedCredential(), http: BooleanUsageZCodeHTTP())
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.zcode: provider], preferences: AppPreferences(codexEnabled: false))
        }
        await model.refresh()
        let result = await MainActor.run { model.snapshots[.zcode] }
        XCTAssertEqual(result?.health, .stale)
        XCTAssertEqual(result?.lifetimeTokens, 12)
    }

    func testZCodeBackfillSealsOnlySuccessfulClosedMonthsAndRecovers() async throws {
        let store = InMemoryUsageStore()
        let http = InterruptingZCodeHTTP()
        let provider = ZCodeProvider(store: store, credentials: FixedCredential(), http: http)
        let now = date("2025-03-15T12:00:00Z")
        do { _ = try await provider.refresh(now: now, calendar: .current); XCTFail("Expected interruption") } catch { }
        let sealedAfterInterruption = await store.sealedMonths()
        XCTAssertEqual(sealedAfterInterruption, Set(["2025-01"]))
        await http.allowRecovery()
        _ = try await provider.refresh(now: now, calendar: .current)
        let sealedAfterRecovery = await store.sealedMonths()
        let januaryRequests = await http.januaryRequests
        XCTAssertEqual(sealedAfterRecovery, Set(["2025-01", "2025-02"]))
        XCTAssertEqual(januaryRequests, 1, "sealed month must not refetch after recovery")
    }

    func testTimezoneChangeDoesNotRewriteStoredZCodeInstants() async throws {
        let store = InMemoryUsageStore()
        let provider = ZCodeProvider(store: store, credentials: FixedCredential(), http: ObservedZCodeHTTP())
        _ = try await provider.refresh(now: date("2025-01-02T00:00:00Z"), calendar: .current)
        let original = await store.monthUsage().map(\.day)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        _ = UsageMath.totals(for: snapshot(.zcode, daily: await store.monthUsage(), lifetime: 30), now: date("2025-01-02T00:00:00Z"), calendar: tokyo)
        let afterTimezoneChange = await store.monthUsage().map(\.day)
        XCTAssertEqual(afterTimezoneChange, original)
    }

    func testRefreshOnOpenFalseDoesNotStartImmediatePoll() async {
        let provider = CountingProvider(.codex)
        let preferences = AppPreferences(zcodeEnabled: false, refreshOnOpen: false)
        let model = await MainActor.run { UsageViewModel(store: InMemoryUsageStore(), providers: [.codex: provider], preferences: preferences) }
        await model.panelOpened()
        await Task.yield()
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    func testChangingRefreshIntervalCancelsOldSleepAndUsesReplacementSchedule() async {
        let sleeper = ControlledSleeper()
        let provider = CountingProvider(.codex)
        let model = await MainActor.run {
            UsageViewModel(
                store: InMemoryUsageStore(),
                providers: [.codex: provider],
                preferences: AppPreferences(zcodeEnabled: false),
                periodicSleep: { duration in try await sleeper.sleep(for: duration) }
            )
        }
        await model.appStarted()
        await sleeper.waitForActiveSleepCount(1)
        await MainActor.run { model.setRefreshInterval(900) }
        await sleeper.waitForSleepCount(2)
        await sleeper.waitForActiveSleepCount(1)
        let beforeRelease = await provider.calls
        XCTAssertEqual(beforeRelease, 0)
        let released = await sleeper.releaseOnlyActiveSleep()
        XCTAssertTrue(released)
        await provider.waitUntilCalls(1)
        let afterRelease = await provider.calls
        XCTAssertEqual(afterRelease, 1)
        let interval = await MainActor.run { model.preferences.refreshInterval }
        XCTAssertEqual(interval, 900)
    }

    func testBadCodexPrimaryPreservesCachedSnapshotAsStale() async {
        let store = InMemoryUsageStore()
        await store.save(snapshot: snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 9)], lifetime: 90))
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.codex: CodexProvider(transport: BadPrimaryCodexTransport())], preferences: AppPreferences(zcodeEnabled: false))
        }
        await model.refresh()
        let result = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(result?.health, .stale)
        XCTAssertEqual(result?.lifetimeTokens, 90)
    }

    func testCachedSnapshotsLoadAsStaleBeforeNetworkRefresh() async {
        let store = InMemoryUsageStore()
        await store.save(snapshot: snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 7)], lifetime: 70))
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(zcodeEnabled: false))
        }
        await model.loadCachedSnapshots()
        let cached = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(cached?.health, .stale)
        XCTAssertEqual(cached?.lifetimeTokens, 70)
    }

    func testJoinedHydrationReturnsOnlyAfterCacheCommit() async {
        let cached = snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 7)], lifetime: 70)
        let store = DelayedHydrationStore(cached: cached)
        let provider = CountingProvider(.codex)
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false))
        }

        let owner = Task { await model.loadCachedSnapshots() }
        await store.waitUntilAllSnapshotsStarted()
        let joined = Task { await model.loadCachedSnapshots() }
        await Task.yield()
        await store.releaseAllSnapshots()

        await joined.value
        let joinedSnapshot = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(joinedSnapshot?.health, .stale)
        XCTAssertEqual(joinedSnapshot?.lifetimeTokens, 70)

        await model.refresh()
        await provider.waitUntilCalls(1)
        let refreshedSnapshot = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(refreshedSnapshot?.health, .fresh)
        await owner.value
    }

    func testRefreshWaitsForDelayedHydrationBeforeProviderCall() async {
        let cached = snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 7)], lifetime: 70)
        let store = DelayedHydrationStore(cached: cached)
        let provider = BlockingProvider(.codex)
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false))
        }

        let firstHydration = Task { await model.loadCachedSnapshots() }
        await store.waitUntilAllSnapshotsStarted()
        let joinedHydration = Task { await model.loadCachedSnapshots() }
        let refresh = Task { await model.refresh() }
        await Task.yield()

        let hydrationReads = await store.allSnapshotsReadCount
        let providerCallsBeforeRelease = await provider.calls
        XCTAssertEqual(hydrationReads, 1)
        XCTAssertEqual(providerCallsBeforeRelease, 0)
        await store.releaseAllSnapshots()
        await provider.waitUntilStarted()

        let cacheFirstSnapshot = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(cacheFirstSnapshot?.health, .stale)
        XCTAssertEqual(cacheFirstSnapshot?.lifetimeTokens, 70)

        await provider.release()
        await refresh.value
        await joinedHydration.value
        await firstHydration.value

        let finalSnapshot = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(finalSnapshot?.health, .fresh)
        XCTAssertEqual(finalSnapshot?.lifetimeTokens, 99)
    }

    func testFailedHydrationClearsStateAndRetries() async {
        let cached = snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 7)], lifetime: 70)
        let store = FailingThenSucceedingHydrationStore(cached: cached)
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [:], preferences: AppPreferences(zcodeEnabled: false))
        }

        await model.loadCachedSnapshots()
        let afterFailure = await MainActor.run { model.snapshots[.codex] }
        XCTAssertNil(afterFailure)

        await model.loadCachedSnapshots()
        let reads = await store.allSnapshotsReadCount
        let afterRetry = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(afterRetry?.health, .stale)
        XCTAssertEqual(afterRetry?.lifetimeTokens, 70)
    }

    func testDisableDuringRefreshPreventsLateResult() async {
        let provider = BlockingProvider(.codex)
        let model = await MainActor.run { UsageViewModel(store: InMemoryUsageStore(), providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false)) }
        let refresh = Task { await model.refresh() }
        await provider.waitUntilStarted()
        await MainActor.run { model.setEnabled(false, for: .codex) }
        await provider.release()
        await refresh.value
        let state = await MainActor.run { model.snapshots[.codex]?.health }
        XCTAssertEqual(state, .disabled)
    }

    func testDisableCancelsProviderTaskBeforeLateWork() async {
        let provider = CancellableBlockingProvider(.codex)
        let model = await MainActor.run {
            UsageViewModel(store: InMemoryUsageStore(), providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false))
        }
        let refresh = Task { await model.refresh() }
        await provider.waitUntilStarted()
        await MainActor.run { model.setEnabled(false, for: .codex) }
        await provider.waitUntilCancelled()
        await refresh.value
        let lateWorkCount = await provider.lateWorkCount
        let cancellationCount = await provider.cancellationCount
        XCTAssertEqual(lateWorkCount, 0)
        XCTAssertEqual(cancellationCount, 1)
    }

    func testReenableShowsLoadingUntilProviderSucceeds() async {
        let provider = BlockingProvider(.codex)
        let model = await MainActor.run {
            UsageViewModel(store: InMemoryUsageStore(), providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false))
        }
        await MainActor.run { model.setEnabled(false, for: .codex) }
        let loading = await MainActor.run { () -> ProviderSnapshot? in
            model.setEnabled(true, for: .codex)
            return model.snapshots[.codex]
        }
        XCTAssertEqual(loading?.health, .loading)
        XCTAssertEqual(loading?.coverage, "Waiting for account data")
        let presentation = ProviderDiagnosticsPresentation.make(provider: .codex, enabled: true, snapshot: loading)
        XCTAssertEqual(presentation.stateLabel, "Loading")

        await provider.waitUntilStarted()
        await provider.release()
        for _ in 0..<20 {
            let health = await MainActor.run { model.snapshots[.codex]?.health }
            if health == .fresh { return }
            await Task.yield()
        }
        XCTFail("Expected successful refresh after re-enabling provider")
    }

    func testReenableQueuesNewProviderPollAfterActiveRefreshCompletes() async {
        let codex = FirstRequestCancelledThenSucceedsProvider()
        let zcode = BlockingProvider(.zcode)
        let model = await MainActor.run {
            UsageViewModel(store: InMemoryUsageStore(), providers: [.codex: codex, .zcode: zcode])
        }
        let oldRefresh = Task { await model.refresh() }
        await codex.waitUntilFirstRequestStarted()
        await MainActor.run { model.setEnabled(false, for: .codex) }
        await codex.waitUntilFirstRequestCancelled()
        await zcode.waitUntilStarted()

        let loading = await MainActor.run { () -> ProviderSnapshot? in
            model.setEnabled(true, for: .codex)
            return model.snapshots[.codex]
        }
        XCTAssertEqual(loading?.health, .loading)

        await zcode.release()
        await oldRefresh.value
        let calls = await codex.calls
        let state = await MainActor.run { model.snapshots[.codex]?.health }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(state, .fresh)
    }

    func testDelayedCachedFailureCannotOverwriteNewEnabledGeneration() async {
        let cached = ProviderSnapshot(
            provider: .codex,
            dailyUsage: [DailyUsage(day: .now, tokens: 99)],
            lifetimeTokens: 99,
            quotaWindows: [],
            health: .fresh,
            updatedAt: .now,
            coverage: "Cached fixture",
            detail: nil
        )
        let store = DelayedCacheStore(cached: cached)
        let provider = FirstFailureThenBlockingProvider()
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.codex: provider], preferences: AppPreferences(zcodeEnabled: false))
        }
        let refresh = Task { await model.refresh() }
        await store.waitUntilCacheReadStarted()
        await MainActor.run {
            model.setEnabled(false, for: .codex)
            model.setEnabled(true, for: .codex)
        }
        await store.releaseCacheRead()
        await provider.waitUntilSecondRequestStarted()

        let loading = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(loading?.health, .loading)
        XCTAssertEqual(loading?.lifetimeTokens, 0)

        await provider.releaseSecondRequest()
        await refresh.value
        let finalState = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(finalState?.health, .fresh)
    }

    func testCodexBooleanQuotaPreservesCachedSnapshot() async {
        let store = InMemoryUsageStore()
        await store.save(snapshot: snapshot(.codex, daily: [DailyUsage(day: .now, tokens: 9)], lifetime: 90))
        let model = await MainActor.run {
            UsageViewModel(store: store, providers: [.codex: CodexProvider(transport: BooleanQuotaCodexTransport())], preferences: AppPreferences(zcodeEnabled: false))
        }
        await model.refresh()
        let result = await MainActor.run { model.snapshots[.codex] }
        XCTAssertEqual(result?.health, .stale)
        XCTAssertEqual(result?.lifetimeTokens, 90)
    }

    func testCodexParsesDistinctLegacyAndLimitIDBuckets() async throws {
        let result = try await CodexProvider(transport: MultiBucketCodexTransport()).refresh(now: .now, calendar: .current)
        XCTAssertEqual(result.quotaWindows.count, 4)
        XCTAssertEqual(Set(result.quotaWindows.map(\.name)), ["Plan", "Secondary plan"])
        XCTAssertEqual(Set(result.quotaWindows.map(\.id)).count, 4)
        XCTAssertEqual(result.quotaWindows.map(\.id), ["codex-plan-primary", "codex-secondary-primary", "codex-secondary-secondary", "codex-secondary-tertiary"])
    }

    func testCodexExecutableResolverUsesExplicitThenPathThenKnownLocations() {
        let executable: (URL) -> Bool = { ["/custom/codex", "/bin/codex", "/opt/homebrew/bin/codex"].contains($0.path) }
        XCTAssertEqual(CodexExecutableResolver.resolve(explicit: URL(fileURLWithPath: "/custom/codex"), path: nil, isExecutable: executable)?.path, "/custom/codex")
        XCTAssertEqual(CodexExecutableResolver.resolve(path: "/missing:/bin", isExecutable: executable)?.path, "/bin/codex")
        XCTAssertEqual(CodexExecutableResolver.resolve(path: "/missing", isExecutable: executable)?.path, "/opt/homebrew/bin/codex")
    }

    func testCodexRateLimitNotificationYieldsSignal() async {
        let transport = CodexAppServerTransport(executableURL: URL(fileURLWithPath: "/missing"))
        let stream = await transport.rateLimitUpdates()
        let signal = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        await transport.handle(line: #"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{}}"#)
        let received = await signal.value
        XCTAssertTrue(received)
    }

    func testZCodeUsesConfiguredOriginForMonitorPaths() async throws {
        let http = PathRecordingZCodeHTTP()
        let provider = ZCodeProvider(store: InMemoryUsageStore(), credentials: FixedCredential(baseURL: "https://api.z.ai/api/anthropic"), http: http)
        _ = try await provider.refresh(now: date("2025-01-01T01:00:00Z"), calendar: .current)
        let paths = await http.paths
        XCTAssertEqual(paths, ["/api/monitor/usage/model-usage", "/api/monitor/usage/quota/limit"])
    }

    func testZCodeClosedMonthsEndBeforeNextMonthAndSkipZeroLengthCurrentMonth() async throws {
        let http = QueryRecordingZCodeHTTP()
        let provider = ZCodeProvider(store: InMemoryUsageStore(), credentials: FixedCredential(), http: http)
        _ = try await provider.refresh(now: date("2025-02-01T00:00:00Z"), calendar: .current)
        let queries = await http.usageQueries
        XCTAssertEqual(queries.count, 1)
        XCTAssertEqual(queries.first?.0, "2025-01-01 00:00:00")
        XCTAssertEqual(queries.first?.1, "2025-01-31 23:59:59")
    }

    func testZCodeCredentialDiscoveryAcceptsOnlyEnabledCodingPlanConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "config.json")
        let discovery = LocalZCodeCredentialDiscovery(consent: { true }, configURL: config)
        do { _ = try await discovery.credential(); XCTFail("Expected missing credential") } catch let error as ProviderError { XCTAssertEqual(error, .credentialUnavailable) }
        try JSONSerialization.data(withJSONObject: ["provider": ["builtin:zai-coding-plan": ["enabled": false, "options": ["apiKey": "fixture", "baseURL": "https://api.z.ai/api/anthropic"]]]]).write(to: config)
        do { _ = try await discovery.credential(); XCTFail("Expected disabled credential") } catch let error as ProviderError { XCTAssertEqual(error, .credentialUnavailable) }
        try JSONSerialization.data(withJSONObject: ["provider": ["builtin:zai-coding-plan": ["enabled": true, "options": ["apiKey": "fixture", "baseURL": "https://api.z.ai/api/anthropic"]]]]).write(to: config)
        let credential = try await discovery.credential()
        XCTAssertEqual(credential.baseURL.absoluteString, "https://api.z.ai/api/anthropic")
    }

    func testQuotaClassificationUsesBothThresholdsAndOrdering() {
        var preferences = AppPreferences(warningThreshold: 0.8, criticalThreshold: 0.95)
        preferences.setWarningThreshold(0.99)
        XCTAssertEqual(preferences.warningThreshold, 0.95)
        preferences.setCriticalThreshold(0.5)
        XCTAssertEqual(preferences.criticalThreshold, 0.95)
        XCTAssertEqual(QuotaClassification.classify(0.79, preferences: preferences), .normal)
        XCTAssertEqual(QuotaClassification.classify(0.95, preferences: preferences), .critical)
        preferences = AppPreferences(warningThreshold: 0.8, criticalThreshold: 0.95)
        XCTAssertEqual(QuotaClassification.classify(0.90, preferences: preferences), .warning)
        XCTAssertEqual(QuotaClassification.classify(0.96, preferences: preferences), .critical)
    }
}

private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func snapshot(_ provider: ProviderID, daily: [DailyUsage], lifetime: Double) -> ProviderSnapshot { ProviderSnapshot(provider: provider, dailyUsage: daily, lifetimeTokens: lifetime, quotaWindows: [], health: .fresh, updatedAt: .now, coverage: "fixture", detail: nil) }

private actor ObservedCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(42_000)]), "dailyUsageBuckets": AnySendable([["startDate": "2026-08-30", "tokens": Int64(12)], ["startDate": "2026-08-31", "tokens": Int64(34)]])]
        }
        return ["rateLimits": AnySendable(["primary": ["usedPercent": 37, "windowDurationMins": Int64(300), "resetsAt": Int64(1_788_000_000)], "secondary": ["usedPercent": 42, "windowDurationMins": Int64(10_080), "resetsAt": Int64(1_788_200_000)]])]
    }
}

private actor MalformedCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] { method == "account/usage/read" ? ["summary": AnySendable([:])] : ["rateLimits": AnySendable([:])] }
}

private actor EmptyLimitsCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            let buckets: [[String: Any]] = [
                ["startDate": "2026-08-30", "tokens": Int64(12)],
                ["startDate": "2026-08-31", "tokens": Int64(34)]
            ]
            return ["summary": AnySendable(["lifetimeTokens": Int64(42_000)]), "dailyUsageBuckets": AnySendable(buckets)]
        }
        return [:]
    }
}

private actor MalformedLimitsCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(1)]), "dailyUsageBuckets": AnySendable([])]
        }
        return ["rateLimits": AnySendable(["primary": ["usedPercent": "unknown"]])]
    }
}

private actor EmptyPrimaryCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(1)]), "dailyUsageBuckets": AnySendable([])]
        }
        return ["rateLimits": AnySendable(["primary": [String: Any]()])]
    }
}

private actor BooleanTokenCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": NSNumber(value: true)]), "dailyUsageBuckets": AnySendable([])]
        }
        return [:]
    }
}

private actor BooleanQuotaCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(1)]), "dailyUsageBuckets": AnySendable([])]
        }
        return ["rateLimits": AnySendable(["primary": ["usedPercent": NSNumber(value: true)]])]
    }
}

private actor BadPrimaryCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(1)]), "dailyUsageBuckets": AnySendable([])]
        }
        return ["rateLimits": AnySendable(["primary": "bad"])]
    }
}

private actor MultiBucketCodexTransport: CodexRPCTransport {
    func request(method: String, params: [String: AnySendable]?) throws -> [String: AnySendable] {
        if method == "account/usage/read" {
            return ["summary": AnySendable(["lifetimeTokens": Int64(1)]), "dailyUsageBuckets": AnySendable([])]
        }
        let legacy: [String: Any] = ["limitId": "plan", "limitName": "Plan", "primary": ["usedPercent": 20, "windowDurationMins": 300]]
        let secondary: [String: Any] = ["limitId": "secondary", "limitName": "Secondary plan", "primary": ["usedPercent": 30, "windowDurationMins": 300], "secondary": ["usedPercent": 40, "windowDurationMins": 10_080], "tertiary": ["usedPercent": 50, "windowDurationMins": 43_200], "credits": ["remaining": 10]]
        return ["rateLimits": AnySendable(legacy), "rateLimitsByLimitId": AnySendable(["plan": legacy, "secondary": secondary])]
    }
}

private struct FixedCredential: ZCodeCredentialDiscovering {
    let baseURL: String
    init(baseURL: String = "https://plan.example.invalid/base") { self.baseURL = baseURL }
    func credential() async throws -> ZCodeCredential { ZCodeCredential(token: "fixture-token", baseURL: URL(string: baseURL)!) }
}

private actor ObservedZCodeHTTP: HTTPClient {
    private(set) var firstUsageQuery: [String: String]?
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any]
        if request.url!.path.contains("model-usage") {
            if firstUsageQuery == nil { firstUsageQuery = Dictionary(uniqueKeysWithValues: request.url!.queryItems!.map { ($0.name, $0.value ?? "") }) }
            body = ["code": 200, "msg": "ok", "success": true, "data": ["x_time": ["2025-01-01 00:00", "2025-01-01 01:00"], "tokensUsage": [10, 20], "totalUsage": ["totalTokensUsage": 30], "modelDataList": [], "granularity": "hourly"]]
        } else {
            body = ["code": 200, "success": true, "data": ["limits": [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "currentValue": 25, "remaining": 75, "percentage": 25, "nextResetTime": 1_788_000_000_000], ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 200, "currentValue": 40, "remaining": 160, "percentage": 20, "nextResetTime": 1_788_200_000_000]], "level": "plan"]]
        }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor FailureEnvelopeHTTP: HTTPClient {
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = ["code": 401, "success": false, "data": [:]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor MalformedQuotaHTTP: HTTPClient {
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = request.url!.path.contains("model-usage")
            ? ["code": 200, "success": true, "data": ["x_time": ["2025-01-01 00:00"], "tokensUsage": [1]]]
            : ["code": 200, "success": true, "data": ["limits": [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "currentValue": 25]]]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor BooleanUsageZCodeHTTP: HTTPClient {
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = request.url!.path.contains("model-usage")
            ? ["code": 200, "success": true, "data": ["x_time": ["2025-01-01 00:00"], "tokensUsage": [true]]]
            : ["code": 200, "success": true, "data": ["limits": []]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor PathRecordingZCodeHTTP: HTTPClient {
    private(set) var paths: [String] = []
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        let body: [String: Any] = request.url!.path.contains("model-usage")
            ? ["code": 200, "success": true, "data": ["x_time": ["2025-01-01 00:00"], "tokensUsage": [1]]]
            : ["code": 200, "success": true, "data": ["limits": []]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor QueryRecordingZCodeHTTP: HTTPClient {
    private(set) var usageQueries: [(String, String)] = []
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if request.url!.path.contains("model-usage") {
            let items = request.url!.queryItems!
            usageQueries.append((items.first(where: { $0.name == "startTime" })!.value!, items.first(where: { $0.name == "endTime" })!.value!))
            let body: [String: Any] = ["code": 200, "success": true, "data": ["x_time": ["2025-01-01 00:00"], "tokensUsage": [1]]]
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let body: [String: Any] = ["code": 200, "success": true, "data": ["limits": []]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor InterruptingZCodeHTTP: HTTPClient {
    private var recoveryAllowed = false
    private(set) var januaryRequests = 0
    func allowRecovery() { recoveryAllowed = true }
    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        if request.url!.path.contains("quota") {
            return (try JSONSerialization.data(withJSONObject: ["code": 200, "success": true, "data": ["limits": []]]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let start = request.url!.queryItems!.first(where: { $0.name == "startTime" })!.value!
        if start.hasPrefix("2025-01") { januaryRequests += 1 }
        if start.hasPrefix("2025-02"), !recoveryAllowed { throw ProviderError.unavailable }
        let body: [String: Any] = ["code": 200, "success": true, "data": ["x_time": [String(start.prefix(10)) + " 00:00"], "tokensUsage": [10], "totalUsage": ["totalTokensUsage": 10], "modelDataList": [], "granularity": "hourly"]]
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor CountingProvider: UsageProvider {
    let id: ProviderID
    private(set) var calls = 0
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ id: ProviderID) { self.id = id }
    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        calls += 1
        callWaiters.forEach { $0.resume() }
        callWaiters.removeAll()
        return snapshot(id, daily: [], lifetime: 0)
    }
    func waitUntilCalls(_ expected: Int) async {
        while calls < expected {
            await withCheckedContinuation { callWaiters.append($0) }
        }
    }
}

private actor ControlledSleeper {
    private var nextID = 0
    private var sleepCount = 0
    private var active: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelled = Set<Int>()
    private var stateWaiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for _: Duration) async throws {
        let id = nextID
        nextID += 1
        sleepCount += 1
        signalStateChange()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    active[id] = continuation
                }
                signalStateChange()
            }
        }, onCancel: {
            Task { await self.cancelSleep(id) }
        })
    }

    func waitForSleepCount(_ expected: Int) async {
        while sleepCount < expected {
            await waitForStateChange()
        }
    }

    func waitForActiveSleepCount(_ expected: Int) async {
        while active.count != expected {
            await waitForStateChange()
        }
    }

    func releaseOnlyActiveSleep() -> Bool {
        guard active.count == 1, let id = active.keys.first,
              let continuation = active.removeValue(forKey: id) else { return false }
        continuation.resume()
        signalStateChange()
        return true
    }

    private func cancelSleep(_ id: Int) {
        if let continuation = active.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
        signalStateChange()
    }

    private func waitForStateChange() async {
        await withCheckedContinuation { stateWaiters.append($0) }
    }

    private func signalStateChange() {
        let waiters = stateWaiters
        stateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor BlockingProvider: UsageProvider {
    let id: ProviderID
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ id: ProviderID) { self.id = id }
    var calls: Int { started ? 1 : 0 }

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return snapshot(id, daily: [], lifetime: 99)
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor CancellableBlockingProvider: UsageProvider {
    let id: ProviderID
    private var started = false
    private var cancelled = false
    private var lateWorkCountStorage = 0
    private var cancellationCountStorage = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ id: ProviderID) { self.id = id }

    var lateWorkCount: Int { lateWorkCountStorage }
    var cancellationCount: Int { cancellationCountStorage }

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
            }
            try Task.checkCancellation()
            lateWorkCountStorage += 1
            return snapshot(id, daily: [], lifetime: 99)
        }, onCancel: {
            Task { await self.observeCancellation() }
        })
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func observeCancellation() {
        guard !cancelled else { return }
        cancelled = true
        cancellationCountStorage += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}

private actor FirstRequestCancelledThenSucceedsProvider: UsageProvider {
    let id: ProviderID = .codex
    private(set) var calls = 0
    private var firstRequestStarted = false
    private var firstRequestCancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        calls += 1
        guard calls == 1 else { return snapshot(.codex, daily: [], lifetime: 42) }
        firstRequestStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
            }
            return snapshot(.codex, daily: [], lifetime: 1)
        }, onCancel: {
            Task { await self.cancelFirstRequest() }
        })
    }

    func waitUntilFirstRequestStarted() async {
        if firstRequestStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilFirstRequestCancelled() async {
        if firstRequestCancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelFirstRequest() {
        guard !firstRequestCancelled else { return }
        firstRequestCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}

private actor FirstFailureThenBlockingProvider: UsageProvider {
    let id: ProviderID = .codex
    private var calls = 0
    private var secondRequestStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func refresh(now: Date, calendar: Calendar) async throws -> ProviderSnapshot {
        calls += 1
        if calls == 1 { throw ProviderError.unavailable }
        secondRequestStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return snapshot(.codex, daily: [], lifetime: 42)
    }

    func waitUntilSecondRequestStarted() async {
        if secondRequestStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseSecondRequest() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DelayedCacheStore: UsageStore {
    private let cached: ProviderSnapshot
    private var cacheReadStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(cached: ProviderSnapshot) { self.cached = cached }

    func cachedSnapshot(for provider: ProviderID) async throws -> ProviderSnapshot? {
        guard provider == .codex else { return nil }
        cacheReadStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return cached
    }

    func allSnapshots() -> [ProviderSnapshot] { [] }
    func save(snapshot: ProviderSnapshot) { }
    func sealedMonths() -> Set<String> { [] }
    func saveMonth(_ month: String, usage: [DailyUsage], sealed: Bool) { }
    func monthUsage() -> [DailyUsage] { [] }

    func waitUntilCacheReadStarted() async {
        if cacheReadStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseCacheRead() {
        continuation?.resume()
        continuation = nil
    }
}

private actor DelayedHydrationStore: UsageStore {
    private let cached: ProviderSnapshot
    private var allSnapshotsStarted = false
    private var reads = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    init(cached: ProviderSnapshot) { self.cached = cached }

    var allSnapshotsReadCount: Int { reads }

    func cachedSnapshot(for _: ProviderID) -> ProviderSnapshot? { nil }

    func allSnapshots() async throws -> [ProviderSnapshot] {
        reads += 1
        allSnapshotsStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return [cached]
    }

    func save(snapshot _: ProviderSnapshot) { }
    func sealedMonths() -> Set<String> { [] }
    func saveMonth(_: String, usage _: [DailyUsage], sealed _: Bool) { }
    func monthUsage() -> [DailyUsage] { [] }

    func waitUntilAllSnapshotsStarted() async {
        if allSnapshotsStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseAllSnapshots() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FailingThenSucceedingHydrationStore: UsageStore {
    private let cached: ProviderSnapshot
    private var reads = 0

    init(cached: ProviderSnapshot) { self.cached = cached }

    var allSnapshotsReadCount: Int { reads }

    func cachedSnapshot(for _: ProviderID) -> ProviderSnapshot? { nil }

    func allSnapshots() throws -> [ProviderSnapshot] {
        reads += 1
        if reads == 1 { throw ProviderError.unavailable }
        return [cached]
    }

    func save(snapshot _: ProviderSnapshot) { }
    func sealedMonths() -> Set<String> { [] }
    func saveMonth(_: String, usage _: [DailyUsage], sealed _: Bool) { }
    func monthUsage() -> [DailyUsage] { [] }
}

private extension URL {
    var queryItems: [URLQueryItem]? { URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems }
}
