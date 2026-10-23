// Mac Android Subsystem - keeps the Subsystem's disk use down by itself.
//
// Light clean-up (on launch, every 6 hours, after Android turns off):
//   * finished or abandoned downloads (Android images, F-Droid), unpacking leftovers,
//     temporary install folders and notification icon copies
//   * icons of apps that are gone, old Android images and their disks
//   * logs over 2 MB, cut down to their last 256 KB (while Android is off)
//   * inside Android, once a day: `sm fstrim`, so space Android frees is released
//     from its disk image (the disks use discard=unmap)
// Deep clean-up (when the Mac is low on space, or "Clean Up Now"):
//   * also clears Android apps' caches (`pm trim-caches`)
//   * and, while Android is off, compacts Android's disks with `qemu-img convert`
//     (rewrites each copy-on-write overlay without its unused clusters). Compaction
//     also runs weekly on power. Starting Android waits for it.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

@MainActor
final class StorageJanitor: ObservableObject {
    static let shared = StorageJanitor()

    struct Usage: Equatable {
        var image: Int64 = 0
        var androidData: Int64 = 0
        var other: Int64 = 0
        var launchers: Int64 = 0
        var total: Int64 { image + androidData + other + launchers }
    }

    @Published private(set) var usage = Usage()
    @Published private(set) var isWorking = false
    @Published private(set) var lastReport: String?
    private(set) var isCompacting = false
    private var waiters: [() -> Void] = []
    private var timer: Timer?
    private let work = DispatchQueue(label: "msa.janitor", qos: .utility)

    private static let lowSpaceThreshold: Int64 = 15 * 1_000_000_000

    private init() {
        lastReport = UserDefaults.standard.string(forKey: "lastCleanupReport")
    }

    // MARK: Scheduling

