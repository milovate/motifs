import AppKit
import Darwin

let captureBundleSchema = "capture-studio.bundle/1"

// Hardware and OS facts only. Location, network, user and host names are never collected.
enum DeviceContext {
    static func collect(screens: [NSScreen] = NSScreen.screens, locale: Locale = .current) -> [String: Any] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var arch = "unknown"
        #if arch(arm64)
        arch = "arm64"
        #elseif arch(x86_64)
        arch = "x86_64"
        #endif
        var device: [String: Any] = [
            "os": "macOS \(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            "arch": arch,
            "memoryBytes": ProcessInfo.processInfo.physicalMemory,
            "displays": screens.map { ["width": Int($0.frame.width * $0.backingScaleFactor), "height": Int($0.frame.height * $0.backingScaleFactor), "scale": Double($0.backingScaleFactor)] as [String: Any] },
            "locale": locale.identifier,
        ]
        if let model = sysctlString("hw.model") { device["model"] = model }
        if let cpu = sysctlString("machdep.cpu.brand_string") { device["cpu"] = cpu }
        return device
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func summary(_ device: [String: Any]) -> [String] {
        var lines: [String] = []
        if let os = device["os"] as? String { lines.append(os + ((device["arch"] as? String).map { " (\($0))" } ?? "")) }
        if let model = device["model"] as? String { lines.append(model) }
        if let cpu = device["cpu"] as? String { lines.append(cpu) }
        if let memory = (device["memoryBytes"] as? NSNumber)?.doubleValue, memory > 0 { lines.append("\(Int((memory / 1_073_741_824).rounded())) GB memory") }
        let displays = device["displays"] as? [[String: Any]] ?? []
        if !displays.isEmpty {
            let sizes = displays.map { "\(($0["width"] as? NSNumber)?.intValue ?? 0)×\(($0["height"] as? NSNumber)?.intValue ?? 0)@\(($0["scale"] as? NSNumber)?.stringValue ?? "1")x" }
            lines.append("\(displays.count) display\(displays.count == 1 ? "" : "s") (\(sizes.joined(separator: ", ")))")
        }
        if let locale = device["locale"] as? String { lines.append("Locale " + locale) }
        return lines
    }
}

struct BundleInclude: Equatable {
    static let sources = ["windowText", "device", "console", "network", "events", "customLogs"]
    private(set) var excluded = Set<String>()

    init(windowText: Bool = true, device: Bool = true) {
        if !windowText { excluded.insert("windowText") }
        if !device { excluded.insert("device") }
    }
    init(_ raw: [String: Any]?) { excluded = Set(Self.sources.filter { raw?[$0] as? Bool == false }) }

    subscript(source: String) -> Bool {
        get { !excluded.contains(source) }
        set { if newValue { excluded.remove(source) } else { excluded.insert(source) } }
    }
    var windowText: Bool { get { self["windowText"] } set { self["windowText"] = newValue } }
    var device: Bool { get { self["device"] } set { self["device"] = newValue } }
    var dictionary: [String: Any] { Dictionary(uniqueKeysWithValues: Self.sources.map { ($0, self[$0]) }) }
}

// Mirrors the plugin's rendering closely enough for previews and size estimates.
enum ContextText {
    static let labels = ["windowText": "Window", "device": "Device", "console": "Console", "network": "Network", "events": "Steps", "customLogs": "Logs"]

    // One line per user event or page step, shared by the picker, the clip review and the text export.
    static func describeEvent(_ entry: [String: Any]) -> String {
        let role = (entry["role"] as? String).map { $0.hasPrefix("AX") ? String($0.dropFirst(2)).lowercased() : $0 } ?? (entry["tag"] as? String)
        let label = (entry["name"] as? String) ?? (entry["title"] as? String)
        let target = (role ?? "element") + (label.map { " \"\($0)\"" } ?? "")
        let number = { (key: String) in (entry[key] as? NSNumber)?.intValue }
        switch entry["kind"] as? String ?? "" {
        case "click": return ((number("count") ?? 1) > 1 ? "Double-clicked " : "Clicked ") + target
        case "type": return "Typed into " + target
        case "select": return "Selected \"\(entry["text"] as? String ?? "")\"" + (role == nil ? "" : " in " + target)
        case "scroll":
            if let direction = entry["direction"] as? String { return "Scrolled \(direction) \(number("distance") ?? 0) pt" + (role == nil ? "" : " over " + target) }
            return "Scrolled " + (role == nil && entry["selector"] == nil ? "the page" : target) + " to \(number("x") ?? 0), \(number("y") ?? 0)"
        case "drag": return "Dragged" + (role == nil ? "" : " in " + target)
        case "choose": return "Chose \"\(entry["option"] as? String ?? "")\" in " + target
        case "check": return (entry["checked"] as? Bool == true ? "Checked " : "Unchecked ") + target
        case "upload": return "Chose a file for " + target
        case "submit": return "Submitted " + target
        case "navigate": return "Opened " + (entry["url"] as? String ?? "a page")
        case "tab": return "Switched to tab " + ((entry["title"] as? String) ?? (entry["url"] as? String) ?? "")
        case "app-switch": return "Switched to " + (entry["app"] as? String ?? "app")
        case let kind: return kind
        }
    }

