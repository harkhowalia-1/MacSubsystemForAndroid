// Mac Android Subsystem - minimal streaming .zip extractor.
//
// macOS has no public unzip API, and Android images hold disks of several hundred
// MB to GBs, so this reads the central directory and inflates each entry in 1 MB chunks
// with Apple's Compression framework (COMPRESSION_ZLIB is raw DEFLATE, which is what
// zip uses). Supports stored and deflated entries and ZIP64 sizes/offsets.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation
import Compression

enum ZipExtractor {
    enum Failure: LocalizedError {
        case notAZip
        case unsupportedMethod(String, UInt16)
        case corrupt(String)
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: return L10n.text("This file isn't a zip archive.")
            case .unsupportedMethod(let name, let method):
                return L10n.format("%@ uses an unsupported compression method (%@). Re-zip it with standard compression.",
                                   name, String(method))
            case .corrupt(let detail): return L10n.format("The zip archive is damaged (%@).", detail)
            case .unsafePath(let name): return L10n.format("The archive contains an unsafe path: %@", name)
            }
        }
    }

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private static let chunk = 1 << 20

    /// Extract every file in `zip` into `destination`. Returns the extracted file URLs.
    @discardableResult
    static func extract(_ zip: URL, to destination: URL, progress: ((Double) -> Void)? = nil) throws -> [URL] {
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        let entries = try readCentralDirectory(handle)
        let total = max(entries.reduce(UInt64(0)) { $0 + $1.compressedSize }, 1)
        var done: UInt64 = 0
        var written: [URL] = []

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            // Finder's resource-fork folder and directory records carry nothing we need.
            if entry.name.hasPrefix("__MACOSX/") || entry.isDirectory { continue }
            let target = try safeTarget(for: entry.name, in: destination)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(entry, from: handle, to: target)
            written.append(target)
            done += entry.compressedSize
            progress?(Double(done) / Double(total))
        }
        return written
    }

    // MARK: Central directory

    static func readCentralDirectory(_ handle: FileHandle) throws -> [Entry] {
        let fileSize = try handle.seekToEnd()
        // The end-of-central-directory record is 22 bytes plus an optional comment (<= 64 KB).
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { throw Failure.notAZip }

        guard let eocd = lastIndex(of: 0x0605_4b50, in: tail) else { throw Failure.notAZip }
        var count = UInt64(tail.zipLE16(eocd + 10))
        var directorySize = UInt64(tail.zipLE32(eocd + 12))
        var directoryOffset = UInt64(tail.zipLE32(eocd + 16))

        // ZIP64: a locator sits 20 bytes before the classic record.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard eocd >= 20, tail.zipLE32(eocd - 20) == 0x0706_4b50 else { throw Failure.corrupt(L10n.text("missing ZIP64 locator")) }
            let zip64Offset = tail.zipLE64(eocd - 20 + 8)
            try handle.seek(toOffset: zip64Offset)
            guard let record = try handle.read(upToCount: 56), record.count == 56, record.zipLE32(0) == 0x0606_4b50 else {
                throw Failure.corrupt(L10n.text("bad ZIP64 record"))
            }
            count = record.zipLE64(32)
            directorySize = record.zipLE64(40)
            directoryOffset = record.zipLE64(48)
        }

        try handle.seek(toOffset: directoryOffset)
        guard let directory = try handle.read(upToCount: Int(directorySize)), directory.count == Int(directorySize) else {
            throw Failure.corrupt(L10n.text("truncated central directory"))
        }

        var entries: [Entry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= directory.count, directory.zipLE32(p) == 0x0201_4b50 else { throw Failure.corrupt(L10n.text("bad directory entry")) }
            let flags = directory.zipLE16(p + 8)
            let method = directory.zipLE16(p + 10)
            var compressed = UInt64(directory.zipLE32(p + 20))
            var uncompressed = UInt64(directory.zipLE32(p + 24))
            let nameLength = Int(directory.zipLE16(p + 28))
            let extraLength = Int(directory.zipLE16(p + 30))
            let commentLength = Int(directory.zipLE16(p + 32))
            var offset = UInt64(directory.zipLE32(p + 42))
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength <= directory.count else { throw Failure.corrupt(L10n.text("bad name")) }
            let nameData = directory.subdata(in: nameStart..<(nameStart + nameLength))
            // Bit 11 = UTF-8 names; older tools use CP437, which is ASCII for typical file names.
            let name = String(data: nameData, encoding: (flags & 0x800) != 0 ? .utf8 : .isoLatin1) ?? ""

            // ZIP64 extended information: only the fields saturated in the record are present, in order.
            var e = nameStart + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = directory.zipLE16(e)
                let size = Int(directory.zipLE16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { uncompressed = directory.zipLE64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { compressed = directory.zipLE64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= e + 4 + size { offset = directory.zipLE64(q); q += 8 }
                }
                e += 4 + size
            }

            entries.append(Entry(name: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: offset))
            p = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: Entries

    private static func extract(_ entry: Entry, from handle: FileHandle, to target: URL) throws {
        try handle.seek(toOffset: entry.localHeaderOffset)
        guard let header = try handle.read(upToCount: 30), header.count == 30, header.zipLE32(0) == 0x0403_4b50 else {
            throw Failure.corrupt(L10n.format("bad local header for %@", entry.name))
        }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(header.zipLE16(26)) + UInt64(header.zipLE16(28))
        try handle.seek(toOffset: dataStart)

        FileManager.default.createFile(atPath: target.path, contents: nil)
        let out = try FileHandle(forWritingTo: target)
        defer { try? out.close() }

        switch entry.method {
        case 0:
            var remaining = entry.compressedSize
            while remaining > 0 {
                try autoreleasepool {
                    let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()
                    guard !data.isEmpty else { throw Failure.corrupt(L10n.format("unexpected end of %@", entry.name)) }
                    try out.write(contentsOf: data)
                    remaining -= UInt64(data.count)
                }
            }
        case 8:
            try inflate(entry, from: handle, to: out)
        default:
            throw Failure.unsupportedMethod(entry.name, entry.method)
        }

        let size = try out.offset()
        if size != entry.uncompressedSize {
            throw Failure.corrupt(L10n.format("%@ is %@ bytes, expected %@",
                                              entry.name, String(size), String(entry.uncompressedSize)))
        }
    }

    private static func inflate(_ entry: Entry, from handle: FileHandle, to out: FileHandle) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.corrupt(L10n.text("could not start decompression"))
        }
        defer { compression_stream_destroy(stream) }

        let source = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer {
            source.deallocate()
            destination.deallocate()
        }

        var remaining = entry.compressedSize
        var idleRounds = 0
        while true {
            var flags: Int32 = 0
            if stream.pointee.src_size == 0 {
                let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))) ?? Data()
                remaining -= UInt64(data.count)
                data.copyBytes(to: source, count: data.count)
                stream.pointee.src_ptr = UnsafePointer(source)
                stream.pointee.src_size = data.count
            }
            if remaining == 0 {
                flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            }

            stream.pointee.dst_ptr = destination
            stream.pointee.dst_size = chunk
            let status = compression_stream_process(stream, flags)
            let produced = chunk - stream.pointee.dst_size
            if produced > 0 {
                try out.write(contentsOf: Data(bytes: destination, count: produced))
                idleRounds = 0
            } else {
                idleRounds += 1
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return
            case COMPRESSION_STATUS_OK:
                // Out of input with nothing left to emit means the stream is truncated.
                if remaining == 0, stream.pointee.src_size == 0, idleRounds > 2 {
                    throw Failure.corrupt(L10n.format("unexpected end of %@", entry.name))
                }
            default:
                throw Failure.corrupt(L10n.format("could not inflate %@", entry.name))
            }
        }
    }

    // MARK: Helpers

    /// Keep extracted files inside `destination` (no absolute paths, no "..").
    private static func safeTarget(for name: String, in destination: URL) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !name.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else {
            throw Failure.unsafePath(name)
        }
        return parts.reduce(destination) { $0.appendingPathComponent($1) }
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        while i >= 0 {
            if data.zipLE32(i) == signature { return i }
            i -= 1
        }
        return nil
    }
}

private extension Data {
    func zipLE16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func zipLE32(_ i: Int) -> UInt32 {
        let s = startIndex + i
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    func zipLE64(_ i: Int) -> UInt64 {
        UInt64(zipLE32(i)) | UInt64(zipLE32(i + 4)) << 32
    }
}
