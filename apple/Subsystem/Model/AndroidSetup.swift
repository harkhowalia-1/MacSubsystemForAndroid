// Mac Android Subsystem - what happens after Android boots.
//
//  1. Wait for sys.boot_completed.
//  2. First boot only: mark the device as set up (no setup wizard on a display
//     nobody sees), keep it awake, use the Mac's time zone.
//  3. Install or update the bridge app (bridge.apk): it reports installed apps
//     with their icons and relays notifications, through a content provider the
//     Mac reads with `content read --uri content://<authority>/...`.
//  4. Push the scrcpy server that app windows use.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum AndroidBridge {
    static var package: String { AppConfig.bridgePackage }
    static var authority: String { package }
    static var notificationListener: String { "\(package)/\(package).NotificationRelayService" }
    static var bundledAPK: URL? { Bundle.main.url(forResource: "bridge", withExtension: "apk") }
    static var bundledVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "MSABridgeVersion") as? String ?? "1"
    }

    /// Read a file the bridge serves, e.g. "apps.json", "icon/org.fdroid.fdroid".
    static func read(_ path: String, from adb: ADBConnection, timeout: TimeInterval = 30) throws -> Data {
        try adb.exec("content read --uri content://\(authority)/\(path)", timeout: timeout)
    }
}

enum AndroidSetup {
    enum Failure: LocalizedError {
        case bootTimeout
        case tradeInMode
        case bridgeMissing
        case bridgeInstall(String)
        var errorDescription: String? {
            switch self {
            case .bootTimeout: return "Android didn't finish starting."
            case .tradeInMode: return "Android's ADB is in trade-in mode, so this Mac can't set it up. Reset Android in Settings and try again."
            case .bridgeMissing: return "bridge.apk is missing from this copy of \(AppConfig.displayName)."
            case .bridgeInstall(let output): return "Couldn't install the bridge app: \(output)"
            }
        }
    }

    static let scrcpyServerPath = "/data/local/tmp/msa-scrcpy-server.jar"

    /// Android 16's trade-in mode: adbd refuses every service but `shell:tradeinmode …`
    /// (see GrubEnvironment.swift).
    static func isInTradeInMode(_ adb: ADBConnection) -> Bool {
        do {
            _ = try adb.exec("true", timeout: 10)
            return false
        } catch ADBError.serviceUnavailable {
            guard let stream = try? adb.openStream("shell:tradeinmode getstatus") else { return false }
            stream.close()
            return true
        } catch {
            return false
        }
    }

    /// Restart Android, one of the few things trade-in mode allows.
    static func restartFromTradeInMode(_ adb: ADBConnection) {
        guard let stream = try? adb.openStream("shell:tradeinmode wait-until-ready reboot") else { return }
        defer { stream.close() }
        _ = try? stream.readToEnd(timeout: 60)
    }

