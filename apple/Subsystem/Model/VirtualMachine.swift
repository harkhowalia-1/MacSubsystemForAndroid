// Mac Android Subsystem - runs Android in QEMU with Apple's Hypervisor framework.
//
// Android (LineageOS's virtio_arm64only target, made for QEMU and UTM) runs as a
// headless arm64 VM at near-native speed. Nobody looks at its main display: each
// Android app gets its own virtual display streamed into its own Mac window. The
// only way in is ADB, forwarded to 127.0.0.1:58526.
//
// The command line follows LineageOS's UTM/QEMU instructions and
// jqssun/android-lineage-qemu's QEMU_OPTS:
//   virt machine + HVF, UEFI (edk2 pflash code + per-VM vars), virtio-blk disks,
//   virtio-net (user mode, adb forwarded), virtio-gpu, intel-hda through Core Audio.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

final class VirtualMachine: @unchecked Sendable {
    struct Configuration {
        var image: AndroidImage
        var disks: [URL]
        var efiVariables: URL
        var memoryMB: Int
        var cpuCount: Int
        var adbPort: UInt16
        var showDisplay: Bool
        var microphone: Bool
    }

    enum Failure: LocalizedError {
        case qemuMissing
        case firmwareMissing
        case portInUse(UInt16)
        case launch(String)

        var errorDescription: String? {
            switch self {
            case .qemuMissing: return L10n.format("QEMU is missing from this copy of %@. Reinstall it (or, for development, run `brew install qemu`).", AppConfig.displayName)
            case .firmwareMissing: return L10n.text("The UEFI firmware (edk2-aarch64-code.fd) is missing.")
            case .portInUse(let port): return L10n.format("Port %@ on this Mac is already in use, so Android's ADB can't be reached. Quit the program using it (often another Android emulator) and try again.", String(port))
            case .launch(let detail): return L10n.format("Android couldn't start: %@", detail)
            }
        }
    }

    let configuration: Configuration
    private let process = Process()
    private var logHandle: FileHandle?
    var onExit: ((Int32) -> Void)?
    var isRunning: Bool { process.isRunning }
    var processIdentifier: pid_t { process.processIdentifier }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: Binaries

