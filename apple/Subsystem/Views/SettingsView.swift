// Mac Android Subsystem - the settings window: System, Performance, Apps, Privacy,
// Files, Storage, Advanced, About.
// Licensed under the GNU General Public License v3 or later.

import AppKit
import GameController
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case system, performance, apps, privacy, files, storage, advanced, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("System")
        case .performance: return L10n.text("Performance")
        case .apps: return L10n.text("Apps")
        case .privacy: return L10n.text("Privacy")
        case .files: return L10n.text("Files")
        case .storage: return L10n.text("Storage")
        case .advanced: return L10n.text("Advanced")
        case .about: return L10n.text("About")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "cpu"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .apps: return "square.grid.2x2"
        case .privacy: return "hand.raised"
        case .files: return "folder"
        case .storage: return "internaldrive"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .system
}

struct SettingsRootView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        Group {
            if subsystem.image == nil {
                SetupView()
            } else {
                NavigationSplitView {
                    SettingsSidebar(selection: $navigation.section)
                } detail: {
                    VStack(spacing: 0) {
                        RestartBanner()
                        pane
                    }
                    .animation(.default, value: subsystem.changesNeedingRestart)
                }
            }
        }
        .overlay {
            if let busy = subsystem.busy { BusyOverlay(busy: busy) }
        }
        .alert(subsystem.notice?.title ?? "", isPresented: Binding(
            get: { subsystem.notice != nil },
            set: { if !$0 { subsystem.notice = nil } }), presenting: subsystem.notice) { _ in
            Button("OK") { subsystem.notice = nil }
        } message: { notice in
            Text(notice.message)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
    @ViewBuilder private var pane: some View {
        switch navigation.section {
        case .system: SystemSettingsView()
        case .performance: PerformanceSettingsView()
        case .apps: AppsSettingsView()
        case .privacy: PrivacySettingsView()
        case .files: FilesSettingsView()
        case .storage: StorageSettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutView()
        }
    }
}

// MARK: - System

