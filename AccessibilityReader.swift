import Foundation

struct AccessibilityLimits {
    var nodes = 6_000
    var characters = 120_000
    var depth = 128
    var seconds: TimeInterval = 8
}

struct AccessibilityNode<Node: Hashable> {
    var role: String
    var subrole = ""
    var roleDescription = ""
    var title = ""
    var description = ""
    var value = ""
    var url = ""
    var placeholder = ""
    var help = ""
    var selectedText = ""
    var enabled: Bool? = nil
    var selected: Bool? = nil
    var expanded: Bool? = nil
    var settable = false
    var integer = false
    var boolean = false
    var children: [Node] = []
}

struct AccessibilityCapture {
    var text: String
    var warnings: [String]
    var nodes: Int
}

struct AccessibilityTreeEntry<Node: Hashable> {
    var node: AccessibilityNode<Node>
    var children: [Int] = []
    var isTab: Bool
    var omitted: Bool
    var focused: Bool
}

// Read first so pruning can distinguish an empty branch from a meaningful group.
func readAccessibilityTree<Node: Hashable>(
    _ root: Node,
    focused: Node? = nil,
    limits: AccessibilityLimits = AccessibilityLimits(),
    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    read: (Node) -> AccessibilityNode<Node>?
) -> AccessibilityCapture {
    var stack: [(Node, Int, Int?, String?, Bool)] = [(root, 0, nil, nil, false)]
    var seen = Set<Node>()
    var entries: [AccessibilityTreeEntry<Node>] = []
    var warnings: [String] = []
    var selectedText = ""
    var selectionPriority = 0
    var focusedLine: String?
    var failed = 0
    let deadline = now() + limits.seconds
    while let (element, depth, parent, editorText, isTab) = stack.popLast() {
        if seen.contains(element) { continue }
        if now() >= deadline {
            warnings.append("Accessibility text truncated: reached the \(limits.seconds)-second time limit.")
            break
        }
        if seen.count >= limits.nodes {
            warnings.append("Accessibility text truncated: reached the \(limits.nodes)-element limit.")
            break
        }
        if depth >= limits.depth {
            if !warnings.contains(where: { $0.contains("nesting limit") }) {
                warnings.append("Accessibility text truncated: reached the \(limits.depth)-level nesting limit.")
            }
            continue
        }
        seen.insert(element)
        guard let node = read(element) else { failed += 1; continue }
        if node.subrole == "AXSecureTextField" { continue }
        if element == focused { focusedLine = accessibilityLine(node, isTab: isTab) }
        // Browsers retain an old omnibox selection after focus moves into a page.
        let priority = element == focused ? 3 : (node.role == "AXWebArea" ? 2 : (["AXTextField", "AXTextArea"].contains(node.role) ? 0 : 1))
        if !node.selectedText.isEmpty && priority > selectionPriority {
            selectedText = node.selectedText
            selectionPriority = priority
        }
        let repeatedEditorText = node.role == "AXStaticText" && editorText.map {
            let value = normalizedAccessibilityText(node.value.isEmpty ? node.title : node.value)
            return !value.isEmpty && $0.contains(value)
        } == true
        let index = entries.count
        entries.append(AccessibilityTreeEntry(node: node, isTab: isTab, omitted: repeatedEditorText, focused: element == focused))
        if let parent { entries[parent].children.append(index) }
        let nextEditor = ["AXTextArea", "AXTextField"].contains(node.role) && !node.value.isEmpty
            ? normalizedAccessibilityText(node.value) : editorText
        for child in node.children.reversed() {
            stack.append((child, depth + 1, index, nextEditor, node.role == "AXTabGroup"))
        }
    }
    if failed > 0 { warnings.append("Accessibility text incomplete: \(failed) element(s) could not be read.") }
    return formatAccessibilityTree(entries, focusedLine: focusedLine, selectedText: selectedText, warnings: warnings, nodes: seen.count, limits: limits)
}

