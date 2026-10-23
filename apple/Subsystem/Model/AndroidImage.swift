// Mac Android Subsystem - the Android image (the "ROM").
//
// The image is LineageOS's UTM package for its virtio_arm64only target
// (UTM-VM-lineage-<version>-<date>-<type>-virtio_arm64only.zip, produced by
// `m vm-utm-zip`). It holds LineageOS_on_ARM64.utm/ with config.plist (UTM's VM
// settings: which disks, in what order) and Data/ (qcow2 disks, efi_vars.fd).
//
// The unpacked image is never written to. Android runs on qcow2 overlays in vm/
// that use the image as their backing file, so "Reset" just deletes the overlays,
// and a new image can be installed without re-downloading anything else.
//
// Where images come from: this project's own releases (built by
// .github/workflows/rom.yml), then jqssun/android-lineage-qemu as a fallback, or
// any UTM-VM-lineage zip / .utm folder the person picks.
//
// Licensed under the GNU General Public License v3 or later.

import CryptoKit
import Foundation

struct AndroidImage: Codable, Equatable, Sendable {
    struct Disk: Codable, Equatable, Sendable {
        let name: String
        let readOnly: Bool
    }

    /// Folder name under rom/, e.g. "lineage-24.0-20261015-UNOFFICIAL-virtio_arm64only"
    let name: String
    /// The .utm package inside the folder.
    let packagePath: String
    let disks: [Disk]
    let memoryMB: Int?
    let installed: Date

    var folder: URL { SubsystemPaths.rom.appendingPathComponent(name, isDirectory: true) }
    var package: URL { folder.appendingPathComponent(packagePath, isDirectory: true) }
    var dataFolder: URL { package.appendingPathComponent("Data", isDirectory: true) }

    /// "LineageOS 24.0 (2026-10-15)" from the archive name, when it follows LineageOS's pattern.
    var displayName: String {
        let parts = name.split(separator: "-")
        if parts.count >= 3, parts[0] == "lineage" {
            let date = String(parts[2])
            if date.count == 8 {
                let pretty = "\(date.prefix(4))-\(date.dropFirst(4).prefix(2))-\(date.suffix(2))"
                return "LineageOS \(parts[1]) (\(pretty))"
            }
            return "LineageOS \(parts[1])"
        }
        return name
    }

    // MARK: Installed image

    private static var manifest: URL { SubsystemPaths.rom.appendingPathComponent("current.json") }

    static func current() -> AndroidImage? {
        guard let data = try? Data(contentsOf: manifest),
              let image = try? JSONDecoder().decode(AndroidImage.self, from: data),
              FileManager.default.fileExists(atPath: image.package.path) else { return nil }
        return image
    }

