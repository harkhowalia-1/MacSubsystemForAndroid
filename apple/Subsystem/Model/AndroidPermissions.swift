// Mac Android Subsystem - which Android apps may use the camera, microphone,
// location and other private data, like Privacy & Security on the Mac.
//
// Android's runtime permissions are grouped the way Android's own settings group
// them (Camera, Microphone, Location, ...). Each app's state comes from the
// "runtime permissions:" block of `dumpsys package <package>`:
//
//     android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|...]
//
// and is changed with `pm grant` / `pm revoke`, which the shell user may run for
// runtime permissions. Ones Android marks SYSTEM_FIXED or POLICY_FIXED can't be
// changed and are shown locked.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum PrivacyCategory: String, CaseIterable, Identifiable, Hashable {
    case camera, microphone, location, contacts, calendars, photos, music, files
    case notifications, phone, callLogs, messages, nearby, bodySensors, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: return L10n.text("Camera")
        case .microphone: return L10n.text("Microphone")
        case .location: return L10n.text("Location")
        case .contacts: return L10n.text("Contacts")
        case .calendars: return L10n.text("Calendars")
        case .photos: return L10n.text("Photos & Videos")
        case .music: return L10n.text("Music & Audio")
        case .files: return L10n.text("Files")
        case .notifications: return L10n.text("Notifications")
        case .phone: return L10n.text("Phone")
        case .callLogs: return L10n.text("Call Logs")
        case .messages: return L10n.text("Messages")
        case .nearby: return L10n.text("Nearby Devices")
        case .bodySensors: return L10n.text("Body Sensors")
        case .activity: return L10n.text("Physical Activity")
        }
    }

    var symbol: String {
        switch self {
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .location: return "location.fill"
        case .contacts: return "person.crop.circle.fill"
        case .calendars: return "calendar"
        case .photos: return "photo.fill"
        case .music: return "music.note"
        case .files: return "folder.fill"
        case .notifications: return "bell.badge.fill"
        case .phone: return "phone.fill"
        case .callLogs: return "list.bullet.rectangle.fill"
        case .messages: return "message.fill"
        case .nearby: return "dot.radiowaves.left.and.right"
        case .bodySensors: return "heart.fill"
        case .activity: return "figure.walk"
        }
    }

    /// The app wants to …
    var detail: String {
        switch self {
        case .camera: return L10n.text("take photos and record video")
        case .microphone: return L10n.text("record audio")
        case .location: return L10n.text("know where you are")
        case .contacts: return L10n.text("read and change your contacts")
        case .calendars: return L10n.text("read and change your calendars")
        case .photos: return L10n.text("see photos and videos")
        case .music: return L10n.text("see music and other audio")
        case .files: return L10n.text("read and change shared files")
        case .notifications: return L10n.text("send notifications")
        case .phone: return L10n.text("make and manage calls")
        case .callLogs: return L10n.text("read and change the call history")
        case .messages: return L10n.text("send and read text messages")
        case .nearby: return L10n.text("find and connect to nearby devices")
        case .bodySensors: return L10n.text("read heart rate and other body sensors")
        case .activity: return L10n.text("know when you walk, run or cycle")
        }
    }

    var permissions: [String] {
        let names: [String]
        switch self {
        case .camera: names = ["CAMERA"]
        case .microphone: names = ["RECORD_AUDIO"]
        case .location: names = ["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION"]
        case .contacts: names = ["READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS"]
        case .calendars: names = ["READ_CALENDAR", "WRITE_CALENDAR"]
        case .photos: names = ["READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_VISUAL_USER_SELECTED"]
        case .music: names = ["READ_MEDIA_AUDIO"]
        case .files: names = ["READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE"]
        case .notifications: names = ["POST_NOTIFICATIONS"]
        case .phone: names = ["READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE", "ANSWER_PHONE_CALLS",
                              "ADD_VOICEMAIL", "USE_SIP", "ACCEPT_HANDOVER"]
        case .callLogs: names = ["READ_CALL_LOG", "WRITE_CALL_LOG", "PROCESS_OUTGOING_CALLS"]
        case .messages: names = ["SEND_SMS", "RECEIVE_SMS", "READ_SMS", "RECEIVE_WAP_PUSH", "RECEIVE_MMS"]
        case .nearby: names = ["BLUETOOTH_SCAN", "BLUETOOTH_CONNECT", "BLUETOOTH_ADVERTISE",
                               "NEARBY_WIFI_DEVICES", "UWB_RANGING"]
        case .bodySensors: names = ["BODY_SENSORS", "BODY_SENSORS_BACKGROUND"]
        case .activity: names = ["ACTIVITY_RECOGNITION"]
        }
        return names.map { "android.permission.\($0)" }
    }

    /// Permissions that only widen access already given (location all the time, sensors
    /// in the background): turning access on leaves them alone, turning it off removes them.
    static let extensions: Set<String> = [
        "android.permission.ACCESS_BACKGROUND_LOCATION", "android.permission.BODY_SENSORS_BACKGROUND",
    ]
}

/// One runtime permission of one app.
struct AppPermission: Hashable, Sendable {
    let name: String
    var granted: Bool
    /// Android doesn't let anyone change it (SYSTEM_FIXED or POLICY_FIXED).
    var fixed: Bool
}

