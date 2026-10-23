// Mac Android Subsystem - the app: a menu bar item plus the settings window,
// keeping Android running in the background.
//
// It opens:
//   .apk/.apks/.apkm/.xapk files  -> installs them (double-click an APK in Finder)
//   UTM-VM-lineage zips, .utm     -> installs that Android image
//   msa://start?package=...       -> starts Android (sent by app windows)
//   msa://open?package=...        -> opens an Android app's window
//   msa://settings                -> shows the settings window
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SubsystemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var subsystem = Subsystem.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(subsystem)
                .environmentObject(subsystem.settings)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: subsystem.state))
        }
    }
}

extension Subsystem {
    var menuBarSymbol: String {
        switch state {
        case .running: return "square.stack.3d.up.fill"
        case .starting, .stopping: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        default: return "square.stack.3d.up"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handledLaunchRequest = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RenameMigration.run()
        NotificationRelay.shared.requestPermission()
        StorageJanitor.shared.startSchedule()
        let subsystem = Subsystem.shared
        subsystem.applyResourcesPolicy()
        // Opened by the person (not at login, by an app window or a file): show the settings.
        let atLogin = Self.launchedAtLogin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            if subsystem.state == .notInstalled || (!self.handledLaunchRequest && !atLogin) {
                SettingsWindowController.shared.show()
            }
        }
    }

    /// Started by "Always ready" at login: stay quietly in the menu bar.
    private static var launchedAtLogin: Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           // keyAEPropData ('prdt') == keyAELaunchedAsLogInItem ('lgit')
           event.paramDescriptor(forKeyword: AEKeyword(0x7072_6474))?.enumCodeValue == OSType(0x6C67_6974) {
            return true
        }
        // Login items registered with SMAppService don't always carry that flag; a launch
        // within a few minutes of the login session starting counts as one.
        guard SubsystemSettings.shared.startAtLogin else { return false }
        let sessionAge = Date().timeIntervalSince(loginSessionStart ?? .distantPast)
        return sessionAge < 180
    }

    private static var loginSessionStart: Date? {
        // The console user's loginwindow starts when the session does.
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.loginwindow" }?.launchDate
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchRequest = true
        var packages: [URL] = []
        for url in urls {
            if url.isFileURL {
                if PackageInstaller.canInstall(url) {
                    packages.append(url)
                } else if url.pathExtension.lowercased() == "utm" || url.lastPathComponent.hasPrefix("UTM-VM-") {
                    confirmImageInstall(url)
                }
            } else {
                handle(url)
            }
        }
        if !packages.isEmpty { Subsystem.shared.install(packages) }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else { return }
        handledLaunchRequest = true
        handle(url)
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == AppConfig.urlScheme.lowercased() else { return }
        let package = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "package" }?.value
        switch url.host?.lowercased() {
        case "start":
            Subsystem.shared.start()
        case "open":
            if let package { AppCatalog.open(package: package) }
        case "settings":
            SettingsWindowController.shared.show()
        default:
            break
        }
    }

    private func confirmImageInstall(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = L10n.format("Replace Android with %@?", url.lastPathComponent)
        alert.informativeText = L10n.text("All Android apps and their data will be erased.")
        alert.addButton(withTitle: L10n.text("Replace"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.alertStyle = .warning
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            Subsystem.shared.installImage(from: url)
            SettingsWindowController.shared.show()
        }
    }

    /// Quitting turns Android off cleanly first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let subsystem = Subsystem.shared
        guard subsystem.state.isActive else { return .terminateNow }
        subsystem.stop()
        Task { @MainActor in
            for _ in 0..<120 where subsystem.state.isActive {
                try? await Task.sleep(for: .milliseconds(250))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The settings window, hosted in AppKit so it can be shown from anywhere.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    let navigation = SettingsNavigation()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = AppConfig.displayName
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SettingsWindow")
        super.init(window: window)
        window.delegate = self
        installContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A fresh SwiftUI hierarchy each time the window opens: one kept alive for the
    /// app's lifetime could end up with an empty sidebar column, and stayed that way.
    private func installContent() {
        guard let window else { return }
        let frame = window.frame
        let hosting = NSHostingController(
            rootView: SettingsRootView()
                .environmentObject(Subsystem.shared)
                .environmentObject(Subsystem.shared.settings)
                .environmentObject(navigation))
        // The window keeps the size the person gives it; SwiftUI resizing it to its
        // content glitched the split view's layout.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrame(frame, display: false)
    }

    func show(section: SettingsSection? = nil) {
        if let section { navigation.section = section }
        if window?.contentViewController == nil { installContent() }
        // While the window is open the app appears in the Dock and ⌘-Tab, like a normal app.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Let the next show() build the window's content again.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }
}

enum FilePicker {
    static var packageTypes: [UTType] {
        PackageInstaller.fileExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    @MainActor
    static func pickPackages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Install Android Apps")
        panel.prompt = L10n.text("Install")
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = packageTypes
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    static func pickImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an Android Image")
        panel.message = L10n.text("Choose a UTM-VM-lineage-…-virtio_arm64only.zip file or a .utm folder.")
        panel.prompt = L10n.text("Use Image")
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "utm") ?? .folder, .folder]
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func pickFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Send Files to Android")
        panel.prompt = L10n.text("Send")
        panel.allowsMultipleSelection = true
        NSApp.activate()
        return panel.runModal() == .OK ? panel.urls : []
    }
}
