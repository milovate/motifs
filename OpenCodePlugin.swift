import Foundation

enum OpenCodePluginState: Equatable {
    case unavailable(String)
    case notInstalled
    case installed
    case outdated
    case foreign
}

// Copies the plugin bundled in Motifs.app into OpenCode's plugin folder and links
// Motifs.app beside it, because the plugin looks for the helper in its own folder.
// Only a folder carrying the marker file is ever replaced.
struct OpenCodePluginInstaller {
    static let marker = ".motifs-app"
    static let legacyFolderNames = ["capture-studio", "appshots"]
    let source: URL
    let app: URL
    let pluginsFolder: URL
    let version: String
    var destination: URL { pluginsFolder.appendingPathComponent("motifs") }

    static func forRunningApp(environment: [String: String] = ProcessInfo.processInfo.environment) -> OpenCodePluginInstaller? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let source = resources.appendingPathComponent("plugin")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("index.js").path) else { return nil }
        let config = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return OpenCodePluginInstaller(source: source, app: Bundle.main.bundleURL, pluginsFolder: config.appendingPathComponent("opencode/plugins"), version: version)
    }

    var markerContents: String { "\(version)\n\(app.path)\n" }

    func state(fileManager: FileManager = .default) -> OpenCodePluginState {
        let path = app.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return .unavailable("Drag Motifs to Applications, then open it from there.")
        }
        guard fileManager.fileExists(atPath: destination.path) || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil else { return .notInstalled }
        guard let recorded = try? String(contentsOf: destination.appendingPathComponent(Self.marker), encoding: .utf8) else { return .foreign }
        return recorded == markerContents ? .installed : .outdated
    }

    func legacyFolders(fileManager: FileManager = .default) -> [URL] {
        Self.legacyFolderNames.map { pluginsFolder.appendingPathComponent($0) }.filter { fileManager.fileExists(atPath: $0.path) }
    }

    func install(fileManager: FileManager = .default) throws {
        let current = state(fileManager: fileManager)
        guard current == .notInstalled || current == .outdated else { return }
        try fileManager.createDirectory(at: pluginsFolder, withIntermediateDirectories: true)
        let staging = pluginsFolder.appendingPathComponent(".motifs-install-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.createSymbolicLink(at: staging.appendingPathComponent("Motifs.app"), withDestinationURL: app)
        try markerContents.write(to: staging.appendingPathComponent(Self.marker), atomically: true, encoding: .utf8)
        if current == .outdated {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}
