import Foundation
import ServiceManagement
import SwiftUI

typealias PeriodicSleep = @Sendable (Duration) async throws -> Void

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var preferences: AppPreferences { didSet { persistPreferences() } }
    /// Deduplicated rows of enabled activity sources from the display window.
    @Published private(set) var activityRows: [UUID: [ActivityRow]] = [:]
    @Published private(set) var activityStatus: [UUID: ActivitySourceStatus] = [:]
    @Published private(set) var activityMetrics: [String: ActivityMetricInfo] = [:]
    @Published private(set) var isRefreshingActivity = false

    private let store: any UsageStore
    private let activityStore: (any ActivityStore)?
    private let activityCollector: ActivityCollector?
    /// Where preferences persist; nil keeps them in memory (tests run inside the app's defaults domain).
    private let defaults: UserDefaults?
    private var storedActivity: [UUID: [ActivityRow]] = [:]
    private var activityTask: Task<Void, Never>?
    private let providers: [ProviderID: any UsageProvider]
    private let backoff: BackoffPolicy
    private let periodicSleep: PeriodicSleep
    private var refreshTask: Task<Void, Never>?
    private var providerTasks: [ProviderID: Task<ProviderSnapshot, Error>] = [:]
    private var periodicTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var queuedProviderRefreshes = Set<ProviderID>()
    private var hasLoadedCache = false
    private var cacheHydrationTask: Task<Void, Never>?
    private var cacheHydrationToken: UUID?
    private var generations: [ProviderID: Int] = [:]
    private var failures: [ProviderID: Int] = [:]

    init(
        store: any UsageStore,
        providers: [ProviderID: any UsageProvider],
        preferences: AppPreferences = AppPreferences(),
        backoff: BackoffPolicy = BackoffPolicy(),
        periodicSleep: @escaping PeriodicSleep = { duration in try await Task.sleep(for: duration) },
        activityStore: (any ActivityStore)? = nil,
        activityCollector: ActivityCollector? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.defaults = defaults
        self.store = store
        self.activityStore = activityStore
        self.activityCollector = activityCollector
        self.providers = providers
        self.preferences = preferences
        self.backoff = backoff
        self.periodicSleep = periodicSleep
        for provider in ProviderID.allCases where !preferences.enabled(provider) {
            snapshots[provider] = .disabled(provider)
        }
    }

    convenience init() {
        let preferences = Self.loadPreferences()
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "QuotaBar/cache.sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store: any UsageStore & ActivityStore = (try? SQLiteUsageStore(url: url)) ?? InMemoryUsageStore()
        let zcode = ZCodeProvider(store: store, credentials: LocalZCodeCredentialDiscovery(consent: { UserDefaults.standard.bool(forKey: "zcodeConsent") }))
        let claude = ClaudeProvider(credentials: KeychainClaudeCredentialDiscovery(consent: { UserDefaults.standard.bool(forKey: "claudeConsent") }))
        self.init(
            store: store,
            providers: [.codex: CodexProvider(transport: CodexAppServerTransport()), .zcode: zcode, .claude: claude],
            preferences: preferences,
            activityStore: store,
            activityCollector: ActivityCollector(runner: ProcessCommandRunner(), collectorScript: ActivityCollector.bundledScript()),
            defaults: .standard
        )
    }

    deinit {
        refreshTask?.cancel()
        providerTasks.values.forEach { $0.cancel() }
        cacheHydrationTask?.cancel()
        activityTask?.cancel()
        periodicTask?.cancel()
        notificationTask?.cancel()
    }

    var enabledActivitySources: [ActivitySourceConfig] { preferences.activitySources.filter(\.enabled) }

    /// Rows of enabled activity sources, already deduplicated across devices.
    var enabledActivityRows: [ActivityRow] {
        enabledActivitySources.flatMap { activityRows[$0.id] ?? [] }
    }

    /// Each enabled provider's headline tokens for the last 30 days, oldest first.
    var headlineSeries: [ChartSeries] {
        UsageMath.headlineSeries(
            Array(snapshots.values),
            localRows: enabledActivitySources.isEmpty ? nil : enabledActivityRows,
            enabled: preferences.enabled,
            days: 30,
            now: .now,
            calendar: preferences.calendar
        )
    }

    func appStarted() async {
        await loadCachedSnapshots()
        await loadActivity()
        startPeriodicRefresh()
        await startCodexNotifications()
    }

    func panelOpened() async {
        await appStarted()
        if preferences.refreshOnOpen { await refresh() }
    }

    func loadCachedSnapshots() async {
        guard !hasLoadedCache else { return }

        if let cacheHydrationTask {
            _ = await cacheHydrationTask.value
            return
        }

        let initialSnapshots = snapshots
        let initialGenerations = generations
        let token = UUID()
        cacheHydrationToken = token
        let task = Task { [weak self, store, initialSnapshots, initialGenerations] in
            let cached = try? await store.allSnapshots()
            self?.finishCacheHydration(
                token: token,
                cached: cached,
                initialSnapshots: initialSnapshots,
                initialGenerations: initialGenerations
            )
        }
        cacheHydrationTask = task
        await task.value
    }

    private func finishCacheHydration(
        token: UUID,
        cached: [ProviderSnapshot]?,
        initialSnapshots: [ProviderID: ProviderSnapshot],
        initialGenerations: [ProviderID: Int]
    ) {
        guard cacheHydrationToken == token else { return }
        defer {
            cacheHydrationTask = nil
            cacheHydrationToken = nil
        }
        guard let cached else { return }

        hasLoadedCache = true
        for snapshot in cached where preferences.enabled(snapshot.provider) {
            guard generations[snapshot.provider, default: 0] == initialGenerations[snapshot.provider, default: 0],
                  snapshots[snapshot.provider] == initialSnapshots[snapshot.provider] else { continue }
            snapshots[snapshot.provider] = ProviderSnapshot(
                provider: snapshot.provider,
                dailyUsage: snapshot.dailyUsage,
                lifetimeTokens: snapshot.lifetimeTokens,
                quotaWindows: snapshot.quotaWindows,
                health: .stale,
                updatedAt: snapshot.updatedAt,
                coverage: snapshot.coverage,
                detail: "Cached account snapshot"
            )
        }
    }

    func startPeriodicRefresh() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.periodicSleep(.seconds(self.nextPeriodicDelay))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func reschedulePeriodicRefresh() {
        guard periodicTask != nil else { return }
        periodicTask?.cancel()
        periodicTask = nil
        startPeriodicRefresh()
    }

    private func startCodexNotifications() async {
        guard notificationTask == nil,
              let notifier = providers[.codex] as? any ProviderUpdateNotifying else { return }
        let updates = await notifier.updates()
        notificationTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        await refresh(targeting: nil)
    }

    private func refresh(targeting requestedProviders: Set<ProviderID>?) async {
        if let refreshTask {
            if let requestedProviders {
                queuedProviderRefreshes.formUnion(requestedProviders)
            }
            await refreshTask.value
            return
        }
        isRefreshing = true
        let providersToRefresh = requestedProviders ?? Set(ProviderID.allCases)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadInitialCacheBeforeRefresh()
            async let accounts: Void = self.performRefresh(providers: providersToRefresh)
            if providersToRefresh.contains(.claude) { await self.refreshActivity() }
            await accounts
        }
        refreshTask = task
        await task.value
        refreshTask = nil
        let queuedProviders = queuedProviderRefreshes
        queuedProviderRefreshes.removeAll()
        if queuedProviders.isEmpty {
            isRefreshing = false
        } else {
            await refresh(targeting: queuedProviders)
        }
    }

    private func loadInitialCacheBeforeRefresh() async {
        guard !hasLoadedCache else { return }
        await loadCachedSnapshots()
    }

    func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        generations[provider, default: 0] += 1
        preferences.setEnabled(enabled, for: provider)
        if provider == .claude, !enabled { activityTask?.cancel() }
        if enabled {
            if snapshots[provider] == nil || snapshots[provider]?.health == .disabled {
                snapshots[provider] = .loading(provider)
            }
            if refreshTask == nil {
                Task { [weak self] in await self?.refresh(targeting: [provider]) }
            } else {
                queuedProviderRefreshes.insert(provider)
            }
        } else {
            providerTasks[provider]?.cancel()
            queuedProviderRefreshes.remove(provider)
            snapshots[provider] = .disabled(provider)
        }
        reschedulePeriodicRefresh()
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        preferences.refreshInterval = interval
        reschedulePeriodicRefresh()
    }

    func setWarningThreshold(_ value: Double) { preferences.setWarningThreshold(value) }

    func setCriticalThreshold(_ value: Double) { preferences.setCriticalThreshold(value) }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            preferences.launchAtLogin = enabled
        } catch {
            preferences.launchAtLogin = false
        }
    }

    func export(_ format: ExportFormat) async throws {
        let snapshots = try await store.allSnapshots()
        let activity = try await activityExport()
        let data: Data
        let name: String
        switch format {
        case .json:
            data = try UsageExport.json(snapshots, preferences: preferences, activity: activity)
            name = "quotabar-export.json"
        case .csv:
            data = UsageExport.csv(snapshots, preferences: preferences, now: .now, activity: activity)
            name = "quotabar-export.csv"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private var nextPeriodicDelay: TimeInterval {
        let maxFailures = ProviderID.allCases
            .filter(preferences.enabled)
            .map { failures[$0, default: 0] }
            .max() ?? 0
        return max(preferences.refreshInterval, backoff.delay(afterFailures: maxFailures))
    }

    private func performRefresh(providers requestedProviders: Set<ProviderID>) async {
        let now = Date.now
        for provider in ProviderID.allCases {
            guard requestedProviders.contains(provider) else { continue }
            guard preferences.enabled(provider), let adapter = providers[provider] else { continue }
            let generation = generations[provider, default: 0]
            if snapshots[provider] == nil || snapshots[provider]?.health == .disabled {
                snapshots[provider] = .loading(provider, now: now)
            }
            let task = Task { try await adapter.refresh(now: now, calendar: preferences.calendar) }
            providerTasks[provider] = task
            defer { providerTasks[provider] = nil }
            do {
                let snapshot = try await task.value
                guard preferences.enabled(provider), generations[provider, default: 0] == generation else { continue }
                snapshots[provider] = snapshot
                failures[provider] = 0
                try await store.save(snapshot: snapshot)
                reschedulePeriodicRefresh()
            } catch let error as ProviderError {
                guard preferences.enabled(provider), generations[provider, default: 0] == generation else { continue }
                failures[provider, default: 0] += 1
                await preserveCached(provider: provider, error: error, now: now, expectedGeneration: generation)
                reschedulePeriodicRefresh()
            } catch {
                guard preferences.enabled(provider), generations[provider, default: 0] == generation else { continue }
                failures[provider, default: 0] += 1
                await preserveCached(provider: provider, error: .unavailable, now: now, expectedGeneration: generation)
                reschedulePeriodicRefresh()
            }
        }
        lastRefresh = now
    }

    private func preserveCached(provider: ProviderID, error: ProviderError, now: Date, expectedGeneration: Int) async {
        guard preferences.enabled(provider), generations[provider, default: 0] == expectedGeneration else { return }
        if let cached = try? await store.cachedSnapshot(for: provider) {
            guard preferences.enabled(provider), generations[provider, default: 0] == expectedGeneration else { return }
            snapshots[provider] = ProviderSnapshot(provider: cached.provider, dailyUsage: cached.dailyUsage, lifetimeTokens: cached.lifetimeTokens, quotaWindows: cached.quotaWindows, health: .stale, updatedAt: cached.updatedAt, coverage: cached.coverage, detail: Self.recoveryDetail(provider: provider, error: error, cached: true))
        } else {
            guard preferences.enabled(provider), generations[provider, default: 0] == expectedGeneration else { return }
            snapshots[provider] = ProviderSnapshot(provider: provider, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [], health: error.health, updatedAt: now, coverage: "No account snapshot", detail: Self.recoveryDetail(provider: provider, error: error, cached: false))
        }
    }

    static func recoveryDetail(provider: ProviderID, error: ProviderError, cached: Bool) -> String {
        let reason: String
        switch (provider, error) {
        case (.claude, .credentialUnavailable): reason = "Allow Claude Code credential access in Settings, and sign in to Claude Code"
        case (.claude, .authenticationRequired): reason = "Claude Code login expired; run Claude Code to sign in again"
        case (_, .authenticationRequired), (_, .credentialUnavailable): reason = "Authorize the active account"
        default: reason = "Provider unavailable"
        }
        if provider == .claude || error.health == .authenticationRequired {
            return cached ? "\(reason). Last account snapshot is stale" : reason
        }
        return cached ? "Last account snapshot is stale" : reason
    }

    // MARK: - Local activity

    func loadActivity() async {
        guard let activityStore else { return }
        let records = (try? await activityStore.activitySources()) ?? [:]
        for source in preferences.activitySources where activityStatus[source.id] == nil {
            if let record = records[source.id] {
                activityStatus[source.id] = ActivitySourceStatus(health: .stale, device: record.device, lastSuccess: record.generatedAt, detail: "Cached activity")
            }
        }
        activityMetrics = records.values.reduce(into: [:]) { $0.merge($1.metrics) { current, _ in current } }
        storedActivity = (try? await activityStore.activityRows(since: Date.now.addingTimeInterval(-ActivityMath.displayWindow))) ?? storedActivity
        rebuildActivity()
    }

    /// Runs enabled activity sources concurrently, or only `sourceID` when given.
    func refreshActivity(only sourceID: UUID? = nil) async {
        // Re-check after each wait: another waiter may have started a run in between.
        while let activityTask { await activityTask.value }
        guard preferences.claudeEnabled, let activityStore, let activityCollector else { return }
        let sources = preferences.activitySources.filter { $0.enabled && (sourceID == nil || $0.id == sourceID) }
        guard !sources.isEmpty else { return }
        isRefreshingActivity = true
        let task = Task { [weak self] in
            let records = (try? await activityStore.activitySources()) ?? [:]
            let now = Date.now
            for source in sources {
                var status = self?.activityStatus[source.id] ?? ActivitySourceStatus(health: .loading)
                if status.lastSuccess == nil { status.health = .loading }
                self?.activityStatus[source.id] = status
            }
            await withTaskGroup(of: (UUID, Result<ActivityReport, Error>).self) { group in
                for source in sources {
                    let since = ActivityMath.nextSince(lastGeneratedAt: records[source.id]?.generatedAt, now: now)
                    group.addTask {
                        do { return (source.id, .success(try await activityCollector.collect(source, since: since))) }
                        catch { return (source.id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    guard !Task.isCancelled else { continue }
                    await self?.finishActivityRun(id: id, result: result, store: activityStore, previous: records[id])
                }
            }
            for source in sources where self?.activityStatus[source.id]?.health == .loading {
                self?.activityStatus[source.id] = Self.failedStatus(previous: records[source.id], detail: "Cancelled")
            }
            await self?.loadActivity()
            // Cleared by the run itself so waiters see it gone as soon as it completes.
            self?.activityTask = nil
            self?.isRefreshingActivity = false
        }
        activityTask = task
        await task.value
    }

    private func finishActivityRun(id: UUID, result: Result<ActivityReport, Error>, store activityStore: any ActivityStore, previous: ActivitySourceRecord?) async {
        guard preferences.activitySources.contains(where: { $0.id == id }) else { return }
        switch result {
        case .success(let report):
            do {
                try await activityStore.replaceActivity(source: id, report: report)
                activityStatus[id] = ActivitySourceStatus(health: .fresh, device: report.device, lastSuccess: report.generatedAt, detail: nil)
            } catch {
                activityStatus[id] = Self.failedStatus(previous: previous, detail: "Could not save activity")
            }
        case .failure(let error):
            let detail = (error as? ActivitySourceError)?.message ?? (error is CancellationError ? "Cancelled" : "The command failed.")
            activityStatus[id] = Self.failedStatus(previous: previous, detail: detail)
        }
    }

    static func failedStatus(previous: ActivitySourceRecord?, detail: String) -> ActivitySourceStatus {
        guard let previous else { return ActivitySourceStatus(health: .unavailable, device: nil, lastSuccess: nil, detail: detail) }
        return ActivitySourceStatus(health: .stale, device: previous.device, lastSuccess: previous.generatedAt, detail: detail)
    }

    private func rebuildActivity() {
        let enabled = preferences.activitySources.filter(\.enabled).map { (id: $0.id, rows: storedActivity[$0.id] ?? []) }
        activityRows = ActivityMath.deduplicated(enabled)
    }

    func addActivitySource(_ source: ActivitySourceConfig) {
        preferences.activitySources.append(source)
        rebuildActivity()
    }

    /// Returns the source's id, which changes when its command changes: a different command may
    /// reach a different device, so its history starts fresh and the old rows are deleted.
    @discardableResult
    func updateActivitySource(_ source: ActivitySourceConfig) -> UUID {
        guard let index = preferences.activitySources.firstIndex(where: { $0.id == source.id }) else { return source.id }
        var source = source
        let previous = preferences.activitySources[index]
        if previous.argv != source.argv || previous.pipesCollector != source.pipesCollector {
            source.id = UUID()
            activityStatus[previous.id] = nil
            storedActivity[previous.id] = nil
            Task { [activityStore] in try? await activityStore?.deleteActivity(source: previous.id) }
        }
        preferences.activitySources[index] = source
        if !source.enabled { activityStatus[source.id]?.health = activityStatus[source.id]?.lastSuccess == nil ? .disabled : .stale }
        rebuildActivity()
        return source.id
    }

    func removeActivitySource(_ id: UUID) async {
        preferences.activitySources.removeAll { $0.id == id }
        activityStatus[id] = nil
        storedActivity[id] = nil
        rebuildActivity()
        try? await activityStore?.deleteActivity(source: id)
    }

    private func activityExport() async throws -> [ActivityExportSource] {
        guard let activityStore else { return [] }
        let records = try await activityStore.activitySources()
        let enabled = preferences.activitySources.filter(\.enabled)
        let all = try await activityStore.activityRows(since: .distantPast)
        let deduped = ActivityMath.deduplicated(enabled.map { (id: $0.id, rows: all[$0.id] ?? []) })
        return enabled.compactMap { source in
            guard let record = records[source.id] else { return nil }
            return ActivityExportSource(name: source.name, device: record.device, generatedAt: record.generatedAt, health: activityStatus[source.id]?.health ?? .stale, metrics: record.metrics, rows: deduped[source.id] ?? [])
        }
    }

    private func persistPreferences() {
        guard let defaults else { return }
        defaults.set(preferences.codexEnabled, forKey: "codexEnabled")
        defaults.set(preferences.zcodeEnabled, forKey: "zcodeEnabled")
        defaults.set(preferences.refreshInterval, forKey: "refreshInterval")
        defaults.set(preferences.refreshOnOpen, forKey: "refreshOnOpen")
        defaults.set(preferences.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(preferences.menuBarText, forKey: "menuBarText")
        defaults.set(preferences.timeZoneIdentifier, forKey: "timeZoneIdentifier")
        defaults.set(preferences.zcodeConsent, forKey: "zcodeConsent")
        defaults.set(preferences.warningThreshold, forKey: "warningThreshold")
        defaults.set(preferences.criticalThreshold, forKey: "criticalThreshold")
        defaults.set(preferences.claudeEnabled, forKey: "claudeEnabled")
        defaults.set(preferences.claudeConsent, forKey: "claudeConsent")
        defaults.set(try? JSONEncoder().encode(preferences.activitySources), forKey: "activitySources")
    }

    private static func loadPreferences() -> AppPreferences {
        let defaults = UserDefaults.standard
        return AppPreferences(
            codexEnabled: defaults.object(forKey: "codexEnabled") as? Bool ?? true,
            zcodeEnabled: defaults.object(forKey: "zcodeEnabled") as? Bool ?? true,
            refreshInterval: defaults.object(forKey: "refreshInterval") as? Double ?? 300,
            refreshOnOpen: defaults.object(forKey: "refreshOnOpen") as? Bool ?? true,
            launchAtLogin: defaults.object(forKey: "launchAtLogin") as? Bool ?? false,
            menuBarText: defaults.object(forKey: "menuBarText") as? Bool ?? true,
            timeZoneIdentifier: defaults.string(forKey: "timeZoneIdentifier") ?? TimeZone.current.identifier,
            zcodeConsent: defaults.object(forKey: "zcodeConsent") as? Bool ?? false,
            warningThreshold: defaults.object(forKey: "warningThreshold") as? Double ?? 0.8,
            criticalThreshold: defaults.object(forKey: "criticalThreshold") as? Double ?? 0.95,
            claudeEnabled: defaults.object(forKey: "claudeEnabled") as? Bool ?? true,
            claudeConsent: defaults.object(forKey: "claudeConsent") as? Bool ?? false,
            activitySources: defaults.data(forKey: "activitySources").flatMap { try? JSONDecoder().decode([ActivitySourceConfig].self, from: $0) } ?? [.thisMac]
        )
    }
}

enum ExportFormat { case json, csv }
