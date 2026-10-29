import AppKit
import ApplicationServices
import Carbon

// OpenCode 2.1's public API creates sessions, not desktop routes or input drafts.
// Navigate through its exact-ID session lookup, then paste only into a verified
// empty Prompt. Never synthesize Return or click Send during this handoff.
@MainActor func openSessionDraft(sessionID: String, title: String, draftText: String, shot: [String: Any], output: String) async throws {
    guard AXIsProcessTrusted() else { throw captureError("Accessibility permission is required to open and fill the new OpenCode session.") }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.opencode.desktop").first else { throw captureError("OpenCode desktop must be running to receive the draft.") }
    try await bringToFront(app)
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 0.1)
    AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)

    // If a prior attempt already opened this session, retry only while empty.
    if let prompt = handoffFind(axApp, matching: { node in
        (attribute(node, kAXRoleAttribute) as? String) == kAXTextAreaRole as String && (attribute(node, kAXDescriptionAttribute) as? String) == "Prompt"
    }), (try? verifyHandoffTarget(axApp, prompt: prompt, title: title, requireEmpty: true)) != nil {
        try await insertIntoOpenCode(shot, output: output, draftText: draftText, expectedSessionTitle: title)
        return
    }

    func searchField() -> AXUIElement? {
        handoffFind(axApp) { node in
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            guard [kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role) else { return false }
            let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute].compactMap { attribute(node, $0) as? String }.joined(separator: " ").lowercased()
            return (label.contains("search") || label.contains("find")) && !label.contains("settings") && !label.contains("file")
        }
    }
    if searchField() == nil {
        if let home = handoffFind(axApp, matching: { node in
            (attribute(node, kAXRoleAttribute) as? String) == kAXButtonRole as String && (attribute(node, kAXDescriptionAttribute) as? String) == "Home"
        }) {
            guard AXUIElementPerformAction(home, kAXPressAction as CFString) == .success else { throw captureError("Could not open OpenCode Home for the new session.") }
        } else {
            // OpenCode V2 desktop's Home toggle focuses session search.
            try postKey(kVK_ANSI_B, flags: .maskCommand, to: app.processIdentifier)
        }
    }
    let searchDeadline = Date().addingTimeInterval(8)
    var search: AXUIElement?
    while Date() < searchDeadline {
        search = searchField()
        if search != nil { break }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
    guard let search else { throw captureError("Created the session, but could not find OpenCode’s session search. Your draft has not been sent.") }
    guard AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw captureError("Could not focus OpenCode’s session search.") }
    try await pasteSessionLookup(sessionID, into: search, app: axApp, pid: app.processIdentifier)

    let resultDeadline = Date().addingTimeInterval(10)
    var result: AXUIElement?
    while Date() < resultDeadline {
        result = handoffFind(axApp) { node in
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains { (attribute(node, $0) as? String)?.contains(title) == true }
        }
        if result != nil { break }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
    guard let result else { throw captureError("The new session did not appear in OpenCode’s exact-ID lookup. No prompt was submitted.") }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw captureError("OpenCode lost focus during handoff. No prompt was submitted.") }
    var clickable = result
    var pressed = false
    for _ in 0..<6 {
        if AXUIElementPerformAction(clickable, kAXPressAction as CFString) == .success { pressed = true; break }
        guard let parent = attribute(clickable, kAXParentAttribute) as! AXUIElement? else { break }
        clickable = parent
    }
    if !pressed {
        // Electron sometimes exposes a clickable title without AXPress.
        guard let position = attribute(result, kAXPositionAttribute) as! AXValue?,
              let size = attribute(result, kAXSizeAttribute) as! AXValue? else { throw captureError("OpenCode’s session result is not actionable.") }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { throw captureError("Could not locate the exact session result.") }
        point.x += min(dimensions.width / 2, 100)
        point.y += dimensions.height / 2
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    let promptDeadline = Date().addingTimeInterval(8)
    while Date() < promptDeadline {
        if let prompt = handoffFind(axApp, matching: { node in
            (attribute(node, kAXRoleAttribute) as? String) == kAXTextAreaRole as String && (attribute(node, kAXDescriptionAttribute) as? String) == "Prompt"
        }), (try? verifyHandoffTarget(axApp, prompt: prompt, title: title, requireEmpty: true)) != nil {
            try await insertIntoOpenCode(shot, output: output, draftText: draftText, expectedSessionTitle: title)
            return
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
    throw captureError("OpenCode did not open the expected empty session. Your saved capture and description have not been sent.")
}

func handoffFind(_ root: AXUIElement, matching: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    var offset = 0
    let deadline = Date().addingTimeInterval(1)
    while offset < queue.count, offset < 6000, Date() < deadline {
        let node = queue[offset]
        offset += 1
        AXUIElementSetMessagingTimeout(node, 0.05)
        if matching(node) { return node }
        if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children.prefix(max(0, 6000 - queue.count))) }
    }
    return nil
}

