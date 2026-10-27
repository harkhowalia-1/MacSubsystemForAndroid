// Mac Android Subsystem - one Android app in its own virtual display, streamed
// with the scrcpy server (scrcpy 5.0.1, Apache 2.0, bundled as scrcpy-server.jar).
//
// The server runs inside Android with app_process. In tunnel_forward mode it
// listens on the abstract socket scrcpy_<scid>; we reach that through adb's
// "localabstract:" service directly (no port forwarding). Socket order: video,
// then control (audio is off; Android's sound plays through the VM's own audio
// device instead).
//
// Video socket: dummy byte, device name (64 bytes), codec id (u32), then a stream of
//   session packets  [0x8000000x | width:u32 | height:u32]   (new size)
//   media packets    [pts+flags:u64 | size:u32] + Annex-B H.264
// all big-endian. Bit 62 of pts marks a config packet (SPS/PPS), bit 61 a key frame.
//
// Control messages (client -> server) and device messages (server -> client) follow
// server/src/main/java/com/genymobile/scrcpy/control/ControlMessageReader.java and
// DeviceMessageWriter.java. The protocol is internal to scrcpy and changes between
// versions, so the client is pinned to the bundled server's version.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

final class ScrcpySession: @unchecked Sendable {
    struct Configuration {
        var package: String
        var width: Int
        var height: Int
        var dpi: Int
        var maxFPS: Int = 60
        var bitRate: Int = 12_000_000
        var showSoftKeyboard = false
        var serverPath = "/data/local/tmp/msa-scrcpy-server.jar"
    }

    enum Failure: LocalizedError {
        case serverDidNotStart(String)
        case codec(UInt32)
        var errorDescription: String? {
            switch self {
            case .serverDidNotStart(let log): return "The app window couldn't start.\(log.isEmpty ? "" : "\n\n\(log)")"
            case .codec(let id): return String(format: "Unsupported video format 0x%08x.", id)
            }
        }
    }

    // Callbacks, called on the session's reader threads.
    var onVideoSize: ((Int, Int) -> Void)?
    var onVideoPacket: ((_ data: Data, _ isConfig: Bool, _ isKeyFrame: Bool, _ pts: UInt64) -> Void)?
    var onClipboard: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let connection: ADBConnection
    private let configuration: Configuration
    private var serverStream: ADBStream?
    private var videoStream: ADBStream?
    private var controlStream: ADBStream?
    private let controlQueue = DispatchQueue(label: "scrcpy.control")
    private var clipboardSequence: UInt64 = 1
    private var closed = false
    private let lock = NSLock()
    private var serverLog = ""

    private(set) var frameSize: (width: Int, height: Int) = (0, 0)

    init(connection: ADBConnection, configuration: Configuration) {
        self.connection = connection
        self.configuration = configuration
    }

    // MARK: Start / stop