struct SystemSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings

    var body: some View {
        Form {
            Section {
                StatusCard()
            }

            Section {
                Toggle(isOn: Binding(get: { settings.alwaysReady }, set: { ready in
                    settings.alwaysReady = ready
                    subsystem.applyResourcesPolicy()
                })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Always ready")
                        Text(L10n.format("Start with your Mac and keep Android running in the background, so Android apps open instantly. %@ stays in the menu bar.", AppConfig.displayName))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section {
                Picker("When the last Android app closes", selection: $settings.resources) {
                    ForEach(SubsystemSettings.Resources.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.resources) { _, _ in subsystem.applyResourcesPolicy() }
                Text(settings.resources.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.performanceMode == .powerSaver {
                    Label("Power Saver is on: Android turns off 30 seconds after the last Android app closes.", systemImage: "leaf")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if settings.resources == .asNeeded {
                    Stepper(L10n.format("Turn off after %@ minutes without open apps", String(settings.idleMinutes)),
                            value: $settings.idleMinutes, in: 1...60)
                }
                Toggle(L10n.format("Start %@ when you log in", AppConfig.displayName), isOn: $settings.startAtLogin)
            } header: {
                Text("Resources")
            }

            Section {
                Toggle("Show Android notifications on the Mac", isOn: $settings.notifications)
                Toggle("Let Android apps use the microphone", isOn: $settings.microphone)
            } header: {
                Text("Integration")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System")
    }
}

struct StatusCard: View {
    @EnvironmentObject private var subsystem: Subsystem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: MenuBarIcon.image(style: MenuBarIcon.style(for: subsystem.state), size: 36))
                .renderingMode(.template)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("Android is %@", subsystem.state.title.localizedLowercase))
                    .font(.headline)
                if let detail = subsystem.state.detail {
                    Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let version = subsystem.androidVersion {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                } else if let image = subsystem.image {
                    Text(image.displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch subsystem.state {
            case .off, .failed:
                Button("Start") { subsystem.start() }.buttonStyle(.borderedProminent)
            case .running:
                Button("Restart") { subsystem.restart() }
                Button("Turn Off") { subsystem.stop() }
            case .starting:
                ProgressView().controlSize(.small)
                Button("Turn Off") { subsystem.stop() }
            case .stopping:
                ProgressView().controlSize(.small)
            case .notInstalled:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch subsystem.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}

// MARK: - Performance

struct PerformanceSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @State private var controllerCount = 0

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(PerformanceMode.allCases) { mode in
                        ModeCard(mode: mode, selected: settings.performanceMode == mode) {
                            settings.performanceMode = mode
                            subsystem.performanceModeChanged()
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Mode")
            } footer: {
                if let level = subsystem.performanceLevel {
                    Text(L10n.format("Right now: %@. App windows stream at up to %@ fps; windows opened from now on use it.",
                                     level.title, String(level.maxFPS)))
                } else {
                    Text("The mode applies whenever Android is running.")
                }
            }

            Section {
                LabeledContent("Processor cores for Android") {
                    Picker("", selection: $settings.cpuCount) {
                        ForEach(settings.cpuChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
                LabeledContent("Memory for Android") {
                    Picker("", selection: $settings.memoryMB) {
                        ForEach(settings.memoryChoices, id: \.self) { Text(L10n.format("%@ GB", String($0 / 1024))).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                Text("These are the most Android can use. Power Saver and Smart lend part of them back to macOS while Android runs. Changes take effect the next time Android starts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Limits")
            }

            Section {
                Toggle("Use game controllers in Android games", isOn: $settings.controllers)
                LabeledContent("Connected controllers", value: controllerCount == 0 ? L10n.text("None") : String(controllerCount))
                Text("Pair a controller in System Settings › Bluetooth (Xbox, PlayStation, Switch Pro and MFi controllers work). It appears in the Android app whose window is in front.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Game controllers")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Performance")
        .onAppear { controllerCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllerCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllerCount = GCController.controllers().filter { $0.extendedGamepad != nil }.count
        }
    }
}

struct ModeCard: View {
    let mode: PerformanceMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(selected ? Color.accentColor : Color.accentColor.opacity(0.12)))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(mode.title).font(.headline)
                Text(mode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Apps

struct AppsSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @State private var confirmRemove: AndroidApp?
    @State private var privacyApp: AndroidApp?
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if subsystem.apps.isEmpty {
                ContentUnavailableView {
                    Label("No Android apps yet", systemImage: "square.grid.2x2")
                } description: {
                    Text(L10n.text(subsystem.state == .running
                                   ? "Install an APK, or get F-Droid to browse free and open-source apps."
                                   : "Start Android to see its apps, or install an APK (Android starts automatically)."))
                } actions: {
                    Button("Install APK…") { install() }
                    Button("Get F-Droid") { subsystem.installFDroid() }
                }
            } else {
                List {
                    ForEach(subsystem.apps) { app in
                        AppRow(app: app)
                            .contextMenu {
                                Button("Open") { subsystem.open(app) }
                                Button("Show in Finder") { revealLauncher(app) }
                                Button("Privacy…") { privacyApp = app }
                                    .disabled(subsystem.state != .running)
                                Divider()
                                Button("Uninstall…", role: .destructive) { confirmRemove = app }
                                    .disabled(app.isSystem)
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            Divider()
            HStack {
                Text(L10n.format("%@ apps", String(subsystem.apps.count)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get F-Droid") { subsystem.installFDroid() }
                Button("Install APK…") { install() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let packages = urls.filter(PackageInstaller.canInstall)
            guard !packages.isEmpty else { return false }
            subsystem.install(packages)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $privacyApp) { AppPrivacySheet(app: $0) }
        .navigationTitle("Apps")
        .navigationSubtitle(L10n.format("Each app is also in Launchpad and Applications › %@", AppConfig.launcherFolderName))
        .confirmationDialog(L10n.format("Uninstall %@?", confirmRemove?.label ?? ""),
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { app in
            Button("Uninstall", role: .destructive) { subsystem.uninstall(app) }
        } message: { _ in
            Text("The app and its data are removed from Android and its Mac launcher is deleted.")
        }
    }

    private func install() {
        let urls = FilePicker.pickPackages()
        if !urls.isEmpty { subsystem.install(urls) }
    }

    private func revealLauncher(_ app: AndroidApp) {
        if let url = LauncherGenerator.existing()[app.package] {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

struct AppRow: View {
    @EnvironmentObject private var subsystem: Subsystem
    let app: AndroidApp

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(package: app.package)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.label).font(.body.weight(.medium))
                Text(app.versionName.isEmpty ? app.package : "\(app.package) · \(app.versionName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { subsystem.open(app) }
        }
        .padding(.vertical, 2)
    }
}

struct AppIcon: View {
    let package: String

    var body: some View {
        if let image = NSImage(contentsOf: SubsystemPaths.icon(for: package)) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .overlay(Image(systemName: "app").foregroundStyle(.secondary))
        }
    }
}

// MARK: - Files

struct FilesSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @State private var dropTargeted = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text("Drop files here to send them to Android")
                        .font(.headline)
                    Text("They're copied into Android's Download folder, where Android apps can open them.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Choose Files…") {
                        let urls = FilePicker.pickFiles()
                        if !urls.isEmpty { subsystem.sendFiles(urls) }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Color.accentColor : .secondary.opacity(0.4),
                                                                           style: StrokeStyle(lineWidth: 2, dash: [6])))
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    subsystem.sendFiles(urls)
                    return true
                } isTargeted: { dropTargeted = $0 }
            }

            Section {
                Button("Open Android's Files app") { AppCatalog.open(package: "com.android.documentsui") }
                    .disabled(!subsystem.apps.contains { $0.package == "com.android.documentsui" })
            } footer: {
                Text("To move files the other way, share them from an Android app, or use ADB (Advanced › Developer mode).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Files")
        .disabled(subsystem.state != .running)
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @ObservedObject private var janitor = StorageJanitor.shared

    var body: some View {
        Form {
            Section {
                UsageBar(usage: janitor.usage)
                    .padding(.vertical, 6)
                row(L10n.text("Android image"), janitor.usage.image, .accentColor)
                row(L10n.text("Android apps and data"), janitor.usage.androidData, .green)
                row(L10n.text("App launchers"), janitor.usage.launchers, .orange)
                row(L10n.text("Downloads, logs and other"), janitor.usage.other, .secondary)
            } header: {
                Text(L10n.format("Space used: %@", format(janitor.usage.total)))
            }

            Section {
                Toggle("Clean up automatically", isOn: $settings.autoCleanup)
                Text("Removes finished downloads, leftovers from installs and updates, icons of removed apps and old logs, and releases space Android no longer uses. When your Mac is low on space it also clears Android apps' caches, and once a week (on power, while Android is off) it compacts Android's disks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(janitor.isWorking ? L10n.text("Cleaning Up…") : L10n.text("Clean Up Now")) { janitor.cleanNow() }
                        .disabled(janitor.isWorking || subsystem.busy != nil)
                    if janitor.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    if let report = janitor.lastReport {
                        Text(report).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if subsystem.state == .running {
                    Text("Compacting Android's disks needs Android to be off; Clean Up Now does everything else while it runs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Clean-up")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .onAppear { janitor.refreshUsage() }
    }

    private func row(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
        LabeledContent {
            Text(format(bytes)).monospacedDigit()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct UsageBar: View {
    let usage: StorageJanitor.Usage

    var body: some View {
        let parts: [(Int64, Color)] = [(usage.image, .accentColor), (usage.androidData, .green),
                                       (usage.launchers, .orange), (usage.other, .secondary)]
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(part.1)
                            .frame(width: max(3, geometry.size.width * CGFloat(part.0) / CGFloat(max(usage.total, 1)) - 2))
                    }
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @State private var confirmReset = false
    @State private var confirmUpdate = false

    private var adbAddress: String { "127.0.0.1:\(AppConfig.adbPort)" }

    var body: some View {
        Form {
            Section {
                Toggle("Developer mode", isOn: $settings.developerMode)
                if settings.developerMode {
                    LabeledContent("ADB address") {
                        HStack {
                            Text(adbAddress).font(.body.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("adb connect \(adbAddress)", forType: .string)
                            }
                        }
                    }
                    Text(L10n.format("Run `adb connect %@` in Terminal, or use Android Studio. ADB only listens on this Mac. The first time, Android asks to allow this computer only if the image requires it.", adbAddress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show Android's own screen in a window", isOn: $settings.showAndroidScreen)
                Text("For troubleshooting: shows Android's home screen in a separate window. Takes effect when Android restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Developer")
            }

            Section {
                LabeledContent("App size") {
                    Slider(value: $settings.displayDensity, in: 0.75...1.5, step: 0.125) {
                        EmptyView()
                    } minimumValueLabel: {
                        Image(systemName: "textformat.size.smaller")
                    } maximumValueLabel: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .frame(maxWidth: 260)
                }
                Toggle("Show Android's on-screen keyboard", isOn: $settings.showSoftKeyboard)
                Text("Both apply to app windows opened from now on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("App windows")
            }

            Section {
                LabeledContent("Image", value: subsystem.image?.displayName ?? L10n.text("None"))
                if let version = subsystem.androidVersion {
                    LabeledContent("Running version", value: version)
                }
                HStack {
                    Button("Download Latest Android…") { confirmUpdate = true }
                    Button("Use an Image File…") {
                        if let url = FilePicker.pickImage() { subsystem.installImage(from: url) }
                    }
                }
                Button("Rebuild App Launchers") { subsystem.rebuildLaunchers() }
                    .disabled(subsystem.state != .running)
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(VirtualMachine.logURL) }
                    Button("Show Android Console") { NSWorkspace.shared.open(VirtualMachine.consoleURL) }
                    Button("Show Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([SubsystemPaths.support]) }
                }
            } header: {
                Text("Android")
            }

            Section {
                Button("Reset Android…", role: .destructive) { confirmReset = true }
                Text("Removes every Android app and all their data, like a factory reset.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .confirmationDialog("Reset Android?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { subsystem.resetAndroid() }
        } message: {
            Text("All Android apps and their data will be erased. This can't be undone.")
        }
        .confirmationDialog("Download the latest Android?", isPresented: $confirmUpdate) {
            Button("Download and Replace", role: .destructive) { subsystem.downloadImage() }
        } message: {
            Text("Installing a new Android image erases all Android apps and their data.")
        }
    }
}

// MARK: - About

struct AboutView: View {
    @EnvironmentObject private var subsystem: Subsystem

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text(AppConfig.displayName).font(.title.weight(.semibold))
                    Text(L10n.format("Version %@", AppConfig.version)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            Section {
                LabeledContent("Device name", value: AppConfig.deviceName)
                if let version = subsystem.androidVersion {
                    LabeledContent("Android", value: version)
                } else if let image = subsystem.image {
                    LabeledContent("Android image", value: image.displayName)
                }
                LabeledContent("Mac app", value: L10n.format("Version %@", AppConfig.version))
            }
            Section {
                Link("Source code (GPLv3)", destination: AppConfig.repositoryURL)
                Link("Guide", destination: AppConfig.guide("start"))
            }
            Section {
                Text("Android apps on your Mac: Android runs in a virtual machine with Apple's Hypervisor framework, and every Android app gets its own Mac window. Built on LineageOS, QEMU and scrcpy. An independent project, not made or endorsed by Google or the LineageOS project. Android is a trademark of Google LLC. The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the Creative Commons 3.0 Attribution License.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Credits")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}

// MARK: - Shared pieces

struct BusyOverlay: View {
    let busy: Subsystem.Busy

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                if let progress = busy.progress {
                    ProgressView(value: progress).frame(width: 260)
                } else {
                    ProgressView()
                }
                Text(busy.message)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
