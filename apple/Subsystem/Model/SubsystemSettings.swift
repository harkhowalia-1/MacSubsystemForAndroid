// Mac Android Subsystem - the settings (System, Performance, Apps, Files,
// Storage, Advanced).
//
// Stored in the Subsystem's UserDefaults; app windows read showSoftKeyboard and
// displayDensity from the same domain.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation
import ServiceManagement

@MainActor
final class SubsystemSettings: ObservableObject {
    static let shared = SubsystemSettings()

    /// What happens when the last Android app closes. Power Saver always turns
    /// Android off (after a short grace period), whatever is chosen here.
    enum Resources: String, CaseIterable, Identifiable {
        /// Decided by the performance mode and power source (see Subsystem.idleShutdownDelay).
        case automatic
        /// Turn Android off a few minutes after the last app closes.
        case asNeeded
        /// Keep Android running, so apps open instantly.
        case continuous
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return L10n.text("Automatic")
            case .asNeeded: return L10n.text("As needed")
            case .continuous: return L10n.text("Continuous")
            }
        }
        var detail: String {
            switch self {
            case .automatic: return L10n.text("Smart, Standard and Performance keep Android ready. Smart drops to Power Saver when idle. Power Saver turns Android off when no app is open.")
            case .asNeeded: return L10n.text("Android starts when you open an Android app and turns off after the minutes you set. The first open takes longer.")
            case .continuous: return L10n.text("Android stays ready in the background, so apps open quickly. Uses more memory and battery. Power Saver still turns it off when no app is open.")
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var resources: Resources { didSet { defaults.set(resources.rawValue, forKey: "resources") } }
    @Published var idleMinutes: Int { didSet { defaults.set(idleMinutes, forKey: "idleMinutes") } }
    @Published var memoryMB: Int { didSet { defaults.set(memoryMB, forKey: "memoryMB") } }
    @Published var cpuCount: Int { didSet { defaults.set(cpuCount, forKey: "cpuCount") } }
    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    @Published var showAndroidScreen: Bool { didSet { defaults.set(showAndroidScreen, forKey: "showAndroidScreen") } }
    @Published var microphone: Bool { didSet { defaults.set(microphone, forKey: "microphone") } }
    @Published var showSoftKeyboard: Bool { didSet { defaults.set(showSoftKeyboard, forKey: "showSoftKeyboard") } }
    @Published var displayDensity: Double { didSet { defaults.set(displayDensity, forKey: "displayDensity") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    @Published var performanceMode: PerformanceMode {
        didSet { defaults.set(performanceMode.rawValue, forKey: "performanceMode") }
    }
    /// Forward Mac game controllers to Android games (always on unless turned off).
    @Published var controllers: Bool { didSet { defaults.set(controllers, forKey: "controllers") } }
    /// Tidy downloads, leftovers, logs and Android's unused disk space automatically.
    @Published var autoCleanup: Bool { didSet { defaults.set(autoCleanup, forKey: "autoCleanup") } }
    @Published var startAtLogin: Bool {
        didSet {
            do {
                if startAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Login item: \(error.localizedDescription)")
            }
        }
    }

    private init() {
        resources = Resources(rawValue: defaults.string(forKey: "resources") ?? "") ?? .automatic
        idleMinutes = defaults.object(forKey: "idleMinutes") as? Int ?? 5
        memoryMB = defaults.object(forKey: "memoryMB") as? Int ?? VirtualMachine.defaultMemoryMB
        cpuCount = defaults.object(forKey: "cpuCount") as? Int ?? VirtualMachine.defaultCPUCount
        developerMode = defaults.bool(forKey: "developerMode")
        showAndroidScreen = defaults.bool(forKey: "showAndroidScreen")
        microphone = defaults.bool(forKey: "microphone")
        showSoftKeyboard = defaults.bool(forKey: "showSoftKeyboard")
        displayDensity = defaults.object(forKey: "displayDensity") as? Double ?? 1.0
        notifications = defaults.object(forKey: "notifications") as? Bool ?? true
        performanceMode = PerformanceMode(saved: defaults.string(forKey: "performanceMode") ?? "") ?? .smart
        controllers = defaults.object(forKey: "controllers") as? Bool ?? true
        autoCleanup = defaults.object(forKey: "autoCleanup") as? Bool ?? true
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// "Always ready": open at login and keep Android running in the background,
    /// so Android apps open at full speed straight away.
    var alwaysReady: Bool {
        get { startAtLogin && resources != .asNeeded }
        set {
            startAtLogin = newValue
            if newValue, resources == .asNeeded { resources = .automatic }
            if !newValue { resources = .asNeeded }
        }
    }

    var memoryChoices: [Int] {
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        return [2048, 3072, 4096, 6144, 8192, 12288].filter { $0 <= total / 2 }
    }

    var cpuChoices: [Int] { Array(1...max(ProcessInfo.processInfo.activeProcessorCount, 1)) }
}