    func start() throws {
        let scid = UInt32.random(in: 1..<0x7fff_ffff)
        let socketName = String(format: "scrcpy_%08x", scid)
        var arguments = [
            "scid=\(String(format: "%08x", scid))",
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "video_codec=h264",
            "new_display=\(configuration.width)x\(configuration.height)/\(configuration.dpi)",
            "flex_display=true",
            "vd_system_decorations=false",
            "keep_active=true",
            "clipboard_autosync=true",
            "max_fps=\(configuration.maxFPS)",
            "video_bit_rate=\(configuration.bitRate)",
            "cleanup=true",
            "power_on=true",
        ]
        arguments.append("display_ime_policy=\(configuration.showSoftKeyboard ? "local" : "hide")")
        let command = "CLASSPATH=\(configuration.serverPath) app_process / com.genymobile.scrcpy.Server "
            + "\(AppConfig.scrcpyVersion) " + arguments.joined(separator: " ")

        let server = try connection.openStream("exec:\(command)")
        serverStream = server
        drainServerOutput(server)

        // The server needs a moment to start listening.
        var video: ADBStream?
        let deadline = Date().addingTimeInterval(15)
        while video == nil {
            do {
                video = try connection.openStream("localabstract:\(socketName)", timeout: 3)
            } catch {
                if server.isClosed || Date() > deadline {
                    server.close()
                    throw Failure.serverDidNotStart(currentServerLog())
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        guard let video else { throw Failure.serverDidNotStart(currentServerLog()) }
        videoStream = video

        _ = try video.readExactly(1, timeout: 10)       // dummy byte
        // The server sends the device name only once every socket is connected.
        controlStream = try connection.openStream("localabstract:\(socketName)", timeout: 5)
        _ = try video.readExactly(64, timeout: 10)      // device name
        let codec = try video.readExactly(4, timeout: 30).be32(0)
        guard codec == 0x6832_3634 else { throw Failure.codec(codec) } // "h264"

        startVideoReader(video)
        if let control = controlStream { startDeviceMessageReader(control) }
        fillDisplay()
        startApp(configuration.package)
    }

    /// The image declares android.hardware.type.pc, so Android makes every display a
    /// freeform desktop and the app would open as a small window inside ours. Switch the
    /// virtual display to fullscreen before the app starts so its tasks fill it.
    private func fillDisplay() {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let id = virtualDisplayID() {
                _ = try? connection.exec("cmd window set-display-windowing-mode -d \(id) 1", timeout: 5)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The id from the server's "New display: 800x1496/320 (id=5)" log line.
    private func virtualDisplayID() -> Int? {
        let log = currentServerLog()
        guard let line = log.range(of: "New display:"),
              let open = log.range(of: "(id=", range: line.upperBound..<log.endIndex),
              let close = log[open.upperBound...].firstIndex(of: ")") else { return nil }
        return Int(log[open.upperBound..<close])
    }

    func stop() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        controlStream?.close()
        videoStream?.close()
        serverStream?.close()
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        controlStream?.close()
        videoStream?.close()
        serverStream?.close()
        if !wasClosed { onClose?(error) }
    }

    // MARK: Readers

    private func startVideoReader(_ stream: ADBStream) {
        let thread = Thread { [weak self] in
            do {
                while true {
                    let header = try stream.readExactly(12)
                    if header[header.startIndex] & 0x80 != 0 {
                        // Session packet: a new capture size.
                        let width = Int(header.be32(4))
                        let height = Int(header.be32(8))
                        self?.frameSize = (width, height)
                        self?.onVideoSize?(width, height)
                        continue
                    }
                    let ptsAndFlags = header.be64(0)
                    let size = Int(header.be32(8))
                    let payload = try stream.readExactly(size)
                    let isConfig = ptsAndFlags & (1 << 62) != 0
                    let isKey = ptsAndFlags & (1 << 61) != 0
                    let pts = ptsAndFlags & ((1 << 61) - 1)
                    self?.onVideoPacket?(payload, isConfig, isKey, pts)
                }
            } catch {
                self?.finish(error)
            }
        }
        thread.name = "scrcpy video"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func startDeviceMessageReader(_ stream: ADBStream) {
        let thread = Thread { [weak self] in
            do {
                while true {
                    let type = try stream.readExactly(1)[0]
                    switch type {
                    case 0: // clipboard
                        let length = Int(try stream.readExactly(4).be32(0))
                        let text = String(decoding: try stream.readExactly(length), as: UTF8.self)
                        self?.onClipboard?(text)
                    case 1: // ack clipboard
                        _ = try stream.readExactly(8)
                    case 2: // uhid output
                        _ = try stream.readExactly(2)
                        let length = Int(try stream.readExactly(2).be16(0))
                        _ = try stream.readExactly(length)
                    default:
                        throw ADBError.protocolError("device message \(type)")
                    }
                }
            } catch {
                self?.finish(error)
            }
        }
        thread.name = "scrcpy control"
        thread.start()
    }

    private func drainServerOutput(_ stream: ADBStream) {
        let thread = Thread { [weak self] in
            while let chunk = try? stream.read() {
                let text = String(decoding: chunk, as: UTF8.self)
                self?.lock.lock()
                self?.serverLog = String(((self?.serverLog ?? "") + text).suffix(4000))
                self?.lock.unlock()
            }
            // The server exited (for example Android shut down).
            self?.finish(nil)
        }
        thread.name = "scrcpy server log"
        thread.start()
    }

    private func currentServerLog() -> String {
        lock.lock(); defer { lock.unlock() }
        return serverLog.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Control messages

    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2, hoverMove = 7 }
    enum KeyAction: UInt8 { case down = 0, up = 1 }

    static let pointerMouse: UInt64 = 0xFFFF_FFFF_FFFF_FFFF  // -1
    /// scrcpy's own pinch uses these two: always touchscreen fingers, never a mouse.
    static let pointerFinger: UInt64 = 0xFFFF_FFFF_FFFF_FFFE  // -2
    static let pointerVirtualFinger: UInt64 = 0xFFFF_FFFF_FFFF_FFFD  // -3
    static let buttonPrimary: UInt32 = 1
    static let buttonSecondary: UInt32 = 2

    func injectKey(_ action: KeyAction, keycode: Int32, repeat count: Int32 = 0, metaState: Int32 = 0) {
        var m = Message(0)
        m.u8(action.rawValue); m.i32(keycode); m.i32(count); m.i32(metaState)
        send(m)
    }

    func injectText(_ text: String) {
        // The server accepts at most 300 bytes per message.
        var remaining = Substring(text)
        while !remaining.isEmpty {
            var piece = remaining.prefix(100)
            while piece.utf8.count > 300 { piece = piece.dropLast() }
            remaining = remaining.dropFirst(piece.count)
            var m = Message(1)
            m.string(String(piece), lengthBytes: 4)
            send(m)
        }
    }

    func injectTouch(_ action: TouchAction, x: Int, y: Int, pointer: UInt64 = ScrcpySession.pointerMouse,
                     pressure: Float = 1, actionButton: UInt32 = 0, buttons: UInt32 = 0) {
        let size = frameSize
        guard size.width > 0 else { return }
        var m = Message(2)
        m.u8(action.rawValue)
        m.u64(pointer)
        m.position(x: x, y: y, width: size.width, height: size.height)
        m.u16(pressure >= 1 ? 0xffff : UInt16(max(0, pressure) * 65536))
        m.u32(actionButton)
        m.u32(buttons)
        send(m)
    }

    /// hScroll/vScroll in Android scroll units (about one notch each), range -16...16.
    func injectScroll(x: Int, y: Int, hScroll: Float, vScroll: Float, buttons: UInt32 = 0) {
        let size = frameSize
        guard size.width > 0 else { return }
        func fixed(_ value: Float) -> Int16 {
            let clamped = max(-1, min(1, value / 16))
            return clamped >= 1 ? Int16.max : Int16(clamped * 32768)
        }
        var m = Message(3)
        m.position(x: x, y: y, width: size.width, height: size.height)
        m.i16(fixed(hScroll))
        m.i16(fixed(vScroll))
        m.u32(buttons)
        send(m)
    }

    /// Back key (or wakes the screen).
    func backOrScreenOn(_ action: KeyAction) {
        var m = Message(4)
        m.u8(action.rawValue)
        send(m)
    }

    /// Ask Android to copy (or cut) the selection; the text comes back through onClipboard.
    func requestCopy(cut: Bool = false) {
        var m = Message(8)
        m.u8(cut ? 2 : 1)
        send(m)
    }

    /// Put text on Android's clipboard, optionally pasting it.
    func setClipboard(_ text: String, paste: Bool) {
        var m = Message(9)
        lock.lock()
        let sequence = clipboardSequence
        clipboardSequence &+= 1
        lock.unlock()
        m.u64(sequence)
        m.u8(paste ? 1 : 0)
        m.string(text, lengthBytes: 4)
        send(m)
    }

    func startApp(_ name: String) {
        var m = Message(16)
        m.string(name, lengthBytes: 1)
        send(m)
    }

    /// Ask for a fresh key frame (after the decoder lost sync).
    func resetVideo() {
        send(Message(17))
    }

    /// Create a virtual HID device in Android (used for game controllers). The server
    /// ties UHID devices to this session's display, so a game in this window gets the input.
    func uhidCreate(id: UInt16, vendorID: UInt16, productID: UInt16, name: String, reportDescriptor: Data) {
        var m = Message(12)
        m.u16(id); m.u16(vendorID); m.u16(productID)
        m.string(name, lengthBytes: 1)
        m.u16(UInt16(reportDescriptor.count))
        m.data.append(reportDescriptor)
        send(m)
    }

    func uhidInput(id: UInt16, report: Data) {
        var m = Message(13)
        m.u16(id)
        m.u16(UInt16(report.count))
        m.data.append(report)
        send(m)
    }

    func uhidDestroy(id: UInt16) {
        var m = Message(14)
        m.u16(id)
        send(m)
    }

    /// Flex display: resize the virtual display to follow the window (pixels).
    func resizeDisplay(width: Int, height: Int) {
        var m = Message(21)
        m.u16(UInt16(clamping: width))
        m.u16(UInt16(clamping: height))
        send(m)
    }

    private func send(_ message: Message) {
        guard let stream = controlStream else { return }
        controlQueue.async {
            try? stream.write(message.data)
        }
    }

    /// Big-endian serializer for control messages.
    struct Message {
        var data: Data
        init(_ type: UInt8) { data = Data([type]) }
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { append(v.bigEndian) }
        mutating func i16(_ v: Int16) { append(v.bigEndian) }
        mutating func u32(_ v: UInt32) { append(v.bigEndian) }
        mutating func i32(_ v: Int32) { append(v.bigEndian) }
        mutating func u64(_ v: UInt64) { append(v.bigEndian) }
        mutating func position(x: Int, y: Int, width: Int, height: Int) {
            i32(Int32(clamping: x)); i32(Int32(clamping: y))
            u16(UInt16(clamping: width)); u16(UInt16(clamping: height))
        }
        mutating func string(_ s: String, lengthBytes: Int) {
            var bytes = Data(s.utf8)
            let limit = lengthBytes == 1 ? 255 : 256 * 1024 - 14
            if bytes.count > limit { bytes = bytes.prefix(limit) }
            let length = UInt32(bytes.count)
            for i in stride(from: lengthBytes - 1, through: 0, by: -1) {
                data.append(UInt8((length >> (8 * UInt32(i))) & 0xff))
            }
            data.append(bytes)
        }
        private mutating func append<T>(_ value: T) {
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
    }
}

extension Data {
    func be16(_ offset: Int) -> UInt16 {
        let s = startIndex + offset
        return UInt16(self[s]) << 8 | UInt16(self[s + 1])
    }
}
