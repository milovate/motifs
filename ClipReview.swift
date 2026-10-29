import AppKit
import AVKit

struct ClipMarker: Equatable {
    enum Kind { case click, error, warning }
    let time: Double
    let kind: Kind
    let label: String

    var title: String {
        let name: String
        switch kind {
        case .click: name = "Click"
        case .error: name = "Error"
        case .warning: name = "Warning"
        }
        return "\(name) · \(clipTime(time))"
    }
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
        let url = entry["url"] as? String ?? ""
        let path = URLComponents(string: url).map { $0.path.isEmpty ? "/" : $0.path } ?? url
        if let time = at(entry) { markers.append(ClipMarker(time: time, kind: .error, label: "\(entry["method"] as? String ?? "GET") \(entry["status"].map { "\($0)" } ?? entry["error"] as? String ?? "failed") \(String(path.prefix(100)))")) }
    }
    return markers.sorted { $0.time < $1.time }
}

func clipTime(_ seconds: Double) -> String {
    let whole = max(0, seconds)
    return String(format: "%d:%04.1f", Int(whole) / 60, whole.truncatingRemainder(dividingBy: 60))
}

// QuickTime-style trim strip: a filmstrip with yellow handles, the cut-away parts
// dimmed, event markers underneath and a playhead. Drag a handle to trim, click or
// drag elsewhere to seek, hover a marker to see what happened.
@MainActor final class ClipTimelineView: NSView {
    var duration: Double = 1 { didSet { trimOut = duration; needsDisplay = true } }
    var markers: [ClipMarker] = [] { didSet { needsDisplay = true; setAccessibilityHelp(markers.isEmpty ? "No clicks, errors or warnings during this clip." : markers.map { "\($0.title): \($0.label)" }.joined(separator: "\n")) } }
    var frames: [NSImage] = [] { didSet { needsDisplay = true } }
    var trimIn: Double = 0 { didSet { needsDisplay = true } }
    var trimOut: Double = 1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var onTrim: ((Double, Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onPlayPause: (() -> Void)?
    private(set) var hovered: ClipMarker? { didSet { if hovered != oldValue { needsDisplay = true; showPopover() } } }
    private enum Drag { case trimIn, trimOut, playhead }
    private var drag: Drag?
    private var tracking: NSTrackingArea?
    private let popover = NSPopover()
    static let handleWidth: CGFloat = 11
    private let inset: CGFloat = 14

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 70) }

    var strip: NSRect { NSRect(x: inset, y: 18, width: max(1, bounds.width - inset * 2), height: max(1, bounds.height - 22)) }
    func x(_ time: Double) -> CGFloat { inset + CGFloat(time / max(duration, 0.1)) * (bounds.width - inset * 2) }
    func time(_ x: CGFloat) -> Double { min(duration, max(0, Double((x - inset) / max(1, bounds.width - inset * 2)) * duration)) }
    func marker(near point: CGFloat) -> ClipMarker? {
        markers.filter { abs(x($0.time) - point) <= 6 }.min { abs(x($0.time) - point) < abs(x($1.time) - point) }
    }

    static func color(_ kind: ClipMarker.Kind) -> NSColor {
        switch kind {
        case .click: return .systemBlue
        case .error: return .systemRed
        case .warning: return .systemOrange
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let strip = self.strip
        let shape = NSBezierPath(roundedRect: strip, xRadius: CornerRadius.small, yRadius: CornerRadius.small)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        strip.fill()
        if !frames.isEmpty {
            let width = strip.width / CGFloat(frames.count)
            for (index, image) in frames.enumerated() {
                let cell = NSRect(x: strip.minX + CGFloat(index) * width, y: strip.minY, width: width, height: strip.height)
                let scale = max(cell.width / max(1, image.size.width), cell.height / max(1, image.size.height))
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cell).addClip()
                image.draw(in: NSRect(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2, width: size.width, height: size.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: strip.minX, y: strip.minY, width: max(0, x(trimIn) - strip.minX), height: strip.height).fill(using: .sourceOver)
        NSRect(x: x(trimOut), y: strip.minY, width: max(0, strip.maxX - x(trimOut)), height: strip.height).fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()

        let handle = Self.handleWidth
        let selection = NSRect(x: x(trimIn) - handle, y: strip.minY - 2, width: x(trimOut) - x(trimIn) + handle * 2, height: strip.height + 4)
        NSColor.systemYellow.setStroke()
        let frame = NSBezierPath(roundedRect: selection.insetBy(dx: 1.5, dy: 1.5), xRadius: CornerRadius.small, yRadius: CornerRadius.small)
        frame.lineWidth = 3
        frame.stroke()
        for left in [true, false] {
            let rect = NSRect(x: left ? selection.minX : selection.maxX - handle, y: selection.minY, width: handle, height: selection.height)
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: rect, xRadius: CornerRadius.small, yRadius: CornerRadius.small).fill()
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: rect.midX + (left ? 1.5 : -1.5), y: rect.midY + 5))
            chevron.line(to: NSPoint(x: rect.midX + (left ? -1.5 : 1.5), y: rect.midY))
            chevron.line(to: NSPoint(x: rect.midX + (left ? 1.5 : -1.5), y: rect.midY - 5))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.6).setStroke()
            chevron.stroke()
        }

