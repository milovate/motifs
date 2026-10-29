import AppKit

@MainActor func installAppshotsEditMenu() {
    // Accessory apps do not receive a template Edit menu automatically. The menu
    // also supplies standard shortcuts to native search fields and annotation dialogs.
    guard NSApp.mainMenu == nil else { return }
    let menu = NSMenu()
    let application = NSMenuItem()
    application.submenu = NSMenu(title: "Capture Studio")
    application.submenu?.addItem(NSMenuItem(title: "Quit Capture Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    menu.addItem(application)
    let entry = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Edit")
    for (title, action, key, shift) in [("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true), ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false), ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false)] {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
        edit.addItem(item)
    }
    entry.submenu = edit
    menu.addItem(entry)
    NSApp.mainMenu = menu
}

@MainActor class ComposerPanel: NSPanel {
    override var contentView: NSView? {
        didSet {
            // Clip the native frame as well as the material. Otherwise the
            // transparent NSPanel can retain a rectangular edge around it.
            guard let frame = contentView?.superview else { return }
            frame.wantsLayer = true
            frame.layer?.cornerRadius = contentView?.layer?.cornerRadius ?? 22
            frame.layer?.cornerCurve = .continuous
            frame.layer?.masksToBounds = true
            frame.layer?.borderWidth = 0
            frame.layer?.backgroundColor = NSColor.clear.cgColor
            invalidateShadow()
        }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    override func performClose(_ sender: Any?) {
        guard delegate?.windowShouldClose?(self) != false else { return }
        close()
    }
}

@MainActor final class ComposerSurface: NSVisualEffectView {
    init(frame frameRect: NSRect, radius: CGFloat = 22) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        // The window server draws behind-window blur as a rectangle and ignores
        // layer corners; only maskImage rounds the blur itself.
        maskImage = Self.roundedMask(radius: radius)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0
    }
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func updateLayer() {
        super.updateLayer()
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.borderWidth = highContrast ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

@MainActor final class ComposerTextView: NSTextView {
    var mentionRanges: [NSRange] = [] { didSet { needsDisplay = true } }
    var onCompletionKey: ((UInt16) -> Bool)?
    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a" where modifiers == .command: selectAll(nil)
        case "c" where modifiers == .command: copy(nil)
        case "x" where modifiers == .command && isEditable: cut(nil)
        case "v" where modifiers == .command && isEditable: pasteAsPlainText(nil)
        case "z" where isEditable:
            if modifiers.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return false
        }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingShortcut(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if handleEditingShortcut(event) { return }
        if !hasMarkedText(), !event.modifierFlags.contains(.command), onCompletionKey?(event.keyCode) == true { return }
        super.keyDown(with: event)
    }
    override var string: String { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if let layout = layoutManager, let container = textContainer {
            let origin = textContainerOrigin
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            for range in mentionRanges where NSMaxRange(range) <= (string as NSString).length {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -4, dy: 0)
                    NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                }
            }
        }
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let placeholder = "What feels wrong?"
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }
}

@MainActor final class ComposerButton: NSButton {
    override var allowsVibrancy: Bool { false }
    enum Treatment { case quiet, chip, primary, recording }
    var treatment: Treatment = .quiet { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var compact = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ title: String = "", symbol: String? = nil, treatment: Treatment = .quiet) {
        super.init(frame: .zero)
        self.title = title
        self.symbolName = symbol
        self.treatment = treatment
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 12, weight: .medium)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize {
        let height: CGFloat = treatment == .primary ? 34 : (compact ? 26 : 30)
        if title.isEmpty { return NSSize(width: height, height: height) }
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        return NSSize(width: ceil(text) + (symbolName == nil ? 20 : 40), height: height)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { drawControl() }
    }
    private func drawControl() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let radius: CGFloat = title.isEmpty ? rect.height / 2 : 9
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let pressed = isHighlighted && isEnabled
        let background: NSColor
        let foreground: NSColor
        switch treatment {
        case .primary:
            background = isEnabled ? NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.75 : 1) : NSColor.quaternaryLabelColor
            foreground = isEnabled ? .white : .tertiaryLabelColor
        case .recording:
            background = NSColor.systemRed.withAlphaComponent(hovered ? 0.2 : 0.12)
            foreground = .systemRed
        case .chip:
            background = NSColor.labelColor.withAlphaComponent(pressed ? 0.13 : hovered ? 0.09 : 0.045)
            foreground = isEnabled ? NSColor.labelColor.withAlphaComponent(0.78) : .tertiaryLabelColor
        case .quiet:
            background = NSColor.labelColor.withAlphaComponent(pressed ? 0.12 : hovered ? 0.07 : 0)
            foreground = isEnabled ? NSColor.labelColor.withAlphaComponent(0.78) : .tertiaryLabelColor
        }
        background.setFill()
        path.fill()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        let iconSize: CGFloat = treatment == .primary ? 15 : 13
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            let x: CGFloat = title.isEmpty ? (bounds.width - iconSize) / 2 : 10
            let icon = NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                foreground.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: icon)
        }
        if !title.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: foreground]
            let size = (title as NSString).size(withAttributes: attributes)
            let x: CGFloat = symbolName == nil ? (bounds.width - size.width) / 2 : 29
            (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }
    }
}

