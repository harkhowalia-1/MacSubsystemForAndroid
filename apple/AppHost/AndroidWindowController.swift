// Mac Android Subsystem - one Mac window for one Android app.
//
// Each launcher in ~/Applications/Android Apps runs its own copy of this host,
// so every Android app has its own Dock icon, ⌘-Tab entry and menu bar.
//
// Flow: splash ("Starting Android…") -> wait for the Subsystem -> connect ADB ->
// start a scrcpy virtual display sized to the window -> launch the app in it.
// Resizing the window resizes the virtual display (scrcpy's flex display).
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import AVFoundation

@MainActor
final class AndroidWindowController: NSWindowController, NSWindowDelegate {
    let app: AndroidApp
    let icon: NSImage?
    private let displayView = AndroidDisplayView(frame: NSRect(x: 0, y: 0, width: 400, height: 780))
    private let overlay = SplashOverlay()
    private var connection: ADBConnection?
    private var session: ScrcpySession?
    private var keyboard: MacKeyboard?
    private let builder = H264SampleBuilder()
    private var lastSentSize = (0, 0)
    private var isClosing = false
    private let gamepads = GamepadBridge()
    /// Keeps macOS from throttling this window while in the Performance or Game level.
    private var activity: NSObjectProtocol?
    /// Follows the orientation the app asks for (issue #2).
    private var orientationWatch: Task<Void, Never>?
    private var lastRequestedLandscape: Bool?

    init(app: AndroidApp, icon: NSImage?) {
        self.app = app
        self.icon = icon
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = app.label
        window.minSize = NSSize(width: 260, height: 300)
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AndroidApp.\(app.package)")
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self

        let container = NSView()
        container.wantsLayer = true
        displayView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(displayView)
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        addBackButton(to: window)
        overlay.show(icon: icon, title: app.label, message: "Starting Android…", busy: true)

        displayView.onPixelSizeChange = { [weak self] width, height in
            self?.resizeDisplay(width: width, height: height)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Lifecycle

    func start() {
        overlay.show(icon: icon, title: app.label, message: "Starting Android…", busy: true)
        overlay.onRetry = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await SubsystemLink.waitUntilRunning(package: self.app.package) { [weak self] message in
                    guard let self else { return }
                    self.overlay.show(icon: self.icon, title: self.app.label, message: message, busy: true)
                }
                self.overlay.show(icon: self.icon, title: self.app.label, message: "Opening \(self.app.label)…", busy: true)
                let size = self.displayView.pixelSize
                let dpi = self.densityDPI()
                let package = self.app.package
                let level = status.level ?? .balanced
                let screenFPS = self.window?.screen?.maximumFramesPerSecond ?? 60
                self.beginActivity(for: level)
                let session = try await Task.detached(priority: .userInitiated) {
                    try Self.connect(port: status.adbPort, package: package, width: size.width, height: size.height,
                                     dpi: dpi, level: level, screenFPS: screenFPS)
                }.value
                self.attach(session.0, session.1)
            } catch {
                self.showError(error)
            }
        }
    }

    /// Connect to adbd, make sure the scrcpy server is in place and start the virtual display.
    nonisolated private static func connect(port: UInt16, package: String, width: Int, height: Int,
                                            dpi: Int, level: PerformanceLevel, screenFPS: Int) throws -> (ADBConnection, ScrcpySession) {
        let connection = ADBConnection(port: port, key: try? ADBKey.shared())
        try connection.connect(timeout: 5, authorizationTimeout: 60)
        var configuration = ScrcpySession.Configuration(package: package, width: max(width, 320),
                                                        height: max(height, 320), dpi: dpi)
        configuration.showSoftKeyboard = UserDefaults(suiteName: AppConfig.subsystemBundleID)?
            .bool(forKey: "showSoftKeyboard") ?? false
        configuration.macKeyboard = MacKeyboard.select(connection, onScreenKeyboard: configuration.showSoftKeyboard)
        // The performance level sets how smooth (and how costly) the stream is.
        configuration.maxFPS = min(level.maxFPS, max(screenFPS, 30))
        configuration.bitRate = level.videoBitRate
        if level.latencyCritical {
            // Ask Android's game manager for its performance mode (games that support it).
            _ = try? connection.exec("cmd game mode performance \(package)", timeout: 5)
        }
        try ensureServer(connection, at: configuration.serverPath)
        let session = ScrcpySession(connection: connection, configuration: configuration)
        return (connection, session)
    }