        for marker in markers {
            let size: CGFloat = marker == hovered ? 10 : 7
            Self.color(marker.kind).setFill()
            NSBezierPath(ovalIn: NSRect(x: x(marker.time) - size / 2, y: 8 - size / 2, width: size, height: size)).fill()
        }

        let head = NSRect(x: x(playhead) - 1, y: strip.minY - 3, width: 2, height: strip.height + 6)
        NSColor.black.withAlphaComponent(0.35).setFill()
        head.insetBy(dx: -1, dy: 0).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: head, xRadius: 1, yRadius: 1).fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        hovered = marker(near: convert(event.locationInWindow, from: nil).x)
    }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    private func showPopover() {
        guard let hovered else { popover.close(); return }
        let title = NSTextField(labelWithString: hovered.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Self.color(hovered.kind)
        let detail = NSTextField(wrappingLabelWithString: hovered.label)
        detail.font = .systemFont(ofSize: 12)
        detail.preferredMaxLayoutWidth = 260
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        let controller = NSViewController()
        controller.view = stack
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        popover.contentSize = stack.fittingSize
        let anchor = NSRect(x: x(hovered.time) - 4, y: 4, width: 8, height: 8)
        if popover.isShown { popover.positioningRect = anchor } else { popover.show(relativeTo: anchor, of: self, preferredEdge: .minY) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hovered = nil
        let point = convert(event.locationInWindow, from: nil).x
        let handle = Self.handleWidth
        if point >= x(trimIn) - handle - 2, point <= x(trimIn) + 3 { drag = .trimIn } else if point >= x(trimOut) - 3, point <= x(trimOut) + handle + 2 { drag = .trimOut } else { drag = .playhead }
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
        case " ": onPlayPause?()
        default:
            switch event.keyCode {
            case 123: seek(max(0, playhead - 0.5))
            case 124: seek(min(duration, playhead + 0.5))
            default: super.keyDown(with: event)
            }
        }
    }

    func dismissPopover() { hovered = nil }

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
    static let filmstripCount = 14
    let video: [String: Any]
    let frameCount: Int
    let duration: Double
    let player: AVPlayer
    let playerView = AVPlayerView()
    let timeline = ClipTimelineView()
    let heading = NSTextField(labelWithString: "")
    let selection = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let closeButton = ComposerButton(symbol: "xmark")
    let removeButton = ComposerButton("Remove clip", symbol: "trash", treatment: .quiet)
    let cancelButton = ComposerButton("Cancel", treatment: .chip)
    let useButton = ComposerButton("Use clip", treatment: .primary)
    private var observer: Any?
    private var filmstrip: Task<Void, Never>?
    private var continuation: CheckedContinuation<ClipReviewResult, Never>?

    init(video: [String: Any], context: [String: Any], frameCount: Int) {
        self.video = video
        self.frameCount = frameCount
        duration = max(0.1, (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0.1)
        player = AVPlayer(url: URL(fileURLWithPath: video["video"] as? String ?? "/dev/null"))
        let label = video["source"] as? String == "recording" ? "Screen recording" : "Instant replay"
        let panel = ComposerPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "Review clip · \(label)"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 560, height: 420)
        super.init(window: panel)
        panel.delegate = self
        heading.stringValue = label + ((video["target"] as? String).map { " · \($0)" } ?? "")
        build(markers: clipMarkers(video, context: context))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func build(markers: [ClipMarker]) {
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.wantsLayer = true
        playerView.layer?.cornerRadius = CornerRadius.popup
        playerView.layer?.masksToBounds = true
        timeline.duration = duration
        timeline.markers = markers
        timeline.setAccessibilityLabel("Clip timeline. Drag the yellow handles to trim. I and O set the in and out points, Space plays or pauses.")
        timeline.toolTip = "Drag the yellow handles to trim · I / O set in and out · ← → step · Space play/pause"
        timeline.onSeek = { [weak self] time in self?.player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        timeline.onTrim = { [weak self] _, _ in self?.refreshSelection() }
        timeline.onPlayPause = { [weak self] in self?.togglePlayback() }
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
        loadFilmstrip()
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.target = self
        closeButton.action = #selector(cancel)
        closeButton.compact = true
        closeButton.toolTip = "Close without changes (Escape)"
        closeButton.setAccessibilityLabel("Close without changes")
        let header = NSStackView(views: [heading, NSView(), closeButton])
        header.alignment = .centerY
        selection.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        selection.textColor = .secondaryLabelColor
        let legend = NSStackView(views: [("Click", ClipMarker.Kind.click), ("Error", .error), ("Warning", .warning)].map { name, kind in
            let count = markers.filter { $0.kind == kind }.count
            let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: ClipTimelineView.color(kind), .font: NSFont.systemFont(ofSize: 12)])
            text.append(NSAttributedString(string: "\(name) \(count)", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)]))
            return NSTextField(labelWithAttributedString: text)
        })
        legend.spacing = 14
        legend.toolTip = "Hover a dot under the strip to see the event"
        let info = NSStackView(views: [selection, NSView(), legend])
        info.alignment = .centerY
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        removeButton.target = self
        removeButton.action = #selector(remove)
        removeButton.toolTip = "Remove this clip from the capture. The MP4 stays in the captures folder."
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.toolTip = "Keep the clip as it was (Escape)"
        useButton.target = self
        useButton.action = #selector(use)
        useButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [removeButton, status, NSView(), cancelButton, useButton])
        buttons.alignment = .centerY
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, playerView, timeline, info, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = ComposerSurface(frame: NSRect(x: 0, y: 0, width: 780, height: 560))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        for view in [header, playerView, timeline, info, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        window?.contentView = content
        refreshSelection()
    }

    func loadFilmstrip() {
        let asset = AVURLAsset(url: URL(fileURLWithPath: video["video"] as? String ?? "/dev/null"))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 150)
        let tolerance = CMTime(seconds: duration / Double(Self.filmstripCount) / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let duration = self.duration
        filmstrip = Task { @MainActor [weak self] in
            var images: [NSImage] = []
            for index in 0..<Self.filmstripCount {
                let at = CMTime(seconds: duration * (Double(index) + 0.5) / Double(Self.filmstripCount), preferredTimescale: 600)
                guard !Task.isCancelled, let image = try? await generator.image(at: at).image else { break }
                images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                self?.timeline.frames = images
            }
        }
    }

    var trimmed: Bool { timeline.trimIn > 0.05 || timeline.trimOut < duration - 0.05 }

    func refreshSelection() {
        selection.stringValue = "\(clipTime(timeline.trimIn)) in · \(clipTime(timeline.trimOut - timeline.trimIn)) selected of \(clipTime(duration)) · \(clipTime(timeline.trimOut)) out"
        useButton.title = trimmed ? "Use trimmed clip" : "Use clip"
        useButton.toolTip = (trimmed ? "Save the selection as a new clip and take key frames from it" : "Keep the whole clip") + " (Return)"
    }

    func togglePlayback() {
        if player.rate > 0 { player.pause(); return }
        if timeline.playhead >= timeline.trimOut - 0.05 || timeline.playhead < timeline.trimIn {
            player.seek(to: CMTime(seconds: timeline.trimIn, preferredTimescale: 600))
        }
        player.play()
    }

    func run() async -> ClipReviewResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            window?.center()
            window?.present { showWindow(nil) }
            NSApp.activate(ignoringOtherApps: true)
            window?.makeFirstResponder(timeline)
        }
    }

    func finish(_ result: ClipReviewResult) {
        let continuation = self.continuation
        self.continuation = nil
        player.pause()
        filmstrip?.cancel()
        timeline.dismissPopover()
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