    static func eventSymbol(_ kind: String) -> String {
        switch kind {
        case "click": return "cursorarrow.click"
        case "type": return "keyboard"
        case "select": return "text.cursor"
        case "scroll": return "scroll"
        case "drag": return "hand.draw"
        case "choose", "check": return "checkmark.square"
        case "upload": return "doc.badge.plus"
        case "submit": return "paperplane"
        case "navigate", "tab": return "safari"
        default: return "arrow.left.arrow.right"
        }
    }

    static func entries(_ context: [String: Any], _ key: String) -> [[String: Any]] {
        (context[key] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
    }

    static func count(_ source: String, shots: [[String: Any]], context: [String: Any]) -> Int {
        switch source {
        case "windowText": return shots.filter { !(($0["text"] as? String) ?? "").isEmpty }.count
        case "device": return render(source, shots: shots, context: context).isEmpty ? 0 : 1
        case "customLogs": return (context["customLogs"] as? [[String: Any]])?.count ?? 0
        default: return entries(context, source).count
        }
    }

    static func render(_ source: String, shots: [[String: Any]], context: [String: Any]) -> String {
        let field = { (entry: [String: Any], key: String) in entry[key].map { "\($0)" } ?? "" }
        switch source {
        case "windowText":
            return String(shots.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n").prefix(120_000))
        case "device":
            var lines = DeviceContext.summary(context["device"] as? [String: Any] ?? [:])
            if let app = context["app"] as? [String: Any], let name = app["name"] as? String { lines.append("Captured app: \(name) \(field(app, "version"))".trimmingCharacters(in: .whitespaces)) }
            if let browser = context["browser"] as? [String: Any] { lines.append("Browser page: \(field(browser, "title")) \(field(browser, "url"))") }
            if let system = context["system"] as? [String: Any] {
                if let memory = system["memory"] as? [String: Any], let pressure = memory["pressure"] as? String { lines.append("Memory pressure: " + pressure) }
                if let battery = system["battery"] as? [String: Any], let level = (battery["level"] as? NSNumber)?.doubleValue { lines.append("Battery: \(Int(level.rounded()))%" + (battery["charging"] as? Bool == true ? ", charging" : "")) }
                if let storage = system["storage"] as? [String: Any], let free = (storage["availableBytes"] as? NSNumber)?.doubleValue { lines.append(String(format: "Storage: %.0f GB free", free / 1_073_741_824)) }
                if let thermal = system["thermal"] as? String { lines.append("Thermal state: " + thermal) }
            }
            return lines.joined(separator: "\n")
        case "console":
            return entries(context, "console").map { "[\(field($0, "time"))] \(field($0, "level").uppercased()) \(field($0, "source") == "browser" ? "page" : ($0["subsystem"] as? String ?? "app")): \(field($0, "message"))" }.joined(separator: "\n")
        case "network":
            return entries(context, "network").map { "[\(field($0, "time"))] \(field($0, "method")) \($0["status"].map { "\($0)" } ?? field($0, "error")) \(field($0, "url"))" }.joined(separator: "\n")
        case "events":
            return entries(context, "events").map { "[\(field($0, "time"))] \(describeEvent($0))" + ($0["kind"] as? String == "app-switch" || field($0, "app").isEmpty ? "" : " in \(field($0, "app"))") }.joined(separator: "\n")
        case "customLogs":
            return (context["customLogs"] as? [[String: Any]] ?? []).map { "== \(field($0, "name")) ==\n\(field($0, "text"))" }.joined(separator: "\n\n")
        default:
            return ""
        }
    }
}

// Included context as delivered. Roughly 4 characters per token.
func contextCharacterCount(shots: [[String: Any]], context: [String: Any], include: BundleInclude) -> Int {
    BundleInclude.sources.filter { include[$0] }.reduce(0) { $0 + contextCharacterCount($1, shots: shots, context: context) }
}

func contextCharacterCount(_ source: String, shots: [[String: Any]], context: [String: Any]) -> Int {
    let length = ContextText.render(source, shots: shots, context: context).count
    return source == "windowText" ? length : min(length, 60_000)
}

func formatTokenEstimate(characters: Int) -> String {
    let tokens = Int((Double(characters) / 4).rounded(.up))
    return tokens >= 1000 ? String(format: "≈%.1fk tokens", Double(tokens) / 1000) : "≈\(tokens) tokens"
}

func writeCaptureBundle(shots: [[String: Any]], videos: [[String: Any]] = [], note: String, context: [String: Any], include: BundleInclude, output: String, id: UUID = UUID(), createdAt: Date? = nil, now: Date = Date()) throws -> String {
    let formatter = ISO8601DateFormatter()
    let bundle: [String: Any] = [
        "schema": captureBundleSchema,
        "id": id.uuidString.lowercased(),
        "createdAt": formatter.string(from: createdAt ?? now),
        "updatedAt": formatter.string(from: now),
        "note": note,
        "media": shots.map { $0.merging(["kind": "image"]) { current, _ in current } } + videos.prefix(3).map { $0.merging(["kind": "video"]) { _, new in new } },
        "context": context,
        "include": include.dictionary,
    ]
    let path = URL(fileURLWithPath: output).appendingPathComponent("bundle-\(id.uuidString.lowercased()).json").path
    let data = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
    guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw captureError("Could not save the capture bundle.") }
    return path
}

struct LoadedBundle {
    let path: String
    let id: UUID?
    let createdAt: Date?
    let shots: [[String: Any]]
    let videos: [[String: Any]]
    let note: String
    let context: [String: Any]
    let include: BundleInclude
    let missingScreenshots: Int
}

// Video entries keep only the MP4 and frame PNGs that still exist in the captures folder.
func restoredVideo(_ entry: [String: Any], root: URL) -> [String: Any]? {
    let inRoot = { (path: String?, ext: String) -> String? in
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return file.deletingLastPathComponent() == root && file.pathExtension == ext && FileManager.default.fileExists(atPath: file.path) ? path : nil
    }
    guard let video = inRoot(entry["video"] as? String, "mp4") else { return nil }
    var restored = entry
    restored["video"] = video
    restored["frames"] = (entry["frames"] as? [[String: Any]] ?? []).prefix(6).filter { inRoot($0["screenshot"] as? String, "png") != nil }
    return restored
}

// Only bundles and screenshots directly inside the captures folder can be reopened.
func loadCaptureBundle(path: String, output: String) throws -> LoadedBundle {
    let root = URL(fileURLWithPath: output).resolvingSymlinksInPath()
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard file.deletingLastPathComponent() == root, file.lastPathComponent.hasPrefix("bundle-"), file.pathExtension == "json" else { throw captureError("Bundles must be in the Capture Studio captures folder.") }
    let data = try Data(contentsOf: file)
    guard data.count <= 2_000_000, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          raw["schema"] as? String == captureBundleSchema, let allMedia = raw["media"] as? [[String: Any]] else { throw captureError("This capture bundle is invalid or from a newer version.") }
    let media = allMedia.filter { $0["kind"] as? String != "video" }
    let videoEntries = allMedia.filter { $0["kind"] as? String == "video" }
    guard media.count <= 8, videoEntries.count <= 3 else { throw captureError("This capture bundle is invalid or from a newer version.") }
    let videos = videoEntries.compactMap { restoredVideo($0, root: root) }
    var shots: [[String: Any]] = []
    for shot in media {
        guard let screenshot = shot["screenshot"] as? String else { continue }
        let image = URL(fileURLWithPath: screenshot).resolvingSymlinksInPath()
        guard image.deletingLastPathComponent() == root, image.pathExtension == "png", FileManager.default.fileExists(atPath: image.path) else { continue }
        var restored = shot
        restored.removeValue(forKey: "kind")
        shots.append(restored)
    }
    return LoadedBundle(path: file.path, id: (raw["id"] as? String).flatMap(UUID.init(uuidString:)), createdAt: (raw["createdAt"] as? String).flatMap(ISO8601DateFormatter().date(from:)), shots: shots, videos: videos, note: raw["note"] as? String ?? "", context: raw["context"] as? [String: Any] ?? [:], include: BundleInclude(raw["include"] as? [String: Any]), missingScreenshots: media.count - shots.count + videoEntries.count - videos.count)
}

struct RecentBundle {
    let path: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let screenshots: Int
    let videos: Int
    let thumbnail: String?
}

func recentBundles(output: String, limit: Int = 8) -> [RecentBundle] {
    let folder = URL(fileURLWithPath: output)
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    let parser = ISO8601DateFormatter()
    let bundles: [RecentBundle] = files.filter { $0.lastPathComponent.hasPrefix("bundle-") && $0.pathExtension == "json" }.compactMap { file in
        guard let data = try? Data(contentsOf: file), data.count <= 2_000_000,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any], raw["schema"] as? String == captureBundleSchema,
              let created = (raw["createdAt"] as? String).flatMap(parser.date(from:)) else { return nil }
        let allMedia = raw["media"] as? [[String: Any]] ?? []
        let media = allMedia.filter { $0["kind"] as? String != "video" }
        let videos = allMedia.filter { $0["kind"] as? String == "video" }
        let thumbnail = media.first?["screenshot"] as? String ?? (videos.first?["frames"] as? [[String: Any]])?.first?["screenshot"] as? String
        let note = (raw["note"] as? String ?? "").split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let fallback = media.first?["app"] as? String ?? (videos.isEmpty ? "Capture" : "Screen recording")
        let title = note.isEmpty ? fallback : (note.count > 48 ? String(note.prefix(45)) + "…" : note)
        let updated = (raw["updatedAt"] as? String).flatMap(parser.date(from:)) ?? created
        return RecentBundle(path: file.path, title: title, createdAt: created, updatedAt: updated, screenshots: media.count, videos: videos.count, thumbnail: thumbnail)
    }
    return Array(bundles.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
}

struct CaptureSettings: Equatable {
    static let builtinDestinations: [(id: String, label: String)] = [("opencode", "OpenCode"), ("clipboard", "Clipboard"), ("folder", "Save to folder")]
    var defaultDestination = "opencode"
    var knownDestinations: [(id: String, label: String)] = CaptureSettings.builtinDestinations
    var recordClicks = false
    var customLogFiles: [String] = []
    var instantReplay = false
    var include = BundleInclude()
    var prefixes: [String] = []
    var showBubble = true
    var redactionJudge = ""
    var redactionModel = ""
    static let maxPrefixes = 12
    static let maxPrefixLength = 500

