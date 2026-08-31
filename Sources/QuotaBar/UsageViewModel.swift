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

    private let store: any UsageStore
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
        periodicSleep: @escaping PeriodicSleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.store = store
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
        let store: any UsageStore = (try? SQLiteUsageStore(url: url)) ?? InMemoryUsageStore()
        let zcode = ZCodeProvider(store: store, credentials: LocalZCodeCredentialDiscovery(consent: { UserDefaults.standard.bool(forKey: "zcodeConsent") }))
        self.init(store: store, providers: [.codex: CodexProvider(transport: CodexAppServerTransport()), .zcode: zcode], preferences: preferences)
    }

    deinit {
        refreshTask?.cancel()
        providerTasks.values.forEach { $0.cancel() }
        cacheHydrationTask?.cancel()
        periodicTask?.cancel()
        notificationTask?.cancel()
    }

    var enabledSnapshots: [ProviderSnapshot] {
        ProviderID.allCases.compactMap { snapshots[$0] }.filter { preferences.enabled($0.provider) }
    }

    var aggregate: ProviderTotals {
        UsageMath.aggregate(Array(snapshots.values), enabled: preferences.enabled, now: .now, calendar: preferences.calendar)
    }

    func appStarted() async {
        await loadCachedSnapshots()
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
            await self.performRefresh(providers: providersToRefresh)
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
        if provider == .codex { preferences.codexEnabled = enabled } else { preferences.zcodeEnabled = enabled }
        if enabled {
            if snapshots[provider] == nil || snapshots[provider]?.health == .disabled {
                snapshots[provider] = ProviderSnapshot(provider: provider, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [], health: .loading, updatedAt: .now, coverage: "Waiting for account data", detail: nil)
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
        let data: Data
        let name: String
        switch format {
        case .json:
            data = try UsageExport.json(snapshots, preferences: preferences)
            name = "quotabar-export.json"
        case .csv:
            data = UsageExport.csv(snapshots, preferences: preferences, now: .now)
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
                snapshots[provider] = ProviderSnapshot(provider: provider, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [], health: .loading, updatedAt: now, coverage: "Waiting for account data", detail: nil)
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
            snapshots[provider] = ProviderSnapshot(provider: cached.provider, dailyUsage: cached.dailyUsage, lifetimeTokens: cached.lifetimeTokens, quotaWindows: cached.quotaWindows, health: .stale, updatedAt: cached.updatedAt, coverage: cached.coverage, detail: "Last account snapshot is stale")
        } else {
            guard preferences.enabled(provider), generations[provider, default: 0] == expectedGeneration else { return }
            snapshots[provider] = ProviderSnapshot(provider: provider, dailyUsage: [], lifetimeTokens: 0, quotaWindows: [], health: error.health, updatedAt: now, coverage: "No account snapshot", detail: error.health == .authenticationRequired ? "Authorize the active account" : "Provider unavailable")
        }
    }

    private func persistPreferences() {
        let defaults = UserDefaults.standard
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
            criticalThreshold: defaults.object(forKey: "criticalThreshold") as? Double ?? 0.95
        )
    }
}

enum ExportFormat { case json, csv }
