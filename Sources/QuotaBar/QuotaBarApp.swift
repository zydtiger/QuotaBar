import SwiftUI

@main
struct QuotaBarApp: App {
    @StateObject private var model = UsageViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            Label(model.preferences.menuBarText ? "QuotaBar" : "", systemImage: "gauge.with.dots.needle.67percent")
                .task { await model.appStarted() }
        }.menuBarExtraStyle(.window)
        Settings { SettingsView(model: model) }
    }
}