    static func == (lhs: CaptureSettings, rhs: CaptureSettings) -> Bool {
        lhs.defaultDestination == rhs.defaultDestination && lhs.knownDestinations.map(\.id) == rhs.knownDestinations.map(\.id) && lhs.knownDestinations.map(\.label) == rhs.knownDestinations.map(\.label)
            && lhs.recordClicks == rhs.recordClicks && lhs.customLogFiles == rhs.customLogFiles && lhs.instantReplay == rhs.instantReplay
            && lhs.include == rhs.include && lhs.prefixes == rhs.prefixes && lhs.showBubble == rhs.showBubble
            && lhs.redactionJudge == rhs.redactionJudge && lhs.redactionModel == rhs.redactionModel
    }

    static func load(output: String) -> CaptureSettings {
        var settings = CaptureSettings()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: output + "/settings.json")), data.count <= 64_000,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return settings }
        if let id = raw["defaultDestination"] as? String, id.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) != nil { settings.defaultDestination = id }
        let known = (raw["knownDestinations"] as? [[String: Any]] ?? []).compactMap { entry -> (id: String, label: String)? in
            guard let id = entry["id"] as? String, let label = entry["label"] as? String, !label.isEmpty else { return nil }
            return (id, String(label.prefix(60)))
        }
        if !known.isEmpty { settings.knownDestinations = Array(known.prefix(16)) }
        settings.recordClicks = raw["recordClicks"] as? Bool == true
        settings.instantReplay = raw["instantReplay"] as? Bool == true
        settings.include = BundleInclude(raw["include"] as? [String: Any])
        settings.prefixes = Array((raw["prefixes"] as? [String] ?? []).filter { !$0.isEmpty && $0.count <= maxPrefixLength }.prefix(maxPrefixes))
        settings.showBubble = raw["showBubble"] as? Bool ?? true
        if let redaction = raw["redaction"] as? [String: Any] {
            settings.redactionJudge = (redaction["judge"] as? String).flatMap(localJudgeAddress) ?? ""
            settings.redactionModel = String((redaction["model"] as? String ?? "").prefix(80))
        }
        settings.customLogFiles = Array((raw["customLogFiles"] as? [String] ?? []).filter { $0.hasPrefix("/") && $0.count <= 1024 }.prefix(4))
        return settings
    }

    func save(output: String) throws {
        let raw: [String: Any] = [
            "defaultDestination": defaultDestination,
            "knownDestinations": knownDestinations.map { ["id": $0.id, "label": $0.label] },
            "recordClicks": recordClicks,
            "instantReplay": instantReplay,
            "customLogFiles": Array(customLogFiles.prefix(4)),
            "include": include.dictionary,
            "prefixes": Array(prefixes.prefix(CaptureSettings.maxPrefixes)),
            "showBubble": showBubble,
            "redaction": ["judge": redactionJudge, "model": redactionModel],
        ]
        let path = output + "/settings.json"
        let temporary = path + ".tmp"
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .prettyPrinted])
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { throw captureError("Could not save Capture Studio settings.") }
        guard rename(temporary, path) == 0 else { throw captureError("Could not save Capture Studio settings.") }
    }
}

