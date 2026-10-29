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

    func show(near textView: NSTextView) {
        guard let parent = textView.window else { return }
        let start = max(0, min(selectedIndex - 5, candidates.count - 6))
        let visible = Array(candidates.dropFirst(start).prefix(6))
        let height = CGFloat(visible.count * 32 + 40)
        let surface = ComposerSurface(frame: NSRect(x: 0, y: 0, width: 330, height: height), radius: 12)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        for (offset, skill) in visible.enumerated() {
            let row = ComposerButton("@" + String(skill.id.prefix(34)), treatment: start + offset == selectedIndex ? .chip : .quiet)
            row.setAccessibilityLabel("Select skill " + skill.id)
            row.toolTip = skill.name
            row.identifier = NSUserInterfaceItemIdentifier(skill.id)
            row.target = self
            row.action = #selector(choose(_:))
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 314).isActive = true
        }
        let hint = NSTextField(labelWithString: "↑↓ Navigate     ↵ Select     esc Close")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8), stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 8)])
        panel.contentView = surface
        let caret = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        let screen = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrame(NSRect(x: min(max(screen.minX + 8, caret.minX), screen.maxX - 338), y: min(screen.maxY - height - 8, max(screen.minY + 8, caret.maxY + 6)), width: 330, height: height), display: true)
        if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    @objc func choose(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onChoose?(id)
    }

    func dismiss() {
        panel.orderOut(nil)
        panel.parent?.removeChildWindow(panel)
        candidates = []
        query = nil
    }
}