/// An app's access in one category.
struct PrivacyAccess: Equatable {
    var allowed: Bool
    var locked: Bool
}

@MainActor
final class PrivacyCenter: ObservableObject {
    static let shared = PrivacyCenter()

    /// Runtime permissions by package, then by permission name.
    @Published private(set) var permissions: [String: [String: AppPermission]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var changing: Set<String> = []
    @Published var failure: String?

    private let work = DispatchQueue(label: "\(AppConfig.subsystemBundleID).privacy", qos: .userInitiated)

    func access(of app: AndroidApp, in category: PrivacyCategory) -> PrivacyAccess? {
        guard let state = permissions[app.package] else { return nil }
        let requested = category.permissions.compactMap { state[$0] }
        guard !requested.isEmpty else { return nil }
        let main = requested.filter { !PrivacyCategory.extensions.contains($0.name) }
        let allowed = (main.isEmpty ? requested : main).contains { $0.granted }
        return PrivacyAccess(allowed: allowed, locked: requested.allSatisfy(\.fixed))
    }

    func apps(in category: PrivacyCategory, from apps: [AndroidApp]) -> [AndroidApp] {
        apps.filter { access(of: $0, in: category) != nil }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    func categories(for app: AndroidApp) -> [PrivacyCategory] {
        PrivacyCategory.allCases.filter { access(of: app, in: $0) != nil }
    }

    func isChanging(_ app: AndroidApp, _ category: PrivacyCategory) -> Bool {
        changing.contains("\(app.package)|\(category.rawValue)")
    }

    /// Read every app's runtime permissions in one round trip.
    func refresh(_ apps: [AndroidApp]) {
        guard let adb = Subsystem.shared.adbConnection else {
            permissions = [:]
            return
        }
        let packages = apps.map(\.package).filter(Self.isSafePackage)
        guard !packages.isEmpty, !loading else { return }
        loading = true
        work.async {
            let script = packages.map {
                "echo '@@@ \($0)'; dumpsys package \($0) | sed -n '/runtime permissions:/,/^ *$/p'"
            }.joined(separator: "; ")
            let result = Result { try adb.execString(script, timeout: 60) }
            Task { @MainActor in
                let center = PrivacyCenter.shared
                center.loading = false
                switch result {
                case .success(let text): center.permissions = Self.parse(text)
                case .failure(let error): center.failure = error.localizedDescription
                }
            }
        }
    }

    /// Allow or deny everything the app asked for in a category.
    func set(_ allowed: Bool, for app: AndroidApp, in category: PrivacyCategory) {
        guard let adb = Subsystem.shared.adbConnection, Self.isSafePackage(app.package),
              let state = permissions[app.package] else { return }
        let names = category.permissions.filter { name in
            guard let permission = state[name], !permission.fixed else { return false }
            return allowed ? !PrivacyCategory.extensions.contains(name) : permission.granted
        }
        guard !names.isEmpty else { return }
        let key = "\(app.package)|\(category.rawValue)"
        changing.insert(key)
        work.async {
            var problem: String?
            for name in names {
                let output = (try? adb.execString("pm \(allowed ? "grant" : "revoke") \(app.package) \(name)", timeout: 20)) ?? "no answer"
                if output.contains("Exception") || output == "no answer" {
                    problem = output.split(separator: "\n").first.map(String.init) ?? output
                }
            }
            let text = try? adb.execString("dumpsys package \(app.package) | sed -n '/runtime permissions:/,/^ *$/p'", timeout: 20)
            Task { @MainActor in
                let center = PrivacyCenter.shared
                center.changing.remove(key)
                if let text { center.permissions[app.package] = Self.parsePermissions(text) }
                if let problem {
                    let detail = problem == "no answer" ? L10n.text("no answer") : problem
                    center.failure = L10n.format("Android didn't change %1$@ for %2$@: %3$@",
                                                 category.title, app.label, detail)
                }
            }
        }
    }

    // MARK: Parsing

    /// Output of the refresh script: "@@@ <package>" followed by its runtime permissions.
    nonisolated static func parse(_ text: String) -> [String: [String: AppPermission]] {
        var result: [String: [String: AppPermission]] = [:]
        for block in text.components(separatedBy: "@@@ ").dropFirst() {
            let lines = block.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let package = lines.first?.trimmingCharacters(in: .whitespaces), !package.isEmpty else { continue }
            result[package] = parsePermissions(lines.count > 1 ? String(lines[1]) : "")
        }
        return result
    }

    /// "android.permission.CAMERA: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED|... ]" lines.
    nonisolated static func parsePermissions(_ text: String) -> [String: AppPermission] {
        var result: [String: AppPermission] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.range(of: ": granted=") else { continue }
            let name = String(trimmed[..<colon.lowerBound])
            let rest = trimmed[colon.upperBound...]
            let flags = rest.range(of: "flags=[").map { String(rest[$0.upperBound...]) } ?? ""
            result[name] = AppPermission(name: name, granted: rest.hasPrefix("true"),
                                         fixed: flags.contains("SYSTEM_FIXED") || flags.contains("POLICY_FIXED"))
        }
        return result
    }

    nonisolated static func isSafePackage(_ package: String) -> Bool {
        !package.isEmpty && package.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }
}