func formatAccessibilityTree<Node>(
    _ captured: [AccessibilityTreeEntry<Node>],
    focusedLine: String?,
    selectedText: String,
    warnings: [String],
    nodes: Int,
    limits: AccessibilityLimits
) -> AccessibilityCapture {
    var entries = captured
    var promoted = Array(repeating: [Int](), count: entries.count)
    for index in entries.indices.reversed() {
        entries[index].children = entries[index].children.flatMap { promoted[$0] }
        let label = normalizedAccessibilityText(entries[index].node.title.isEmpty ? entries[index].node.description : entries[index].node.title)
        if entries[index].node.role == "AXLink", !label.isEmpty {
            let filtered = entries[index].children.filter { child in
                let entry = entries[child]
                let value = entry.node.value.isEmpty ? entry.node.title : entry.node.value
                return !(isPlainAccessibilityText(entry) && normalizedAccessibilityText(value) == label)
            }
            entries[index].children = filtered
        }
        let children = entries[index].children
        entries[index].children = coalesceAccessibilityText(children, entries: &entries)
        let entry = entries[index]
        // Keep named containers, states, interactive controls, and multi-child groups.
        if entry.omitted {
            promoted[index] = entry.children
        } else if index != 0 && !entry.focused && isAnonymousAccessibilityGroup(entry.node)
            && (entry.children.isEmpty || (entry.children.count == 1 && ["", "AXUnknown", "AXParagraph", "AXSVGRoot"].contains(entry.node.subrole))) {
            promoted[index] = entry.children
        } else {
            promoted[index] = [index]
        }
    }
    var stack = (promoted.first ?? []).reversed().map { ($0, 0) }
    var lines: [String] = []
    var characters = 0
    var warnings = warnings
    let budget = max(0, limits.characters - min(1_024, limits.characters / 4))
    while let (index, depth) = stack.popLast() {
        let entry = entries[index]
        let indentation = String(repeating: "\t", count: depth)
        let line = accessibilityLine(entry.node, isTab: entry.isTab)
        let indented = indentation + line.replacingOccurrences(of: "\n", with: "\n" + indentation + "\t")
        if !appendAccessibilityLine(indented, to: &lines, count: &characters, budget: budget) {
            warnings.append("Accessibility text truncated: reached the \(limits.characters)-character limit.")
            break
        }
        for child in entry.children.reversed() { stack.append((child, depth + 1)) }
    }
    if !selectedText.isEmpty {
        if !appendAccessibilityLine("\nSelected text: \n\u{0060}\u{0060}\u{0060}\n" + selectedText + "\n\u{0060}\u{0060}\u{0060}", to: &lines, count: &characters, budget: budget) {
            warnings.append("Accessibility text truncated: selected text exceeded the character limit.")
        }
    }
    if let focusedLine {
        if !appendAccessibilityLine("\nThe focused UI element is " + focusedLine, to: &lines, count: &characters, budget: budget) {
            warnings.append("Accessibility text truncated: focused element description exceeded the character limit.")
        }
    }
    if !warnings.isEmpty { lines.append("\n[" + warnings.joined(separator: " ") + "]") }
    return AccessibilityCapture(text: lines.joined(separator: "\n"), warnings: warnings, nodes: nodes)
}