    /// QEMU bundled in Contents/Helpers, or Homebrew's for development builds.
    static var qemuSystem: URL? { helper("qemu-system-aarch64") }
    /// QEMU option values escape commas by doubling them.
    static func smbios(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

    static var qemuImg: URL? { helper("qemu-img") }

    /// The bundled QEMU is built with SDL audio, which can record; Homebrew's (used by
    /// development builds) isn't, and would refuse to start with `-audiodev sdl`.
    static let hasSDLAudio: Bool = {
        guard let qemu = qemuSystem else { return false }
        let process = Process()
        process.executableURL = qemu
        process.arguments = ["-audiodev", "help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "sdl" }
    }()

    private static func helper(_ name: String) -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var firmware: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("qemu/edk2-aarch64-code.fd"),
            URL(fileURLWithPath: "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"),
            URL(fileURLWithPath: "/usr/local/share/qemu/edk2-aarch64-code.fd"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var logURL: URL { SubsystemPaths.vm.appendingPathComponent("qemu.log") }
    static var consoleURL: URL { SubsystemPaths.vm.appendingPathComponent("console.log") }
    static var pidURL: URL { SubsystemPaths.vm.appendingPathComponent("qemu.pid") }

    // MARK: Launch

    func launch() throws {
        guard let qemu = Self.qemuSystem else { throw Failure.qemuMissing }
        guard let firmware = Self.firmware else { throw Failure.firmwareMissing }
        Self.killStaleInstance()
        guard Self.isPortFree(configuration.adbPort) else { throw Failure.portInUse(configuration.adbPort) }

        try? FileManager.default.removeItem(at: QMPClient.socketURL)
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: Self.logURL)
        logHandle = log
        let arguments = Self.arguments(for: configuration, firmware: firmware)
        log.write(Data(("qemu-system-aarch64 " + arguments.joined(separator: " ") + "\n\n").utf8))

        process.executableURL = qemu
        process.arguments = arguments
        process.currentDirectoryURL = SubsystemPaths.vm
        process.standardOutput = log
        process.standardError = log
        process.qualityOfService = .userInteractive
        process.terminationHandler = { [weak self] process in
            try? self?.logHandle?.close()
            try? FileManager.default.removeItem(at: Self.pidURL)
            self?.onExit?(process.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw Failure.launch(error.localizedDescription)
        }
    }

    /// Ask QEMU to quit (SIGTERM flushes the disks); escalate if it hangs.
    func terminate(after grace: TimeInterval = 8) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in
            if self?.process.isRunning == true { kill(pid, SIGKILL) }
        }
    }

    // MARK: Command line

    static func arguments(for c: Configuration, firmware: URL) -> [String] {
        // QEMU's Core Audio backend can't record (max_voices_in = 0); SDL can, and plays too.
        let recording = c.microphone && hasSDLAudio
        var args: [String] = [
            "-name", AppConfig.displayName,
            "-machine", "virt",
            // What Android reports as the manufacturer and model (instead of "QEMU Virtual Machine").
            "-smbios", "type=1,manufacturer=\(Self.smbios(AppConfig.displayName)),product=\(Self.smbios(AppConfig.deviceName)),family=\(Self.smbios(AppConfig.shortName)),version=\(Self.smbios(AppConfig.version))",
            "-smbios", "type=2,manufacturer=\(Self.smbios(AppConfig.displayName)),product=\(Self.smbios(AppConfig.deviceName))",
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", "\(c.cpuCount)",
            "-m", "\(c.memoryMB)",
            "-nodefaults",
            "-L", firmware.deletingLastPathComponent().path,
            "-pidfile", pidURL.path,
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,file.locking=off,file.filename=\(firmware.path)",
            "-drive", "if=pflash,format=raw,unit=1,file.filename=\(c.efiVariables.path)",
        ]
        for (index, disk) in c.disks.enumerated() {
            args += [
                "-drive", "file=\(disk.path),if=none,id=vd\(index),format=qcow2,discard=unmap,detect-zeroes=unmap",
                "-device", "virtio-blk-pci,drive=vd\(index),bootindex=\(index)",
            ]
        }
        args += [
            "-netdev", "user,id=net0,hostfwd=tcp:127.0.0.1:\(c.adbPort)-:5555",
            // romfile= : UEFI has its own virtio-net driver, so no option ROM is needed.
            "-device", "virtio-net-pci,netdev=net0,romfile=",
            "-device", "virtio-rng-pci",
            // Lets the performance modes hand unused memory back to macOS while Android runs.
            "-device", "virtio-balloon-pci,deflate-on-oom=on",
            "-qmp", "unix:\(QMPClient.socketURL.path),server=on,wait=off",
            "-device", "virtio-serial",
            "-serial", "file:\(consoleURL.path)",
            "-audiodev", recording ? "sdl,id=audio0" : "coreaudio,id=audio0",
            "-device", "intel-hda",
            "-device", recording ? "hda-duplex,audiodev=audio0" : "hda-output,audiodev=audio0",
            // The main display only hosts Android's own launcher; app windows use virtual displays.
            "-device", "virtio-gpu-pci,xres=1080,yres=1920",
        ]
        if c.showDisplay {
            args += [
                "-display", "cocoa,show-cursor=on",
                "-device", "qemu-xhci,id=usb-bus",
                "-device", "usb-tablet,bus=usb-bus.0",
                "-device", "usb-kbd,bus=usb-bus.0",
            ]
        } else {
            args += ["-display", "none"]
        }
        return args
    }

    // MARK: Helpers

    /// A QEMU left behind by a crash would hold the disks and the ADB port.
    static func killStaleInstance() {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        if kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
            for _ in 0..<40 where kill(pid, 0) == 0 { usleep(100_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    static func isPortFree(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Reasonable defaults for this Mac: the performance cores and a quarter of the memory.
    static var defaultCPUCount: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(min(value, 8))
        }
        return min(ProcessInfo.processInfo.activeProcessorCount, 4)
    }

    static var defaultMemoryMB: Int {
        let total = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        return max(2048, min(6144, total / 4 / 512 * 512))
    }
}
