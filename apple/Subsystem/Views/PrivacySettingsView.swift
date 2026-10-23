// Mac Android Subsystem - Settings › Privacy: which Android apps may use the
// camera, microphone, location and other private data (AndroidPermissions.swift),
// laid out like Privacy & Security on the Mac. Also the per-app sheet in Apps.
// Licensed under the GNU General Public License v3 or later.

import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @ObservedObject private var privacy = PrivacyCenter.shared
    @State private var path: [PrivacyCategory] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if subsystem.state != .running {
                    ContentUnavailableView {
                        Label("Android is off", systemImage: "hand.raised")
                    } description: {
                        Text("Start Android to see which apps can use your camera, microphone, location and other private data.")
                    } actions: {
                        Button("Start Android") { subsystem.start() }
                    }
                } else {
                    Form {
                        Section {
                            ForEach(PrivacyCategory.allCases) { category in
                                NavigationLink(value: category) {
                                    HStack {
                                        PrivacySymbol(category: category)
                                        Text(category.title)
                                        Spacer()
                                        let count = privacy.apps(in: category, from: subsystem.apps).count
                                        if count > 0 {
                                            Text("\(count)").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        } footer: {
                            Text("Apps ask for access when they need it. Here you can see which apps asked and turn access on or off at any time.")
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Privacy")
            .navigationDestination(for: PrivacyCategory.self) { PrivacyCategoryView(category: $0) }
        }
        .task(id: subsystem.state) { privacy.refresh(subsystem.apps) }
        .onChange(of: subsystem.apps) { _, apps in privacy.refresh(apps) }
        .privacyFailureAlert()
    }
}

struct PrivacyCategoryView: View {
    @EnvironmentObject private var subsystem: Subsystem
    @EnvironmentObject private var settings: SubsystemSettings
    @ObservedObject private var privacy = PrivacyCenter.shared
    let category: PrivacyCategory

    var body: some View {
        Form {
            if category == .microphone {
                Section {
                    Toggle("Let Android use this Mac's microphone", isOn: $settings.microphone)
                } footer: {
                    Text(L10n.text(subsystem.state == .running
                                   ? "Android has no microphone when this is off, whatever apps are allowed. A change takes effect the next time Android starts."
                                   : "Android has no microphone when this is off, whatever apps are allowed."))
                }
            }
            if let hardware {
                Section {
                    Label(L10n.text(hardware), systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
            Section {
                let apps = privacy.apps(in: category, from: subsystem.apps)
                if apps.isEmpty {
                    Text(privacy.loading
                         ? L10n.text("Checking apps…")
                         : L10n.format("No apps have asked to %@.", category.detail))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(apps) { app in
                        PrivacyToggleRow(app: app, category: category, showsApp: true)
                    }
                }
            } header: {
                Text(L10n.format("Apps that asked to %@", category.detail))
            } footer: {
                if category == .location {
                    Text("Turning access on allows it while the app is in use. Turning it off also removes access in the background.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(category.title)
    }

    /// What the Mac hands to Android, where an allowed app still gets nothing.
    private var hardware: String? {
        switch category {
        case .camera: return "Android doesn't have a camera on this Mac yet, so apps can't take photos even when allowed."
        case .location: return "Android has no location source on this Mac, so apps can't find where you are even when allowed."
        case .phone, .callLogs, .messages: return "Android on this Mac has no cellular service, so it can't make calls and has no call log or text messages."
        case .bodySensors, .activity: return "Android has no body or motion sensors on this Mac."
        default: return nil
        }
    }
}

/// An app's permissions in one sheet, from Settings › Apps.
struct AppPrivacySheet: View {
    @EnvironmentObject private var subsystem: Subsystem
    @ObservedObject private var privacy = PrivacyCenter.shared
    @Environment(\.dismiss) private var dismiss
    let app: AndroidApp

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(package: app.package).frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text(app.label).font(.headline)
                    Text(app.package).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Form {
                let categories = privacy.categories(for: app)
                if categories.isEmpty {
                    Text(privacy.loading
                         ? L10n.text("Checking…")
                         : L10n.format("%@ hasn't asked for access to any private data.", app.label))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(categories) { category in
                        PrivacyToggleRow(app: app, category: category, showsApp: false)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
        .task { privacy.refresh(subsystem.apps) }
        .privacyFailureAlert()
    }
}

struct PrivacyToggleRow: View {
    @ObservedObject private var privacy = PrivacyCenter.shared
    let app: AndroidApp
    let category: PrivacyCategory
    let showsApp: Bool

    var body: some View {
        let access = privacy.access(of: app, in: category)
        HStack(spacing: 10) {
            if showsApp {
                AppIcon(package: app.package).frame(width: 24, height: 24)
                Text(app.label)
            } else {
                PrivacySymbol(category: category)
                Text(category.title)
            }
            Spacer()
            if privacy.isChanging(app, category) {
                ProgressView().controlSize(.small)
            }
            if access?.locked == true {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    .help(L10n.format("Android locks this permission for %@, so it can't be changed here.", app.label))
            }
            Toggle(isOn: Binding(get: { access?.allowed ?? false },
                                 set: { privacy.set($0, for: app, in: category) })) {
                Text(L10n.format("%@ for %@", category.title, app.label))
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(access == nil || access?.locked == true || privacy.isChanging(app, category))
        }
    }
}

/// The colored rounded square the Mac shows next to each privacy category.
struct PrivacySymbol: View {
    let category: PrivacyCategory

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient))
    }

    private var color: Color {
        switch category {
        case .camera, .photos: return .gray
        case .microphone, .music, .bodySensors: return .red
        case .location, .files, .nearby: return .blue
        case .contacts, .calendars: return .orange
        case .notifications: return .pink
        case .phone, .callLogs, .messages, .activity: return .green
        }
    }
}

private extension View {
    func privacyFailureAlert() -> some View {
        modifier(PrivacyFailureAlert())
    }
}

private struct PrivacyFailureAlert: ViewModifier {
    @ObservedObject private var privacy = PrivacyCenter.shared

    func body(content: Content) -> some View {
        content.alert("Couldn't change access", isPresented: Binding(
            get: { privacy.failure != nil }, set: { if !$0 { privacy.failure = nil } })) {
            Button("OK") { privacy.failure = nil }
        } message: {
            Text(privacy.failure ?? "")
        }
    }
}
