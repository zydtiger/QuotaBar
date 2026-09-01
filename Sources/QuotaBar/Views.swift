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
    static let insets = NSEdgeInsets(top: 16, left: 0, bottom: 16, right: 1)

    static func apply(to scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerInsets = insets
        scrollView.verticalScroller?.controlSize = .mini
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("QuotaBar").font(.title3.weight(.semibold))
                        Text(model.isRefreshing ? "Refreshing account usage…" : "Account-based, cross-device usage")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Settings") {
                        SettingsPresenter.show { openSettings() }
                    }
                    .buttonStyle(.borderless)
                }
                TotalsRow(totals: model.aggregate, title: "Enabled providers")
                ForEach(ProviderID.allCases) { provider in
                    if let snapshot = model.snapshots[provider], model.preferences.enabled(provider) {
                        ProviderCard(snapshot: snapshot, totals: UsageMath.totals(for: snapshot, now: .now, calendar: model.preferences.calendar), preferences: model.preferences)
                    }
                }
                SevenDayChart(snapshots: model.enabledSnapshots, calendar: model.preferences.calendar)
                HStack {
                    if model.preferences.codexEnabled { Text("● Codex").foregroundStyle(.blue) }
                    if model.preferences.zcodeEnabled { Text("● ZCode").foregroundStyle(.orange) }
                    Spacer()
                    Button("Quit QuotaBar") { ApplicationActions.quit() }
                    Button("Refresh") { Task { await model.refresh() } }.disabled(model.isRefreshing)
                }.font(.caption)
            }
            .padding(16)
            .background(OverlayScrollerConfigurator())
        }.frame(width: 380, height: 620).task { await model.panelOpened() }
    }
}

private struct TotalsRow: View {
    let totals: ProviderTotals
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                TotalCell(label: "Today", value: totals.today)
                TotalCell(label: "7 days", value: totals.sevenDays)
                TotalCell(label: "Lifetime", value: totals.lifetime)
            }
        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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

private struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let totals: ProviderTotals
    let preferences: AppPreferences
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.provider.rawValue).font(.headline)
                Spacer()
                Text(snapshot.health.label).font(.caption).foregroundStyle(snapshot.health == .fresh ? .green : .secondary)
            }
            if let detail = snapshot.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            TotalsRow(totals: totals, title: snapshot.coverage)
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
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
    let snapshots: [ProviderSnapshot]
    let calendar: Calendar
    var body: some View {
        VStack(alignment: .leading) {
            Text("7-day provider tokens").font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let maximum = max(1, snapshots.flatMap(\.dailyUsage).map(\.tokens).max() ?? 1)
                HStack(alignment: .bottom, spacing: SevenDayChartLayout.daySpacing) {
                    ForEach(0..<7, id: \.self) { index in
                        let date = calendar.date(byAdding: .day, value: index - 6, to: calendar.startOfDay(for: .now))!
                        HStack(alignment: .bottom, spacing: SevenDayChartLayout.providerSpacing) {
                            ForEach(snapshots, id: \.provider) { snapshot in
                                let value = UsageMath.tokens(for: snapshot, on: date, calendar: calendar)
                                let height = max(2, proxy.size.height * value / maximum)
                                RoundedRectangle(
                                    cornerRadius: SevenDayChartLayout.cornerRadius(for: height),
                                    style: .continuous
                                )
                                    .fill(snapshot.provider == .codex ? Color.blue : Color.orange)
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
            List(["General", "Providers", "Data & Privacy"], id: \.self, selection: $selection) { Text($0) }
                .navigationTitle("QuotaBar")
        } detail: {
            Form {
                if selection == "General" { general }
                if selection == "Providers" { providers }
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
            Text("ZCode Lifetime covers account usage from 2025-01-01. Provider timestamps are stored as UTC instants; changing this display boundary does not rewrite the ledger.")
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
            Text("MCP quota rows are displayed only when reported by the provider. Credentials, prompts, raw responses, and local session logs are neither exported nor stored.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
