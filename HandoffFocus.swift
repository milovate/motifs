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
