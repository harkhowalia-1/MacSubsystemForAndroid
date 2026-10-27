// Mac Android Subsystem - the view that shows one Android app's virtual display
// and turns Mac input into Android input.
//
// Mouse: left button = finger touch (scrcpy maps the "mouse" pointer with only the
// primary button to a touchscreen event), right button = mouse secondary click,
// trackpad and wheel = scroll, hover = mouse hover, trackpad pinch and rotation =
// two fingers around the pointer.
// Keyboard: text goes as text, everything else as keycodes (AndroidKeys).
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import AVFoundation

final class AndroidDisplayView: NSView {
    weak var session: ScrcpySession?
    /// Size of the Android frame in pixels; input coordinates are scaled to it.
    var frameSize = CGSize(width: 1, height: 1)
    /// Called when the view's pixel size settles after a resize.
    var onPixelSizeChange: ((Int, Int) -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private var trackingArea: NSTrackingArea?
    private var buttons: UInt32 = 0
    private var fingers: TwoFingers?
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
        androidPoint(inWindow: event.locationInWindow)
    }

    private func androidPoint(inWindow location: NSPoint) -> (Int, Int)? {
        let point = convert(location, from: nil)
        let video = AVMakeRect(aspectRatio: frameSize, insideRect: bounds)
        guard video.width > 0, video.height > 0 else { return nil }
        let x = (point.x - video.minX) / video.width * frameSize.width
        let y = (point.y - video.minY) / video.height * frameSize.height
        return (Int(max(0, min(frameSize.width - 1, x))), Int(max(0, min(frameSize.height - 1, y))))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
        guard buttons == 0, fingers == nil, let (x, y) = androidPoint(event) else { return }
        session?.injectTouch(.hoverMove, x: x, y: y, pressure: 0)
    }

    override func scrollWheel(with event: NSEvent) {
        guard fingers == nil, let (x, y) = androidPoint(event) else { return }
        // Trackpads report precise point deltas; wheels report lines.
        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
        let h = Float(event.scrollingDeltaX / divisor)
        let v = Float(event.scrollingDeltaY / divisor)
        guard h != 0 || v != 0 else { return }
        session?.injectScroll(x: x, y: y, hScroll: h, vScroll: v)
    }

    // MARK: Trackpad gestures

    /// A pinch or rotation on the trackpad, as two fingers on either side of the
    /// point where it started. macOS sends magnify and rotate as separate events,
    /// often interleaved in one gesture, so the fingers stay down until both end.
    private struct TwoFingers {
        enum Gesture { case magnify, rotate }
        /// Android pixels: about a fingertip apart.
        static let closest: CGFloat = 48

        var center: CGPoint  // Android pixels
        var span: CGFloat    // distance between the fingers, Android pixels
        var angle: CGFloat = 0  // radians, clockwise on the screen
        var active: Set<Gesture> = []

        /// Both fingers' positions, kept inside the frame.
        func points(in size: CGSize) -> [(x: Int, y: Int)] {
            let dx = cos(angle) * span / 2, dy = sin(angle) * span / 2
            return [CGPoint(x: center.x - dx, y: center.y - dy), CGPoint(x: center.x + dx, y: center.y + dy)].map {
                (Int(max(0, min(size.width - 1, $0.x))), Int(max(0, min(size.height - 1, $0.y))))
            }
        }
    }

    override func magnify(with event: NSEvent) {
        let factor = 1 + event.magnification
        twoFingerGesture(.magnify, phase: event.phase, location: event.locationInWindow) { fingers in
            // Never closer than a fingertip, never wider than the display.
            let diagonal = hypot(frameSize.width, frameSize.height)
            fingers.span = max(TwoFingers.closest, min(diagonal, fingers.span * factor))
        }
    }

    override func rotate(with event: NSEvent) {
        // Degrees, counterclockwise; Android's y axis points down.
        let radians = -CGFloat(event.rotation) * .pi / 180
        twoFingerGesture(.rotate, phase: event.phase, location: event.locationInWindow) { fingers in
            fingers.angle += radians
        }
    }

    private func twoFingerGesture(_ gesture: TwoFingers.Gesture, phase: NSEvent.Phase, location: NSPoint,
                                  update: (inout TwoFingers) -> Void) {
        if phase.contains(.began) {
            if fingers == nil {
                // A click in progress keeps the mouse pointer; it can't also be a finger.
                guard buttons == 0, let (x, y) = androidPoint(inWindow: location) else { return }
                // About a thumb and finger apart on a phone.
                let span = min(frameSize.width, frameSize.height) / 4
                fingers = TwoFingers(center: CGPoint(x: x, y: y), span: max(TwoFingers.closest, span))
                sendFingers(.down)
            }
            fingers?.active.insert(gesture)
        }
        guard fingers?.active.contains(gesture) == true else { return }
        if phase.contains(.changed) {
            update(&fingers!)
            sendFingers(.move)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            fingers?.active.remove(gesture)
            if fingers?.active.isEmpty == true {
                sendFingers(.up)
                fingers = nil
            }
        }
    }

    /// Down in order, up in reverse, so Android sees one finger and then two.
    private func sendFingers(_ action: ScrcpySession.TouchAction) {
        guard let fingers else { return }
        let points = fingers.points(in: frameSize)
        var touches = [(ScrcpySession.pointerFinger, points[0]), (ScrcpySession.pointerVirtualFinger, points[1])]
        if action == .up { touches.reverse() }
        for (pointer, point) in touches {
            session?.injectTouch(action, x: point.x, y: point.y, pointer: pointer)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if let text = AndroidKeys.text(for: event) {
            session?.injectText(text)
            return
        }
        guard let code = AndroidKeys.keycodes[Int(event.keyCode)] else { return }
        session?.injectKey(.down, keycode: code, repeat: event.isARepeat ? 1 : 0,
                           metaState: AndroidKeys.metaState(event.modifierFlags))
    }

    override func keyUp(with event: NSEvent) {
        if AndroidKeys.text(for: event) != nil { return }
        guard let code = AndroidKeys.keycodes[Int(event.keyCode)] else { return }
        session?.injectKey(.up, keycode: code, metaState: AndroidKeys.metaState(event.modifierFlags))
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
