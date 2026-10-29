import Foundation

@main struct HandoffFocusTests {
    @MainActor static func main() async throws {
        let parents = ["search-input": "search-combo", "other-input": "window", "search-combo": "window", "window": "app"]
        func owned(_ focused: String?) -> Bool {
            handoffFocusBelongsToOwner(focused: focused, owner: "search-combo", parent: { parents[$0] }, equals: ==, isEditable: { ["search-input", "search-combo", "other-input"].contains($0) })
        }
        precondition(owned("search-input"), "Electron’s child editor belongs to the requested combo box")
        precondition(owned("search-combo"), "direct focus remains supported")
        precondition(!owned("other-input"), "another editable field in the same app must be rejected")
        precondition(!owned("window"), "window focus is not editor focus")
        precondition(!owned(nil), "missing focus must be rejected")
        var tick = 0
        let ready = try await waitForHandoffFocus(attempts: 5, check: { tick >= 2 && owned("search-input") }, pause: { tick += 1 })
        precondition(ready && tick == 2, "wait for asynchronous activation and child-editor focus before typing")
        var keystrokes = 0
        let wrong = try await waitForHandoffFocus(attempts: 3, check: { owned("other-input") }, pause: {})
        if wrong { keystrokes += 1 }
        precondition(!wrong && keystrokes == 0, "timeout must never permit typing into an unrelated input")
        let oldHomeField = HandoffSearchSnapshot(label: "Search sessions", value: "")
        let replacementPopupField = HandoffSearchSnapshot(label: "Search sessions", value: "ses_fixture")
        precondition(!handoffSearchMatches([oldHomeField], sessionID: "ses_fixture"), "stale Home input does not confirm the lookup")
        precondition(handoffSearchMatches([oldHomeField, replacementPopupField], sessionID: "ses_fixture"), "re-resolve the new popup input after Home replaces its search control")
        precondition(!handoffSearchMatches([HandoffSearchSnapshot(label: "Search files", value: "ses_fixture")], sessionID: "ses_fixture"), "a file search is not a session lookup")
        precondition(!handoffSearchMatches([replacementPopupField], sessionID: "ses_other"), "a different lookup is not accepted")
        precondition(handoffDraftIsEmpty("\u{200B}"), "OpenCode's actual empty-editor sentinel is not user text")
        precondition(handoffDraftIsEmpty(" \n\u{200B}"), "whitespace around an editor sentinel remains empty")
        precondition(!handoffDraftIsEmpty("\u{200B}user draft"), "a real existing draft must remain protected")
        print("Handoff focus ownership and asynchronous activation checks passed")
    }
}