func verifyHandoffTarget(_ app: AXUIElement, prompt: AXUIElement, title: String, requireEmpty: Bool = false) throws {
    guard handoffFind(app, matching: { node in
        guard [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { (attribute(node, $0) as? String)?.contains(title) == true }) else { return false }
        var current = node
        for _ in 0..<6 {
            let role = attribute(current, kAXRoleAttribute) as? String ?? ""
            if role == "AXHeading" { return true }
            if (attribute(current, kAXSelectedAttribute) as? NSNumber)?.boolValue == true { return true }
            if [kAXRadioButtonRole as String, kAXButtonRole as String].contains(role),
               (attribute(current, kAXValueAttribute) as? NSNumber)?.boolValue == true { return true }
            if ["page", "true"].contains(attribute(current, "AXARIACurrent") as? String ?? "") { return true }
            guard let parent = attribute(current, kAXParentAttribute) as! AXUIElement? else { break }
            current = parent
        }
        return false
    }) != nil else { throw captureError("OpenCode is no longer showing the expected session. Draft insertion stopped.") }
    if requireEmpty {
        guard let value = attribute(prompt, kAXValueAttribute) as? String else { throw captureError("Could not confirm whether the new session's draft is empty. It was left untouched.") }
        guard handoffDraftIsEmpty(value) else { throw captureError("The new session already has a draft. It was left untouched.") }
    }
}

@MainActor private func pasteSessionLookup(_ text: String, into field: AXUIElement, app: AXUIElement, pid: pid_t) async throws {
    func focusedSearchEditor() -> AXUIElement? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = attribute(app, kAXFocusedUIElementAttribute) as! AXUIElement? else { return nil }
        let owned = handoffFocusBelongsToOwner(focused: focused, owner: field, parent: { attribute($0, kAXParentAttribute) as! AXUIElement? }, equals: { CFEqual($0, $1) }, isEditable: {
            [kAXTextFieldRole as String, kAXComboBoxRole as String, kAXTextAreaRole as String].contains(attribute($0, kAXRoleAttribute) as? String ?? "")
        })
        return owned ? focused : nil
    }
    // AXSetAttributeValue reports that the focus request was accepted; it does
    // not guarantee Electron has delivered focus to the actual editor yet.
    guard try await waitForHandoffFocus(check: { focusedSearchEditor() != nil }) else {
        throw captureError("Could not confirm focus in OpenCode’s session search. The session exists, but its ID was not pasted. Nothing was run.")
    }
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let owned = pasteboard.changeCount
    defer {
        if pasteboard.changeCount == owned {
            let items = saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            pasteboard.clearContents()
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }
    guard focusedSearchEditor() != nil else { throw captureError("OpenCode’s session search lost focus before lookup. Nothing was pasted.") }
    try postKey(kVK_ANSI_A, flags: .maskCommand, to: pid)
    try await Task.sleep(nanoseconds: 80_000_000)
    guard focusedSearchEditor() != nil, pasteboard.changeCount == owned else {
        throw captureError("Focus or clipboard changed during session lookup. No draft was inserted.")
    }
    try postKey(kVK_ANSI_V, flags: .maskCommand, to: pid)
    guard try await waitForHandoffFocus(check: {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        // Typing in Home mounts a different input in a floating search panel.
        // The old AX element is no longer the owner after that transition. Read
        // the live search tree instead of demanding focus/value on the old node.
        return handoffFind(app, matching: { node in
            guard [kAXTextFieldRole as String, kAXComboBoxRole as String].contains(attribute(node, kAXRoleAttribute) as? String ?? "") else { return false }
            let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXPlaceholderValueAttribute].compactMap { attribute(node, $0) as? String }.joined(separator: " ")
            return handoffSearchMatches([HandoffSearchSnapshot(label: label, value: attribute(node, kAXValueAttribute) as? String)], sessionID: text)
        }) != nil
    }) else { throw captureError("Could not confirm the new session ID in OpenCode’s search. Draft insertion stopped; nothing was run.") }
}
