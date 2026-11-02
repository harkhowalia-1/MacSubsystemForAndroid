// Mac Android Subsystem - removing the app and everything it put on this Mac.
//
// After the person confirms, in this order:
//   1. quit every Android app launcher that is open (so none asks to start Android again)
//   2. turn Android off cleanly (QEMU exits when Android powers off)
//   3. remove the start-at-login item
//   4. unregister and delete every launcher in ~/Applications/Android Apps
//   5. delete ~/Library/Application Support/Mac Android Subsystem (Android, its disks,
//      every app's data) and the folders earlier names used, plus caches and QEMU's sockets
//   6. remove the app's preferences and each launcher's
//   7. move the app itself to the Trash and quit
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import ServiceManagement

@MainActor
enum Uninstaller {
    /// Set while uninstalling, so nothing starts Android again meanwhile.
    private(set) static var isRunning = false

    static func confirmAndUninstall() {
        guard !isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(AppConfig.displayName)?"
        alert.informativeText = "Android and the data of every Android app, including photos and files saved in Android, will be deleted from this Mac. The Android apps in \(AppConfig.launcherFolderName) are removed too, and \(AppConfig.displayName) moves to the Trash. This can't be undone."
        alert.alertStyle = .critical
        let uninstallButton = alert.addButton(withTitle: "Uninstall")
        uninstallButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await uninstall() }
    }

    private static func uninstall() async {
        isRunning = true
        let subsystem = Subsystem.shared
        subsystem.busy = Subsystem.Busy(message: "Uninstalling \(AppConfig.displayName)…")

        await quitLaunchers()

        subsystem.stop()
        // stop() waits up to 20 s for Android to power off, then QEMU gets 8 s more.
        for _ in 0..<160 where subsystem.state.isActive {
            try? await Task.sleep(for: .milliseconds(250))
        }
        // A storage clean-up may still be compacting the disks.
        for _ in 0..<240 where StorageJanitor.shared.isCompacting {
            try? await Task.sleep(for: .milliseconds(250))
        }
        VirtualMachine.killStaleInstance()

        try? await SMAppService.mainApp.unregister()

        // The settings window saves its frame to the preferences as it closes.
        NSApp.windows.forEach { $0.close() }

        var failures = removeLaunchers()
        failures += removeData()
        removePreferences()

        do {
            try await NSWorkspace.shared.recycle([Bundle.main.bundleURL])
        } catch {
            failures.append(Bundle.main.bundleURL)
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some items couldn't be removed"
            alert.informativeText = "Move these to the Trash in Finder:\n" + failures.map(\.path).joined(separator: "\n")
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "Quit")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(failures)
            }
        }
        NSApp.terminate(nil)
    }

    /// Ask every open Android app to quit; force the ones that don't within a few seconds.
    private static func quitLaunchers() async {
        let prefix = AppConfig.launcherBundlePrefix + "."
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(prefix) == true }
        running.forEach { $0.terminate() }
        for _ in 0..<20 where running.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    // MARK: Removing files

    /// Unregister each launcher from Launch Services (so Launchpad and Spotlight drop it),
    /// then delete it, and the launcher folder once it's empty. Returns what couldn't be deleted.
    nonisolated static func removeLaunchers() -> [URL] {
        let fm = FileManager.default
        let folder = SubsystemPaths.launchers
        var failures: [URL] = []
        for url in LauncherGenerator.existing().values {
            // LSRegisterURL can only add or refresh a registration; lsregister -u removes it.
            run(lsregister, ["-u", url.path])
            do { try fm.removeItem(at: url) } catch { failures.append(url) }
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
            try? fm.removeItem(at: folder)
        }
        return failures
    }

    /// Android, its disks and every app's data, and what else the app keeps on disk.
    nonisolated static var dataFolders: [URL] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var folders = [SubsystemPaths.support]
        folders += AppConfig.legacySupportFolderNames.map { support.appendingPathComponent($0, isDirectory: true) }
        folders += [
            caches.appendingPathComponent(AppConfig.subsystemBundleID, isDirectory: true),
            library.appendingPathComponent("HTTPStorages/\(AppConfig.subsystemBundleID)", isDirectory: true),
            SubsystemPaths.runtime,
        ]
        return folders
    }

    /// Returns what couldn't be deleted.
    nonisolated static func removeData() -> [URL] {
        let fm = FileManager.default
        return dataFolders.filter { url in
            guard fm.fileExists(atPath: url.path) else { return false }
            return (try? fm.removeItem(at: url)) == nil
        }
    }

    /// The preference domains to remove: the app's own and every launcher's.
    nonisolated static var preferenceDomains: [String] {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Preferences").path)) ?? []
        let prefix = AppConfig.launcherBundlePrefix + "."
        let launchers = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") }.map { String($0.dropLast(".plist".count)) }
        return [AppConfig.subsystemBundleID] + launchers
    }

    nonisolated static func removePreferences() {
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        for domain in preferenceDomains {
            // Through cfprefsd first, so its cached copy goes too, then the file itself
            // (after the synchronize, or cfprefsd writes an empty one back).
            UserDefaults.standard.removePersistentDomain(forName: domain)
            CFPreferencesAppSynchronize(domain as CFString)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(domain).plist"))
        }
    }

    private nonisolated static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

    private nonisolated static func run(_ tool: URL, _ arguments: [String]) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
