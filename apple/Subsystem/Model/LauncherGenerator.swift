// Mac Android Subsystem - a real Mac app for every Android app.
//
// Each Android app becomes ~/Applications/Android Apps/<App>.app, which Launchpad, Spotlight
// and the Dock treat like any other app:
//
//   <App>.app/Contents/Info.plist        names the Android package (MSAPackageName)
//   <App>.app/Contents/MacOS/AndroidApp  a copy of the window host (AndroidAppHost)
//   <App>.app/Contents/Resources/AppIcon.icns
//
// Because each launcher is its own process, each Android app gets its own Dock
// icon, ⌘-Tab entry and menu bar. Bundles are signed ad hoc on this Mac; files we
// write aren't quarantined, so Gatekeeper lets them run.
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import CoreServices
import ImageIO
import UniformTypeIdentifiers

enum LauncherGenerator {
    enum Failure: LocalizedError {
        case hostMissing
        case signing(String)
        var errorDescription: String? {
            switch self {
            case .hostMissing: return "The app window host is missing from \(AppConfig.displayName). Reinstall it."
            case .signing(let output): return "Signing the launcher failed: \(output)"
            }
        }
    }

    static var hostExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/AndroidAppHost")
    }

    /// Changes whenever the Subsystem (and so the window host) is updated, so launchers are rebuilt.
    static var generation: String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: hostExecutable.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "\(AppConfig.version)-\(size)-\(modified)"
    }

    /// Existing launchers, keyed by Android package.
    static func existing() -> [String: URL] {
        var result: [String: URL] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(at: SubsystemPaths.launchers, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "app" {
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               let package = info["MSAPackageName"] as? String {
                result[package] = url
            }
        }
        return result
    }

    static func needsUpdate(_ bundle: URL, for app: AndroidApp) -> Bool {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return true }
        return info["MSALauncherGeneration"] as? String != generation
            || info["CFBundleDisplayName"] as? String != app.label
            || (info["MSAAppUpdated"] as? NSNumber)?.int64Value != app.updated
            || bundle.deletingPathExtension().lastPathComponent != app.launcherFileName
    }

    @discardableResult
    static func create(for app: AndroidApp, iconPNG: URL?) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: hostExecutable.path) else { throw Failure.hostMissing }

        if let old = existing()[app.package] { try? fm.removeItem(at: old) }
        let bundle = uniqueBundleURL(for: app)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "AndroidApp",
            "CFBundleIdentifier": app.launcherBundleID,
            "CFBundleName": app.label,
            "CFBundleDisplayName": app.label,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": app.versionName.isEmpty ? "1.0" : app.versionName,
            "CFBundleVersion": "\(max(app.updated / 1000, 1))",
            "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "NSSupportsAutomaticGraphicsSwitching": true,
            "NSHumanReadableCopyright": "Android app \(app.package), running in \(AppConfig.displayName).",
            "MSAPackageName": app.package,
            "MSAActivity": app.activity,
            "MSAAppUpdated": NSNumber(value: app.updated),
            "MSALauncherGeneration": generation,
        ]
        // The window host reads the Subsystem's settings from its own Info.plist.
        for key in ["MSADisplayName", "MSAShortName", "MSALegacySupportFolders", "MSASubsystemBundleID", "MSAURLScheme", "MSASupportFolder",
                    "MSALauncherFolder", "MSAScrcpyVersion", "MSAADBPort", "MSARepository", "MSAWebsiteURL", "MSABridgePackage"] {
            if let value = Bundle.main.object(forInfoDictionaryKey: key) { info[key] = value }
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        try fm.copyItem(at: hostExecutable, to: macOS.appendingPathComponent("AndroidApp"))

        if let iconPNG, let source = CGImageSourceCreateWithURL(iconPNG as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            writeICNS(image, adaptive: app.adaptiveIcon, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        try sign(bundle)
        LSRegisterURL(bundle as CFURL, true)
        return bundle
    }

    static func remove(package: String) {
        guard let url = existing()[package] else { return }
        LSRegisterURL(url as CFURL, false)
        try? FileManager.default.removeItem(at: url)
    }

    static func removeAll() {
        for url in existing().values { try? FileManager.default.removeItem(at: url) }
    }

    private static func uniqueBundleURL(for app: AndroidApp) -> URL {
        var url = SubsystemPaths.launchers.appendingPathComponent("\(app.launcherFileName).app", isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = SubsystemPaths.launchers.appendingPathComponent("\(app.launcherFileName) \(counter).app", isDirectory: true)
            counter += 1
        }
        return url
    }

    // MARK: Icons

    /// Adaptive icons arrive as full-bleed layers: crop to the visible area and use
    /// the Mac's rounded-square grid. Legacy icons sit on a light tile.
    static func writeICNS(_ icon: CGImage, adaptive: Bool, to url: URL) {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString,
                                                                sizes.count, nil) else { return }
        for size in sizes {
            if let tile = macIcon(icon, adaptive: adaptive, size: size) {
                CGImageDestinationAddImage(destination, tile, nil)
            }
        }
        CGImageDestinationFinalize(destination)
    }

    static func macIcon(_ icon: CGImage, adaptive: Bool, size: Int) -> CGImage? {
        let s = CGFloat(size)
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // macOS icon grid: an 824/1024 rounded square, corner radius about 185/1024.
        let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        let path = CGPath(roundedRect: tile, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

        // Soft shadow like the system's icons.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025,
                          color: CGColor(gray: 0, alpha: 0.3))
        context.addPath(path)
        context.setFillColor(CGColor(gray: 0.98, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        if adaptive {
            // 108dp layers, of which the inner ~88dp are meant to be seen.
            let visible: CGFloat = 0.815
            let width = CGFloat(icon.width), height = CGFloat(icon.height)
            let crop = CGRect(x: width * (1 - visible) / 2, y: height * (1 - visible) / 2,
                              width: width * visible, height: height * visible)
            if let cropped = icon.cropping(to: crop.integral) {
                context.draw(cropped, in: tile)
            }
        } else {
            context.draw(icon, in: tile.insetBy(dx: tile.width * 0.12, dy: tile.height * 0.12))
        }
        context.restoreGState()
        return context.makeImage()
    }

    // MARK: Signing

    private static func sign(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw Failure.signing(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}