func coalesceAccessibilityText<Node>(_ children: [Int], entries: inout [AccessibilityTreeEntry<Node>]) -> [Int] {
    var result: [Int] = []
    let inline = children.contains { child in
        let entry = entries[child]
        let value = entry.node.value.isEmpty ? entry.node.title : entry.node.value
        return isPlainAccessibilityText(entry) && ["{", "}", "[", "]", ":", ",", "\""].contains(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    for child in children {
        if let previous = result.last,
           isPlainAccessibilityText(entries[previous]), isPlainAccessibilityText(entries[child]) {
            let first = entries[previous].node.value.isEmpty ? entries[previous].node.title : entries[previous].node.value
            let next = entries[child].node.value.isEmpty ? entries[child].node.title : entries[child].node.value
            // Repeated replies may be distinct messages; keep both identities.
            if !first.isEmpty && !next.isEmpty && normalizedAccessibilityText(first) != normalizedAccessibilityText(next) {
                entries[previous].node.title = ""
                entries[previous].node.description = ""
                entries[previous].node.value = first + (inline ? " " : "\n\n") + next
                continue
            }
        }
        result.append(child)
    }
    return result
}

func isPlainAccessibilityText<Node>(_ entry: AccessibilityTreeEntry<Node>) -> Bool {
    let node = entry.node
    let text = node.value.isEmpty ? node.title : node.value
    return node.role == "AXStaticText" && entry.children.isEmpty && !entry.focused
        && node.subrole.isEmpty && node.url.isEmpty && node.help.isEmpty && node.placeholder.isEmpty
        && node.selectedText.isEmpty && node.enabled != false && node.selected != true && node.expanded != true
        && !node.settable && !node.boolean && !node.integer
        && (node.title.isEmpty || normalizedAccessibilityText(node.title) == normalizedAccessibilityText(text))
        && (node.description.isEmpty || normalizedAccessibilityText(node.description) == normalizedAccessibilityText(text))
}

func isAnonymousAccessibilityGroup<Node>(_ node: AccessibilityNode<Node>) -> Bool {
    node.role == "AXGroup"
        && node.title.isEmpty && node.description.isEmpty && node.value.isEmpty
        && node.url.isEmpty && node.placeholder.isEmpty && node.help.isEmpty
        && node.enabled != false && node.selected != true && node.expanded != true && !node.settable
}

func accessibilityLine<Node>(_ node: AccessibilityNode<Node>, isTab: Bool = false) -> String {
    let isTab = isTab || node.subrole == "AXTabButton"
    let role = accessibilityRole(node.role, subrole: node.subrole, description: node.roleDescription, isTab: isTab)
    var flags: [String] = []
    let selected = node.selected == true || (isTab && ["1", "on"].contains(node.value))
    if selected { flags.append("selected") }
    if node.enabled == false { flags.append("disabled") }
    if node.settable { flags.append("settable") }
    if node.boolean { flags.append("boolean") }
    else if node.integer && !(isTab && selected) { flags.append("integer") }
    if node.expanded == true { flags.append("expanded") }
    else if node.expanded == false && ["AXDisclosureTriangle", "AXRow", "AXOutline", "AXComboBox"].contains(node.role) {
        flags.append("collapsed")
    }
    var line = role + (flags.isEmpty ? "" : " (" + flags.joined(separator: ", ") + ")")
    var label = node.title.isEmpty ? node.description : node.title
    if label.isEmpty && ["AXStaticText", "AXTextArea", "AXTextField", "AXListMarker"].contains(node.role) {
        label = node.placeholder.isEmpty ? node.value : node.placeholder
    }
    if !label.isEmpty { line += " " + label }
    if !node.value.isEmpty && normalizedAccessibilityText(node.value) != normalizedAccessibilityText(label) {
        line += ", Value: " + node.value
    }
    if !node.url.isEmpty && node.url != node.value {
        line += (node.role == "AXLink" ? ", Value: " : ", URL: ") + node.url
    }
    if !node.placeholder.isEmpty && node.placeholder != label { line += ", Placeholder: " + node.placeholder }
    if !node.help.isEmpty && node.help != label { line += ", Help: " + node.help }
    return line
}

func accessibilityRole(_ role: String, subrole: String, description: String, isTab: Bool) -> String {
    if role == "AXWindow" && subrole == "AXStandardWindow" { return "standard window" }
    if isTab && role == "AXRadioButton" { return "tab" }
    let subroles = ["AXCloseButton": "close button", "AXZoomButton": "full screen button", "AXMinimizeButton": "minimize button", "AXToggleButton": "toggle button", "AXSwitch": "switch", "AXTabButton": "tab"]
    if let name = subroles[subrole] { return name }
    if role == "AXCheckBox" && ["toggle button", "switch"].contains(description) { return description }
    if role == "AXImage" && description == "unlabeled image" { return "Unlabeled image" }
    let roles = [
        "AXWindow": "window", "AXGroup": "container", "AXWebArea": "HTML content",
        "AXStaticText": "text", "AXTextArea": "text entry area", "AXTextField": "text field",
        "AXButton": "button", "AXPopUpButton": "pop up button", "AXMenuButton": "menu button",
        "AXLink": "link", "AXImage": "image", "AXHeading": "heading",
        "AXToolbar": "toolbar", "AXTabGroup": "tab group", "AXTab": "tab",
        "AXRadioButton": "radio button", "AXCheckBox": "checkbox", "AXSlider": "slider",
        "AXScrollArea": "scroll area", "AXScrollBar": "scroll bar", "AXList": "content list",
        "AXTable": "table", "AXRow": "row", "AXColumn": "column", "AXCell": "cell",
        "AXOutline": "outline", "AXDisclosureTriangle": "disclosure triangle",
        "AXComboBox": "combo box", "AXMenu": "menu", "AXMenuItem": "menu item",
        "AXSplitGroup": "split group", "AXSplitter": "splitter", "AXProgressIndicator": "progress indicator",
        "AXValueIndicator": "value indicator", "AXIncrementor": "incrementor",
        "AXDialog": "dialog", "AXSheet": "sheet", "AXApplication": "application",
    ]
    return roles[role] ?? (description.isEmpty ? role : description)
}

func normalizedAccessibilityText(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func appendAccessibilityLine(_ line: String, to lines: inout [String], count: inout Int, budget: Int) -> Bool {
    let remaining = max(0, budget - count - (lines.isEmpty ? 0 : 1))
    if line.count > remaining {
        if remaining > 0 { lines.append(String(line.prefix(remaining))) }
        count = budget
        return false
    }
    lines.append(line)
    count += line.count + (lines.count > 1 ? 1 : 0)
    return true
}
