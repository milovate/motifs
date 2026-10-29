import AppKit
import AVKit

struct ClipMarker: Equatable {
    enum Kind { case click, error, warning }
    let time: Double
    let kind: Kind
    let label: String
}

// Clicks, console errors/warnings and failed requests that happened during the
// clip, placed in clip time (paused spans skipped).
func clipMarkers(_ video: [String: Any], context: [String: Any]) -> [ClipMarker] {
    func at(_ entry: [String: Any]) -> Double? {
        (entry["time"] as? String).flatMap(ReplayWriter.parseDate).flatMap { ReplayWriter.offset(of: $0, in: video) }
    }
    var markers: [ClipMarker] = []
    for entry in ContextText.entries(context, "events") where entry["kind"] as? String == "click" {
        if let time = at(entry) { markers.append(ClipMarker(time: time, kind: .click, label: "Clicked \(entry["role"] as? String ?? "element")" + ((entry["title"] as? String).map { " “\($0)”" } ?? ""))) }
    }
    for entry in ContextText.entries(context, "console") {
        let level = (entry["level"] as? String ?? "").lowercased()
        let kind: ClipMarker.Kind? = ["error", "fault"].contains(level) ? .error : level.hasPrefix("warn") ? .warning : nil
        if let kind, let time = at(entry) { markers.append(ClipMarker(time: time, kind: kind, label: String((entry["message"] as? String ?? level).prefix(120)))) }
    }
    for entry in ContextText.entries(context, "network") {
        if let time = at(entry) { markers.append(ClipMarker(time: time, kind: .error, label: "\(entry["method"] as? String ?? "GET") \(entry["status"].map { "\($0)" } ?? entry["error"] as? String ?? "failed") \(String((entry["url"] as? String ?? "").prefix(100)))")) }
    }
    return markers.sorted { $0.time < $1.time }
}

func clipTime(_ seconds: Double) -> String {
    let whole = max(0, seconds)
    return String(format: "%d:%04.1f", Int(whole) / 60, whole.truncatingRemainder(dividingBy: 60))
}

// Track with trim handles, event markers and a playhead. Drag a handle to trim,
// click or drag elsewhere to seek. Keys: ←/→ step, I/O set the in/out point.
@MainActor final class ClipTimelineView: NSView {
    var duration: Double = 1 { didSet { trimOut = duration; needsDisplay = true } }
    var markers: [ClipMarker] = [] { didSet { needsDisplay = true; toolTip = markers.isEmpty ? "No clicks, errors or warnings during this clip." : markers.map { "\(clipTime($0.time))  \($0.label)" }.joined(separator: "\n") } }
    var trimIn: Double = 0 { didSet { needsDisplay = true } }
    var trimOut: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onTrim: ((Double, Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    private enum Drag { case trimIn, trimOut, playhead }
    private var drag: Drag?
    private let inset: CGFloat = 10

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    func x(_ time: Double) -> CGFloat { inset + CGFloat(time / max(duration, 0.1)) * (bounds.width - inset * 2) }
    func time(_ x: CGFloat) -> Double { min(duration, max(0, Double((x - inset) / max(1, bounds.width - inset * 2)) * duration)) }

    static func color(_ kind: ClipMarker.Kind) -> NSColor {
        switch kind {
        case .click: return .systemBlue
        case .error: return .systemRed
        case .warning: return .systemOrange
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSRect(x: inset, y: 14, width: bounds.width - inset * 2, height: 16)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let selected = NSRect(x: x(trimIn), y: track.minY - 3, width: max(0, x(trimOut) - x(trimIn)), height: track.height + 6)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: selected, xRadius: 5, yRadius: 5).fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: selected, xRadius: 5, yRadius: 5)
        outline.lineWidth = 2
        outline.stroke()
        for edge in [selected.minX, selected.maxX] {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: edge - 3, y: selected.minY - 2, width: 6, height: selected.height + 4), xRadius: 3, yRadius: 3).fill()
        }
        for marker in markers {
            Self.color(marker.kind).setFill()
            NSBezierPath(ovalIn: NSRect(x: x(marker.time) - 4, y: track.midY - 4, width: 8, height: 8)).fill()
        }
        NSColor.labelColor.setFill()
        NSRect(x: x(playhead) - 1, y: 4, width: 2, height: bounds.height - 8).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - x(trimIn)) <= 8 { drag = .trimIn } else if abs(point.x - x(trimOut)) <= 8 { drag = .trimOut } else { drag = .playhead }
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let value = time(convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .trimIn: trimIn = min(value, trimOut - 0.5); onTrim?(trimIn, trimOut); seek(trimIn)
        case .trimOut: trimOut = max(value, trimIn + 0.5); onTrim?(trimIn, trimOut); seek(trimOut)
        case .playhead: seek(value)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": trimIn = min(playhead, trimOut - 0.5); onTrim?(trimIn, trimOut)
        case "o": trimOut = max(playhead, trimIn + 0.5); onTrim?(trimIn, trimOut)
        default:
            switch event.keyCode {
            case 123: seek(max(0, playhead - 0.5))
            case 124: seek(min(duration, playhead + 0.5))
            default: super.keyDown(with: event)
            }
        }
    }

    private func seek(_ value: Double) {
        playhead = value
        onSeek?(value)
    }
}

