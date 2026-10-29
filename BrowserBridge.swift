import AppKit
import Darwin
import Security

let browserExtensionID = "ffjgcjgbehaoabcniapiljdcpeehoocd"
let nativeHostName = "local.opencode.capturestudio"

// Connects capture to the Capture Studio browser extension. Chrome launches this
// same executable as a native messaging host; the menu-bar helper asks it for
// the extension's buffer only when the user captures a browser window. The two
// talk over a Unix socket and each refuses a peer that is not this same signed
// binary, so other processes can neither request nor read browser context.
enum BrowserBridge {
    static let browsers: [(name: String, bundleID: String, support: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Chrome Canary", "com.google.Chrome.canary", "Google/Chrome Canary"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Chromium", "org.chromium.Chromium", "Chromium"),
        ("Arc", "company.thebrowser.Browser", "Arc/User Data"),
    ]

    static func isChromium(_ bundleID: String) -> Bool { browsers.contains { $0.bundleID == bundleID } }

    static func isNativeHostLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "chrome-extension://\(browserExtensionID)/" }
    }

    static func socketDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Capture Studio/browser")
    }

    // One socket per running host: "<browser index>.<host pid>". Short names keep
    // the path under the 104-byte sockaddr_un limit.
    static func socketPath(directory: URL, browser: Int, pid: pid_t) -> String {
        directory.appendingPathComponent("\(browser).\(pid)").path
    }

    static func hostManifest(executable: String) -> [String: Any] {
        ["name": nativeHostName, "description": "Capture Studio browser context", "path": executable, "type": "stdio", "allowed_origins": ["chrome-extension://\(browserExtensionID)/"]]
    }

    static func installHostManifests(executable: String, supportDirectory: URL) throws -> [String] {
        var installed: [String] = []
        let data = try JSONSerialization.data(withJSONObject: hostManifest(executable: executable), options: [.prettyPrinted, .sortedKeys])
        for browser in browsers {
            let root = supportDirectory.appendingPathComponent(browser.support)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let hosts = root.appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent(nativeHostName + ".json"), options: .atomic)
            installed.append(browser.name)
        }
        return installed
    }

    static func encodeMessage(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(payload.count).littleEndian
        return Data(bytes: &length, count: 4) + payload
    }

    static func decodeLength(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        return Int(UInt32(littleEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
    }

    static func runNativeHost() -> Never {
        let directory = socketDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        guard let browser = NSRunningApplication(processIdentifier: getppid())?.bundleIdentifier,
              let index = browsers.firstIndex(where: { $0.bundleID == browser }) else { exit(0) }
        let path = socketPath(directory: directory, browser: index, pid: getpid())
        guard let server = PeerSocket.listen(path: path) else { exit(0) }
        let state = NativeHostState()
        Thread.detachNewThread {
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { continue }
                guard PeerSocket.peerIsSameBinary(client) else { close(client); continue }
                DispatchQueue.main.async { state.begin(client) }
            }
        }
        Thread.detachNewThread {
            let input = FileHandle.standardInput
            while true {
                guard let length = decodeLength(input.readData(ofLength: 4)), length <= 16_000_000 else { break }
                let payload = input.readData(ofLength: length)
                guard payload.count == length else { break }
                DispatchQueue.main.async { state.receive(payload) }
            }
            unlink(path)
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    static func requestSnapshot(bundleID: String, windowTitle: String, timeout: TimeInterval = 2) async -> [String: Any]? {
        guard let index = browsers.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
        let directory = socketDirectory()
        let paths = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("\(index).") }.map { directory.appendingPathComponent($0).path }
        let windows = await withTaskGroup(of: [[String: Any]].self) { group in
            for path in paths.prefix(8) { group.addTask { query(path: path, timeout: timeout) } }
            var all: [[String: Any]] = []
            for await result in group { all += result }
            return all
        }
        return pick(windows: windows, windowTitle: windowTitle)
    }

    static func query(path: String, timeout: TimeInterval) -> [[String: Any]] {
        guard let socket = PeerSocket.connect(path: path, timeout: timeout) else { return [] }
        defer { close(socket) }
        guard PeerSocket.peerIsSameBinary(socket), let data = PeerSocket.readAll(socket, limit: 32_000_000),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return raw["windows"] as? [[String: Any]] ?? []
    }

    // Chrome window titles are "<tab title> - <browser>", sometimes with a profile suffix.
    static func pick(windows: [[String: Any]], windowTitle: String) -> [String: Any]? {
        let snapshots = windows.compactMap { window -> (focused: Bool, snapshot: [String: Any])? in
            guard let snapshot = window["snapshot"] as? [String: Any] else { return nil }
            return (window["focused"] as? Bool ?? false, snapshot)
        }
        let matching = snapshots.first { ($0.snapshot["title"] as? String).map { !$0.isEmpty && windowTitle.hasPrefix($0) } ?? false }
        return (matching ?? snapshots.first { $0.focused } ?? snapshots.first)?.snapshot
    }

    static func context(from snapshot: [String: Any]) -> [String: Any] {
        var context: [String: Any] = [:]
        var browser: [String: Any] = [:]
        for (key, limit) in [("url", 2000), ("title", 300), ("userAgent", 400)] {
            if let value = snapshot[key] as? String, !value.isEmpty { browser[key] = String(value.prefix(limit)) }
        }
        if !browser.isEmpty { context["browser"] = browser }
        let console: [[String: Any]] = (snapshot["console"] as? [[String: Any]] ?? []).suffix(300).compactMap { entry in
            guard let message = entry["message"] as? String, !message.isEmpty else { return nil }
            return ["time": entry["time"] as? String ?? "", "level": entry["level"] as? String ?? "log", "message": String(message.prefix(2000)), "source": "browser"]
        }
        if !console.isEmpty { context["console"] = ["entries": console] }
        let network: [[String: Any]] = (snapshot["network"] as? [[String: Any]] ?? []).suffix(200).compactMap { entry in
            guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
            var result: [String: Any] = ["time": entry["time"] as? String ?? "", "method": entry["method"] as? String ?? "GET", "url": String(url.prefix(2000))]
            for key in ["status", "error", "type"] { if let value = entry[key] { result[key] = value } }
            return result
        }
        if !network.isEmpty { context["network"] = ["entries": network] }
        return context
    }
}

// Each connection from the helper becomes one request to the extension; the
// reply goes back on that connection only.
final class NativeHostState {
    var pending: [String: Int32] = [:]
    var send: (Data) -> Void = { FileHandle.standardOutput.write($0) }
    var timeout: TimeInterval = 3

    func begin(_ client: Int32) {
        let requestID = UUID().uuidString
        guard let message = try? BrowserBridge.encodeMessage(["type": "snapshot", "requestID": requestID]) else { close(client); return }
        pending[requestID] = client
        send(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let client = self?.pending.removeValue(forKey: requestID) { close(client) }
        }
    }

    func receive(_ payload: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], message["type"] as? String == "snapshot",
              let requestID = message["requestID"] as? String, let client = pending.removeValue(forKey: requestID) else { return }
        defer { close(client) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["windows": message["windows"] as? [[String: Any]] ?? []]) else { return }
        PeerSocket.writeAll(client, data)
    }
}

