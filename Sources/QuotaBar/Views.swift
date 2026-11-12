import AppKit
import SwiftUI

enum ApplicationActions {
    @MainActor
    static func quit(terminate: () -> Void = { NSApplication.shared.terminate(nil) }) {
        terminate()
    }
}

@MainActor
enum SettingsPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")

    static func show(
        openSettings: () -> Void,
        application: NSApplication = .shared
    ) {
        application.activate(ignoringOtherApps: true)
        openSettings()
        focusSettingsWindow(in: application)
        Task { @MainActor in
            await Task.yield()
            focusSettingsWindow(in: application)
            try? await Task.sleep(for: .milliseconds(150))
            focusSettingsWindow(in: application)
        }
    }

    static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == windowIdentifier }
    }

    private static func focusSettingsWindow(in application: NSApplication) {
        application.activate(ignoringOtherApps: true)
        settingsWindow(in: application.windows)?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
enum ScrollbarAppearance {
    static let insets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)

    /// Idempotent: SwiftUI calls this on every update, and reassigning the style or scroller
    /// resets the overlay scroller's show/hide state, which made the knob fail to appear.
    static func apply(to scrollView: NSScrollView) {
        if !(scrollView.verticalScroller is SoftScroller) {
            scrollView.verticalScroller = SoftScroller()
        }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        let current = scrollView.scrollerInsets
        if current.top != insets.top || current.bottom != insets.bottom || current.right != insets.right || current.left != insets.left {
            scrollView.scrollerInsets = insets
        }
        if scrollView.verticalScroller?.controlSize != .mini { scrollView.verticalScroller?.controlSize = .mini }
    }
}

/// A slim neutral knob without a track, pinned near the panel's right edge and matched to the
/// card borders instead of the system's dark knob.
final class SoftScroller: NSScroller {
    static let knobWidth: CGFloat = 6
    static let edgeGap: CGFloat = 2

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = Self.knobRect(in: bounds, track: rect(for: .knob))
        guard knob.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }

    /// Fixed width regardless of the system's knob rect, so the knob never collapses to a sliver.
    static func knobRect(in bounds: NSRect, track: NSRect) -> NSRect {
        NSRect(x: bounds.maxX - knobWidth - edgeGap, y: track.minY + 2, width: knobWidth, height: max(0, track.height - 4))
    }
}

enum SevenDayChartLayout {
    static let barWidth: CGFloat = 7
    static let providerSpacing: CGFloat = 2
    static let daySpacing: CGFloat = 12

    static func cornerRadius(for height: CGFloat) -> CGFloat {
        min(2, height * 0.2)
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    ScrollbarAppearance.apply(to: scrollView)
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: UsageViewModel
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("QuotaBar").font(.title3.weight(.semibold))
                        Text(model.isRefreshing ? "Refreshing usage…" : "Account usage and local Claude activity")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings") {
                        SettingsPresenter.show { openSettings() }
                    }
                    .buttonStyle(.borderless)
                }
                let series = model.headlineSeries
                if !series.isEmpty {
                    let combined = UsageMath.periodTotals(series.map(\.values).reduce(into: Array(repeating: 0.0, count: 30)) { sum, values in
                        for index in sum.indices { sum[index] += values[index] }
                    })
                    TotalsRow(
                        title: "All tokens · " + series.map { $0.provider.reportsAccountTokens ? $0.provider.rawValue : "\($0.provider.rawValue) (local)" }.joined(separator: " + "),
                        cells: [("Today", combined.today), ("7 days", combined.sevenDays), ("30 days", combined.thirtyDays)]
                    )
                    .padding(2)
                    .cardSurface()
                }
                ForEach(ProviderID.allCases) { provider in
                    // Claude's card also carries local activity, so it shows before its first account poll.
                    if model.preferences.enabled(provider), let snapshot = model.snapshots[provider] ?? (provider == .claude ? .loading(provider) : nil) {
                        ProviderCard(snapshot: snapshot, preferences: model.preferences) {
                            if provider == .claude {
                                LocalActivityTotals(model: model)
                            } else {
                                TotalsRow(totals: UsageMath.totals(for: snapshot, now: .now, calendar: model.preferences.calendar), title: snapshot.coverage)
                                    .tinted(provider.tint)
                            }
                        } extra: {
                            if provider == .claude { LocalActivitySection(model: model) }
                        }
                    }
                }
                if !series.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SevenDayChart(series: series.map { ChartSeries(provider: $0.provider, values: Array($0.values.suffix(7))) })
                        HStack(spacing: 12) {
                            ForEach(series, id: \.provider) { line in
                                Text("● \(line.provider.rawValue)").foregroundStyle(line.provider.tint)
                            }
                        }.font(.caption)
                    }
                    .padding(12)
                    .cardSurface()
                }
                HStack {
                    Spacer()
                    Button("Quit QuotaBar") { ApplicationActions.quit() }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.isRefreshing)
                }.font(.caption)
            }
            .padding(16)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                contentHeight = height
            }
            .background(OverlayScrollerConfigurator())
        }
        .frame(width: 380)
        .background(Color.panelBase)
        .frame(height: contentHeight.map { min($0, 620) })
        .frame(maxHeight: 620)
        .task { await model.panelOpened() }
    }

}

