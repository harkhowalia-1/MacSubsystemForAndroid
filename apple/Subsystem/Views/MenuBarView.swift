// Mac Android Subsystem - the menu bar item: status, start/stop, performance mode,
// Always ready, open apps, settings and quit.
// Licensed under the GNU General Public License v3 or later.

import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings

    var body: some View {
        Text(statusLine)
        if let detail = subsystem.state.detail {
            Text(detail)
        }
        if !subsystem.changesNeedingRestart.isEmpty {
            Button("Restart Android to Apply Changes") { subsystem.restart() }
        }
        Divider()

        switch subsystem.state {
        case .off, .failed:
            Button("Start Android") { subsystem.start() }
        case .running:
            Button("Restart Android") { subsystem.restart() }
            Button("Turn Off Android") { subsystem.stop() }
        case .starting:
            Button("Turn Off Android") { subsystem.stop() }
        case .notInstalled:
            Button("Set Up Android…") { SettingsWindowController.shared.show(section: .system) }
        case .stopping:
            EmptyView()
        }

        Divider()
        Picker("Performance Mode", selection: Binding(
            get: { settings.performanceMode },
            set: { mode in
                settings.performanceMode = mode
                subsystem.performanceModeChanged()
            })) {
            ForEach(PerformanceMode.allCases) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.inline)

        Toggle("Always Ready (Start with Mac)", isOn: Binding(
            get: { settings.alwaysReady },
            set: { ready in
                settings.alwaysReady = ready
                subsystem.applyResourcesPolicy()
            }))

        Divider()
        if !subsystem.apps.isEmpty {
            Menu("Open Android App") {
                ForEach(subsystem.apps) { app in
                    Button(app.label) { subsystem.open(app) }
                }
            }
        }
        Button("Install Android App…") {
            let urls = FilePicker.pickPackages()
            if !urls.isEmpty { subsystem.install(urls) }
        }
        .disabled(subsystem.state == .notInstalled)

        Divider()
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button(L10n.format("Quit %@", AppConfig.displayName)) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        var line = L10n.format("Android: %@", subsystem.state.title)
        if case .running = subsystem.state {
            line += L10n.format(" · %@", settings.performanceMode.title)
        }
        return line
    }
}
