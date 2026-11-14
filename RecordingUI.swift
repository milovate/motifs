import AppKit

// Floating pills for recording. `sharingType = .none` keeps them out of every
// capture, including window recordings that ScreenCaptureKit would otherwise composite.
@MainActor final class RecordingPanel: ComposerPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    static func pill(_ views: [NSView], activating: Bool) -> RecordingPanel {
        let panel = RecordingPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 48), styleMask: activating ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let surface = ComposerSurface(frame: panel.frame, radius: CornerRadius.pill)
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            row.topAnchor.constraint(equalTo: surface.topAnchor),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        panel.contentView = surface
        panel.setContentSize(row.fittingSize)
        return panel
    }

    func place(on screen: NSScreen?, nearTop: Bool) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: nearTop ? frame.maxY - self.frame.height - 12 : frame.minY + min(80, frame.height * 0.1)))
    }
}

// Timer, restart, pause and Stop while recording. The panel never takes focus
// from the app being recorded.
@MainActor final class RecordingControls: NSObject {
    let dot = NSTextField(labelWithString: "●")
    let time = NSTextField(labelWithString: "00:00")
    let restartButton = ComposerButton(symbol: "arrow.counterclockwise")
    let pauseButton = ComposerButton(symbol: "pause.fill")
    let stopButton = ComposerButton("Stop", symbol: "stop.fill", treatment: .primary)
    var onRestart: (() -> Void)?
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?
    private(set) var panel: RecordingPanel!

    override init() {
        super.init()
        dot.font = .systemFont(ofSize: 13)
        dot.textColor = .systemRed
        time.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        time.textColor = .labelColor
        time.setAccessibilityLabel("Recorded time")
        for (button, action, tip) in [(restartButton, #selector(restart), "Restart: discard this recording and start again"), (pauseButton, #selector(pause), "Pause recording"), (stopButton, #selector(stop), "Stop and attach the recording (⌥⇧G)")] {
            button.target = self
            button.action = action
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
        }
        panel = RecordingPanel.pill([dot, time, restartButton, pauseButton, stopButton], activating: false)
        panel.title = "Recording controls"
        panel.becomesKeyOnlyIfNeeded = true
    }

    static func format(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    func update(seconds: Double, paused: Bool, limit: Double) {
        let remaining = limit - seconds
        let ending = remaining <= 30
        time.stringValue = Self.format(seconds) + (ending ? " · \(Int(max(0, remaining)))s left" : "")
        time.textColor = ending ? .systemOrange : .labelColor
        dot.textColor = paused ? .secondaryLabelColor : .systemRed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            dot.animator().alphaValue = paused ? 1 : dot.alphaValue > 0.6 ? 0.35 : 1
        }
        pauseButton.symbolName = paused ? "play.fill" : "pause.fill"
        pauseButton.toolTip = paused ? "Resume recording" : "Pause recording"
        pauseButton.setAccessibilityLabel(pauseButton.toolTip ?? "")
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    func show(on screen: NSScreen?) {
        panel.place(on: screen, nearTop: true)
        panel.present { panel.orderFrontRegardless() }
    }

    func close() { panel.orderOut(nil); panel.close() }

    @objc func restart() { onRestart?() }
    @objc func pause() { onPause?() }
    @objc func stop() { onStop?() }
}

// A small circle above the capture overlay's hint that skips the capture and opens
// the composer instead. It is excluded from captures like the pills.
@MainActor final class ComposerBubble: NSObject {
    static let diameter: CGFloat = 44
    var onOpen: (() -> Void)?
    var onHide: (() -> Void)?
    let panel: RecordingPanel
    let button = BubbleView(frame: NSRect(x: 0, y: 0, width: ComposerBubble.diameter, height: ComposerBubble.diameter))

    override init() {
        panel = RecordingPanel(contentRect: button.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Motifs composer button"
        let surface = ComposerSurface(frame: button.frame, radius: Self.diameter / 2)
        button.autoresizingMask = [.width, .height]
        surface.addSubview(button)
        panel.contentView = surface
        button.onClick = { [weak self] in self?.onOpen?() }
        button.menu = NSMenu()
        for (title, action) in [("Open composer", #selector(open)), ("Hide floating button", #selector(hideFromMenu))] {
            button.menu?.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    // Centered at the bottom of the screen, `bottom` points up, e.g. just above the overlay hint.
    func show(on screen: NSScreen?, bottom: CGFloat) {
        guard let frame = (screen ?? NSScreen.main)?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + bottom))
        guard !panel.isVisible else { return }
        panel.present { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }

    @objc func open() { onOpen?() }
    @objc func hideFromMenu() { onHide?() }

    final class BubbleView: NSView {
        var onClick: (() -> Void)?
        private var pressed = false
        let icon = NSImageView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            if let artwork = Bundle.main.url(forResource: "Bubble", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                icon.image = artwork
                icon.imageScaling = .scaleAxesIndependently
            } else {
                icon.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
                icon.contentTintColor = .labelColor
            }
            icon.frame = bounds
            icon.autoresizingMask = [.width, .height]
            addSubview(icon)
            toolTip = "Skip the capture and open the composer, with Recents"
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Skip capture and open the composer")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

        override func mouseDown(with event: NSEvent) { pressed = true }

        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }

        override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    }
}

// A dashed outline just outside a recorded area, so the user sees what is captured.
@MainActor final class RecordingAreaOutline {
    let panel: NSPanel

    init(rect: CGRect, on screen: NSScreen) {
        // Region rects are top-left based within the screen; AppKit windows are bottom-left based.
        let frame = NSRect(x: screen.frame.minX + rect.minX - 3, y: screen.frame.maxY - rect.maxY - 3, width: rect.width + 6, height: rect.height + 6)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil); panel.close() }

    final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}
