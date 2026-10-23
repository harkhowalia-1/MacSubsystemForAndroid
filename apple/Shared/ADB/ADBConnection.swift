// Mac Android Subsystem - a small ADB client speaking the wire protocol directly
// to adbd over TCP (no adb server, no adb binary).
//
// Messages are a 24-byte little-endian header plus payload:
//   command, arg0, arg1, data_length, data_check (byte sum), magic (command ^ 0xffffffff)
//
// Handshake: CNXN -> [AUTH token -> AUTH signature | AUTH public key] -> CNXN
// Streams:   OPEN(local, 0, "service\0") -> OKAY(remote, local) -> WRTE/OKAY ... -> CLSE
// Each side may have one unacknowledged WRTE per stream, so writes wait for OKAY.
//
// Several processes (the Subsystem app and every app window) open their own
// connection; adbd serves each as a separate transport.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

enum ADBError: LocalizedError {
    case connect(String)
    case closed
    case timeout(String)
    case protocolError(String)
    case unauthorized
    case serviceUnavailable(String)
    case command(String)

    var errorDescription: String? {
        switch self {
        case .connect(let detail): return L10n.format("Couldn't connect to Android: %@", detail)
        case .closed: return L10n.text("The connection to Android closed.")
        case .timeout(let what): return L10n.format("Android didn't answer in time (%@).", what)
        case .protocolError(let detail): return L10n.format("Unexpected answer from Android (%@).", detail)
        case .unauthorized: return L10n.text("Android hasn't allowed this Mac to connect yet.")
        case .serviceUnavailable(let service): return L10n.format("Android refused %@.", service)
        case .command(let output): return output
        }
    }
}

final class ADBConnection: @unchecked Sendable {
    enum Command: UInt32 {
        case sync = 0x434e_5953
        case cnxn = 0x4e58_4e43
        case auth = 0x4854_5541
        case open = 0x4e45_504f
        case okay = 0x5941_4b4f
        case clse = 0x4553_4c43
        case wrte = 0x4554_5257
        case stls = 0x534c_5453
    }

    struct Message {
        let command: UInt32
        let arg0: UInt32
        let arg1: UInt32
        let payload: Data
    }

    static let version: UInt32 = 0x0100_0001
    static let localMaxData: UInt32 = 256 * 1024

    let host: String
    let port: UInt16
    private let key: ADBKey?
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var streams: [UInt32: ADBStream] = [:]
    private var nextLocalID: UInt32 = 1
    private var isClosed = false
    private(set) var remoteMaxData: Int = 256 * 1024
    private(set) var banner = ""
    /// Called (on the reader thread) when the connection drops.
    var onClose: (() -> Void)?

    init(host: String = "127.0.0.1", port: UInt16, key: ADBKey?) {
        self.host = host
        self.port = port
        self.key = key
    }

    deinit { close() }

    // MARK: Connect

    /// Open the TCP connection and finish the handshake.
    /// `authorizationTimeout` is how long to wait for a person to tap "Allow" on the Android side.
    func connect(timeout: TimeInterval = 5, authorizationTimeout: TimeInterval = 0) throws {
        fd = try Self.openSocket(host: host, port: port, timeout: timeout)
        setReceiveTimeout(timeout)

        try send(.cnxn, Self.version, Self.localMaxData,
                 Data("host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir\0".utf8))

        var signed = false
        var sentPublicKey = false
        while true {
            let message: Message
            do {
                message = try readMessage()
            } catch ADBError.timeout {
                throw sentPublicKey ? ADBError.unauthorized : ADBError.timeout(L10n.text("handshake"))
            }
            switch Command(rawValue: message.command) {
            case .cnxn:
                remoteMaxData = Int(min(message.arg1, 1024 * 1024))
                banner = String(decoding: message.payload, as: UTF8.self)
                setReceiveTimeout(0)
                startReader()
                return
            case .auth where message.arg0 == 1: // TOKEN
                guard let key else { throw ADBError.unauthorized }
                if !signed {
                    signed = true
                    try send(.auth, 2, 0, try key.sign(token: message.payload)) // SIGNATURE
                } else if !sentPublicKey {
                    sentPublicKey = true
                    try send(.auth, 3, 0, key.androidPublicKey) // RSAPUBLICKEY
                    if authorizationTimeout <= 0 { throw ADBError.unauthorized }
                    setReceiveTimeout(authorizationTimeout)
                } else {
                    throw ADBError.unauthorized
                }
            case .stls:
                throw ADBError.protocolError(L10n.text("TLS is not supported on this port"))
            default:
                throw ADBError.protocolError(L10n.format("command %@ during handshake",
                                                         String(format: "0x%08x", message.command)))
            }
        }
    }