    /// The Subsystem pushes the server after boot; push it here too if it is missing.
    nonisolated private static func ensureServer(_ connection: ADBConnection, at path: String) throws {
        guard let local = SubsystemLink.scrcpyServerURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.uint32Value
        else { return }
        let remote = try? connection.stat(path)
        if remote?.size != size {
            try connection.push(local, to: path)
        }
    }

    private func attach(_ connection: ADBConnection, _ session: ScrcpySession) {
        self.connection = connection
        self.session = session
        displayView.session = session

        session.onVideoSize = { [weak self] width, height in
            DispatchQueue.main.async {
                self?.displayView.frameSize = CGSize(width: width, height: height)
            }
        }
        session.onVideoPacket = { [weak self] data, isConfig, _, pts in
            guard let self else { return }
            if isConfig {
                let changed = self.builder.handleConfig(data)
                if changed { DispatchQueue.main.async { self.displayView.flushVideo() } }
                return
            }
            guard let sample = self.builder.sampleBuffer(for: data, pts: pts) else { return }
            DispatchQueue.main.async {
                self.displayView.enqueue(sample)
                self.overlay.hide()
            }
        }
        session.onClipboard = { text in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        session.onClose = { [weak self] error in
            DispatchQueue.main.async { self?.sessionEnded(error) }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try session.start()
                // Without it typing still works, as scrcpy text (characters Android's key map has).
                let keyboard = session.usesMacKeyboard
                    ? session.displayID.map { MacKeyboard(connection: connection, display: $0) } : nil
                await MainActor.run { [weak self] in
                    guard let self else { keyboard?.close(); return }
                    self.keyboard = keyboard
                    self.displayView.keyboard = keyboard
                    self.lastSentSize = self.displayView.pixelSize
                    self.window?.makeFirstResponder(self.displayView)
                    self.gamepads.session = session
                    if self.window?.isKeyWindow == true { self.gamepads.activate() }
                    self.watchOrientation()
                }
            } catch {
                await MainActor.run { [weak self] in self?.showError(error) }
            }
        }
    }

    private func sessionEnded(_ error: Error?) {
        guard !isClosing else { return }
        orientationWatch?.cancel()
        gamepads.session = nil
        displayView.keyboard = nil
        keyboard?.close()
        keyboard = nil
        session = nil
        connection?.close()
        connection = nil
        overlay.show(icon: icon, title: app.label,
                     message: "\(app.label) stopped. Android may have shut down.", busy: false)
        overlay.onRetry = { [weak self] in self?.start() }
    }

    private func showError(_ error: Error) {
        overlay.show(icon: icon, title: app.label, message: error.localizedDescription, busy: false)
        overlay.onRetry = { [weak self] in self?.start() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        gamepads.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        gamepads.deactivate()
    }

    private func beginActivity(for level: PerformanceLevel) {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if level.latencyCritical {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                            reason: "Streaming an Android app")
        }
    }

    func windowWillClose(_ notification: Notification) {
        gamepads.deactivate()
        isClosing = true
        orientationWatch?.cancel()
        keyboard?.close()
        session?.stop()
        connection?.close()
        NSApp.terminate(nil)
    }

    // MARK: Display size

    private func resizeDisplay(width: Int, height: Int) {
        guard let session, width > 0, height > 0, (width, height) != lastSentSize else { return }
        lastSentSize = (width, height)
        session.resizeDisplay(width: width, height: height)
    }

    /// 160 dpi = 1 dp per pixel. With Retina scale 2 and density 1.0 this makes one
    /// Android dp the size of one Mac point.
    private func densityDPI() -> Int {
        let scale = window?.backingScaleFactor ?? 2
        let stored = UserDefaults(suiteName: AppConfig.subsystemBundleID)?.double(forKey: "displayDensity") ?? 0
        let factor = stored > 0 ? stored : 1.0
        return Int((160 * scale * factor).rounded())
    }

    // MARK: Orientation

