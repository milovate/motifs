import Foundation

@main
struct AccessibilityReaderTests {
    static func main() {
        deepChatAndFormatting()
        duplicateTextAndSecureFields()
        compactLayoutAndSelection()
        selectionAndInlineFragments()
        limitsAndUnreadableNodes()
        print("Accessibility reader: 5 regression groups passed")
    }

    static func deepChatAndFormatting() {
        var nodes: [Int: AccessibilityNode<Int>] = [
            0: AccessibilityNode(role: "AXWindow", subrole: "AXStandardWindow", title: "Fixture", children: [1]),
            1: AccessibilityNode(role: "AXWebArea", title: "Research", url: "https://example.test/research", children: [2]),
        ]
        for depth in 2...44 { nodes[depth] = AccessibilityNode(role: "AXGroup", children: [depth + 1]) }
        nodes[45] = AccessibilityNode(role: "AXGroup", children: [46, 47, 48, 49, 50])
        nodes[46] = AccessibilityNode(role: "AXStaticText", value: "Deep chat message")
        nodes[47] = AccessibilityNode(role: "AXLink", title: "Debug this run", url: "https://example.test/debug")
        nodes[48] = AccessibilityNode(role: "AXTextArea", description: "Message Yatra Partner", value: "draft", placeholder: "Ask a question", settable: true)
        nodes[49] = AccessibilityNode(role: "AXTabGroup", children: [51, 52])
        nodes[50] = AccessibilityNode(role: "AXSlider", description: "audio time scrubber", value: "0", enabled: false, settable: true, integer: true)
        nodes[51] = AccessibilityNode(role: "AXRadioButton", title: "Preview", value: "1", selected: true, expanded: false, integer: true)
        nodes[52] = AccessibilityNode(role: "AXRadioButton", title: "Settings", value: "0", settable: true, integer: true)
        let result = readAccessibilityTree(0, focused: 48, read: { nodes[$0] })
        expect(result.warnings.isEmpty, "deep content must not be silently pruned")
        expect(result.text.contains("\t\t\ttext Deep chat message") && result.nodes == nodes.count, "read deep content while collapsing layout-only wrappers")
        expect(result.text.contains("HTML content Research, URL: https://example.test/research"), "web URL")
        expect(result.text.contains("link Debug this run, Value: https://example.test/debug"), "link target")
        expect(result.text.contains("tab (selected) Preview, Value: 1"), "selected tab")
        expect(!result.text.contains("collapsed"), "do not label ordinary Chromium controls as collapsed")
        let emptyInput = AccessibilityNode<Int>(role: "AXTextArea", placeholder: "Message Yatra Partner", expanded: false, settable: true)
        expect(accessibilityLine(emptyInput) == "text entry area (settable) Message Yatra Partner", "use placeholder to label an otherwise unnamed empty input")
        expect(result.text.contains("tab (settable, integer) Settings, Value: 0"), "editable tab state")
        expect(result.text.contains("slider (disabled, settable, integer) audio time scrubber, Value: 0"), "audio state")
        expect(result.text.contains("The focused UI element is text entry area (settable) Message Yatra Partner, Value: draft, Placeholder: Ask a question"), "focused input")
        expect(result.text.range(of: "text Deep chat message")!.lowerBound < result.text.range(of: "link Debug this run")!.lowerBound, "preserve sibling UI order")
        let outsideFocus = readAccessibilityTree(0, focused: 999, read: { nodes[$0] })
        expect(!outsideFocus.text.contains("The focused UI element"), "focus must belong to this window")
    }