    var isConnected: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !isClosed && fd >= 0
    }

    func close() {
        stateLock.lock()
        if isClosed { stateLock.unlock(); return }
        isClosed = true
        let open = Array(streams.values)
        streams.removeAll()
        let socket = fd
        fd = -1
        stateLock.unlock()
        if socket >= 0 {
            shutdown(socket, SHUT_RDWR)
            Darwin.close(socket)
        }
        open.forEach { $0.remoteClosed() }
    }

    // MARK: Streams

    /// Open a service such as "exec:ls", "sync:" or "localabstract:name".
    func openStream(_ service: String, timeout: TimeInterval = 10) throws -> ADBStream {
        stateLock.lock()
        guard !isClosed else { stateLock.unlock(); throw ADBError.closed }
        let localID = nextLocalID
        nextLocalID &+= 1
        let stream = ADBStream(connection: self, localID: localID, service: service)
        streams[localID] = stream
        stateLock.unlock()

        try send(.open, localID, 0, Data(service.utf8) + Data([0]))
        guard stream.waitUntilOpen(timeout: timeout) else {
            forget(localID)
            if stream.isClosed { throw ADBError.serviceUnavailable(service) }
            throw ADBError.timeout(L10n.format("opening %@", service))
        }
        return stream
    }

    /// Run a command and return everything it prints (stdout and stderr together).
    func exec(_ command: String, timeout: TimeInterval = 60) throws -> Data {
        let stream = try openStream("exec:\(command)")
        defer { stream.close() }
        return try stream.readToEnd(timeout: timeout)
    }

    func execString(_ command: String, timeout: TimeInterval = 60) throws -> String {
        String(decoding: try exec(command, timeout: timeout), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Run a command, feed `input` to its stdin, and return its output.
    func exec(_ command: String, input: Data, timeout: TimeInterval = 300) throws -> String {
        let stream = try openStream("exec:\(command)")
        defer { stream.close() }
        try stream.write(input)
        let output = try stream.readToEnd(timeout: timeout)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stream a file to a command's stdin without loading it all into memory.
    func exec(_ command: String, inputFile: URL, timeout: TimeInterval = 600,
              progress: ((Double) -> Void)? = nil) throws -> String {
        let stream = try openStream("exec:\(command)")
        defer { stream.close() }
        let handle = try FileHandle(forReadingFrom: inputFile)
        defer { try? handle.close() }
        let total = Double((try? FileManager.default.attributesOfItem(atPath: inputFile.path)[.size] as? NSNumber)?.int64Value ?? 1)
        var sent = 0.0
        while true {
            let chunk = try handle.read(upToCount: maxPayload) ?? Data()
            if chunk.isEmpty { break }
            try stream.write(chunk)
            sent += Double(chunk.count)
            progress?(min(sent / max(total, 1), 1))
        }
        let output = try stream.readToEnd(timeout: timeout)
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var maxPayload: Int { min(remoteMaxData, Int(Self.localMaxData)) }

    // MARK: Internal (used by ADBStream)

    func send(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) throws {
        var header = Data(capacity: 24)
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        put(command.rawValue)
        put(arg0)
        put(arg1)
        put(UInt32(payload.count))
        put(payload.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        put(command.rawValue ^ 0xffff_ffff)

        writeLock.lock()
        defer { writeLock.unlock() }
        let socket = fd
        guard socket >= 0 else { throw ADBError.closed }
        try Self.writeAll(socket, header)
        if !payload.isEmpty { try Self.writeAll(socket, payload) }
    }

    func forget(_ localID: UInt32) {
        stateLock.lock()
        streams.removeValue(forKey: localID)
        stateLock.unlock()
    }

    // MARK: Reader

    private func startReader() {
        let thread = Thread { [weak self] in
            while let self, self.isConnected {
                do {
                    let message = try self.readMessage()
                    self.dispatch(message)
                } catch {
                    self.close()
                    self.onClose?()
                    return
                }
            }
        }
        thread.name = "ADB reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func dispatch(_ message: Message) {
        // For messages from the device, arg0 is its (remote) id and arg1 is our local id.
        stateLock.lock()
        let stream = streams[message.arg1]
        stateLock.unlock()

        switch Command(rawValue: message.command) {
        case .okay:
            stream?.receivedOkay(remoteID: message.arg0)
        case .wrte:
            guard let stream else {
                // Unknown stream: tell the device to close it.
                try? send(.clse, 0, message.arg0)
                return
            }
            stream.receivedData(message.payload)
            try? send(.okay, stream.localID, message.arg0)
        case .clse:
            if let stream {
                forget(stream.localID)
                stream.remoteClosed()
            }
        default:
            break
        }
    }

    private func readMessage() throws -> Message {
        let header = try readExactly(24)
        func word(_ i: Int) -> UInt32 {
            header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        }
        let command = word(0)
        guard word(5) == command ^ 0xffff_ffff else { throw ADBError.protocolError(L10n.text("bad magic")) }
        let length = Int(word(3))
        guard length <= 16 * 1024 * 1024 else { throw ADBError.protocolError(L10n.text("oversized message")) }
        let payload = length > 0 ? try readExactly(length) : Data()
        return Message(command: command, arg0: word(1), arg1: word(2), payload: payload)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let socket = fd
            guard socket >= 0 else { throw ADBError.closed }
            let n = data.withUnsafeMutableBytes { buffer in
                recv(socket, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if n > 0 {
                offset += n
            } else if n == 0 {
                throw ADBError.closed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ADBError.timeout(L10n.text("read"))
            } else {
                throw ADBError.closed
            }
        }
        return data
    }

    private func setReceiveTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Sockets

    private static func openSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ADBError.connect(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            Darwin.close(socket)
            throw ADBError.connect(L10n.format("bad address %@", host))
        }

        // Non-blocking connect so a dead port fails fast.
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 && errno != EINPROGRESS {
            let reason = String(cString: strerror(errno))
            Darwin.close(socket)
            throw ADBError.connect(reason)
        }
        if result != 0 {
            var pfd = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length)
            if ready <= 0 || error != 0 {
                Darwin.close(socket)
                throw ADBError.connect(ready <= 0 ? L10n.text("timed out") : String(cString: strerror(error)))
            }
        }
        _ = fcntl(socket, F_SETFL, flags & ~O_NONBLOCK)
        return socket
    }

    private static func writeAll(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    throw ADBError.closed
                }
            }
        }
    }
}