    func startSchedule() {
        refreshUsage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { StorageJanitor.shared.runAutomatic() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in StorageJanitor.shared.runAutomatic() }
        }
    }

    /// Android just turned off: a good moment to tidy (and maybe compact).
    func androidStopped() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { StorageJanitor.shared.runAutomatic() }
    }

    func runAutomatic() {
        guard SubsystemSettings.shared.autoCleanup else { return }
        let lowOnSpace = (Self.freeSpace() ?? .max) < Self.lowSpaceThreshold
        clean(deep: lowOnSpace, manual: false)
    }

    /// "Clean Up Now" in Settings.
    func cleanNow() {
        clean(deep: true, manual: true)
    }

    /// Run `block` once no compaction is in progress.
    func whenIdle(_ block: @escaping () -> Void) {
        if isCompacting { waiters.append(block) } else { block() }
    }

    // MARK: Cleaning

    private func clean(deep: Bool, manual: Bool) {
        guard !isWorking else { return }
        let subsystem = Subsystem.shared
        // Don't pull files from under an install or a download.
        guard subsystem.busy == nil else { return }
        isWorking = true

        let adb = subsystem.adbConnection
        let androidOff: Bool
        switch subsystem.state {
        case .off, .failed, .notInstalled: androidOff = true
        default: androidOff = false
        }
        let image = subsystem.image
        let installed = Set(subsystem.apps.map(\.package))
        let onBattery = PerformanceManager.shared.currentConditions().onBattery
        let lastCompaction = UserDefaults.standard.object(forKey: "lastCompaction") as? Date ?? .distantPast
        let compactionDue = Date().timeIntervalSince(lastCompaction) > 7 * 86_400
        let shouldCompact = androidOff && image != nil && (manual || ((deep || compactionDue) && !onBattery))
        if shouldCompact { isCompacting = true }

        work.async {
            var freed: Int64 = 0
            freed += Self.removeLeftovers(image: image, installedApps: installed, androidOff: androidOff)
            if androidOff { freed += Self.trimLogs() }
            if let adb {
                if deep { _ = try? adb.exec("pm trim-caches 1000G", timeout: 120) }
                Self.trimIfDue(adb, force: deep)
            }
            if shouldCompact, let image {
                freed += Self.compactDisks(image)
                UserDefaults.standard.set(Date(), forKey: "lastCompaction")
            }
            let total = freed
            Task { @MainActor in
                let janitor = StorageJanitor.shared
                janitor.isWorking = false
                if shouldCompact {
                    janitor.isCompacting = false
                    let waiting = janitor.waiters
                    janitor.waiters = []
                    waiting.forEach { $0() }
                }
                if total > 0 || manual {
                    let amount = ByteCountFormatter.string(fromByteCount: max(total, 0), countStyle: .file)
                    let date = Date().formatted(date: .abbreviated, time: .shortened)
                    janitor.lastReport = total > 0
                        ? L10n.format("Freed %@ on %@.", amount, date)
                        : L10n.format("Nothing to clean up on %@.", date)
                    UserDefaults.standard.set(janitor.lastReport, forKey: "lastCleanupReport")
                }
                janitor.refreshUsage()
            }
        }
    }

    /// Android's own TRIM, at most once a day unless forced. Space Android frees is
    /// then released from its disk image.
    nonisolated static func trimIfDue(_ adb: ADBConnection, force: Bool = false) {
        let last = UserDefaults.standard.object(forKey: "lastAndroidTrim") as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 86_400 else { return }
        if (try? adb.exec("sm fstrim", timeout: 30)) != nil {
            UserDefaults.standard.set(Date(), forKey: "lastAndroidTrim")
        }
    }

    nonisolated private static func removeLeftovers(image: AndroidImage?, installedApps: Set<String>, androidOff: Bool) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        let tenMinutesAgo = Date().addingTimeInterval(-600)
        let dayAgo = Date().addingTimeInterval(-86_400)

        func remove(_ url: URL) {
            let size = allocatedSize(url)
            if (try? fm.removeItem(at: url)) != nil { freed += size }
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        func contents(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }

        // Downloads that were installed (or abandoned).
        for url in contents(SubsystemPaths.downloads) where modified(url) < tenMinutesAgo { remove(url) }

        // Unpacking leftovers and images that are no longer current.
        for url in contents(SubsystemPaths.rom) {
            let name = url.lastPathComponent
            if name == "current.json" { continue }
            if name.hasPrefix(".staging-") {
                if modified(url) < tenMinutesAgo { remove(url) }
            } else if let image, name != image.name {
                remove(url)
            }
        }

        // Disks of an image that was replaced (only while Android is off).
        if androidOff, let image {
            let wanted = Set(image.disks.enumerated().map { "disk\($0.offset)-\($0.element.name)" })
            for url in contents(SubsystemPaths.vm)
                where url.lastPathComponent.hasPrefix("disk") && !wanted.contains(url.lastPathComponent) {
                remove(url)
            }
        }

        // Temporary install folders and notification icon copies.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        for url in contents(tmp) where url.lastPathComponent.hasPrefix("msa-install-") && modified(url) < tenMinutesAgo {
            remove(url)
        }
        for url in contents(SubsystemPaths.notificationAttachments) where modified(url) < dayAgo { remove(url) }

        // Icons of apps that are gone.
        if !installedApps.isEmpty {
            for url in contents(SubsystemPaths.icons)
                where !installedApps.contains(url.deletingPathExtension().lastPathComponent) {
                remove(url)
            }
        }
        return freed
    }

    /// Keep the last 256 KB of logs over 2 MB (QEMU holds them open while running).
    nonisolated private static func trimLogs() -> Int64 {
        var freed: Int64 = 0
        for url in [VirtualMachine.logURL, VirtualMachine.consoleURL] {
            let size = allocatedSize(url)
            guard size > 2 << 20, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let length = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
            let tail = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            if (try? tail.write(to: url, options: .atomic)) != nil { freed += size - Int64(tail.count) }
        }
        return freed
    }

    /// Rewrite each overlay without unused clusters. Android must be off.
    nonisolated private static func compactDisks(_ image: AndroidImage) -> Int64 {
        guard let qemuImg = VirtualMachine.qemuImg else { return 0 }
        let fm = FileManager.default
        var freed: Int64 = 0
        for (index, disk) in image.disks.enumerated() {
            let overlay = SubsystemPaths.vm.appendingPathComponent("disk\(index)-\(disk.name)")
            let before = allocatedSize(overlay)
            guard before > 256 << 20 else { continue }
            let base = image.dataFolder.appendingPathComponent(disk.name)
            let compacted = overlay.appendingPathExtension("compact")
            try? fm.removeItem(at: compacted)
            let process = Process()
            process.executableURL = qemuImg
            process.arguments = ["convert", "-O", "qcow2", "-B", base.path, "-F", "qcow2", overlay.path, compacted.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            let after = allocatedSize(compacted)
            if process.terminationStatus == 0, after > 0, after < before,
               (try? fm.replaceItemAt(overlay, withItemAt: compacted)) != nil {
                freed += before - after
            } else {
                try? fm.removeItem(at: compacted)
            }
        }
        return freed
    }

    // MARK: Measuring

    func refreshUsage() {
        work.async {
            var usage = Usage()
            usage.image = Self.allocatedSize(SubsystemPaths.rom)
            usage.androidData = Self.allocatedSize(SubsystemPaths.vm)
            usage.launchers = Self.allocatedSize(SubsystemPaths.launchers)
            let support = Self.allocatedSize(SubsystemPaths.support)
            usage.other = max(0, support - usage.image - usage.androidData)
            Task { @MainActor in StorageJanitor.shared.usage = usage }
        }
    }

    /// Bytes actually used on disk (sparse disk images count only what they hold).
    nonisolated static func allocatedSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            if let size = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    nonisolated static func freeSpace() -> Int64? {
        try? SubsystemPaths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
