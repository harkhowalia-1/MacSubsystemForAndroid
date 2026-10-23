// Mac Android Subsystem - the GRUB settings of LineageOS's virtio images.
//
// These images boot through GRUB, which adds kernel arguments from the variables in
// a `grubenv` file on the FAT32 PERSIST partition (its Settings menu edits them).
// android_insecure_adb=1 adds androidboot.insecure_adb=1, and LineageOS then turns
// ADB on without the authorization prompt and marks the build debuggable.
//
// Android 16 (LineageOS 23) needs it here. On a build that isn't debuggable, the
// setup wizard starts "trade-in mode", in which adbd answers nothing but
// `tradeinmode` commands, so the Mac could never even ask whether Android had
// finished starting. Trade-in mode never starts on a debuggable build, and Android
// leaves it on the first debuggable boot if an earlier boot entered it.
//
// grub_timeout=0 skips the menu, which otherwise waits 10 s on every boot.
//
// arm64.nobti: LineageOS 24's kernel (6.18) enables Branch Target Identification for
// code that lacks the landing pads, so on a Mac whose processor has BTI (M2 and
// later) Android panics within seconds of starting (issue #5). GRUB has no setting
// for extra kernel arguments, but it pastes android_wifi_impl into the command line
// unquoted, so "none arm64.nobti" adds androidboot.wifi_impl=none (Android only acts
// on virt_wifi) and arm64.nobti. Macs without BTI (M1) keep BTI on in Android.
//
// android_wifi_impl is never virt_wifi: VirtWifi renames eth0 and only has an
// address once Android joins its network, so the Mac's ADB couldn't reach Android.
//
// The file is edited in the VM's overlay, never in the image, with qemu-img writing
// through a raw view of the disk at the file's offset. QEMU must not be running.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum GrubEnvironment {
    enum Failure: LocalizedError {
        case qemuImg(String)
        var errorDescription: String? {
            switch self {
            case .qemuImg(let output): return L10n.format("Couldn't change Android's boot settings: %@", output)
            }
        }
    }

    /// Turn on the image's "Insecure ADB" setting, skip GRUB's menu, keep Android on
    /// Ethernet, and turn off BTI in Android on Macs whose processor has it. Does
    /// nothing for images without these settings.
    static func configure(_ disks: [URL]) throws {
        let wifi = hostHasBTI ? "none arm64.nobti" : ""
        try set(["android_insecure_adb": "1", "grub_timeout": "0", "android_wifi_impl": wifi], on: disks)
    }

    /// The Mac's processor has Branch Target Identification (M2 and later).
    /// `defaults write <bundle id> androidNoBTI -bool YES|NO` overrides it.
    static var hostHasBTI: Bool {
        if let forced = UserDefaults.standard.object(forKey: "androidNoBTI") as? Bool { return forced }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm.FEAT_BTI", &value, &size, nil, 0) == 0 && value == 1
    }

    static func set(_ settings: KeyValuePairs<String, String>, on disks: [URL]) throws {
        for disk in disks {
            guard let partition = try persistPartition(of: disk),
                  let file = try GrubEnvFile(disk: disk, partitionOffset: partition) else { continue }
            guard let updated = file.contents(setting: settings) else { return }
            try file.write(updated)
            return
        }
    }

    // MARK: Disk layout

    /// Byte offset of the GPT partition named "persist", if the disk has one.
    private static func persistPartition(of disk: URL) throws -> UInt64? {
        let header = try read(disk, at: 512, count: 512)
        guard header.count == 512, header.prefix(8) == Data("EFI PART".utf8) else { return nil }
        let entriesLBA = header.uint64(at: 72)
        let count = Int(min(header.uint32(at: 80), 256))
        let size = Int(header.uint32(at: 84))
        guard size >= 128 else { return nil }
        let entries = try read(disk, at: entriesLBA * 512, count: count * size)
        for index in 0..<count where (index + 1) * size <= entries.count {
            let entry = entries.subdata(in: index * size..<(index + 1) * size)
            let units = stride(from: 56, to: 128, by: 2).map { entry.uint16(at: $0) }
            let name = String(decoding: units, as: UTF16.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if name.lowercased() == "persist" { return entry.uint64(at: 32) * 512 }
        }
        return nil
    }

    /// `grubenv` in the root folder of a FAT32 file system.
    private struct GrubEnvFile {
        let disk: URL
        /// Disk offsets and lengths of the file's clusters, in order.
        let extents: [(offset: UInt64, length: Int)]
        let contents: Data

        init?(disk: URL, partitionOffset: UInt64) throws {
            let boot = try read(disk, at: partitionOffset, count: 512)
            guard boot.count == 512, boot[510] == 0x55, boot[511] == 0xAA else { return nil }
            let bytesPerSector = UInt64(boot.uint16(at: 11))
            let sectorsPerCluster = UInt64(boot[13])
            let reserved = UInt64(boot.uint16(at: 14))
            let fatCount = UInt64(boot[16])
            let sectorsPerFAT = UInt64(boot.uint32(at: 36))
            guard bytesPerSector >= 512, sectorsPerCluster > 0, sectorsPerFAT > 0 else { return nil }
            let clusterSize = bytesPerSector * sectorsPerCluster
            let fat = try read(disk, at: partitionOffset + reserved * bytesPerSector,
                               count: Int(sectorsPerFAT * bytesPerSector))
            let dataStart = partitionOffset + (reserved + fatCount * sectorsPerFAT) * bytesPerSector

            func chain(from first: UInt32) -> [UInt32] {
                var clusters: [UInt32] = []
                var cluster = first
                while cluster >= 2, cluster < 0x0FFF_FFF8, clusters.count < 4096,
                      Int(cluster) * 4 + 4 <= fat.count {
                    clusters.append(cluster)
                    cluster = fat.uint32(at: Int(cluster) * 4) & 0x0FFF_FFFF
                }
                return clusters
            }
            func offset(of cluster: UInt32) -> UInt64 { dataStart + UInt64(cluster - 2) * clusterSize }

            var found: (cluster: UInt32, size: Int)?
            search: for cluster in chain(from: boot.uint32(at: 44)) {
                let folder = try read(disk, at: offset(of: cluster), count: Int(clusterSize))
                for start in stride(from: 0, to: folder.count - 31, by: 32) {
                    let entry = folder.subdata(in: start..<start + 32)
                    if entry[0] == 0 { break search }
                    let attributes = entry[11]
                    guard entry[0] != 0xE5, attributes & 0x18 == 0,
                          entry.prefix(11) == Data("GRUBENV    ".utf8) else { continue }
                    let first = UInt32(entry.uint16(at: 20)) << 16 | UInt32(entry.uint16(at: 26))
                    found = (first, Int(entry.uint32(at: 28)))
                    break search
                }
            }
            guard let found, found.size > 0, found.size <= 64 * 1024 else { return nil }

            var extents: [(offset: UInt64, length: Int)] = []
            var remaining = found.size
            for cluster in chain(from: found.cluster) where remaining > 0 {
                let length = min(remaining, Int(clusterSize))
                if let last = extents.last, last.offset + UInt64(last.length) == offset(of: cluster) {
                    extents[extents.count - 1].length += length
                } else {
                    extents.append((offset(of: cluster), length))
                }
                remaining -= length
            }
            guard remaining == 0 else { return nil }
            var contents = Data()
            for extent in extents { contents += try read(disk, at: extent.offset, count: extent.length) }
            guard contents.starts(with: Data("# GRUB Environment Block\n".utf8)) else { return nil }
            self.disk = disk
            self.extents = extents
            self.contents = contents
        }

        /// The file with each `name=value`, padded with "#" to its size like grub-editenv
        /// does, or nil if it already says so (or there's no room).
        func contents(setting settings: KeyValuePairs<String, String>) -> Data? {
            var lines = String(decoding: contents, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // The padding after the last newline.
            lines.removeLast()
            let original = lines
            for (name, value) in settings {
                let line = "\(name)=\(value)"
                if let index = lines.firstIndex(where: { $0.hasPrefix("\(name)=") }) {
                    lines[index] = line
                } else {
                    lines.append(line)
                }
            }
            guard lines != original else { return nil }
            var text = Data(lines.map { $0 + "\n" }.joined().utf8)
            guard text.count <= contents.count else { return nil }
            text += Data(repeating: UInt8(ascii: "#"), count: contents.count - text.count)
            return text
        }

        func write(_ data: Data) throws {
            var position = 0
            for extent in extents {
                try GrubEnvironment.write(data.subdata(in: position..<position + extent.length), to: disk, at: extent.offset)
                position += extent.length
            }
        }
    }

    // MARK: qemu-img

    /// A raw window onto a qcow2 disk, in qemu-img's json: syntax.
    private static func window(_ disk: URL, at offset: UInt64, count: Int) throws -> String {
        let spec: [String: Any] = [
            "driver": "raw", "offset": offset, "size": count,
            "file": ["driver": "qcow2", "file": ["driver": "file", "filename": disk.path]],
        ]
        return "json:" + String(decoding: try JSONSerialization.data(withJSONObject: spec, options: .withoutEscapingSlashes), as: UTF8.self)
    }

    private static func read(_ disk: URL, at offset: UInt64, count: Int) throws -> Data {
        let output = SubsystemPaths.runtime.appendingPathComponent("grubenv-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: output) }
        try qemuImg(["convert", "-O", "raw", try window(disk, at: offset, count: count), output.path])
        return try Data(contentsOf: output)
    }

    private static func write(_ data: Data, to disk: URL, at offset: UInt64) throws {
        let input = SubsystemPaths.runtime.appendingPathComponent("grubenv-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: input) }
        try data.write(to: input)
        try qemuImg(["convert", "-n", "-f", "raw", input.path, try window(disk, at: offset, count: data.count)])
    }

    private static func qemuImg(_ arguments: [String]) throws {
        guard let qemuImg = VirtualMachine.qemuImg else { throw VirtualMachine.Failure.qemuMissing }
        let process = Process()
        process.executableURL = qemuImg
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.qemuImg(String(decoding: output, as: UTF8.self)) }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