extension Color {
    /// A soft cool-gray base in light mode so white cards stand out; the system window color in dark mode.
    static let panelBase = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 0.925, green: 0.93, blue: 0.945, alpha: 1)
    })
}

extension View {
    /// The panel's only surface: an opaque card on the window background, so nothing behind the
    /// menu bar panel bleeds through and nested blocks never stack shades of gray.
    func cardSurface() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.09), radius: 10, y: 4)
    }
}

extension ProviderID {
    var tint: Color {
        switch self {
        case .codex: .blue
        case .zcode: .orange
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }
}

extension ProviderHealth {
    var tint: Color {
        switch self {
        case .fresh: .green
        case .stale, .loading: .orange
        case .unavailable, .authenticationRequired: .red
        case .disabled: .secondary
        }
    }
}

/// Claude's headline: local tokens from every enabled device, in the same layout as account totals.
private struct LocalActivityTotals: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        let calendar = model.preferences.calendar
        let rows = model.enabledActivityRows
        let tokens = ActivityMath.totals(rows, metric: ActivityMath.tokens, now: .now, calendar: calendar)
        TotalsRow(
            title: "Local tokens · " + (model.enabledActivitySources.isEmpty ? "no devices" : model.enabledActivitySources.map(\.name).joined(separator: " + ")),
            cells: [("Today", tokens.today), ("7 days", tokens.sevenDays), ("30 days", tokens.thirtyDays)]
        )
        .tinted(ProviderID.claude.tint)
    }
}

/// Claude local activity details: device-counted, never an account total.
private struct LocalActivitySection: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        let calendar = model.preferences.calendar
        let rows = model.enabledActivityRows
        let messages = ActivityMath.totals(rows, metric: ActivityMath.userMessages, now: .now, calendar: calendar)
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Local activity").font(.caption.weight(.semibold))
                Spacer()
                Text(enabledSources.isEmpty ? "No devices" : enabledSources.map(deviceName).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if enabledSources.isEmpty {
                Text("Add an activity source in Settings to count Claude Code tokens and messages.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text("Today").font(.caption2).foregroundStyle(.secondary)
                        Text("7 days").font(.caption2).foregroundStyle(.secondary)
                        Text("30 days").font(.caption2).foregroundStyle(.secondary)
                    }
                    activityRow("User messages", messages, unit: \.countText)
                    ForEach(extraMetrics, id: \.self) { metric in
                        activityRow(model.activityMetrics[metric]?.label ?? metric, ActivityMath.totals(rows, metric: metric, now: .now, calendar: calendar), unit: \.tokenText)
                    }
                }
                ForEach(enabledSources) { source in
                    DeviceFreshnessRow(source: source, status: model.activityStatus[source.id])
                }
            }
        }
    }

    private var enabledSources: [ActivitySourceConfig] { model.enabledActivitySources }

    private var extraMetrics: [String] {
        model.activityMetrics.keys.filter { $0 != ActivityMath.tokens && $0 != ActivityMath.userMessages }.sorted()
    }

    private func deviceName(_ source: ActivitySourceConfig) -> String {
        model.activityStatus[source.id]?.device.map { $0 == source.name ? $0 : "\(source.name) (\($0))" } ?? source.name
    }

    private func activityRow(_ label: String, _ totals: PeriodTotals, unit: KeyPath<Double, String>) -> some View {
        GridRow {
            Text(label).font(.caption)
            Text(totals.today[keyPath: unit]).font(.callout.monospacedDigit().weight(.semibold))
            Text(totals.sevenDays[keyPath: unit]).font(.callout.monospacedDigit())
            Text(totals.thirtyDays[keyPath: unit]).font(.callout.monospacedDigit())
        }
    }
}