/// One ADB stream: a service on the Android side.
final class ADBStream: @unchecked Sendable {
    let localID: UInt32
    let service: String
    private weak var connection: ADBConnection?
    private let condition = NSCondition()
    private var remoteID: UInt32 = 0
    private var buffer = Data()
    private var opened = false
    private var writeAcknowledged = true
    private(set) var isClosed = false

    init(connection: ADBConnection, localID: UInt32, service: String) {
        self.connection = connection
        self.localID = localID
        self.service = service
    }

    // MARK: Writing

    /// Send data, split to the negotiated payload size, waiting for each OKAY.
    func write(_ data: Data) throws {
        guard let connection else { throw ADBError.closed }
        var offset = 0
        let chunkSize = connection.maxPayload
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))

            condition.lock()
            while !writeAcknowledged && !isClosed { condition.wait() }
            if isClosed { condition.unlock(); throw ADBError.closed }
            writeAcknowledged = false
            let remote = remoteID
            condition.unlock()

            try connection.send(.wrte, localID, remote, chunk)
            offset = end
        }
    }

    // MARK: Reading

    /// Up to `maxLength` bytes; nil once the stream has closed and the buffer is empty.
    func read(maxLength: Int = 64 * 1024, timeout: TimeInterval? = nil) throws -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while buffer.isEmpty && !isClosed {
            if let deadline {
                if !condition.wait(until: deadline) { throw ADBError.timeout(service) }
            } else {
                condition.wait()
            }
        }
        if buffer.isEmpty { return nil }
        let count = min(maxLength, buffer.count)
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    func readExactly(_ count: Int, timeout: TimeInterval? = nil) throws -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            guard let chunk = try read(maxLength: count - out.count, timeout: timeout) else { throw ADBError.closed }
            out.append(chunk)
        }
        return out
    }

    func readToEnd(timeout: TimeInterval? = nil) throws -> Data {
        var out = Data()
        while let chunk = try read(maxLength: 1 << 20, timeout: timeout) {
            out.append(chunk)
        }
        return out
    }

    func close() {
        condition.lock()
        let wasClosed = isClosed
        isClosed = true
        let remote = remoteID
        condition.broadcast()
        condition.unlock()
        guard !wasClosed, let connection else { return }
        connection.forget(localID)
        if remote != 0 { try? connection.send(.clse, localID, remote) }
    }

    // MARK: Events from the reader thread

    func waitUntilOpen(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !opened && !isClosed {
            if !condition.wait(until: deadline) { return false }
        }
        return opened
    }

    func receivedOkay(remoteID: UInt32) {
        condition.lock()
        if !opened {
            opened = true
            self.remoteID = remoteID
        } else {
            writeAcknowledged = true
        }
        condition.broadcast()
        condition.unlock()
    }

    func receivedData(_ data: Data) {
        condition.lock()
        buffer.append(data)
        condition.broadcast()
        condition.unlock()
    }

    func remoteClosed() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }
}