    static func duplicateTextAndSecureFields() {
        let longValue = String(repeating: "long editor content ", count: 2_500)
        let nodes: [Int: AccessibilityNode<Int>] = [
            0: AccessibilityNode(role: "AXWindow", children: [1, 4, 5, 6, 8]),
            1: AccessibilityNode(role: "AXTextArea", value: longValue, settable: true, children: [2, 3]),
            2: AccessibilityNode(role: "AXStaticText", title: "long editor content", value: "long editor content"),
            3: AccessibilityNode(role: "AXButton", title: "Copy"),
            4: AccessibilityNode(role: "AXStaticText", value: "Repeated chat reply"),
            5: AccessibilityNode(role: "AXStaticText", value: "Repeated chat reply"),
            6: AccessibilityNode(role: "AXTextField", subrole: "AXSecureTextField", title: "secret label", value: "secret password", children: [7]),
            7: AccessibilityNode(role: "AXStaticText", value: "secret descendant"),
            8: AccessibilityNode(role: "AXGroup", children: [0, 3]),
        ]
        var readElements: [Int] = []
        let result = readAccessibilityTree(0, read: { readElements.append($0); return nodes[$0] })
        expect(result.text.contains(longValue), "capture and retain an editor value larger than the old 40000-character output cap")
        expect(!result.text.contains("text long editor content"), "omit duplicate editor text descendants")
        expect(result.text.components(separatedBy: "text Repeated chat reply").count == 3, "do not globally deduplicate legitimate chat messages")
        expect(!result.text.contains("secret") && !readElements.contains(7), "exclude secure subtrees")
        expect(readElements.count == Set(readElements).count, "handle cycles and shared references")
        expect(result.warnings.isEmpty, "large complete capture needs no truncation warning")
    }