private struct DeviceFreshnessRow: View {
    let source: ActivitySourceConfig
    let status: ActivitySourceStatus?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill((status?.health ?? .loading).tint).frame(width: 6, height: 6)
            Text(source.name).font(.caption2)
            Spacer()
            Text(freshness).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(status?.detail ?? "")
    }

    private var freshness: String {
        let updated = status?.lastSuccess.map { "updated " + $0.formatted(.relative(presentation: .named)) }
        switch status?.health {
        case .fresh?: return updated ?? "Connected"
        case .stale?: return ["Stale", updated].compactMap { $0 }.joined(separator: " · ")
        case .unavailable?: return status?.detail ?? "Unavailable"
        case .loading?, nil: return updated ?? "Waiting for first run"
        case let health?: return health.label
        }
    }
}

private struct TotalsRow: View {
    let title: String
    let cells: [(label: String, value: Double)]

    init(title: String, cells: [(label: String, value: Double)]) {
        self.title = title
        self.cells = cells
    }

    init(totals: ProviderTotals, title: String) {
        self.init(title: title, cells: [("Today", totals.today), ("7 days", totals.sevenDays), ("Lifetime", totals.lifetime)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                ForEach(cells, id: \.label) { cell in
                    TotalCell(label: cell.label, value: cell.value)
                }
            }
        }.padding(10)
    }

