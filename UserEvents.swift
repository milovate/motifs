import AppKit
import ApplicationServices

// Memory-only history of user events. Outside recordings it is opt-in ("Record recent
// clicks") and keeps clicks and app switches. While a screen recording runs it also
// keeps scrolls, drags, selected text and which field was typed into; key codes and
// typed characters are never read. Entries leave memory only inside a bundle the user sends.
@MainActor final class UserEventRecorder {
    static let limit = 300
    static let maxAge: TimeInterval = 600
    static let recordingKinds: Set<String> = ["scroll", "drag", "select", "type"]
    private(set) var entries: [[String: Any]] = []
    private var monitor: Any?
    private var recordingMonitor: Any?
    private var scroll = ScrollAccumulator()
    private var scrollTimer: Timer?
    private var dragStart: NSPoint?
    private var lastTyping: (element: AXUIElement, time: Date)?
    var isRunning: Bool { monitor != nil }
    var isRecording: Bool { recordingMonitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"
            DispatchQueue.global(qos: .utility).async {
                let element = UserEventRecorder.element(at: location)
                Task { @MainActor in self?.append(["kind": "click", "app": app].merging(element) { current, _ in current }) }
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        entries.removeAll()
    }

    func beginRecording() {
        guard recordingMonitor == nil else { return }
        start()
        recordingMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleRecording(event) }
        }
    }

    // Returns what was recorded, then drops the recording-only monitors and kinds.
    func endRecording(keepClicks: Bool) -> [[String: Any]] {
        flushScroll()
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        dragStart = nil
        lastTyping = nil
        let recorded = snapshot()
        if keepClicks { entries.removeAll { Self.recordingKinds.contains($0["kind"] as? String ?? "") } } else { stop() }
        return recorded
    }

    private func handleRecording(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"
        switch event.type {
        case .leftMouseDown:
            dragStart = location
        case .leftMouseUp:
            let dragged = dragStart.map { hypot($0.x - location.x, $0.y - location.y) > 5 } ?? false
            dragStart = nil
            guard dragged || event.clickCount >= 2 else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.08) { [weak self] in
                let selection = UserEventRecorder.focusedSelection()
                Task { @MainActor in
                    if let selection { self?.append(["kind": "select", "app": app].merging(selection) { current, _ in current }) }
                    else if dragged { self?.append(["kind": "drag", "app": app]) }
                }
            }
        case .scrollWheel:
            let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
            let dx = Double(event.scrollingDeltaX) * scale, dy = Double(event.scrollingDeltaY) * scale
            if !scroll.add(app: app, location: location, dx: dx, dy: dy, now: Date()) {
                flushScroll()
                _ = scroll.add(app: app, location: location, dx: dx, dy: dy, now: Date())
            }
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: ScrollAccumulator.gap, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushScroll() }
            }
        case .keyDown:
            // Only the fact that typing happened is used, never which key.
            guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return }
            let now = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let focused = UserEventRecorder.focusedElement() else { return }
                let described = UserEventRecorder.describe(element: focused)
                Task { @MainActor in
                    guard let self else { return }
                    defer { self.lastTyping = (focused, now) }
                    if let last = self.lastTyping, CFEqual(last.element, focused), now.timeIntervalSince(last.time) < 30 { return }
                    self.append(["kind": "type", "app": app].merging(described) { current, _ in current }, now: now)
                }
            }
        default:
            break
        }
    }

    private func flushScroll() {
        scrollTimer?.invalidate()
        scrollTimer = nil
        guard let entry = scroll.entry() else { scroll = ScrollAccumulator(); return }
        let location = scroll.location, started = scroll.started
        scroll = ScrollAccumulator()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let element = UserEventRecorder.element(at: location)
            Task { @MainActor in self?.append(entry.merging(element) { current, _ in current }, now: started) }
        }
    }

    func recordAppSwitch(_ app: NSRunningApplication) {
        guard isRunning, let name = app.localizedName else { return }
        append(["kind": "app-switch", "app": name])
    }

    func append(_ entry: [String: Any], now: Date = Date()) {
        entries.append(entry.merging(["time": ISO8601DateFormatter.events.string(from: now)]) { _, new in new })
        entries.sort { ($0["time"] as? String ?? "") < ($1["time"] as? String ?? "") }
        trim(now: max(Date(), now))
    }

    func snapshot(now: Date = Date()) -> [[String: Any]] {
        trim(now: now)
        return entries
    }

    private func trim(now: Date) {
        let parser = ISO8601DateFormatter.events
        entries = Array(entries.filter { ($0["time"] as? String).flatMap(parser.date(from:)).map { now.timeIntervalSince($0) <= Self.maxAge } ?? false }.suffix(Self.limit))
    }

    nonisolated static func element(at location: NSPoint) -> [String: Any] {
        guard let primary = NSScreen.screens.first?.frame else { return [:] }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(primary.maxY - location.y), &element) == .success, let element else { return [:] }
        return describe(element: element)
    }

    nonisolated static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated static func describe(element: AXUIElement) -> [String: Any] {
        describe(role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute), title: string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute))
    }

    nonisolated static func focusedSelection() -> [String: Any]? {
        guard let element = focusedElement() else { return nil }
        return selectionEntry(text: string(element, kAXSelectedTextAttribute), role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute), title: string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute))
    }

    // Labels only, never values. Secure fields keep their role but lose any label.
    nonisolated static func describe(role: String?, subrole: String?, title: String?) -> [String: Any] {
        var result: [String: Any] = [:]
        if let role { result["role"] = role }
        if !isSecure(role: role, subrole: subrole), let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { result["title"] = String(title.prefix(120)) }
        return result
    }

    nonisolated static func selectionEntry(text: String?, role: String?, subrole: String?, title: String?) -> [String: Any]? {
        guard !isSecure(role: role, subrole: subrole), let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return describe(role: role, subrole: subrole, title: title).merging(["text": String(text.prefix(200))]) { _, new in new }
    }

    nonisolated static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

// Joins scroll-wheel events into one gesture while they keep coming in the same app.
struct ScrollAccumulator {
    static let gap: TimeInterval = 0.8
    var app = ""
    var location = NSPoint.zero
    var started = Date.distantPast
    var last = Date.distantPast
    var dx = 0.0
    var dy = 0.0
    var isEmpty: Bool { dx == 0 && dy == 0 }

    mutating func add(app: String, location: NSPoint, dx: Double, dy: Double, now: Date) -> Bool {
        if !isEmpty, app != self.app || now.timeIntervalSince(last) > Self.gap { return false }
        if isEmpty {
            self.app = app
            self.location = location
            started = now
        }
        self.dx += dx
        self.dy += dy
        last = now
        return true
    }

    // AppKit's scrolling deltas are negative when the content moves toward its end.
    func entry() -> [String: Any]? {
        guard abs(dx) >= 1 || abs(dy) >= 1 else { return nil }
        let vertical = abs(dy) >= abs(dx)
        let direction = vertical ? (dy < 0 ? "down" : "up") : (dx < 0 ? "right" : "left")
        return ["kind": "scroll", "app": app, "direction": direction, "distance": Int(abs(vertical ? dy : dx).rounded())]
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let events: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
