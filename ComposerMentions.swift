import AppKit

// The editable text is canonical. Skill attachments and highlighting are derived
// from complete, known @mentions; arbitrary email addresses are not skills.
struct ComposerSkillMention {
    let id: String
    let range: NSRange
}

struct ComposerMentionQuery {
    let range: NSRange
    let prefix: String
}

enum ComposerMentions {
    static func matches(in text: String, skills: [String]) -> [ComposerSkillMention] {
        guard !skills.isEmpty else { return [] }
        let alternatives = skills.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}_@/])@(" + alternatives + ")(?![\\p{L}\\p{N}_-])"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let value = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: value.length)).map {
            ComposerSkillMention(id: value.substring(with: $0.range(at: 1)), range: $0.range)
        }
    }

    static func query(in text: String, selection: NSRange) -> ComposerMentionQuery? {
        let value = text as NSString
        guard selection.length == 0, selection.location <= value.length else { return nil }
        let prefix = value.substring(to: selection.location)
        let expression = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_@/])@([\\p{L}\\p{N}_.-]*)$")
        guard let match = expression.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) else { return nil }
        // A caret inside an existing token must not replace only half of it.
        if selection.location < value.length,
           let scalar = UnicodeScalar(value.character(at: selection.location)),
           CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.@")).contains(scalar) { return nil }
        return ComposerMentionQuery(range: match.range, prefix: (prefix as NSString).substring(with: match.range(at: 1)))
    }
}

@MainActor final class ComposerCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ComposerMentionCompletion {
    let panel = ComposerCompletionPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var candidates: [(id: String, name: String)] = []
    var selectedIndex = 0
    var query: ComposerMentionQuery?
    var onChoose: ((String) -> Void)?

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
    }

    func update(textView: NSTextView, skills: [(id: String, name: String)], display: Bool) {
        let next = ComposerMentions.query(in: textView.string, selection: textView.selectedRange())
        if next?.prefix != query?.prefix || next?.range.location != query?.range.location { selectedIndex = 0 }
        query = next
        guard let next else { dismiss(); return }
        candidates = skills.filter { next.prefix.isEmpty || $0.id.localizedCaseInsensitiveContains(next.prefix) || $0.name.localizedCaseInsensitiveContains(next.prefix) }
            .sorted {
                if $0.id == "report" { return $1.id != "report" }
                if $1.id == "report" { return false }
                return $0.id < $1.id
            }
        selectedIndex = min(selectedIndex, max(0, candidates.count - 1))
        guard !candidates.isEmpty else { dismiss(); return }
        if display { show(near: textView) }
    }

    func move(_ delta: Int, near textView: NSTextView) {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + candidates.count) % candidates.count
        if textView.window?.isVisible == true { show(near: textView) }
    }

    static let width: CGFloat = 280
    static let visibleRows = 8

    func show(near textView: NSTextView) {
        guard let parent = textView.window else { return }
        let start = max(0, min(selectedIndex - (Self.visibleRows - 1), candidates.count - Self.visibleRows))
        let visible = Array(candidates.dropFirst(start).prefix(Self.visibleRows))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        for (offset, skill) in visible.enumerated() {
            let row = ComposerMentionRow(id: skill.id, name: skill.name, selected: start + offset == selectedIndex)
            row.onChoose = { [weak self] id in self?.onChoose?(id) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.width - 12).isActive = true
        }
        let hint = NSTextField(labelWithString: "↑↓ navigate · ↵ select · esc close")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last ?? hint)
        stack.addArrangedSubview(hint)
        let height = stack.fittingSize.height
        let surface = ComposerSurface(frame: NSRect(x: 0, y: 0, width: Self.width, height: height), radius: CornerRadius.popup)
        stack.frame = surface.bounds
        stack.autoresizingMask = [.width, .height]
        surface.addSubview(stack)
        panel.contentView = surface
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrame(NSRect(x: min(max(screen.minX + 8, caret.minX - 8), screen.maxX - Self.width - 8), y: min(screen.maxY - height - 8, max(screen.minY + 8, caret.maxY + 6)), width: Self.width, height: height), display: true)
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func dismiss() {
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
        candidates = []
        query = nil
    }
}

// One suggestion: the mention left-aligned, with the skill's name when it differs.
@MainActor final class ComposerMentionRow: NSView {
    let skillID: String
    let selected: Bool
    var onChoose: ((String) -> Void)?
    private var hovering = false

    init(id: String, name: String, selected: Bool) {
        skillID = id
        self.selected = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.small
        let mention = NSTextField(labelWithString: "@" + id)
        mention.font = .systemFont(ofSize: 13, weight: .medium)
        mention.lineBreakMode = .byTruncatingTail
        mention.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        var views: [NSView] = [mention]
        if name.caseInsensitiveCompare(id) != .orderedSame, !name.isEmpty {
            let detail = NSTextField(labelWithString: name)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(detail)
        }
        let row = NSStackView(views: views)
        row.spacing = 6
        row.alignment = .firstBaseline
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Select skill " + id)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.labelColor.withAlphaComponent(hovering ? 0.08 : 0).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onChoose?(skillID) }
    override func accessibilityPerformPress() -> Bool { onChoose?(skillID); return true }
}