    /// Provider token rows sit on a light wash of the provider's color instead of another gray layer.
    func tinted(_ color: Color) -> some View {
        background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TotalCell: View {
    let label: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading) {
            Text(value.tokenText).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderCard<Summary: View, Extra: View>: View {
    let snapshot: ProviderSnapshot
    let preferences: AppPreferences
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let extra: () -> Extra
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(snapshot.provider.tint).frame(width: 8, height: 8)
                Text(snapshot.provider.rawValue).font(.headline)
                Spacer()
                Text(snapshot.health.label).font(.caption).foregroundStyle(snapshot.health.tint)
            }
            if let detail = snapshot.detail, snapshot.health != .fresh {
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(snapshot.health.tint)
            }
            summary()
            if !snapshot.quotaWindows.isEmpty {
                Text("\(snapshot.provider.rawValue) account quota").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.quotaWindows) { quota in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(quota.name)
                        Spacer()
                        Text("\(quota.used.tokenText) / \(quota.limit.tokenText) \(quota.unit)").foregroundStyle(.secondary)
                    }
                    ProgressView(value: quota.fraction).tint(tint(for: quota))
                    if let resetAt = quota.resetAt {
                        Text("Resets \(resetAt.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            extra()
        }.padding(12).cardSurface()
    }

    private func tint(for quota: QuotaWindow) -> Color {
        switch QuotaClassification.classify(quota.fraction, preferences: preferences) {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct SevenDayChart: View {
    let series: [ChartSeries]
    var body: some View {
        VStack(alignment: .leading) {
            Text("7-day tokens").font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let maximum = max(1, series.flatMap(\.values).max() ?? 1)
                HStack(alignment: .bottom, spacing: SevenDayChartLayout.daySpacing) {
                    ForEach(0..<7, id: \.self) { index in
                        HStack(alignment: .bottom, spacing: SevenDayChartLayout.providerSpacing) {
                            ForEach(series, id: \.provider) { line in
                                let height = max(2, proxy.size.height * line.values[index] / maximum)
                                RoundedRectangle(
                                    cornerRadius: SevenDayChartLayout.cornerRadius(for: height),
                                    style: .continuous
                                )
                                    .fill(line.provider.tint)
                                    .frame(width: SevenDayChartLayout.barWidth, height: height)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }.frame(height: 56)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: UsageViewModel
    @State private var selection = "General"
    private let timeZones = TimeZone.knownTimeZoneIdentifiers.sorted()

    var body: some View {
        NavigationSplitView {
            List(["General", "Providers", "Activity Sources", "Data & Privacy"], id: \.self, selection: $selection) { Text($0) }
                .navigationTitle("QuotaBar")
        } detail: {
            Form {
                if selection == "General" { general }
                if selection == "Providers" { providers }
                if selection == "Activity Sources" { ActivitySourcesSettings(model: model) }
                if selection == "Data & Privacy" { privacy }
            }.formStyle(.grouped).padding().navigationTitle(selection)
        }.frame(minWidth: 760, minHeight: 510)
    }

    private var general: some View {
        Section("Menu bar") {
            Toggle("Launch at login", isOn: Binding(get: { model.preferences.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Toggle("Show menu bar text", isOn: $model.preferences.menuBarText)
            Toggle("Refresh when panel opens", isOn: $model.preferences.refreshOnOpen)
            Picker("Refresh interval", selection: Binding(get: { model.preferences.refreshInterval }, set: { model.setRefreshInterval($0) })) {
                Text("5 minutes").tag(TimeInterval(300))
                Text("15 minutes").tag(TimeInterval(900))
                Text("30 minutes").tag(TimeInterval(1800))
            }
            Slider(value: Binding(get: { model.preferences.warningThreshold }, set: { model.setWarningThreshold($0) }), in: 0.5...1) { Text("Warning threshold") }
            Slider(value: Binding(get: { model.preferences.criticalThreshold }, set: { model.setCriticalThreshold($0) }), in: 0.5...1) { Text("Critical threshold") }
        }
    }

    private var providers: some View {
        Section("Account sources") {
            providerControl(.codex, enabled: model.preferences.codexEnabled, protocolDetail: "Signed-in Codex app-server JSON-RPC")
            providerControl(.zcode, enabled: model.preferences.zcodeEnabled, protocolDetail: "Z.ai Coding Plan API; local credential access requires consent")
            Toggle("Allow local ZCode credential discovery", isOn: $model.preferences.zcodeConsent)
            providerControl(.claude, enabled: model.preferences.claudeEnabled, protocolDetail: "Anthropic OAuth usage endpoint for quota windows; local activity comes from Activity Sources")
            Toggle("Allow reading Claude Code's sign-in from the Keychain", isOn: $model.preferences.claudeConsent)
            Text("QuotaBar reads the access token from the “Claude Code-credentials” Keychain item only to request quota windows. It never refreshes, rewrites, stores, or exports it. When the token expires, run Claude Code to sign in again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func providerControl(_ provider: ProviderID, enabled: Bool, protocolDetail: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(provider.rawValue, isOn: Binding(get: { enabled }, set: { model.setEnabled($0, for: provider) }))
            Text(protocolDetail).font(.caption).foregroundStyle(.secondary)
            if let snapshot = model.snapshots[provider] {
                Text("\(snapshot.health.label) · last poll \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Coverage: \(snapshot.coverage)")
                    .font(.caption).foregroundStyle(.secondary)
                if let detail = snapshot.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(enabled ? "No account snapshot yet" : "Disabled")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Test connection") { Task { await model.refresh() } }
        }
    }

    private var privacy: some View {
        Section("Data and privacy") {
            Picker("Day boundary time zone", selection: $model.preferences.timeZoneIdentifier) {
                ForEach(timeZones, id: \.self) { Text($0).tag($0) }
            }
            Text("ZCode Lifetime covers account usage from 2025-01-01. Provider and activity timestamps are stored as UTC instants; changing this display boundary does not rewrite the ledger.")
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude local activity").font(.headline)
                let sources = model.preferences.activitySources.filter(\.enabled)
                Text(sources.isEmpty ? "No enabled activity sources." : "Covers " + sources.map { source in
                    model.activityStatus[source.id]?.device.map { "\(source.name) (\($0))" } ?? source.name
                }.joined(separator: ", ") + ".")
                Text("Counted per device from Claude Code transcripts and never added to account totals. Tokens include input, output, cache reads, and cache writes. A session mirrored on several devices is counted once.")
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Provider diagnostics").font(.headline)
            ForEach(ProviderID.allCases) { provider in
                let presentation = ProviderDiagnosticsPresentation.make(
                    provider: provider,
                    enabled: model.preferences.enabled(provider),
                    snapshot: model.snapshots[provider]
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(presentation.provider.rawValue) · \(presentation.stateLabel)")
                    Text("Coverage: \(presentation.coverage)")
                    if let updatedAt = presentation.updatedAt {
                        Text("Last poll \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let detail = presentation.detail {
                        Text(detail)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Export JSON") { Task { try? await model.export(.json) } }
                Button("Export CSV") { Task { try? await model.export(.csv) } }
            }
            Text("MCP quota rows are displayed only when reported by the provider. Exports include hourly activity counts per source without session ids. Credentials, prompts, raw responses, paths, and local session logs are neither exported nor stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActivitySourcesSettings: View {
    @ObservedObject var model: UsageViewModel

    var body: some View {
        Section {
            ForEach(model.preferences.activitySources) { source in
                ActivitySourceEditor(model: model, source: source, status: model.activityStatus[source.id])
                    .id(source.id)
            }
            HStack {
                Button("Add SSH Source") {
                    model.addActivitySource(ActivitySourceConfig(id: UUID(), name: "Remote", argv: ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "host", "python3", "-"], enabled: false, pipesCollector: true))
                }
                Button("Add Custom Command") {
                    model.addActivitySource(ActivitySourceConfig(id: UUID(), name: "Custom", argv: [], enabled: false, pipesCollector: false))
                }
                Spacer()
                Button("Refresh All") { Task { await model.refreshActivity() } }
                    .disabled(model.isRefreshingActivity || !model.preferences.claudeEnabled)
            }
        } header: {
            Text("Claude activity sources")
        } footer: {
            Text("Each source is a command run directly, without a shell. With “Pipe bundled collector”, QuotaBar sends its stdlib-only Python collector to the command's standard input and appends --since; for SSH, replace host with your SSH alias. Otherwise the command must print the quotabar.activity JSON schema itself. Apps opened from Finder have a minimal PATH and may not see your shell's SSH agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ActivitySourceEditor: View {
    @ObservedObject var model: UsageViewModel
    let source: ActivitySourceConfig
    let status: ActivitySourceStatus?
    @State private var name: String
    @State private var command: String
    @State private var commandError: String?

    init(model: UsageViewModel, source: ActivitySourceConfig, status: ActivitySourceStatus?) {
        self.model = model
        self.source = source
        self.status = status
        _name = State(initialValue: source.name)
        _command = State(initialValue: CommandLineSplitter.join(source.argv))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $name).onSubmit { save() }.font(.headline)
                Spacer()
                Circle().fill((status?.health ?? (source.enabled ? .loading : .disabled)).tint).frame(width: 8, height: 8)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            TextField("Command", text: $command, prompt: Text("python3 -"))
                .font(.system(.caption, design: .monospaced))
                .onSubmit { save() }
            HStack {
                Toggle("Enabled", isOn: Binding(get: { source.enabled }, set: { enabled in
                    var updated = source
                    updated.enabled = enabled
                    model.updateActivitySource(updated)
                    if enabled { Task { await model.refreshActivity(only: source.id) } }
                }))
                Toggle("Pipe bundled collector", isOn: Binding(get: { source.pipesCollector }, set: { pipes in
                    var updated = source
                    updated.pipesCollector = pipes
                    model.updateActivitySource(updated)
                }))
            }.toggleStyle(.checkbox).font(.caption)
            if let commandError { Text(commandError).font(.caption).foregroundStyle(.red) }
            if let detail = status?.detail, status?.health != .fresh { Text(detail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Save") { save() }.disabled(!isDirty)
                Button("Test") {
                    let id = save()
                    Task { await model.refreshActivity(only: id) }
                }.disabled(!source.enabled || model.isRefreshingActivity || !model.preferences.claudeEnabled)
                Spacer()
                Button("Remove", role: .destructive) { Task { await model.removeActivitySource(source.id) } }
            }.controlSize(.small)
        }
        .padding(.vertical, 4)
        .onChange(of: source) { load() }
    }

    private var isDirty: Bool { name != source.name || command != CommandLineSplitter.join(source.argv) }

    private var statusText: String {
        guard source.enabled else { return "Disabled" }
        guard let status else { return "Not run yet" }
        let device = status.device.map { "\($0) · " } ?? ""
        let updated = status.lastSuccess.map { $0.formatted(.relative(presentation: .named)) }
        switch status.health {
        case .fresh: return device + (updated ?? "Connected")
        case .loading: return "Running…"
        default: return device + status.health.label + (updated.map { " · \($0)" } ?? "")
        }
    }

    private func load() {
        name = source.name
        command = CommandLineSplitter.join(source.argv)
        commandError = nil
    }

    /// Saves edits and returns the source's current id.
    @discardableResult
    private func save() -> UUID {
        guard isDirty else { return source.id }
        guard let argv = CommandLineSplitter.split(command), !argv.isEmpty else {
            commandError = "Enter a command; quotes must be balanced."
            return source.id
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var updated = source
        updated.name = trimmed.isEmpty ? source.name : trimmed
        updated.argv = argv
        commandError = nil
        return model.updateActivitySource(updated)
    }
}
