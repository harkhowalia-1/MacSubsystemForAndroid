// Mac Android Subsystem - adb's file sync protocol ("sync:" service), enough to
// push files and check whether a file is already there.
//
//   STAT <path>               -> STAT mode:u32 size:u32 mtime:u32
//   SEND <path>,<mode>        then DATA <len> <bytes>... DONE <mtime>  -> OKAY | FAIL <msg>
//   QUIT
// All lengths little-endian; ids are 4 ASCII bytes.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

extension ADBConnection {
    struct RemoteFile {
        let mode: UInt32
        let size: UInt32
        let modified: UInt32
        var exists: Bool { mode != 0 }
    }

    func stat(_ path: String) throws -> RemoteFile {
        let stream = try openStream("sync:")
        defer { stream.close() }
        try stream.write(Self.syncRequest("STAT", Data(path.utf8)))
        let reply = try stream.readExactly(16, timeout: 15)
        guard String(decoding: reply.prefix(4), as: UTF8.self) == "STAT" else {
            throw ADBError.protocolError(L10n.text("STAT reply"))
        }
        try? stream.write(Self.syncRequest("QUIT", Data()))
        return RemoteFile(mode: reply.le32(4), size: reply.le32(8), modified: reply.le32(12))
    }

    /// Copy a local file to Android.
    func push(_ file: URL, to remotePath: String, mode: UInt32 = 0o644, progress: ((Double) -> Void)? = nil) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Double((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 1)
        try push(remotePath: remotePath, mode: mode) { send in
            var sent = 0.0
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try send(chunk)
                sent += Double(chunk.count)
                progress?(min(sent / max(total, 1), 1))
            }
        }
    }

    func push(_ data: Data, to remotePath: String, mode: UInt32 = 0o644) throws {
        try push(remotePath: remotePath, mode: mode) { send in
            var offset = 0
            while offset < data.count {
                let end = min(offset + 64 * 1024, data.count)
                try send(data.subdata(in: offset..<end))
                offset = end
            }
        }
    }

    private func push(remotePath: String, mode: UInt32, body: ((Data) throws -> Void) throws -> Void) throws {
        let stream = try openStream("sync:")
        defer { stream.close() }
        // S_IFREG | permissions
        let spec = "\(remotePath),\(0o100000 | mode)"
        try stream.write(Self.syncRequest("SEND", Data(spec.utf8)))
        try body { chunk in
            try stream.write(Self.syncRequest("DATA", chunk))
        }
        try stream.write(Self.syncHeader("DONE", UInt32(Date().timeIntervalSince1970)))
        let reply = try stream.readExactly(8, timeout: 60)
        let id = String(decoding: reply.prefix(4), as: UTF8.self)
        if id == "FAIL" {
            let length = Int(reply.le32(4))
            let message = (try? stream.readExactly(length, timeout: 5)).map { String(decoding: $0, as: UTF8.self) } ?? L10n.text("push failed")
            throw ADBError.command(message)
        }
        guard id == "OKAY" else { throw ADBError.protocolError(L10n.format("SEND reply %@", id)) }
        try? stream.write(Self.syncHeader("QUIT", 0))
    }

    private static func syncRequest(_ id: String, _ payload: Data) -> Data {
        syncHeader(id, UInt32(payload.count)) + payload
    }

    private static func syncHeader(_ id: String, _ value: UInt32) -> Data {
        var out = Data(id.utf8)
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        return out
    }
}

extension Data {
    func le32(_ offset: Int) -> UInt32 {
        let s = startIndex + offset
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    func be32(_ offset: Int) -> UInt32 {
        let s = startIndex + offset
        return UInt32(self[s]) << 24 | UInt32(self[s + 1]) << 16 | UInt32(self[s + 2]) << 8 | UInt32(self[s + 3])
    }

    func be64(_ offset: Int) -> UInt64 {
        UInt64(be32(offset)) << 32 | UInt64(be32(offset + 4))
    }
}