// The secret-check model must run on this Mac: a hosted model would receive the secrets.
func localJudgeAddress(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme == "http", url.user == nil, url.password == nil,
          let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host) else { return nil }
    return trimmed
}

struct ComposerTarget: Equatable {
    let id: String
    let label: String
    let detail: String?
    let actionLabel: String
    let hint: String
    let endpoint: Int
}

struct ComposerDestination: Equatable {
    let id: String
    let label: String
    let status: String
    var targets: [ComposerTarget]
}

enum DesktopDraftApp: String {
    case claude, codex

    var label: String { self == .claude ? "Claude" : "Codex" }
    var bundleID: String { self == .claude ? "com.anthropic.claudefordesktop" : "com.openai.codex" }

    func draftURL(text: String, directory: String?) -> URL? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var link = URLComponents()
        link.scheme = rawValue
        switch self {
        case .claude:
            link.host = "claude.ai"
            link.path = "/new"
            link.queryItems = [URLQueryItem(name: "q", value: text)]
        case .codex:
            guard let directory, directory.hasPrefix("/") else { return nil }
            link.host = "threads"
            link.path = "/new"
            link.queryItems = [URLQueryItem(name: "prompt", value: text), URLQueryItem(name: "path", value: directory)]
        }
        link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return link.url
    }
}

