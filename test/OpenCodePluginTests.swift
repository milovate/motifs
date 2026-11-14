import Foundation

@main struct OpenCodePluginTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = root.appendingPathComponent("Motifs.app/Contents/Resources/plugin")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "export default {}".write(to: source.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let app = root.appendingPathComponent("Applications/Motifs.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let plugins = root.appendingPathComponent("config/opencode/plugins")
        var installer = OpenCodePluginInstaller(source: source, app: app, pluginsFolder: plugins, version: "0.5.0")

        precondition(installer.state() == .notInstalled, "a missing plugin folder can be installed")
        precondition(installer.legacyFolders().isEmpty, "no legacy copy yet")
        try installer.install()
        precondition(installer.state() == .installed, "the installed copy is recognised")
        let link = try fm.destinationOfSymbolicLink(atPath: installer.destination.appendingPathComponent("Motifs.app").path)
        precondition(link == app.path, "the plugin links to the installed app")
        precondition(fm.fileExists(atPath: installer.destination.appendingPathComponent("index.js").path), "plugin files are copied")
        let entries = try fm.contentsOfDirectory(atPath: plugins.path)
        precondition(entries == ["motifs"], "no staging folder is left behind")

        installer = OpenCodePluginInstaller(source: source, app: app, pluginsFolder: plugins, version: "0.6.0")
        precondition(installer.state() == .outdated, "a newer app refreshes its own copy")
        try installer.install()
        precondition(installer.state() == .installed, "the refreshed copy records the new version")

        let marker = installer.destination.appendingPathComponent(OpenCodePluginInstaller.marker)
        try fm.removeItem(at: marker)
        precondition(installer.state() == .foreign, "a folder without the marker belongs to someone else")
        try installer.install()
        precondition(!fm.fileExists(atPath: marker.path), "a foreign folder is never replaced")

        let mounted = OpenCodePluginInstaller(source: source, app: URL(fileURLWithPath: "/Volumes/Motifs/Motifs.app"), pluginsFolder: plugins, version: "0.6.0")
        guard case .unavailable = mounted.state() else { preconditionFailure("an app running from the DMG must not install") }

        try fm.createDirectory(at: plugins.appendingPathComponent("capture-studio"), withIntermediateDirectories: true)
        precondition(installer.legacyFolders().map(\.lastPathComponent) == ["capture-studio"], "an older Capture Studio copy is reported")
        print("OpenCode plugin install checks passed")
    }
}
