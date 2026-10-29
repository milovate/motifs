import AppKit
import ApplicationServices

// Opt-in, memory-only history of recent clicks and app switches. Keystrokes are
// never observed. Entries leave memory only inside a bundle the user sends.
@MainActor final class UserEventRecorder {
    static let limit = 100
    static let maxAge: TimeInterval = 600
    private(set) var entries: [[String: Any]] = []
    private var monitor: Any?
    var isRunning: Bool { monitor != nil }

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

    func recordAppSwitch(_ app: NSRunningApplication) {
        guard isRunning, let name = app.localizedName else { return }
        append(["kind": "app-switch", "app": name])
    }

    func append(_ entry: [String: Any], now: Date = Date()) {
        entries.append(entry.merging(["time": ISO8601DateFormatter().string(from: now)]) { _, new in new })
        trim(now: now)
    }

    func snapshot(now: Date = Date()) -> [[String: Any]] {
        trim(now: now)
        return entries
    }

    private func trim(now: Date) {
        let parser = ISO8601DateFormatter()
        entries = Array(entries.filter { ($0["time"] as? String).flatMap(parser.date(from:)).map { now.timeIntervalSince($0) <= Self.maxAge } ?? false }.suffix(Self.limit))
    }

    nonisolated static func element(at location: NSPoint) -> [String: Any] {
        guard let primary = NSScreen.screens.first?.frame else { return [:] }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(primary.maxY - location.y), &element) == .success, let element else { return [:] }
        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        return describe(role: string(kAXRoleAttribute), subrole: string(kAXSubroleAttribute), title: string(kAXTitleAttribute) ?? string(kAXDescriptionAttribute))
    }

    // Labels only, never values. Secure fields keep their role but lose any label.
    nonisolated static func describe(role: String?, subrole: String?, title: String?) -> [String: Any] {
        var result: [String: Any] = [:]
        if let role { result["role"] = role }
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        if !secure, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { result["title"] = String(title.prefix(120)) }
        return result
    }
}
