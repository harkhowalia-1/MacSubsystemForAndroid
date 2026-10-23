// Mac Android Subsystem - the subsystem itself: starts and stops Android, keeps
// the app list and launchers current, installs apps, relays notifications, and
// publishes its state to status.json for the app windows.
//
// Life cycle:
//   off --start--> starting (QEMU boots, ADB connects, bridge installed) --> running
//   running --last app window closed + idle (As needed) / Turn off--> stopping --> off
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import Foundation
import UserNotifications

@MainActor
final class Subsystem: ObservableObject {
    static let shared = Subsystem()

    enum State: Equatable {
        case notInstalled
        case off
        case starting(String)
        case running
        case stopping
        case failed(String)

        var title: String {
            switch self {
            case .notInstalled: return L10n.text("Not set up")
            case .off: return L10n.text("Off")
            case .starting: return L10n.text("Starting")
            case .running: return L10n.text("Running")
            case .stopping: return L10n.text("Turning off")
            case .failed: return L10n.text("Stopped with an error")
            }
        }

        var detail: String? {
            switch self {
            case .starting(let message), .failed(let message): return message
            default: return nil
            }
        }

        var isActive: Bool {
            switch self {
            case .starting, .running, .stopping: return true
            default: return false
            }
        }
    }

    struct Busy: Equatable {
        var message: String
        var progress: Double?
    }

    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var state: State
    @Published private(set) var apps: [AndroidApp]
    @Published private(set) var image: AndroidImage?
    @Published private(set) var androidVersion: String?
    @Published var busy: Busy?
    @Published var notice: Notice?
    /// What the performance mode means right now (Smart changes it as conditions change).
    @Published private(set) var performanceLevel: PerformanceLevel?
    /// The settings Android was started with, for the ones that only apply at start.
    @Published private(set) var launchedWith: LaunchSettings?

    /// Settings that are read only when Android starts.
    struct LaunchSettings: Equatable {
        var memoryMB: Int
        var cpuCount: Int
        var microphone: Bool
        var showAndroidScreen: Bool

        @MainActor init(_ settings: SubsystemSettings) {
            memoryMB = settings.memoryMB
            cpuCount = settings.cpuCount
            microphone = settings.microphone
            showAndroidScreen = settings.showAndroidScreen
        }
    }

    /// Settings changed since Android started that take effect after a restart,
    /// in words ("memory", "processor cores"). Empty when nothing is waiting.
    var changesNeedingRestart: [String] {
        guard let launched = launchedWith else { return [] }
        switch state {
        case .running, .starting: break
        default: return []
        }
        let now = LaunchSettings(settings)
        var changes: [String] = []
        if now.memoryMB != launched.memoryMB { changes.append(L10n.text("memory")) }
        if now.cpuCount != launched.cpuCount { changes.append(L10n.text("processor cores")) }
        if now.microphone != launched.microphone { changes.append(L10n.text("microphone")) }
        if now.showAndroidScreen != launched.showAndroidScreen { changes.append(L10n.text("Android screen window")) }
        return changes
    }

    let settings = SubsystemSettings.shared
    private var vm: VirtualMachine?
    private var adb: ADBConnection?
    private let work = DispatchQueue(label: "msa.subsystem.work", qos: .userInitiated)
    private var syncTimer: Timer?
    private var notificationTimer: Timer?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var stopRequested = false
    private var pendingInstalls: [URL] = []
    private var displayForApproval = false
    private var syncing = false