    /// Games and other apps that lock themselves to landscape (or portrait) get a window
    /// of that shape: Android reports what the app asks for, and the window turns when
    /// that changes. A shape chosen by hand stays until the app asks for another.
    private func watchOrientation() {
        orientationWatch?.cancel()
        lastRequestedLandscape = nil
        guard let connection else { return }
        let package = app.package
        orientationWatch = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let landscape = Self.requestedLandscape(package: package, connection: connection)
                await MainActor.run { [weak self] in self?.applyRequestedOrientation(landscape) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// true for a landscape request, false for portrait, nil when the app takes any shape.
    nonisolated private static func requestedLandscape(package: String, connection: ADBConnection) -> Bool? {
        guard package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }),
              let text = try? connection.execString(
                "dumpsys activity activities | grep -A60 ' u0 \(package)/' | grep -m1 'requestedOrientation='", timeout: 5)
        else { return nil }
        if text.contains("LANDSCAPE") { return true }
        if text.contains("PORTRAIT") { return false }
        return nil
    }

    private func applyRequestedOrientation(_ landscape: Bool?) {
        guard let landscape, landscape != lastRequestedLandscape else { return }
        lastRequestedLandscape = landscape
        let size = displayView.bounds.size
        guard size.width > 0, size.height > 0, (size.width > size.height) != landscape else { return }
        rotate()
    }

    /// Swap the window's width and height, keeping its centre and staying on screen.
    private func rotate() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let content = displayView.bounds.size
        let chrome = window.frame.height - displayView.bounds.height
        var frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: content.height, height: content.width + chrome)
        if let visible = window.screen?.visibleFrame {
            let scale = min(1, visible.width / frame.width, visible.height / frame.height)
            frame.size = NSSize(width: (frame.width * scale).rounded(),
                                height: ((frame.height - chrome) * scale + chrome).rounded())
            frame.origin = NSPoint(x: min(max(center.x - frame.width / 2, visible.minX), visible.maxX - frame.width),
                                   y: min(max(center.y - frame.height / 2, visible.minY), visible.maxY - frame.height))
        } else {
            frame.origin = NSPoint(x: center.x - frame.width / 2, y: center.y - frame.height / 2)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: Actions (menus and toolbar)

    @objc func rotateWindow(_ sender: Any?) {
        rotate()
    }

    @objc func goBack(_ sender: Any?) {
        session?.injectKey(.down, keycode: AndroidKeys.back)
        session?.injectKey(.up, keycode: AndroidKeys.back)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.setClipboard(text, paste: true)
    }

    @objc func copy(_ sender: Any?) { session?.requestCopy() }
    @objc func cut(_ sender: Any?) { session?.requestCopy(cut: true) }

    @objc override func selectAll(_ sender: Any?) {
        session?.injectKey(.down, keycode: 29, metaState: AndroidKeys.metaCtrl) // Ctrl+A
        session?.injectKey(.up, keycode: 29, metaState: AndroidKeys.metaCtrl)
    }

    @objc func undo(_ sender: Any?) {
        session?.injectKey(.down, keycode: 54, metaState: AndroidKeys.metaCtrl) // Ctrl+Z
        session?.injectKey(.up, keycode: 54, metaState: AndroidKeys.metaCtrl)
    }

    @objc func restartApp(_ sender: Any?) {
        session?.startApp("+\(app.package)") // "+" force-stops the app first
    }

    private func addBackButton(to window: NSWindow) {
        let button = NSButton(image: NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")!,
                              target: self, action: #selector(goBack(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = "Back (⌘[)"
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        button.frame = NSRect(x: 4, y: 2, width: 26, height: 24)
        holder.addSubview(button)
        accessory.view = holder
        window.addTitlebarAccessoryViewController(accessory)
    }
}

/// The "Starting…" screen shown over the window until the first frame arrives.
final class SplashOverlay: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .regular
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [iconView, titleLabel, spinner, messageLabel, retryButton])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 96),
            iconView.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(icon: NSImage?, title: String, message: String, busy: Bool) {
        isHidden = false
        alphaValue = 1
        iconView.image = icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        spinner.isHidden = !busy
        retryButton.isHidden = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.spinner.stopAnimation(nil)
        })
    }

    @objc private func retry() { onRetry?() }

    // Clicks on the splash must not reach the Android view below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
}