enum ClipReviewResult {
    case keep
    case remove
    case replace([String: Any])
}

@MainActor final class ClipReviewController: NSWindowController, NSWindowDelegate {
    let video: [String: Any]
    let frameCount: Int
    let duration: Double
    let player: AVPlayer
    let playerView = AVPlayerView()
    let timeline = ClipTimelineView()
    let selection = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let removeButton = NSButton(title: "Remove clip", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let useButton = NSButton(title: "Use clip", target: nil, action: nil)
    private var observer: Any?
    private var continuation: CheckedContinuation<ClipReviewResult, Never>?

    init(video: [String: Any], context: [String: Any], frameCount: Int) {
        self.video = video
        self.frameCount = frameCount
        duration = max(0.1, (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0.1)
        player = AVPlayer(url: URL(fileURLWithPath: video["video"] as? String ?? "/dev/null"))
        let label = video["source"] as? String == "recording" ? "Screen recording" : "Instant replay"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Review clip · \(label)" + ((video["target"] as? String).map { " · \($0)" } ?? "")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        window.delegate = self
        build(markers: clipMarkers(video, context: context))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func build(markers: [ClipMarker]) {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        timeline.duration = duration
        timeline.markers = markers
        timeline.setAccessibilityLabel("Clip timeline. Drag the handles to trim. I and O set the in and out points.")
        timeline.onSeek = { [weak self] time in self?.player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        timeline.onTrim = { [weak self] _, _ in self?.refreshSelection() }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timeline.playhead = time.seconds
                if time.seconds >= self.timeline.trimOut, self.player.rate > 0 {
                    self.player.pause()
                    self.player.seek(to: CMTime(seconds: self.timeline.trimIn, preferredTimescale: 600))
                }
            }
        }
        selection.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selection.textColor = .secondaryLabelColor
        let legend = NSStackView(views: [("Click", ClipMarker.Kind.click), ("Error", .error), ("Warning", .warning)].map { name, kind in
            let count = markers.filter { $0.kind == kind }.count
            let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: ClipTimelineView.color(kind), .font: NSFont.systemFont(ofSize: 12)])
            text.append(NSAttributedString(string: "\(name) \(count)", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            return NSTextField(labelWithAttributedString: text)
        })
        legend.spacing = 14
        legend.toolTip = timeline.toolTip
        let info = NSStackView(views: [selection, NSView(), legend])
        info.alignment = .centerY
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.stringValue = markers.isEmpty ? "Drag the handles to trim. Markers appear for clicks, errors and failed requests captured as context." : "Hover the timeline to list events. Drag the handles to trim."
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = "Remove this clip from the capture. The MP4 stays in the captures folder."
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        useButton.target = self
        useButton.action = #selector(use)
        useButton.keyEquivalent = "\r"
        useButton.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [removeButton, status, NSView(), cancelButton, useButton])
        buttons.alignment = .centerY
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [playerView, timeline, info, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        for view in [playerView, timeline, info, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        window?.contentView = content
        refreshSelection()
    }

    var trimmed: Bool { timeline.trimIn > 0.05 || timeline.trimOut < duration - 0.05 }

    func refreshSelection() {
        selection.stringValue = "\(clipTime(timeline.trimIn)) in · \(clipTime(timeline.trimOut - timeline.trimIn)) selected of \(clipTime(duration)) · \(clipTime(timeline.trimOut)) out"
        useButton.title = trimmed ? "Use trimmed clip" : "Use clip"
    }

    func run() async -> ClipReviewResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            window?.center()
            showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeFirstResponder(timeline)
        }
    }

    func finish(_ result: ClipReviewResult) {
        let continuation = self.continuation
        self.continuation = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        window?.orderOut(nil)
        continuation?.resume(returning: result)
    }

    @objc func remove() { finish(.remove) }
    @objc func cancel() { finish(.keep) }

    @objc func use() {
        guard trimmed else { finish(.keep); return }
        for button in [removeButton, cancelButton, useButton] { button.isEnabled = false }
        status.stringValue = "Trimming…"
        player.pause()
        Task { @MainActor in
            do {
                finish(.replace(try await ReplayWriter.trim(video, from: timeline.trimIn, to: timeline.trimOut, frameCount: frameCount)))
            } catch {
                status.stringValue = error.localizedDescription
                for button in [removeButton, cancelButton, useButton] { button.isEnabled = true }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { if continuation != nil { finish(.keep) } }
}
