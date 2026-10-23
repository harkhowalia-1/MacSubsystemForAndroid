// Mac Android Subsystem - installs Android apps from the Mac.
//
//   .apk            streamed into `cmd package install -S <size>` (no copy on the device)
//   .apks / .apkm   zip of split APKs (bundletool, APKMirror): one install session
//   .xapk           zip of split APKs plus optional OBB data (manifest.json)
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum PackageInstaller {
    enum Failure: LocalizedError {
        case unsupported(String)
        case noAPKs
        case android(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let ext):
                let name = ext.isEmpty ? L10n.text("This file") : L10n.format(".%@ files", ext)
                return L10n.format("%@ can't be installed. Use .apk, .apks, .apkm or .xapk.", name)
            case .noAPKs: return L10n.text("There are no APK files in this archive.")
            case .android(let output): return Self.explain(output)
            }
        }

        private static func explain(_ output: String) -> String {
            if output.contains("INSTALL_FAILED_NO_MATCHING_ABIS") {
                return L10n.text("This app is built only for Intel/x86 Android devices and can't run on an Apple silicon Mac.")
            }
            if output.contains("INSTALL_FAILED_OLDER_SDK") {
                return L10n.text("This app needs a newer version of Android.")
            }
            if output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                return L10n.text("A different build of this app is already installed. Uninstall it first.")
            }
            if output.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                return L10n.text("Android is out of storage space.")
            }
            return L10n.format("Android couldn't install the app:\n%@", output)
        }
    }

    static let fileExtensions = ["apk", "apks", "apkm", "xapk"]

    static func canInstall(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func install(_ url: URL, adb: ADBConnection, progress: @escaping (Double) -> Void) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "apk":
            let output = try adb.exec("cmd package install -r -S \(size(of: url))", inputFile: url, progress: progress)
            guard output.contains("Success") else { throw Failure.android(output) }
        case "apks", "apkm", "xapk":
            try installBundle(url, adb: adb, progress: progress)
        default:
            throw Failure.unsupported(url.pathExtension)
        }
    }

    private static func installBundle(_ url: URL, adb: ADBConnection, progress: @escaping (Double) -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("msa-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ZipExtractor.extract(url, to: folder) { progress($0 * 0.3) }

        let apks = files.filter { $0.pathExtension.lowercased() == "apk" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !apks.isEmpty else { throw Failure.noAPKs }
        let total = apks.reduce(Int64(0)) { $0 + size(of: $1) }

        let created = try adb.execString("cmd package install-create -r -S \(total)")
        guard let open = created.firstIndex(of: "["), let close = created.firstIndex(of: "]"),
              let session = Int(created[created.index(after: open)..<close]) else {
            throw Failure.android(created)
        }
        var written: Int64 = 0
        for (index, apk) in apks.enumerated() {
            let apkSize = size(of: apk)
            let name = "\(index)_\(apk.deletingPathExtension().lastPathComponent).apk"
                .replacingOccurrences(of: " ", with: "_")
            let output = try adb.exec("cmd package install-write -S \(apkSize) \(session) \(name) -", inputFile: apk) { part in
                progress(0.3 + 0.65 * (Double(written) + part * Double(apkSize)) / Double(max(total, 1)))
            }
            written += apkSize
            guard output.contains("Success") else {
                _ = try? adb.exec("cmd package install-abandon \(session)")
                throw Failure.android(output)
            }
        }
        let committed = try adb.execString("cmd package install-commit \(session)", timeout: 300)
        guard committed.contains("Success") else { throw Failure.android(committed) }

        // XAPK expansion files (OBB) go to /sdcard/Android/obb/<package>/.
        if let manifestURL = files.first(where: { $0.lastPathComponent == "manifest.json" }),
           let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expansions = manifest["expansions"] as? [[String: Any]] {
            for expansion in expansions {
                guard let file = expansion["file"] as? String, let target = expansion["install_path"] as? String else { continue }
                let local = folder.appendingPathComponent(file)
                let remote = target.hasPrefix("/") ? target : "/sdcard/\(target)"
                _ = try? adb.exec("mkdir -p '\((remote as NSString).deletingLastPathComponent)'")
                try adb.push(local, to: remote)
            }
        }
        progress(1)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Remove an app from Android.
    static func uninstall(_ package: String, adb: ADBConnection) throws {
        let output = try adb.execString("pm uninstall \(package)")
        guard output.contains("Success") else { throw Failure.android(output) }
    }
}
