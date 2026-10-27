// Mac Android Subsystem - the view that shows one Android app's virtual display
// and turns Mac input into Android input.
//
// Mouse: left button = finger touch (scrcpy maps the "mouse" pointer with only the
// primary button to a touchscreen event), right button = mouse secondary click,
// trackpad and wheel = scroll, hover = mouse hover.
// Keyboard: the Mac's input methods (any layout, dead keys, Pinyin, Kana) give text
// and composing text through NSTextInputClient; it goes to the bridge's keyboard
// while an editor has input (MacKeyboard), as scrcpy text otherwise. Everything
// else goes as keycodes (AndroidKeys).
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import AVFoundation

final class AndroidDisplayView: NSView {
    weak var session: ScrcpySession?
    /// The bridge's keyboard, when Android uses it.
    var keyboard: MacKeyboard?
    /// Size of the Android frame in pixels; input coordinates are scaled to it.
    var frameSize = CGSize(width: 1, height: 1)
    /// Called when the view's pixel size settles after a resize.
    var onPixelSizeChange: ((Int, Int) -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?
    private var buttons: UInt32 = 0
    /// Keys whose down went to Android as keycodes, and whether through the keyboard.
    private var keysDown: [UInt16: Bool] = [:]
    /// The key interpretKeyEvents is working on, for doCommand(by:).
    private var keyEvent: NSEvent?
    private var markedText = ""
    /// Where the last click landed (view coordinates): the input method's candidates go there.
    private var lastClick: NSPoint?
    private var resizeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Video

    func enqueue(_ sample: CMSampleBuffer) {
        if #available(macOS 15.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
                session?.resetVideo()
            }
            renderer.enqueue(sample)
        } else {
            if displayLayer.status == .failed {
                displayLayer.flush()
                session?.resetVideo()
            }
            displayLayer.enqueue(sample)
        }
    }

    func flushVideo() {
        if #available(macOS 15.0, *) {
            displayLayer.sampleBufferRenderer.flush()
        } else {
            displayLayer.flush()
        }
    }

    // MARK: Size

    var pixelSize: (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? 2
        return (Int((bounds.width * scale).rounded()), Int((bounds.height * scale).rounded()))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        // Debounce: the virtual display is resized once the window stops moving for a moment.
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = self.pixelSize
            self.onPixelSizeChange?(size.width, size.height)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Map a point in the view to Android pixels, honouring the aspect-fit letterbox.
    private func androidPoint(_ event: NSEvent) -> (Int, Int)? {
        let point = convert(event.locationInWindow, from: nil)
        let video = AVMakeRect(aspectRatio: frameSize, insideRect: bounds)
        guard video.width > 0, video.height > 0 else { return nil }
        let x = (point.x - video.minX) / video.width * frameSize.width
        let y = (point.y - video.minY) / video.height * frameSize.height
        return (Int(max(0, min(frameSize.width - 1, x))), Int(max(0, min(frameSize.height - 1, y))))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastClick = convert(event.locationInWindow, from: nil)
        guard let (x, y) = androidPoint(event) else { return }
        buttons |= ScrcpySession.buttonPrimary
        session?.injectTouch(.down, x: x, y: y, actionButton: ScrcpySession.buttonPrimary, buttons: buttons)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (x, y) = androidPoint(event) else { return }
        session?.injectTouch(.move, x: x, y: y, buttons: buttons)
    }

    override func mouseUp(with event: NSEvent) {
        guard let (x, y) = androidPoint(event) else { return }
        buttons &= ~ScrcpySession.buttonPrimary
        session?.injectTouch(.up, x: x, y: y, actionButton: ScrcpySession.buttonPrimary, buttons: buttons)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let (x, y) = androidPoint(event) else { return }
        buttons |= ScrcpySession.buttonSecondary
        session?.injectTouch(.down, x: x, y: y, actionButton: ScrcpySession.buttonSecondary, buttons: buttons)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let (x, y) = androidPoint(event) else { return }
        buttons &= ~ScrcpySession.buttonSecondary
        session?.injectTouch(.up, x: x, y: y, actionButton: ScrcpySession.buttonSecondary, buttons: buttons)
    }

    override func mouseMoved(with event: NSEvent) {
        guard buttons == 0, let (x, y) = androidPoint(event) else { return }
        session?.injectTouch(.hoverMove, x: x, y: y, pressure: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = androidPoint(event) else { return }
        // Trackpads report precise point deltas; wheels report lines.
        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        let h = Float(event.scrollingDeltaX / divisor)
        let v = Float(event.scrollingDeltaY / divisor)
        guard h != 0 || v != 0 else { return }
        session?.injectScroll(x: x, y: y, hScroll: h, vScroll: v)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shortcuts, and arrows or function keys outside a composition, are keys, never text.
        if flags.contains(.control) || flags.contains(.command) || (flags.contains(.function) && markedText.isEmpty) {
            sendKey(event, .down)
            return
        }
        // Text and editing commands come back through NSTextInputClient below.
        keyEvent = event
        interpretKeyEvents([event])
        keyEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        guard let throughKeyboard = keysDown.removeValue(forKey: event.keyCode) else { return }
        sendKey(event, .up, throughKeyboard: throughKeyboard)
    }

    /// A key as an Android keycode: through the bridge's keyboard while an editor has input,
    /// so it stays in order with the text, otherwise through scrcpy. A key goes up the way it went down.
    private func sendKey(_ event: NSEvent, _ action: ScrcpySession.KeyAction, throughKeyboard: Bool? = nil) {
        guard let code = AndroidKeys.keycodes[Int(event.keyCode)] else { return }
        let meta = AndroidKeys.metaState(event.modifierFlags)
        let count: Int32 = action == .down && event.isARepeat ? 1 : 0
        let viaKeyboard = throughKeyboard ?? (keyboard?.isEditing == true)
        if action == .down { keysDown[event.keyCode] = viaKeyboard }
        if viaKeyboard, let keyboard {
            keyboard.key(action, keycode: code, metaState: meta, repeat: count)
        } else {
            session?.injectKey(action, keycode: code, repeat: count, metaState: meta)
        }
    }

    override func resignFirstResponder() -> Bool {
        // Keep what is being composed, as typed.
        inputContext?.discardMarkedText()
        unmarkText()
        return super.resignFirstResponder()
    }

    /// Control-key shortcuts reach keyDown; Command shortcuts are menu items (Edit menu).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command), window?.firstResponder === self {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Text input

extension AndroidDisplayView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        if let keyboard, keyboard.isEditing {
            keyboard.commit(text)  // replaces the composing text
        } else {
            session?.injectText(text)
        }
    }

    /// Return, Delete, Tab, Escape and the like: the key itself.
    override func doCommand(by selector: Selector) {
        if let keyEvent { sendKey(keyEvent, .down) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if let keyboard, keyboard.isEditing { keyboard.compose(markedText) }
    }

    func unmarkText() {
        guard !markedText.isEmpty else { return }
        markedText = ""
        if let keyboard, keyboard.isEditing { keyboard.finishComposing() }
    }

    func selectedRange() -> NSRange {
        NSRange(location: (markedText as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Android doesn't tell us where its caret is; the last click is usually next to it.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let point = lastClick ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let rect = NSRect(x: point.x, y: point.y - 10, width: 1, height: 20)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}
