// Mac Android Subsystem - performance modes.
//
//   Power Saver   Android only runs while an Android app is open (it turns off
//                 30 s after the last one closes; see Subsystem.idleShutdownDelay).
//                 While it runs it adapts like Smart, but never above Balanced:
//                 the Saver level unless an Android app is in front and the Mac
//                 has power and resources to spare.
//   Smart         Android stays ready in the background and adapts all the time:
//                 full speed for the app in front, and the Saver level as soon as
//                 other Mac apps need the processor or memory, the battery runs
//                 low, Low Power Mode is on or the Mac gets hot.
//   Standard      Android as is: nothing tuned, every core and all memory,
//                 Android's own power settings, 60 fps windows.
//   Performance   the most of everything, always: every core and all memory,
//                 Android's fixed-performance and game modes, up to 120 fps and
//                 a higher-quality stream.
//
// Levels and what they change:
//   Saver         QEMU as a background task (efficiency cores, low I/O priority),
//                 2 cores online in Android, 60% memory (balloon), Android's
//                 battery saver, 30 fps windows.
//   Balanced      half the cores, 85% memory, 60 fps.
//   Standard      all cores and memory, normal priority, Android's defaults, 60 fps.
//   Performance   Standard + fixed-performance and game modes, 120 fps, higher
//                 bitrate, latency-critical windows.
//
// The Subsystem applies the level to the VM; app windows read it from
// status.json when they open (frame rate, bitrate, game tweaks).
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum PerformanceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case powerSaver
    case smart
    case standard
    case performance

    var id: String { rawValue }

    /// Reads a saved mode; Gaming was merged into Performance.
    init?(saved: String) {
        self.init(rawValue: saved == "game" ? "performance" : saved)
    }

    var title: String {
        switch self {
        case .powerSaver: return L10n.text("Power Saver")
        case .smart: return L10n.text("Smart")
        case .standard: return L10n.text("Standard")
        case .performance: return L10n.text("Performance")
        }
    }

    var symbol: String {
        switch self {
        case .powerSaver: return "leaf"
        case .smart: return "wand.and.stars"
        case .standard: return "cpu"
        case .performance: return "gauge.with.dots.needle.100percent"
        }
    }

    var summary: String {
        switch self {
        case .powerSaver:
            return L10n.text("Android only runs while an Android app is open, and adapts while it does: frugal by default, a little faster for the app in front when your Mac has power to spare.")
        case .smart:
            return L10n.text("Stays ready so apps open instantly, and adapts all the time: full speed for the app you're using, and power saving as soon as other apps need your Mac or the battery runs low.")
        case .standard:
            return L10n.text("Android runs as it is, with nothing tuned: every processor core, all of its memory and its own power settings. Stays ready in the background.")
        case .performance:
            return L10n.text("Maximum performance, all the time: every core and all of Android's memory, its game optimizations, up to 120 fps and lower input latency.")
        }
    }
}

/// What a mode means right now. Smart resolves to one of the others.
enum PerformanceLevel: String, Codable, Sendable {
    case saver
    case balanced
    case standard
    case performance

    var title: String {
        switch self {
        case .saver: return L10n.text("Saving power")
        case .balanced: return L10n.text("Balanced")
        case .standard: return L10n.text("Standard")
        case .performance: return L10n.text("Performance")
        }
    }

    /// Share of the VM's processor cores kept online inside Android.
    var cpuShare: Double {
        switch self {
        case .saver: return 0.25
        case .balanced: return 0.5
        case .standard, .performance: return 1
        }
    }

    /// Share of the VM's memory Android keeps; the rest goes back to macOS.
    var memoryShare: Double {
        switch self {
        case .saver: return 0.6
        case .balanced: return 0.85
        case .standard, .performance: return 1
        }
    }

    /// QEMU runs as a background task (efficiency cores, throttled I/O).
    var backgroundPriority: Bool { self == .saver }
    var androidBatterySaver: Bool { self == .saver }
    var androidFixedPerformance: Bool { self == .performance }
    /// Windows hold a latency-critical activity and ask for Android's game mode.
    var latencyCritical: Bool { self == .performance }

    var maxFPS: Int {
        switch self {
        case .saver: return 30
        case .balanced, .standard: return 60
        case .performance: return 120
        }
    }

    var videoBitRate: Int {
        switch self {
        case .saver: return 6_000_000
        case .balanced, .standard: return 10_000_000
        case .performance: return 20_000_000
        }
    }
}