enum PeerSocket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withAddress<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = address
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }

    static func makeSocket() -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return socket
    }

    static func listen(path: String) -> Int32? {
        guard let address = address(path), let socket = makeSocket() else { return nil }
        unlink(path)
        let previous = umask(0o077)
        let bound = withAddress(address) { bind(socket, $0, $1) } == 0
        umask(previous)
        guard bound, Darwin.listen(socket, 8) == 0 else { close(socket); return nil }
        return socket
    }

    static func connect(path: String, timeout: TimeInterval) -> Int32? {
        guard let address = address(path), let socket = makeSocket() else { return nil }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard withAddress(address, { Darwin.connect(socket, $0, $1) }) == 0 else {
            if errno == ECONNREFUSED { unlink(path) }
            close(socket)
            return nil
        }
        return socket
    }

    static func readAll(_ socket: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(socket, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0, data.count + count <= limit else { return nil }
            data.append(buffer, count: count)
        }
    }

    static func writeAll(_ socket: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(socket, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    static func cdhash(_ code: SecCode) -> Data? {
        var information: CFDictionary?
        // SecCode is accepted wherever SecStaticCode is; this reads the running code's hash.
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    static let ownHash: Data? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return cdhash(code)
    }()

    // The peer must be a validly signed process with exactly this binary's code
    // directory hash. The audit token pins the process, so pid reuse cannot fool it.
    static func peerIsSameBinary(_ socket: Int32) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0, let ownHash else { return false }
        let attributes = [kSecGuestAttributeAudit: Data(bytes: &token, count: Int(size))] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        return cdhash(code) == ownHash
    }
}