    static func compactLayoutAndSelection() {
        let nodes: [Int: AccessibilityNode<Int>] = [
            0: AccessibilityNode(role: "AXWindow", children: [1, 2, 3, 4, 12]),
            1: AccessibilityNode(role: "AXGroup", children: [5]),
            2: AccessibilityNode(role: "AXGroup", children: [6]),
            3: AccessibilityNode(role: "AXGroup", children: [7]),
            4: AccessibilityNode(role: "AXGroup", subrole: "AXSVGRoot"),
            5: AccessibilityNode(role: "AXGroup", subrole: "AXUnknown"),
            6: AccessibilityNode(role: "AXGroup", subrole: "AXParagraph", children: [8]),
            7: AccessibilityNode(role: "AXGroup", title: "Conversation", children: [9, 10, 11]),
            8: AccessibilityNode(role: "AXStaticText", value: "First paragraph"),
            9: AccessibilityNode(role: "AXStaticText", value: "Second paragraph"),
            10: AccessibilityNode(role: "AXStaticText", value: "Third paragraph"),
            11: AccessibilityNode(role: "AXLink", title: "Debug", url: "https://example.test/debug"),
            12: AccessibilityNode(role: "AXTextArea", description: "Prompt", value: "draft", selectedText: "invalid_request_error", settable: true),
        ]
        let result = readAccessibilityTree(0, focused: 12, read: { nodes[$0] })
        expect(!result.text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "container" }), "remove empty branches and chains of anonymous single-child groups")
        expect(result.text.contains("\ttext First paragraph"), "promote content through redundant wrappers")
        expect(result.text.contains("\tcontainer Conversation"), "preserve named grouping")
        expect(result.text.contains("text Second paragraph\n\t\t\t\n\t\t\tThird paragraph"), "coalesce text fragments while preserving paragraph boundaries")
        expect(result.text.contains("Selected text: ") && result.text.contains("invalid_request_error"), "include selection from this captured window")
        let boolTab = AccessibilityNode<Int>(role: "AXRadioButton", title: "Chrome tab", value: "on", selected: true, settable: true, boolean: true)
        expect(accessibilityLine(boolTab, isTab: true) == "tab (selected, settable, boolean) Chrome tab, Value: on", "preserve boolean type and on/off value")
        expect(accessibilityRole("AXCheckBox", subrole: "", description: "toggle button", isTab: false) == "toggle button", "respect exposed semantic toggle roles")
        expect(accessibilityRole("AXCheckBox", subrole: "AXToggleButton", description: "", isTab: false) == "toggle button", "use Chromium's toggle subrole")
        expect(accessibilityLine(AccessibilityNode<Int>(role: "AXListMarker", value: "1. ")) == "AXListMarker 1. ", "readable list numbering")
    }

    static func selectionAndInlineFragments() {
        var nodes: [Int: AccessibilityNode<Int>] = [
            0: AccessibilityNode(role: "AXWindow", children: [1, 2]),
            1: AccessibilityNode(role: "AXTextField", description: "Address bar", selectedText: "stale URL"),
            2: AccessibilityNode(role: "AXWebArea", selectedText: "messages.39.content", children: [3, 4, 5]),
            3: AccessibilityNode(role: "AXLink", title: "Usage", url: "https://example.test/usage", children: [6]),
            4: AccessibilityNode(role: "AXGroup", children: [7, 8, 9, 10, 11]),
            5: AccessibilityNode(role: "AXButton", title: "Debug"),
            6: AccessibilityNode(role: "AXStaticText", value: "Usage"),
            7: AccessibilityNode(role: "AXStaticText", value: "{"),
            8: AccessibilityNode(role: "AXStaticText", value: "role"),
            9: AccessibilityNode(role: "AXStaticText", value: ":"),
            10: AccessibilityNode(role: "AXStaticText", value: "assistant"),
            11: AccessibilityNode(role: "AXStaticText", value: "}"),
        ]
        let page = readAccessibilityTree(0, focused: 5, read: { nodes[$0] })
        expect(page.text.contains("messages.39.content") && !page.text.contains("stale URL"), "page selection wins over a stale address bar selection")
        expect(page.text.contains("text { role : assistant }"), "JSON tokens remain in order without paragraph breaks between every token")
        expect(!page.text.contains("text Usage"), "link names do not repeat in their static text descendants")
        let address = readAccessibilityTree(0, focused: 1, read: { nodes[$0] })
        expect(address.text.contains("Selected text: ") && address.text.contains("stale URL"), "a genuinely focused address field retains its selection")
        nodes[2]?.selectedText = ""
        let none = readAccessibilityTree(0, focused: 5, read: { nodes[$0] })
        expect(!none.text.contains("Selected text:"), "an unfocused input alone must not invent a current selection")
    }

    static func limitsAndUnreadableNodes() {
        let nodes: [Int: AccessibilityNode<Int>] = [
            0: AccessibilityNode(role: "AXWindow", children: [1, 2]),
            1: AccessibilityNode(role: "AXGroup", children: [3]),
            2: AccessibilityNode(role: "AXStaticText", value: "Later sibling"),
            3: AccessibilityNode(role: "AXStaticText", value: String(repeating: "x", count: 400)),
        ]
        let depth = readAccessibilityTree(0, limits: AccessibilityLimits(depth: 2), read: { nodes[$0] })
        expect(depth.warnings.contains(where: { $0.contains("nesting limit") }), "report depth pruning")
        expect(depth.text.contains("Later sibling"), "depth pruning must keep later branches")
        let elements = readAccessibilityTree(0, limits: AccessibilityLimits(nodes: 2), read: { nodes[$0] })
        expect(elements.warnings.contains(where: { $0.contains("element limit") }), "report node exhaustion")
        let text = readAccessibilityTree(0, limits: AccessibilityLimits(characters: 300), read: { nodes[$0] })
        expect(text.warnings.contains(where: { $0.contains("character limit") }), "report character exhaustion")
        expect(text.text.count <= 300, "reserve space for an explicit warning")
        var clock: TimeInterval = 0
        let time = readAccessibilityTree(0, limits: AccessibilityLimits(seconds: 2), now: { clock += 1; return clock }, read: { nodes[$0] })
        expect(time.warnings.contains(where: { $0.contains("time limit") }), "report deadline exhaustion")
        let unavailable = readAccessibilityTree(0, read: { $0 == 1 ? nil : nodes[$0] })
        expect(unavailable.warnings.contains(where: { $0.contains("could not be read") }), "report failed AX reads")
    }

    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
