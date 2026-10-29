import AppKit

enum RecordingChoice: Int {
    case display, window, area
}

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

// Chooses what a recording captures: the display, the window of the app that
// was in front, or a dragged area. Return starts, Escape cancels.
@MainActor final class RecordingCaptureBar: NSObject {
    static var lastChoice = RecordingChoice.display
    let modes: NSSegmentedControl
    let hint = NSTextField(labelWithString: "")
    let startButton = ComposerButton("Start", symbol: "record.circle", treatment: .primary)
    let cancelButton = ComposerButton(symbol: "xmark")
    let appName: String?
    private(set) var panel: RecordingPanel!
    private var continuation: CheckedContinuation<RecordingChoice?, Never>?

    init(appName: String?) {
        self.appName = appName
        modes = NSSegmentedControl(labels: ["Display", "Window", "Area"], trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        modes.segmentStyle = .rounded
        for (segment, symbol) in ["display", "macwindow", "rectangle.dashed"].enumerated() {
            modes.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: segment)
        }
        modes.setEnabled(appName != nil, forSegment: RecordingChoice.window.rawValue)
        modes.selectedSegment = appName == nil && Self.lastChoice == .window ? RecordingChoice.display.rawValue : Self.lastChoice.rawValue
        modes.setToolTip("The whole display. Capture Studio's own windows are left out.", forSegment: 0)
        modes.setToolTip("Only the front window of \(appName ?? "the app"). Other windows on top are left out.", forSegment: 1)
        modes.setToolTip("Drag to choose an area of the screen.", forSegment: 2)
        modes.setAccessibilityLabel("What to record")
        modes.target = self
        modes.action = #selector(modeChanged)
        startButton.target = self
        startButton.action = #selector(start)
        startButton.keyEquivalent = "\r"
        startButton.toolTip = "Start recording (Return) · No audio · Up to 5 min"
        startButton.setAccessibilityLabel("Start recording")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.compact = true
        cancelButton.toolTip = "Cancel (Escape)"
        cancelButton.setAccessibilityLabel("Cancel recording")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        hint.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        refreshHint()
        panel = RecordingPanel.pill([cancelButton, modes, hint, startButton], activating: true)
        panel.title = "Screen recording"
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    var choice: RecordingChoice { RecordingChoice(rawValue: modes.selectedSegment) ?? .display }

    func choose() async -> RecordingChoice? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            panel.place(on: NSScreen.main, nearTop: false)
            NSApp.activate(ignoringOtherApps: true)
            panel.present { panel.makeKeyAndOrderFront(nil) }
        }
    }

    func refreshHint() {
        switch choice {
        case .display: hint.stringValue = "Whole screen"
        case .window: hint.stringValue = appName ?? "Front window"
        case .area: hint.stringValue = "Drag after Start"
        }
        hint.toolTip = hint.stringValue
    }

    @objc func modeChanged() { refreshHint() }
    @objc func start() { finish(choice) }
    @objc func cancel() { finish(nil) }

    func finish(_ choice: RecordingChoice?) {
        panel.orderOut(nil)
        if let choice { Self.lastChoice = choice }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: choice)
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
