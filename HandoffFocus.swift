import Foundation

struct HandoffSearchSnapshot {
    let label: String
    let value: String?
}

func handoffSearchMatches(_ fields: [HandoffSearchSnapshot], sessionID: String) -> Bool {
    fields.contains {
        let label = $0.label.lowercased()
        return (label.contains("search") || label.contains("find")) && !label.contains("settings") && !label.contains("file") && $0.value == sessionID
    }
}

// OpenCode's contenteditable places U+200B in an otherwise empty draft. Ignore
// that editor sentinel only for emptiness; never strip characters from user text.
func handoffDraftIsEmpty(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { $0 == "\u{200B}" || CharacterSet.whitespacesAndNewlines.contains($0) }
}

// Ownership is scoped to the requested control, not merely to the app/window.
// Electron may report a combo box as the requested control and its child editor
// as the focused element. An unrelated editable field is never equivalent.
func handoffFocusBelongsToOwner<Node>(focused: Node?, owner: Node, parent: (Node) -> Node?, equals: (Node, Node) -> Bool, isEditable: (Node) -> Bool) -> Bool {
    guard var node = focused, isEditable(node) else { return false }
    for _ in 0..<12 {
        if equals(node, owner) { return true }
        guard let next = parent(node) else { return false }
        node = next
    }
    return false
}

@MainActor func waitForHandoffFocus(attempts: Int = 60, check: () -> Bool, pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }) async throws -> Bool {
    for attempt in 0..<attempts {
        if check() { return true }
        if attempt + 1 < attempts { try await pause() }
    }
    return false
}

// A line of the pasted text that identifies it in the prompt: the legacy capture
// timestamp, else the bundle path, else the last line. Kept short because the prompt
// may reflow long lines.
func insertionMarker(text: String, capturedAt: String?) -> String {
    if let capturedAt { return "Captured at: " + capturedAt }
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let line = lines.first { $0.hasPrefix("- Capture bundle: ") } ?? lines.last ?? text
    return String(line.suffix(80))
}

func promptContains(_ value: String, _ marker: String) -> Bool {
    let flatten = { (string: String) in string.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    return flatten(value).contains(flatten(marker))
}
