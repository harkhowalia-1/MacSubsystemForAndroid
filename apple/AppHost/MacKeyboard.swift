// Mac Android Subsystem - typing through the bridge's keyboard (MacInputMethod.java).
//
// scrcpy's text injection only carries characters Android's virtual key map has,
// so Persian, Russian or Chinese never arrived. The bridge's input method commits
// text itself. While an editor on this window's display has input, text, composing
// text and editing keys go to it over the abstract socket "msa_ime"; the rest
// (keys for games and lists, text with no editor) still goes through scrcpy.
//
// Licensed under the GNU General Public License v3 or later.

import Foundation

final class MacKeyboard: @unchecked Sendable {
    static var inputMethod: String { "\(AppConfig.bridgePackage)/.MacInputMethod" }

    /// Make the bridge's keyboard Android's input method, or, when Android's own on-screen
    /// keyboard is wanted, give that back. True when the bridge's keyboard is the input
    /// method afterwards (a bridge older than version 2 has none).
    static func select(_ connection: ADBConnection, onScreenKeyboard: Bool) -> Bool {
        let current = (try? connection.execString("settings get secure default_input_method", timeout: 5))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if onScreenKeyboard {
            if current == inputMethod { _ = try? connection.exec("ime reset", timeout: 5) }
            return false
        }
        if current == inputMethod { return true }
        _ = try? connection.exec("ime enable \(inputMethod)", timeout: 5)
        let output = (try? connection.execString("ime set \(inputMethod)", timeout: 5)) ?? ""
        return output.contains("selected")
    }

    private weak var connection: ADBConnection?
    private let display: Int
    private let queue = DispatchQueue(label: "msa.keyboard")
    private let lock = NSLock()
    private var stream: ADBStream?
    private var editing = false
    private var closed = false

    /// True while an editor on this window's display has input.
    var isEditing: Bool {
        lock.lock(); defer { lock.unlock() }
        return editing
    }

    /// Android starts the input method once an app needs it, and may restart it, so the
    /// link keeps reconnecting until the window closes.
    init(connection: ADBConnection, display: Int) {
        self.connection = connection
        self.display = display
        let thread = Thread { [weak self] in
            var delay: TimeInterval = 0.25
            while let self, !self.isClosed, let connection = self.connection {
                if let stream = try? connection.openStream("localabstract:msa_ime", timeout: 5) {
                    self.run(stream)
                    delay = 0.25
                }
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 4)
            }
        }
        thread.name = "msa keyboard"
        thread.start()
    }

    func close() {
        lock.lock()
        closed = true
        let current = stream
        lock.unlock()
        current?.close()
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Say which display this window is, then follow "editing" messages
    /// (displayId:i32 active:u8) until the stream ends.
    private func run(_ stream: ADBStream) {
        lock.lock()
        if closed { lock.unlock(); stream.close(); return }
        self.stream = stream
        lock.unlock()
        var hello = ScrcpySession.Message(1)
        hello.i32(Int32(display))
        send(hello)
        while let type = try? stream.readExactly(1)[0], type == 1,
              let body = try? stream.readExactly(5) {
            guard Int(Int32(bitPattern: body.be32(0))) == display else { continue }
            lock.lock()
            editing = body[body.startIndex + 4] != 0
            lock.unlock()
        }
        stream.close()
        lock.lock()
        self.stream = nil
        editing = false
        lock.unlock()
    }

    func commit(_ text: String) {
        var m = ScrcpySession.Message(2)
        m.string(text, lengthBytes: 4)
        send(m)
    }

    /// The composing text so far (shown underlined); commit replaces it.
    func compose(_ text: String) {
        var m = ScrcpySession.Message(3)
        m.string(text, lengthBytes: 4)
        send(m)
    }

    /// Keep the composing text as typed.
    func finishComposing() {
        send(ScrcpySession.Message(4))
    }

    func key(_ action: ScrcpySession.KeyAction, keycode: Int32, metaState: Int32, repeat count: Int32) {
        var m = ScrcpySession.Message(5)
        m.u8(action.rawValue); m.i32(keycode); m.i32(metaState); m.i32(count)
        send(m)
    }

    private func send(_ message: ScrcpySession.Message) {
        lock.lock()
        let current = stream
        lock.unlock()
        guard let current else { return }
        queue.async {
            try? current.write(message.data)
        }
    }
}