    private func makeCurrent() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.manifest, options: .atomic)
    }

    // MARK: Overlays

    /// The disks Android runs on, created on first use, with ADB turned on and the menu
    /// skipped in GRUB's settings (see GrubEnvironment.swift). Call it only while QEMU
    /// isn't running.
    func runtimeDisks() throws -> [URL] {
        var urls: [URL] = []
        for (index, disk) in disks.enumerated() {
            let base = dataFolder.appendingPathComponent(disk.name)
            let overlay = SubsystemPaths.vm.appendingPathComponent("disk\(index)-\(disk.name)")
            if !FileManager.default.fileExists(atPath: overlay.path) {
                try Self.createOverlay(overlay, backedBy: base)
            } else {
                try Self.repointOverlay(overlay, to: base)
            }
            urls.append(overlay)
        }
        try GrubEnvironment.configure(urls)
        return urls
    }

    func runtimeEFIVariables() throws -> URL {
        let target = SubsystemPaths.vm.appendingPathComponent("efi_vars.fd")
        if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: dataFolder.appendingPathComponent("efi_vars.fd"), to: target)
        }
        try Self.padFlash(target)
        return target
    }

    /// QEMU's virt machine needs both pflash images to be the same size as the
    /// firmware (64 MiB for Homebrew's edk2-aarch64-code.fd). UTM images ship a
    /// small efi_vars.fd that UTM pads itself, so pad it with zeros here.
    static func padFlash(_ url: URL) throws {
        let firmware = Bundle.main.resourceURL?.appendingPathComponent("qemu/edk2-aarch64-code.fd")
        let firmwareSize = (firmware.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? UInt64 }) ?? 0
        let size = firmwareSize > 0 ? firmwareSize : 64 * 1_048_576
        let current = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard current < size else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
    }

    /// Erase everything Android stored (apps, data, settings).
    static func resetRuntime() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: SubsystemPaths.vm, includingPropertiesForKeys: nil)) ?? [] {
            if url.lastPathComponent.hasPrefix("disk") || url.lastPathComponent == "efi_vars.fd" {
                try? fm.removeItem(at: url)
            }
        }
        // The first boot of a fresh image runs the setup steps again.
        UserDefaults.standard.removeObject(forKey: "firstBootDone")
    }

    /// Overlays record their base disk's absolute path. When the support folder
    /// moved (the app was renamed), point them at the base's new location; the
    /// base itself is unchanged, so only the header is rewritten (`rebase -u`).
    private static func repointOverlay(_ overlay: URL, to base: URL) throws {
        guard let qemuImg = VirtualMachine.qemuImg else { throw VirtualMachine.Failure.qemuMissing }
        let info = Process()
        info.executableURL = qemuImg
        info.arguments = ["info", "--output=json", "-U", overlay.path]
        let pipe = Pipe()
        info.standardOutput = pipe
        info.standardError = FileHandle.nullDevice
        try info.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        info.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backing = json["backing-filename"] as? String,
              backing != base.path else { return }
        let rebase = Process()
        rebase.executableURL = qemuImg
        rebase.arguments = ["rebase", "-u", "-F", "qcow2", "-b", base.path, overlay.path]
        let errors = Pipe()
        rebase.standardError = errors
        rebase.standardOutput = errors
        try rebase.run()
        rebase.waitUntilExit()
        guard rebase.terminationStatus == 0 else {
            throw ImageError.overlay(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    private static func createOverlay(_ overlay: URL, backedBy base: URL) throws {
        guard let qemuImg = VirtualMachine.qemuImg else { throw VirtualMachine.Failure.qemuMissing }
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = ["create", "-f", "qcow2", "-F", "qcow2", "-b", base.path, overlay.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ImageError.overlay(output)
        }
    }

    // MARK: Importing

    enum ImageError: LocalizedError {
        case noPackage
        case noDisks
        case overlay(String)
        case noRelease
        case checksum
        case download(String)

        var errorDescription: String? {
            switch self {
            case .noPackage: return L10n.text("This file doesn't contain a LineageOS virtual machine (a .utm folder with config.plist).")
            case .noDisks: return L10n.text("The virtual machine has no disks.")
            case .overlay(let output): return L10n.format("Couldn't prepare Android's disks: %@", output)
            case .noRelease: return L10n.text("No Android image is available to download yet. Pick a UTM-VM-lineage zip instead (see the guide).")
            case .checksum: return L10n.text("The download is damaged (its checksum doesn't match). Try again.")
            case .download(let detail): return L10n.format("The download failed: %@", detail)
            }
        }
    }

    /// Install an image from a UTM-VM-lineage zip or an unpacked .utm folder. Replaces the
    /// current image and erases Android's data (the disks of different images don't mix).
    @discardableResult
    static func install(from source: URL, progress: @escaping (Double) -> Void) throws -> AndroidImage {
        let fm = FileManager.default
        let staging = SubsystemPaths.rom.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
            progress(1)
        } else {
            try ZipExtractor.extract(source, to: staging, progress: progress)
        }

        guard let package = findPackage(in: staging) else { throw ImageError.noPackage }
        let (disks, memory) = try readConfiguration(package)

        var name = source.deletingPathExtension().lastPathComponent
        if name.hasPrefix("UTM-VM-") { name.removeFirst("UTM-VM-".count) }
        let folder = SubsystemPaths.rom.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let packagePath = package.lastPathComponent
        try fm.moveItem(at: package, to: folder.appendingPathComponent(packagePath))

        let image = AndroidImage(name: name, packagePath: packagePath, disks: disks, memoryMB: memory, installed: Date())
        // Remove older images and their overlays.
        for url in (try? fm.contentsOfDirectory(at: SubsystemPaths.rom, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent != name && !url.lastPathComponent.hasPrefix(".") && url.pathExtension != "json" {
            try? fm.removeItem(at: url)
        }
        resetRuntime()
        try image.makeCurrent()
        return image
    }

    private static func findPackage(in folder: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "utm",
               FileManager.default.fileExists(atPath: url.appendingPathComponent("config.plist").path) {
                return url
            }
        }
        return nil
    }

    /// Disks (in boot order) and memory from UTM's config.plist.
    private static func readConfiguration(_ package: URL) throws -> ([Disk], Int?) {
        let data = try Data(contentsOf: package.appendingPathComponent("config.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        var disks: [Disk] = []
        for drive in plist["Drive"] as? [[String: Any]] ?? [] {
            let type = (drive["ImageType"] as? String ?? "Disk").lowercased()
            guard type == "disk", let name = drive["ImageName"] as? String,
                  FileManager.default.fileExists(atPath: package.appendingPathComponent("Data/\(name)").path) else { continue }
            disks.append(Disk(name: name, readOnly: drive["ReadOnly"] as? Bool ?? false))
        }
        if disks.isEmpty {
            // Older packages: every qcow2 in Data, alphabetically (vda, vdb, ...).
            let files = (try? FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Data").path)) ?? []
            disks = files.filter { $0.hasSuffix(".qcow2") }.sorted().map { Disk(name: $0, readOnly: false) }
        }
        guard !disks.isEmpty else { throw ImageError.noDisks }
        let memory = (plist["System"] as? [String: Any])?["MemorySize"] as? Int
        return (disks, memory)
    }

    // MARK: Downloading

    struct Release: Sendable {
        let repository: String
        let tag: String
        let assetName: String
        let url: URL
        let size: Int64
        let sha256: String?
    }

    /// Newest UTM-VM-lineage arm64 image from the configured repositories, in order of preference.
    static func latestRelease() async throws -> Release {
        let repositories = (Bundle.main.object(forInfoDictionaryKey: "MSAImageRepositories") as? String ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pattern = try NSRegularExpression(pattern: #"^UTM-VM-lineage-.*arm64only.*\.zip$"#)
        for repository in repositories.isEmpty ? [AppConfig.repository] : repositories {
            guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for release in releases where (release["draft"] as? Bool) != true {
                for asset in release["assets"] as? [[String: Any]] ?? [] {
                    guard let name = asset["name"] as? String,
                          pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
                          let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
                    let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
                    return Release(repository: repository, tag: release["tag_name"] as? String ?? "",
                                   assetName: name, url: link,
                                   size: (asset["size"] as? NSNumber)?.int64Value ?? 0, sha256: digest)
                }
            }
        }
        throw ImageError.noRelease
    }

    /// SHA-256 of a large file, read in chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