    static func waitForBoot(_ adb: ADBConnection, timeout: TimeInterval = 300) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? adb.execString("getprop sys.boot_completed", timeout: 10)) == "1" { return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw Failure.bootTimeout
    }

    /// No lock screen: nobody sees Android's own display, and a keyguard that is
    /// always up makes some apps treat the device as locked. Applied on every boot.
    static func disableLockScreen(_ adb: ADBConnection) {
        _ = try? adb.exec("locksettings set-disabled true", timeout: 10)
        _ = try? adb.exec("wm dismiss-keyguard", timeout: 10)
    }

    /// Android's device name: Settings › About, Bluetooth and other devices see
    /// "Mac Android Subsystem (MAS)" rather than the virtual machine's model.
    /// Applied on every boot so a rename reaches existing installs too.
    static func applyIdentity(_ adb: ADBConnection) {
        let name = shellQuoted(AppConfig.deviceName)
        for command in [
            "settings put global device_name \(name)",
            "settings put secure bluetooth_name \(name)",
            "cmd bluetooth_manager set-name \(name) >/dev/null 2>&1 || true",
        ] {
            _ = try? adb.exec(command, timeout: 10)
        }
    }

    /// Apps that download or ship app packages: they may install apps without the
    /// person first finding Android's "Install unknown apps" setting.
    static let installerPackages = [
        "org.lineageos.jelly",          // Browser
        "com.android.documentsui",      // Files
        "org.fdroid.fdroid", "org.fdroid.basic", "com.aurora.store", "com.machiav3lli.fdroid",
        "dev.imranr.obtainium", "com.looker.droidify",
        "org.mozilla.fennec_fdroid", "org.mozilla.firefox", "com.android.chrome",
        "com.brave.browser", "app.vanadium.browser", "org.chromium.chrome",
    ]

    /// Allow the browser, Files and app stores (and whichever browser is the
    /// default) to install the packages they download. Installing still shows
    /// Android's own "Do you want to install this app?" confirmation.
    static func allowInstallingApps(_ adb: ADBConnection) {
        let browsers = ((try? adb.execString("cmd role get-role-holders android.app.role.BROWSER", timeout: 10)) ?? "")
            .split(whereSeparator: { $0 == ";" || $0 == "," || $0.isWhitespace })
            .map(String.init)
        let valid = (installerPackages + browsers).filter { name in
            !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        }
        let script = Array(Set(valid)).sorted()
            .map { "appops set --user 0 \($0) REQUEST_INSTALL_PACKAGES allow 2>/dev/null" }
            .joined(separator: "; ")
        _ = try? adb.exec(script + "; true", timeout: 30)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func firstBoot(_ adb: ADBConnection) {
        let commands = [
            "settings put global device_provisioned 1",
            "settings put secure user_setup_complete 1",
            "pm disable-user --user 0 org.lineageos.setupwizard",
            "svc power stayon true",
            "settings put system screen_off_timeout 2147483647",
            "settings put global stay_on_while_plugged_in 7",
            "cmd time_zone_detector suggest_manual_time_zone --zone_id \(TimeZone.current.identifier)",
            "settings put system time_12_24 \(Self.uses24HourClock ? 24 : 12)",
        ]
        for command in commands {
            _ = try? adb.exec(command, timeout: 15)
        }
    }

    /// Install the bridge when it is missing or older than the one bundled here.
    static func ensureBridge(_ adb: ADBConnection) throws {
        let installed = (try? AndroidBridge.read("version", from: adb, timeout: 10))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard installed != AndroidBridge.bundledVersion else { return }
        guard let apk = AndroidBridge.bundledAPK else { throw Failure.bridgeMissing }
        let size = (try FileManager.default.attributesOfItem(atPath: apk.path)[.size] as? NSNumber)?.int64Value ?? 0
        var output = try adb.exec("cmd package install -r -S \(size)", inputFile: apk)
        // Right after a first boot Android may still be installing it (issue #5).
        for _ in 0..<5 where output.contains("INSTALL_FAILED_DUPLICATE_PACKAGE") {
            Thread.sleep(forTimeInterval: 3)
            output = try adb.exec("cmd package install -r -S \(size)", inputFile: apk)
        }
        if output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            // A bridge signed with another key (e.g. a different build): replace it.
            _ = try? adb.exec("pm uninstall \(AndroidBridge.package)")
            output = try adb.exec("cmd package install -S \(size)", inputFile: apk)
        }
        guard output.contains("Success") else { throw Failure.bridgeInstall(output) }
        _ = try? adb.exec("cmd notification allow_listener \(AndroidBridge.notificationListener)")
    }

    static func ensureScrcpyServer(_ adb: ADBConnection) throws {
        guard let local = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar"),
              let size = (try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint32Value
        else { return }
        if (try? adb.stat(scrcpyServerPath))?.size != size {
            try adb.push(local, to: scrcpyServerPath)
        }
    }

    /// "Android 17 · LineageOS 24.0-20261015-UNOFFICIAL-virtio_arm64only"
    static func versionDescription(_ adb: ADBConnection) -> String? {
        guard let release = try? adb.execString("getprop ro.build.version.release", timeout: 10), !release.isEmpty else { return nil }
        let lineage = (try? adb.execString("getprop ro.lineage.display.version", timeout: 10)) ?? ""
        return lineage.isEmpty ? "Android \(release)" : "Android \(release) · LineageOS \(lineage)"
    }

    private static var uses24HourClock: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }
}