// Each loaded OpenCode project serves the same destination list. Targets are
// merged by id and remember the first endpoint that offered them.
func mergeDestinations(_ responses: [(endpoint: Int, destinations: [[String: Any]])]) -> [ComposerDestination] {
    var merged: [ComposerDestination] = []
    for response in responses {
        for raw in response.destinations {
            guard let id = raw["id"] as? String, let label = raw["label"] as? String else { continue }
            let status = raw["status"] as? String ?? "not-running"
            let targets: [ComposerTarget] = (raw["targets"] as? [[String: Any]] ?? []).compactMap { target in
                guard let targetID = target["id"] as? String, let targetLabel = target["label"] as? String else { return nil }
                return ComposerTarget(id: targetID, label: targetLabel, detail: target["detail"] as? String, actionLabel: target["actionLabel"] as? String ?? "Continue", hint: target["hint"] as? String ?? "", endpoint: response.endpoint)
            }
            if let index = merged.firstIndex(where: { $0.id == id }) {
                for target in targets where !merged[index].targets.contains(where: { $0.id == target.id }) { merged[index].targets.append(target) }
                if status == "ready" && merged[index].status != "ready" { merged[index] = ComposerDestination(id: id, label: merged[index].label, status: status, targets: merged[index].targets) }
            } else {
                merged.append(ComposerDestination(id: id, label: label, status: status, targets: targets))
            }
        }
    }
    return merged
}

// Plugins older than destinations only offer OpenCode drafts.
func legacyOpenCodeDestination(_ endpoint: ComposerEndpoint) -> [String: Any] {
    let name = URL(fileURLWithPath: endpoint.directory).lastPathComponent
    return ["id": "opencode", "label": "OpenCode", "status": "ready", "targets": [["id": endpoint.directory, "label": name.isEmpty ? "Project" : name, "detail": endpoint.directory, "actionLabel": "Review in OpenCode", "hint": "Opens an unsent draft in a new session. You press Enter."]]]
}