    private init() {
        let image = AndroidImage.current()
        self.image = image
        state = image == nil ? .notInstalled : .off
        apps = AppStore.load()
        publishStatus()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in Subsystem.shared.checkIdle() }
        }
        PerformanceManager.shared.onChange = { level in
            Subsystem.shared.performanceLevel = level
            Subsystem.shared.publishStatus()
        }
    }

    var adbConnection: ADBConnection? { adb }
    var vmProcessIdentifier: pid_t? { vm?.isRunning == true ? vm?.processIdentifier : nil }

    /// Called when the person picks another mode.
    func performanceModeChanged() {
        PerformanceManager.shared.evaluate(force: true)
        publishStatus()
        applyResourcesPolicy()
    }

    // MARK: Status file

    private func publishStatus() {
        let status: SubsystemStatus.State
        switch state {
        case .notInstalled: status = .notInstalled
        case .off: status = .off
        case .starting: status = .starting
        case .running: status = .running
        case .stopping: status = .stopping
        case .failed: status = .failed
        }
        let running = status == .running
        SubsystemStatus(state: status, message: state.detail, adbPort: AppConfig.adbPort,
                        androidVersion: androidVersion, pid: getpid(), updated: Date(),
                        mode: settings.performanceMode,
                        level: running ? (performanceLevel ?? PerformanceManager.shared.level) : nil).write()
    }

    private func setState(_ newState: State) {
        state = newState
        publishStatus()
    }

    var appWindowsOpen: Bool {
        let prefix = AppConfig.launcherBundlePrefix + "."
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix(prefix) == true }
    }

    // MARK: Start

    func start() {
        switch state {
        case .off, .failed: break
        case .notInstalled:
            notice = Notice(title: L10n.text("Android isn't set up yet"),
                            message: L10n.format("Download Android first in %@ settings.", AppConfig.displayName))
            return
        default: return
        }
        guard let image else { return }
        if StorageJanitor.shared.isCompacting {
            // Android's disks are being compacted; start as soon as that finishes.
            setState(.starting(L10n.text("Finishing a storage clean-up…")))
            StorageJanitor.shared.whenIdle {
                let subsystem = Subsystem.shared
                guard case .starting = subsystem.state, subsystem.vm == nil else { return }
                subsystem.setState(.off)
                subsystem.start()
            }
            return
        }
        stopRequested = false
        lastActivity = Date()
        setState(.starting(L10n.text("Starting Android…")))
        // Before touching the disks: a QEMU left behind still holds them.
        VirtualMachine.killStaleInstance()

        let configuration: VirtualMachine.Configuration
        do {
            configuration = VirtualMachine.Configuration(
                image: image,
                disks: try image.runtimeDisks(),
                efiVariables: try image.runtimeEFIVariables(),
                memoryMB: settings.memoryMB,
                cpuCount: settings.cpuCount,
                adbPort: AppConfig.adbPort,
                showDisplay: settings.showAndroidScreen || displayForApproval,
                microphone: settings.microphone)
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }

        launchedWith = LaunchSettings(settings)
        let vm = VirtualMachine(configuration: configuration)
        vm.onExit = { [weak vm] code in
            Task { @MainActor in
                guard let vm else { return }
                Subsystem.shared.vmExited(vm, code: code)
            }
        }
        do {
            try vm.launch()
        } catch {
            setState(.failed(error.localizedDescription))
            return
        }
        self.vm = vm

        let firstBoot = !UserDefaults.standard.bool(forKey: "firstBootDone")
        let approvalTimeout: TimeInterval = configuration.showDisplay ? 600 : 0
        Task.detached(priority: .userInitiated) {
            do {
                let (connection, version) = try Self.boot(firstBoot: firstBoot, approvalTimeout: approvalTimeout) { message in
                    Task { @MainActor in
                        if case .starting = Subsystem.shared.state { Subsystem.shared.setState(.starting(message)) }
                    }
                }
                await MainActor.run { Subsystem.shared.didBoot(connection, version: version, firstBoot: firstBoot) }
            } catch {
                await MainActor.run { Subsystem.shared.bootFailed(error) }
            }
        }
    }

    /// Connect, wait for Android, and prepare it. Runs off the main thread.
    nonisolated private static func boot(firstBoot: Bool, approvalTimeout: TimeInterval,
                                         progress: @escaping @Sendable (String) -> Void) throws -> (ADBConnection, String?) {
        let key = try ADBKey.shared()
        let deadline = Date().addingTimeInterval(240)
        var connection: ADBConnection?
        var restartedFromTradeInMode = false
        while connection == nil {
            let candidate = ADBConnection(port: AppConfig.adbPort, key: key)
            do {
                try candidate.connect(timeout: 3, authorizationTimeout: approvalTimeout)
                if AndroidSetup.isInTradeInMode(candidate) {
                    // Left over from a boot without ADB turned on in GRUB; Android leaves
                    // trade-in mode during this boot, and adbd follows after a restart.
                    guard !restartedFromTradeInMode else { throw AndroidSetup.Failure.tradeInMode }
                    restartedFromTradeInMode = true
                    progress(L10n.text("Restarting Android…"))
                    AndroidSetup.restartFromTradeInMode(candidate)
                    candidate.close()
                    Thread.sleep(forTimeInterval: 5)
                    continue
                }
                connection = candidate
            } catch ADBError.unauthorized {
                throw ADBError.unauthorized
            } catch AndroidSetup.Failure.tradeInMode {
                candidate.close()
                throw AndroidSetup.Failure.tradeInMode
            } catch {
                candidate.close()
                if Date() > deadline { throw ADBError.timeout(L10n.text("Android didn't start")) }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        guard let adb = connection else { throw ADBError.closed }
        progress(L10n.text("Starting Android…"))
        try AndroidSetup.waitForBoot(adb)
        if firstBoot {
            progress(L10n.text("Setting up Android for the first time…"))
            AndroidSetup.firstBoot(adb)
        }
        AndroidSetup.applyIdentity(adb)
        AndroidSetup.disableLockScreen(adb)
        AndroidSetup.allowInstallingApps(adb)
        progress(L10n.text("Preparing apps…"))
        try AndroidSetup.ensureBridge(adb)
        try AndroidSetup.ensureScrcpyServer(adb)
        return (adb, AndroidSetup.versionDescription(adb))
    }

    private func didBoot(_ connection: ADBConnection, version: String?, firstBoot: Bool) {
        guard !stopRequested, case .starting = state else {
            connection.close()
            return
        }
        if firstBoot { UserDefaults.standard.set(true, forKey: "firstBootDone") }
        adb = connection
        connection.onClose = {
            Task { @MainActor in Subsystem.shared.connectionDropped() }
        }
        androidVersion = version
        displayForApproval = false
        setState(.running)
        lastActivity = Date()
        NotificationRelay.shared.reset()
        PerformanceManager.shared.start()
        performanceLevel = PerformanceManager.shared.level
        publishStatus()

        syncApps()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in Subsystem.shared.syncApps() }
        }
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in Subsystem.shared.pollNotifications() }
        }
        if !pendingInstalls.isEmpty {
            let urls = pendingInstalls
            pendingInstalls = []
            install(urls)
        } else if UserDefaults.standard.bool(forKey: "installFDroidAfterSetup") {
            // Chosen during setup: the open-source app store.
            UserDefaults.standard.set(false, forKey: "installFDroidAfterSetup")
            installFDroid()
        }
    }

    private func bootFailed(_ error: Error) {
        // Ignore a boot attempt that was overtaken (Android was turned off meanwhile).
        guard !stopRequested, case .starting = state else { return }
        if case ADBError.unauthorized = error, !displayForApproval {
            // An image whose ADB needs approval: show Android's screen so the person can allow this Mac.
            displayForApproval = true
            stopRequested = true
            vm?.terminate()
            Task {
                // Wait for this QEMU to exit (it holds the disks and the ADB port).
                for _ in 0..<60 where self.vm != nil { try? await Task.sleep(for: .milliseconds(250)) }
                guard self.vm == nil else { return }
                self.stopRequested = false
                self.setState(.off)
                self.start()
                if case .starting = self.state {
                    self.setState(.starting(L10n.text("In the Android window, tick “Always allow from this computer” and click Allow.")))
                }
            }
            return
        }
        setState(.failed(error.localizedDescription))
        vm?.terminate()
    }

    private func connectionDropped() {
        guard case .running = state, vm?.isRunning == true else { return }
        adb = nil
        Task.detached(priority: .userInitiated) {
            for _ in 0..<10 {
                let connection = ADBConnection(port: AppConfig.adbPort, key: try? ADBKey.shared())
                if (try? connection.connect(timeout: 3)) != nil {
                    await MainActor.run {
                        Subsystem.shared.adb = connection
                        connection.onClose = { Task { @MainActor in Subsystem.shared.connectionDropped() } }
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Stop

    func stop() {
        guard state.isActive, state != .stopping else { return }
        if vm == nil {
            // Nothing running yet (e.g. waiting for a storage clean-up).
            setState(image == nil ? .notInstalled : .off)
            return
        }
        stopRequested = true
        setState(.stopping)
        stopTimers()
        let connection = adb
        adb = nil
        let vm = self.vm
        work.async {
            // A clean Android shutdown; QEMU exits when the VM powers off.
            if let connection { StorageJanitor.trimIfDue(connection) }
            _ = try? connection?.exec("reboot -p", timeout: 3)
            connection?.close()
            let deadline = Date().addingTimeInterval(20)
            while vm?.isRunning == true && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            vm?.terminate()
        }
    }

    func restart() {
        if state.isActive {
            stop()
            Task {
                while self.state.isActive { try? await Task.sleep(for: .milliseconds(300)) }
                self.start()
            }
        } else {
            start()
        }
    }

    private func vmExited(_ exited: VirtualMachine, code: Int32) {
        guard exited === vm else { return }
        vm = nil
        launchedWith = nil
        adb?.close()
        adb = nil
        stopTimers()
        if stopRequested || state == .stopping {
            setState(image == nil ? .notInstalled : .off)
        } else if case .failed = state {
            publishStatus()
        } else {
            let reason = Self.lastQEMUError().map { "\n\($0)" } ?? ""
            setState(.failed(L10n.format("Android stopped unexpectedly (QEMU exit code %@).%@\nThe full log is in Settings › Advanced › Show Log.",
                                         String(code), reason)))
        }
        stopRequested = false
        StorageJanitor.shared.androidStopped()
    }

    private func stopTimers() {
        PerformanceManager.shared.stop()
        performanceLevel = nil
        syncTimer?.invalidate(); syncTimer = nil
        notificationTimer?.invalidate(); notificationTimer = nil
    }

    /// As needed: turn Android off once no Android app window has been open for a while.
    /// How long Android may run with no Android app open before it turns off;
    /// nil keeps it ready in the background.
    ///
    ///   Power Saver            30 s, always (Android never idles in the background)
    ///   As needed              the idle time chosen in Settings
    ///   Continuous, Automatic  keep ready (Smart, Standard and Performance stay ready;
    ///                          Smart drops to the Saver level while idle)
    func idleShutdownDelay() -> TimeInterval? {
        if settings.performanceMode == .powerSaver { return 30 }
        switch settings.resources {
        case .asNeeded: return TimeInterval(settings.idleMinutes * 60)
        case .continuous, .automatic: return nil
        }
    }

    private func checkIdle() {
        guard case .running = state else { return }
        if appWindowsOpen || busy != nil {
            lastActivity = Date()
            return
        }
        guard let delay = idleShutdownDelay() else { return }
        if Date().timeIntervalSince(lastActivity) > delay {
            stop()
        }
    }

    /// Called at launch and when settings change.
    /// Called at launch and when the mode or resources setting changes: start Android
    /// when it should be kept ready, and let the idle check turn it off when it shouldn't.
    func applyResourcesPolicy() {
        if idleShutdownDelay() == nil, state == .off { start() }
        checkIdle()
    }

    // MARK: Apps

    func syncApps() {
        guard let adb, !syncing else { return }
        syncing = true
        work.async {
            let result = Result { try AppCatalog.sync(adb) }
            // A newly installed browser or app store may install apps too.
            if case .success(let catalog) = result,
               catalog.added.contains(where: { AndroidSetup.installerPackages.contains($0.package) }) {
                AndroidSetup.allowInstallingApps(adb)
            }
            Task { @MainActor in
                let subsystem = Subsystem.shared
                subsystem.syncing = false
                if case .success(let catalog) = result {
                    subsystem.apps = catalog.apps
                }
            }
        }
    }

    private func pollNotifications() {
        guard settings.notifications, let adb else { return }
        work.async {
            guard let data = try? AndroidBridge.read("notifications.json", from: adb, timeout: 10),
                  let list = try? JSONDecoder().decode([AndroidNotification].self, from: data) else { return }
            Task { @MainActor in
                NotificationRelay.shared.update(list, apps: Subsystem.shared.apps)
            }
        }
    }

    func open(_ app: AndroidApp) {
        AppCatalog.open(package: app.package)
    }

    /// Install .apk/.apks/.apkm/.xapk files, starting Android first if needed.
    func install(_ urls: [URL]) {
        let packages = urls.filter(PackageInstaller.canInstall)
        guard !packages.isEmpty else {
            notice = Notice(title: L10n.text("Can't install this file"),
                            message: L10n.text("Choose an .apk, .apks, .apkm or .xapk file."))
            return
        }
        guard case .running = state, let adb else {
            pendingInstalls += packages
            let what = packages.count == 1
                ? packages[0].lastPathComponent
                : L10n.format("%@ apps", String(packages.count))
            busy = Busy(message: L10n.format("Starting Android to install %@…", what))
            if state == .notInstalled {
                busy = nil
                pendingInstalls = []
                notice = Notice(title: L10n.text("Android isn't set up yet"),
                                message: L10n.format("Finish setting up %@, then install the app again.", AppConfig.displayName))
            } else {
                start()
            }
            return
        }
        let before = Set(apps.map(\.package))
        busy = Busy(message: L10n.format("Installing %@…", packages[0].lastPathComponent), progress: 0)
        work.async {
            var failures: [String] = []
            for (index, url) in packages.enumerated() {
                Task { @MainActor in
                    Subsystem.shared.busy = Busy(message: L10n.format("Installing %@…", url.lastPathComponent), progress: 0)
                }
                do {
                    try PackageInstaller.install(url, adb: adb) { fraction in
                        Task { @MainActor in
                            Subsystem.shared.busy = Busy(message: L10n.format("Installing %@…", url.lastPathComponent),
                                                         progress: (Double(index) + fraction) / Double(packages.count))
                        }
                    }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let catalog = try? AppCatalog.sync(adb)
            Task { @MainActor in
                let subsystem = Subsystem.shared
                subsystem.busy = nil
                subsystem.lastActivity = Date()
                if let catalog { subsystem.apps = catalog.apps }
                let added = (catalog?.apps ?? []).filter { !before.contains($0.package) }
                if !failures.isEmpty {
                    subsystem.notice = Notice(title: L10n.text("Some apps weren't installed"), message: failures.joined(separator: "\n\n"))
                }
                for app in added { subsystem.announceInstalled(app) }
                // Open the app straight away when exactly one was installed, like double-clicking an installer.
                if added.count == 1, failures.isEmpty { subsystem.open(added[0]) }
            }
        }
    }

    private func announceInstalled(_ app: AndroidApp) {
        let content = UNMutableNotificationContent()
        content.title = L10n.format("%@ installed", app.label)
        content.body = L10n.format("Find it in Launchpad, Spotlight and Applications › %@.", AppConfig.launcherFolderName)
        content.userInfo = ["package": app.package]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "installed-\(app.package)", content: content, trigger: nil))
    }

    func uninstall(_ app: AndroidApp) {
        guard let adb else {
            notice = Notice(title: L10n.text("Android is off"), message: L10n.text("Start Android to uninstall apps."))
            return
        }
        busy = Busy(message: L10n.format("Removing %@…", app.label))
        work.async {
            let result = Result { try PackageInstaller.uninstall(app.package, adb: adb) }
            let catalog = try? AppCatalog.sync(adb)
            Task { @MainActor in
                let subsystem = Subsystem.shared
                subsystem.busy = nil
                if let catalog { subsystem.apps = catalog.apps }
                if case .failure(let error) = result {
                    subsystem.notice = Notice(title: L10n.format("Couldn't remove %@", app.label), message: error.localizedDescription)
                }
            }
        }
    }

    /// The last error QEMU wrote to its log, to show with the failure.
    static func lastQEMUError() -> String? {
        guard let text = try? String(contentsOf: VirtualMachine.logURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last { $0.localizedCaseInsensitiveContains("error") || $0.hasPrefix("qemu") } ?? lines.last
        return line.map { String($0.prefix(300)) }
    }

    /// F-Droid, the open-source app store, offered during setup and in Settings › Apps.
    func installFDroid() {
        busy = Busy(message: L10n.text("Downloading F-Droid…"), progress: 0)
        Task {
            do {
                let target = SubsystemPaths.downloads.appendingPathComponent("F-Droid.apk")
                let file = try await Downloader.download(URL(string: "https://f-droid.org/F-Droid.apk")!, to: target) { fraction, _ in
                    Task { @MainActor in Subsystem.shared.busy = Busy(message: L10n.text("Downloading F-Droid…"), progress: fraction) }
                }
                busy = nil
                install([file])
            } catch {
                busy = nil
                notice = Notice(title: L10n.text("Couldn't download F-Droid"), message: error.localizedDescription)
            }
        }
    }

    /// Copy files into Android's Download folder.
    func sendFiles(_ urls: [URL]) {
        guard let adb else {
            notice = Notice(title: L10n.text("Android is off"), message: L10n.text("Start Android to send files to it."))
            return
        }
        busy = Busy(message: L10n.text("Sending files to Android…"), progress: 0)
        work.async {
            var errors: [String] = []
            for (index, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let remote = "/sdcard/Download/\(url.lastPathComponent)"
                do {
                    try adb.push(url, to: remote) { fraction in
                        Task { @MainActor in
                            Subsystem.shared.busy?.progress = (Double(index) + fraction) / Double(urls.count)
                        }
                    }
                    let quoted = remote.replacingOccurrences(of: "'", with: "'\\''")
                    _ = try? adb.exec("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(quoted)'")
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { @MainActor in
                let subsystem = Subsystem.shared
                subsystem.busy = nil
                subsystem.notice = errors.isEmpty
                    ? Notice(title: L10n.text("Files sent"),
                             message: L10n.text("They're in Android's Download folder (open Files)."))
                    : Notice(title: L10n.text("Some files weren't sent"), message: errors.joined(separator: "\n"))
            }
        }
    }

    // MARK: Android image

    func downloadImage() {
        busy = Busy(message: L10n.text("Finding the latest Android…"))
        Task {
            do {
                let release = try await AndroidImage.latestRelease()
                let target = SubsystemPaths.downloads.appendingPathComponent(release.assetName)
                let total = release.size
                let file = try await Downloader.download(release.url, to: target) { fraction, written in
                    let message = total > 0
                        ? L10n.format("Downloading Android… %@ of %@",
                                      ByteCountFormatter.string(fromByteCount: written, countStyle: .file),
                                      ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                        : L10n.text("Downloading Android…")
                    Task { @MainActor in Subsystem.shared.busy = Busy(message: message, progress: fraction) }
                }
                if let expected = release.sha256 {
                    busy = Busy(message: L10n.text("Checking the download…"))
                    let actual = try await Task.detached { try AndroidImage.sha256(of: file) }.value
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: file)
                        throw AndroidImage.ImageError.checksum
                    }
                }
                installImage(from: file, deleteAfterwards: true)
            } catch {
                busy = nil
                notice = Notice(title: L10n.text("Couldn't download Android"), message: error.localizedDescription)
            }
        }
    }

    /// Install an image the person picked (UTM-VM-lineage zip or .utm folder).
    func installImage(from url: URL, deleteAfterwards: Bool = false) {
        if state.isActive { stop() }
        busy = Busy(message: L10n.text("Unpacking Android…"), progress: 0)
        Task {
            while self.state.isActive { try? await Task.sleep(for: .milliseconds(300)) }
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result {
                    try AndroidImage.install(from: url) { fraction in
                        Task { @MainActor in Subsystem.shared.busy = Busy(message: L10n.text("Unpacking Android…"), progress: fraction) }
                    }
                }
            }.value
            if deleteAfterwards { try? FileManager.default.removeItem(at: url) }
            busy = nil
            switch result {
            case .success(let image):
                self.image = image
                androidVersion = nil
                LauncherGenerator.removeAll()
                AppStore.save([])
                apps = []
                setState(.off)
                start()
            case .failure(let error):
                notice = Notice(title: L10n.text("Couldn't install Android"), message: error.localizedDescription)
            }
        }
    }

    /// Erase all Android apps and data.
    func resetAndroid() {
        let wasActive = state.isActive
        if wasActive { stop() }
        Task {
            while self.state.isActive { try? await Task.sleep(for: .milliseconds(300)) }
            AndroidImage.resetRuntime()
            LauncherGenerator.removeAll()
            AppStore.save([])
            try? FileManager.default.removeItem(at: SubsystemPaths.icons)
            apps = []
            notice = Notice(title: L10n.text("Android was reset"),
                            message: L10n.text("All Android apps and their data were removed."))
            if wasActive || settings.resources == .continuous { start() }
        }
    }

    /// Rebuild every launcher (after changing which apps show, or if some went missing).
    func rebuildLaunchers() {
        LauncherGenerator.removeAll()
        syncApps()
    }
}