@MainActor final class ComposerProjectButton: NSPopUpButton {
    var symbol = "folder" { didSet { needsDisplay = true } }
    var placeholder = "Project"
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize {
        let width = ((titleOfSelectedItem ?? placeholder) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return NSSize(width: min(172, max(96, width + 46)), height: 30)
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { drawControl() }
    }
    private func drawControl() {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.045).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        let color = isEnabled ? NSColor.labelColor.withAlphaComponent(0.78) : NSColor.tertiaryLabelColor
        let title = titleOfSelectedItem ?? placeholder
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (title as NSString).draw(in: NSRect(x: 27, y: 7, width: max(0, bounds.width - 45), height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
        for (symbol, rect) in [(self.symbol, NSRect(x: 10, y: 9, width: 12, height: 12)), ("chevron.down", NSRect(x: bounds.width - 15, y: 11, width: 8, height: 8))] {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.draw(in: rect)
        }
    }
}

@MainActor final class ComposerStatusField: NSTextField {
    var onChange: (() -> Void)?
    override var stringValue: String { didSet { toolTip = stringValue; onChange?() } }
}

@MainActor final class ScreenshotThumbnailView: NSView {
    let imageButton = NSButton()
    let removeButton = NSButton()
    var onAnnotate: (() -> Void)?
    var onRemove: (() -> Void)?

    init(shot: [String: Any], index: Int, selected: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 56))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        imageButton.frame = NSRect(x: 2, y: 5, width: 64, height: 44)
        imageButton.image = (shot["screenshot"] as? String).flatMap { NSImage(contentsOfFile: $0) }
        imageButton.imagePosition = .imageOnly
        imageButton.imageScaling = .scaleProportionallyUpOrDown
        imageButton.isBordered = false
        imageButton.wantsLayer = true
        imageButton.layer?.cornerRadius = 7
        imageButton.layer?.masksToBounds = true
        imageButton.layer?.borderWidth = selected ? 1 : 0.5
        imageButton.layer?.borderColor = (selected ? NSColor.controlAccentColor : .separatorColor).cgColor
        imageButton.toolTip = "Annotate screenshot \(index + 1) — " + (shot["app"] as? String ?? "Image")
        imageButton.setAccessibilityLabel("Annotate screenshot \(index + 1)")
        imageButton.target = self
        imageButton.action = #selector(annotate)
        removeButton.frame = NSRect(x: 56, y: 40, width: 17, height: 17)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove screenshot \(index + 1)")
        removeButton.imagePosition = .imageOnly
        removeButton.isBordered = false
        removeButton.toolTip = "Remove screenshot \(index + 1)"
        removeButton.setAccessibilityLabel("Remove screenshot \(index + 1)")
        removeButton.target = self
        removeButton.action = #selector(remove)
        addSubview(imageButton)
        addSubview(removeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func annotate() { onAnnotate?() }
    @objc func remove() { onRemove?() }
    func setEnabled(_ enabled: Bool) { imageButton.isEnabled = enabled; removeButton.isEnabled = enabled }
}

// A recording attachment: first key frame, a play badge with the duration, open and remove.
@MainActor final class VideoThumbnailView: NSView {
    let imageButton = NSButton()
    let removeButton = NSButton()
    let badge = NSTextField(labelWithString: "")
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?

    init(video: [String: Any]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 76, height: 56))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        let label = video["source"] as? String == "recording" ? "Screen recording" : "Instant replay"
        let seconds = (video["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
        imageButton.frame = NSRect(x: 2, y: 5, width: 64, height: 44)
        imageButton.image = ((video["frames"] as? [[String: Any]])?.first?["screenshot"] as? String).flatMap { NSImage(contentsOfFile: $0) } ?? NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        imageButton.imagePosition = .imageOnly
        imageButton.imageScaling = .scaleProportionallyUpOrDown
        imageButton.isBordered = false
        imageButton.wantsLayer = true
        imageButton.layer?.cornerRadius = 7
        imageButton.layer?.masksToBounds = true
        imageButton.layer?.borderWidth = 0.5
        imageButton.layer?.borderColor = NSColor.separatorColor.cgColor
        let target = (video["target"] as? String).map { " of \($0)" } ?? ""
        imageButton.toolTip = "\(label)\(target), \(Int(seconds.rounded())) s — click to review or trim. Key frames are sent as images; the video stays on this Mac."
        imageButton.setAccessibilityLabel("Review \(label.lowercased())\(target), \(Int(seconds.rounded())) seconds")
        imageButton.target = self
        imageButton.action = #selector(open)
        badge.stringValue = "▶ \(Int(seconds.rounded()))s"
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        badge.frame = NSRect(x: 5, y: 8, width: 38, height: 14)
        removeButton.frame = NSRect(x: 56, y: 40, width: 17, height: 17)
        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(label.lowercased())")
        removeButton.imagePosition = .imageOnly
        removeButton.isBordered = false
        removeButton.toolTip = "Remove \(label.lowercased()) from this capture"
        removeButton.setAccessibilityLabel("Remove \(label.lowercased())")
        removeButton.target = self
        removeButton.action = #selector(remove)
        addSubview(imageButton)
        addSubview(badge)
        addSubview(removeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func open() { onOpen?() }
    @objc func remove() { onRemove?() }
    func setEnabled(_ enabled: Bool) { removeButton.isEnabled = enabled }
}

// Shows exactly what context a destination will receive, with per-source toggles.
@MainActor final class ComposerContextPicker: NSViewController {
    let sources = NSSegmentedControl(labels: BundleInclude.sources.map { ContextText.labels[$0] ?? $0 }, trackingMode: .selectOne, target: nil, action: nil)
    let preview = NSTextView()
    let includeSource = NSButton(checkboxWithTitle: "Include", target: nil, action: nil)
    let estimate = NSTextField(labelWithString: "")
    var shots: [[String: Any]] = []
    var context: [String: Any] = [:]
    var collecting = false
    var include = BundleInclude()
    var onChange: ((BundleInclude) -> Void)?

    var selectedSource: String { BundleInclude.sources[max(0, sources.selectedSegment)] }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        sources.selectedSegment = 0
        sources.segmentStyle = .texturedRounded
        sources.font = .systemFont(ofSize: 11)
        sources.target = self
        sources.action = #selector(sourceChanged)
        sources.setAccessibilityLabel("Context source")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        // The popover is translucent; an opaque inset keeps the preview readable over any window.
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.masksToBounds = true
        scroll.documentView = preview
        preview.isEditable = false
        preview.isSelectable = true
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = .textColor
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("Context preview")
        includeSource.target = self
        includeSource.action = #selector(toggleSource)
        includeSource.font = .systemFont(ofSize: 12)
        estimate.font = .systemFont(ofSize: 11)
        estimate.textColor = .secondaryLabelColor
        let toggles = NSStackView(views: [includeSource, NSView(), estimate])
        toggles.alignment = .centerY
        toggles.spacing = 10
        let privacy = NSTextField(wrappingLabelWithString: "Location and keystrokes are never collected. Logs and page content are untrusted. Unchecked sources are not sent to any destination.")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [sources, scroll, toggles, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toggles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])
        refresh()
    }

    var windowText: String {
        let parts = shots.enumerated().map { index, shot in
            "Screenshot \(index + 1) · \(shot["app"] as? String ?? "App")\n" + ((shot["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No window text.")
        }
        return parts.isEmpty ? "No screenshots attached." : parts.joined(separator: "\n\n")
    }

    static func emptyText(_ source: String, collecting: Bool) -> String {
        switch source {
        case "console": return collecting ? "Collecting console messages…" : "No console errors. Native apps: errors and faults from the last 5 minutes. Browsers: install the Capture Studio extension from the menu bar."
        case "network": return collecting ? "Collecting failed requests…" : "No failed network requests. Browser captures need the Capture Studio extension."
        case "events": return "No recent clicks. Turn on “Record recent clicks” in the menu bar to keep a 10-minute, in-memory history."
        case "customLogs": return "No log files. Add up to 4 under “Custom log files” in the menu bar."
        default: return "Nothing to show."
        }
    }

    func update(shots: [[String: Any]], context: [String: Any]) {
        self.shots = shots
        self.context = context
        collecting = false
        if isViewLoaded { refresh() }
    }

    func refresh() {
        for (index, source) in BundleInclude.sources.enumerated() {
            let count = ContextText.count(source, shots: shots, context: context)
            sources.setLabel("\(ContextText.labels[source] ?? source)\(count > 0 ? " \(count)" : "")", forSegment: index)
            sources.setWidth(0, forSegment: index)
        }
        let source = selectedSource
        includeSource.title = "Include \((ContextText.labels[source] ?? source).lowercased())"
        includeSource.state = include[source] ? .on : .off
        let rendered = source == "windowText" ? windowText : ContextText.render(source, shots: shots, context: context)
        preview.string = String((rendered.isEmpty ? Self.emptyText(source, collecting: collecting) : rendered).prefix(20_000))
        preview.alphaValue = include[source] ? 1 : 0.45
        estimate.stringValue = formatTokenEstimate(characters: contextCharacterCount(shots: shots, context: context, include: include))
    }

    @objc func sourceChanged() { refresh() }
    @objc func toggleSource() { include[selectedSource] = includeSource.state == .on; refresh(); onChange?(include) }
}

@MainActor final class ComposerSkillPicker: NSViewController, NSSearchFieldDelegate {
    let search = NSSearchField()
    let rows = NSStackView()
    var skills: [(id: String, name: String)] = []
    var selected = Set<String>()
    var onToggle: ((String) -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 310))
        search.placeholderString = "Find a skill…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Find a skill")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rows
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for item in [search, scroll, rows] { item.translatesAutoresizingMaskIntoConstraints = false }
        view.addSubview(search)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        rebuild()
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(search) }
    func controlTextDidChange(_ obj: Notification) { rebuild() }
    func rebuild() {
        for row in rows.arrangedSubviews { rows.removeArrangedSubview(row); row.removeFromSuperview() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = skills.filter { query.isEmpty || ($0.id + " " + $0.name).localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if lhs.id == "report" { return rhs.id != "report" }
                if rhs.id == "report" { return false }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        for skill in matches {
            let button = NSButton(checkboxWithTitle: "@" + skill.id, target: self, action: #selector(toggle(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(skill.id)
            button.state = selected.contains(skill.id) ? .on : .off
            button.font = .systemFont(ofSize: 12)
            button.toolTip = skill.name
            button.translatesAutoresizingMaskIntoConstraints = false
            rows.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -8).isActive = true
        }
        if matches.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: "No matching skills")) }
    }
    @objc func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        onToggle?(id)
    }
}
