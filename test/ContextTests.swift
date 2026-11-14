import AppKit
import os

func captureError(_ message: String) -> NSError { NSError(domain: "ContextTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
let helperBundleID = "local.motifs.tests"
struct ComposerEndpoint { let directory: String }

@main struct ContextTests {
    @MainActor static func main() async throws {
        let temporary = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())

        let system = SystemContext.collect(app: NSRunningApplication.current)
        let memory = system["memory"] as? [String: Any] ?? [:]
        precondition(((memory["physicalBytes"] as? NSNumber)?.uint64Value ?? 0) > 0, "physical memory is reported")
        precondition(["normal", "warning", "critical", "unknown"].contains(memory["pressure"] as? String ?? ""), "memory pressure is named")
        precondition((SystemContext.footprint(pid: getpid()) ?? 0) > 0 && SystemContext.footprint(pid: -1) == nil, "the captured app's footprint is reported")
        precondition(["nominal", "fair", "serious", "critical"].contains(system["thermal"] as? String ?? ""), "thermal state is named")
        precondition(system["lowPowerMode"] is Bool, "low power mode is reported")
        if let storage = system["storage"] as? [String: Any] {
            let available = (storage["availableBytes"] as? NSNumber)?.int64Value ?? -1, total = (storage["totalBytes"] as? NSNumber)?.int64Value ?? 0
            precondition(available >= 0 && total > 0, "storage reports the home volume")
        } else { preconditionFailure("storage is reported") }
        if let battery = system["battery"] as? [String: Any] {
            let level = (battery["level"] as? NSNumber)?.doubleValue ?? -1
            precondition((0...100).contains(level), "battery level is a percentage")
        }
        precondition(SystemContext.pressureName(1) == "normal" && SystemContext.pressureName(2) == "warning" && SystemContext.pressureName(4) == "critical" && SystemContext.pressureName(9) == "unknown", "pressure levels")
        let battery = SystemContext.batteryDescription(["Type": "InternalBattery", "Current Capacity": 40, "Max Capacity": 80, "Is Charging": true, "Power Source State": "AC Power"])
        precondition((battery?["level"] as? Double) == 50 && battery?["charging"] as? Bool == true && battery?["source"] as? String == "AC Power", "battery description")
        precondition(SystemContext.batteryDescription(["Type": "UPS", "Current Capacity": 1, "Max Capacity": 2]) == nil, "only the internal battery counts")
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        let finderInfo = SystemContext.appInfo(finder)
        precondition(finderInfo?["name"] is String && finderInfo?["bundleID"] as? String == "com.apple.finder" && finderInfo?["version"] is String, "captured app name, bundle ID and version")

        let ndjson = """
        {"timestamp":"2026-10-29 10:00:00.1+0530","messageType":"Error","eventMessage":"first","subsystem":"com.example"}
        not json
        {"timestamp":"2026-10-29 10:00:01.1+0530","messageType":"Fault","eventMessage":"\(String(repeating: "x", count: 2500))"}
        {"timestamp":"2026-10-29 10:00:02.1+0530","messageType":"Error","eventMessage":""}
        {"timestamp":"2026-10-29 10:00:03.1+0530","messageType":"Error","eventMessage":"last"}
        """
        let parsed = ConsoleContext.parse(ndjson: Data(ndjson.utf8), limit: 2)
        precondition(parsed.count == 2 && parsed.last?["message"] as? String == "last", "unified log keeps the newest entries")
        precondition(parsed[0]["level"] as? String == "fault" && (parsed[0]["message"] as? String)?.count == 2000, "levels are lowercased and messages capped")
        let all = ConsoleContext.parse(ndjson: Data(ndjson.utf8), limit: 10)
        precondition(all.count == 3 && all[0]["subsystem"] as? String == "com.example" && all.allSatisfy { $0["source"] as? String == "app" }, "malformed and empty lines are skipped")
        Logger(subsystem: "local.motifs.tests", category: "context").fault("motifs-test-fault")
        let started = Date()
        let live = await ConsoleContext.unifiedLog(pid: ProcessInfo.processInfo.processIdentifier, minutes: 1)
        precondition(Date().timeIntervalSince(started) < 10, "unified log queries are bounded")
        precondition(live.contains { ($0["message"] as? String)?.contains("motifs-test-fault") == true }, "the captured process's faults are read from the unified log")

        let logs = temporary.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let big = logs.appendingPathComponent("big.log")
        try (0..<3000).map { "line \($0) " + String(repeating: "y", count: 40) }.joined(separator: "\n").write(to: big, atomically: true, encoding: .utf8)
        let small = logs.appendingPathComponent("small.log")
        try "one\ntwo".write(to: small, atomically: true, encoding: .utf8)
        let tails = CustomLogs.tail(paths: [big.path, logs.path, logs.appendingPathComponent("missing.log").path, small.path], maxBytes: 64_000)
        precondition(tails.count == 2, "directories and missing files are skipped")
        let bigText = tails[0]["text"] as? String ?? ""
        precondition(tails[0]["truncated"] as? Bool == true && bigText.utf8.count <= 64_000 && bigText.hasPrefix("line ") && bigText.hasSuffix("line 2999 " + String(repeating: "y", count: 40)), "large logs keep whole last lines")
        precondition(tails[1]["text"] as? String == "one\ntwo" && tails[1]["truncated"] as? Bool == false && tails[1]["name"] as? String == "small.log", "small logs are read whole")
        precondition(CustomLogs.tail(paths: Array(repeating: small.path, count: 6)).count == 4, "at most 4 log files")
        var settings = CaptureSettings()
        settings.customLogFiles = [small.path]
        let immediate = CaptureContext.immediate(app: finder, settings: settings, events: [["kind": "app-switch", "app": "Finder", "time": "t"]])
        precondition(immediate["device"] != nil && immediate["system"] != nil && immediate["app"] != nil, "fast sources are collected at capture")
        precondition(ContextText.count("events", shots: [], context: immediate) == 1 && ContextText.count("customLogs", shots: [], context: immediate) == 1, "events and custom logs join the context")
        precondition(CaptureContext.immediate(app: nil, settings: CaptureSettings(), events: [])["events"] == nil, "no events key when recording is off")

        let recorder = UserEventRecorder()
        recorder.recordAppSwitch(NSRunningApplication.current)
        precondition(recorder.snapshot().isEmpty, "app switches are ignored while recording is off")
        let now = Date()
        recorder.append(["kind": "click", "app": "Old"], now: now.addingTimeInterval(-700))
        for index in 0..<(UserEventRecorder.limit + 20) { recorder.append(["kind": "click", "app": "App \(index)"], now: now) }
        let events = recorder.snapshot(now: now)
        precondition(events.count == UserEventRecorder.limit && events.last?["app"] as? String == "App \(UserEventRecorder.limit + 19)" && !events.contains { $0["app"] as? String == "Old" }, "the event buffer is capped and expires old entries")
        precondition(recorder.snapshot(now: now.addingTimeInterval(601)).isEmpty, "events expire after 10 minutes")
        recorder.stop()
        precondition(recorder.entries.isEmpty, "stopping clears the buffer")
        precondition(UserEventRecorder.describe(role: "AXSecureTextField", subrole: nil, title: "Password") as? [String: String] == ["role": "AXSecureTextField"], "secure fields never keep labels")
        precondition(UserEventRecorder.describe(role: "AXTextField", subrole: "AXSecureTextField", title: "PIN")["title"] == nil, "secure subroles never keep labels")
        precondition((UserEventRecorder.describe(role: "AXButton", subrole: nil, title: "  " + String(repeating: "p", count: 200))["title"] as? String)?.count == 120, "labels are trimmed and capped")
        precondition(UserEventRecorder.selectionEntry(text: "  Seattle weather  ", role: "AXStaticText", subrole: nil, title: nil)?["text"] as? String == "Seattle weather", "selected text is kept, trimmed")
        precondition(UserEventRecorder.selectionEntry(text: "hunter2", role: "AXTextField", subrole: "AXSecureTextField", title: "Password") == nil, "selections in secure fields are never kept")
        precondition(UserEventRecorder.selectionEntry(text: String(repeating: "s", count: 500), role: nil, subrole: nil, title: nil)?["text"] as? String == String(repeating: "s", count: 200), "selected text is capped")
        var gesture = ScrollAccumulator()
        let scrollStart = Date()
        precondition(gesture.add(app: "Chrome", location: .zero, dx: 0, dy: -40, now: scrollStart) && gesture.add(app: "Chrome", location: .zero, dx: 0, dy: -60, now: scrollStart.addingTimeInterval(0.3)), "a continuing scroll joins the gesture")
        precondition(!gesture.add(app: "Chrome", location: .zero, dx: 0, dy: -10, now: scrollStart.addingTimeInterval(2)) && !gesture.add(app: "Finder", location: .zero, dx: 0, dy: -10, now: scrollStart.addingTimeInterval(0.5)), "a pause or another app starts a new gesture")
        precondition(gesture.entry()?["direction"] as? String == "down" && gesture.entry()?["distance"] as? Int == 100, "a gesture becomes one scroll step")
        let recording = UserEventRecorder()
        recording.beginRecording()
        precondition(recording.isRunning && recording.isRecording, "recordings capture clicks even when Record recent clicks is off")
        recording.append(["kind": "click", "app": "Notes"])
        recording.append(["kind": "type", "app": "Notes", "role": "AXTextArea"])
        precondition(recording.endRecording(keepClicks: false).count == 2 && !recording.isRunning && recording.entries.isEmpty, "ending a recording returns its steps and stops when clicks are off")
        recording.start()
        recording.beginRecording()
        recording.append(["kind": "click", "app": "Notes"])
        recording.append(["kind": "scroll", "app": "Notes", "direction": "down", "distance": 10])
        _ = recording.endRecording(keepClicks: true)
        precondition(recording.isRunning && recording.entries.map { $0["kind"] as? String } == ["click"], "recording-only steps leave the click history when the recording ends")
        recording.stop()
        precondition(ContextText.describeEvent(["kind": "type", "role": "AXTextField", "title": "Search"]) == "Typed into textfield \"Search\"", "typing names the field only")
        precondition(ContextText.describeEvent(["kind": "click", "role": "button", "name": "Run", "source": "browser", "count": 2]) == "Double-clicked button \"Run\"", "browser steps use the role and accessible name")
        precondition(ContextText.describeEvent(["kind": "scroll", "x": 0, "y": 400]) == "Scrolled the page to 0, 400", "page scrolls keep their position")

        precondition(BrowserBridge.isNativeHostLaunch(["chrome-extension://\(browserExtensionID)/"]) && !BrowserBridge.isNativeHostLaunch(["chrome-extension://abcdefghijklmnopabcdefghijklmnop/"]) && !BrowserBridge.isNativeHostLaunch([]), "only the pinned extension starts host mode")
        precondition(BrowserBridge.isChromium("com.google.Chrome") && BrowserBridge.isChromium("com.brave.Browser") && !BrowserBridge.isChromium("com.apple.Safari"), "Chromium browsers are recognised")
        let framed = try BrowserBridge.encodeMessage(["type": "snapshot", "requestID": "r"])
        precondition(BrowserBridge.decodeLength(framed.prefix(4)) == framed.count - 4 && BrowserBridge.decodeLength(Data([1, 2])) == nil, "native messages are length-prefixed")
        precondition(BrowserBridge.socketPath(directory: BrowserBridge.socketDirectory(home: "/Users/x"), browser: 2, pid: 4321) == "/Users/x/Library/Application Support/Motifs/browser/2.4321", "one socket per host in a fixed private folder")
        precondition(PeerSocket.address("/" + String(repeating: "a", count: 200)) == nil, "overlong socket paths are refused")

        let windows: [[String: Any]] = [
            ["focused": true, "snapshot": ["title": "Inbox", "url": "https://mail.test"]],
            ["focused": false, "snapshot": ["title": "Checkout - Shop", "url": "https://shop.test"]],
            ["focused": false],
        ]
        precondition(BrowserBridge.pick(windows: windows, windowTitle: "Checkout - Shop - Google Chrome - Work")?["url"] as? String == "https://shop.test", "the captured window's tab is chosen by title")
        precondition(BrowserBridge.pick(windows: windows, windowTitle: "Something else")?["url"] as? String == "https://mail.test", "falls back to the focused window")
        precondition(BrowserBridge.pick(windows: [], windowTitle: "x") == nil, "no windows, no snapshot")
        let snapshot: [String: Any] = [
            "url": "https://shop.test/pay", "title": "Pay", "userAgent": "Mozilla/5.0",
            "console": Array(repeating: ["time": "t", "level": "error", "message": String(repeating: "m", count: 3000)], count: 320) + [["level": "log"]],
            "network": [["time": "t", "method": "POST", "url": "https://shop.test/api", "status": 502, "type": "xmlhttprequest"], ["method": "GET"]],
        ]
        let context = BrowserBridge.context(from: snapshot)
        precondition((context["browser"] as? [String: Any])?["userAgent"] as? String == "Mozilla/5.0", "browser page and user agent")
        let console = ContextText.entries(context, "console")
        precondition(console.count == 299 && console.allSatisfy { $0["source"] as? String == "browser" && ($0["message"] as? String)?.count == 2000 }, "browser console is capped, labeled and trimmed")
        let network = ContextText.entries(context, "network")
        precondition(network.count == 1 && network[0]["status"] as? Int == 502, "failed requests keep status, entries without URLs are dropped")
        precondition(BrowserBridge.context(from: [:]).isEmpty, "empty snapshots add nothing")

        let support = temporary.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        let installed = try BrowserBridge.installHostManifests(executable: "/Applications/Motifs.app/Contents/MacOS/Motifs", supportDirectory: support)
        precondition(installed == ["Google Chrome"], "manifests are written only for installed browsers")
        let manifestURL = support.appendingPathComponent("Google/Chrome/NativeMessagingHosts/\(nativeHostName).json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        precondition(manifest["allowed_origins"] as? [String] == ["chrome-extension://\(browserExtensionID)/"] && manifest["type"] as? String == "stdio" && manifest["name"] as? String == nativeHostName, "the host allows only the pinned extension")
        precondition(!FileManager.default.fileExists(atPath: support.appendingPathComponent("BraveSoftware").path), "absent browsers are left untouched")

        let sockets = URL(fileURLWithPath: "/tmp/cs-\(getpid())")
        try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sockets) }
        let socketPath = BrowserBridge.socketPath(directory: sockets, browser: 0, pid: getpid())
        guard let server = PeerSocket.listen(path: socketPath) else { preconditionFailure("host socket listens") }
        let socketMode = try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber
        precondition((socketMode?.intValue ?? 0o777) & 0o077 == 0, "host sockets are owner-only")
        precondition(PeerSocket.ownHash != nil, "the helper knows its own code hash")

        let host = NativeHostState()
        var sent: [[String: Any]] = []
        host.send = { data in sent.append((try? JSONSerialization.jsonObject(with: data.dropFirst(4))) as? [String: Any] ?? [:]) }
        let client = Task.detached { BrowserBridge.query(path: socketPath, timeout: 3) }
        let accepted = accept(server, nil, nil)
        precondition(PeerSocket.peerIsSameBinary(accepted), "the helper is accepted by its own host")
        precondition(NativeHostState.requestType(accepted) == "snapshot", "the host reads which request the helper sent")
        host.begin(accepted)
        let requestID = sent.first?["requestID"] as? String ?? ""
        precondition(sent.count == 1 && sent[0]["type"] as? String == "snapshot" && UUID(uuidString: requestID) != nil, "each connection asks the extension once")
        host.receive(try JSONSerialization.data(withJSONObject: ["type": "snapshot", "requestID": UUID().uuidString, "windows": [["focused": true]]]))
        precondition(host.pending.count == 1, "unrequested replies are ignored")
        host.receive(try JSONSerialization.data(withJSONObject: ["type": "snapshot", "requestID": requestID, "windows": windows]))
        let received = await client.value
        precondition(received.count == 3 && host.pending.isEmpty, "the reply goes back on the requesting connection only")
        precondition(BrowserBridge.pick(windows: received, windowTitle: "Checkout - Shop - Brave")?["url"] as? String == "https://shop.test", "the helper picks the captured tab from the reply")
        sent.removeAll()
        let stopping = Task.detached { BrowserBridge.request(path: socketPath, type: "steps-stop", timeout: 3) }
        let stepClient = accept(server, nil, nil)
        let stepType = NativeHostState.requestType(stepClient)
        precondition(stepType == "steps-stop", "stopping page steps is its own request")
        host.begin(stepClient, type: stepType!)
        precondition(sent.first?["type"] as? String == "steps-stop", "the extension is told to stop recording steps")
        host.receive(try JSONSerialization.data(withJSONObject: ["type": "steps", "requestID": sent[0]["requestID"] as? String ?? "", "steps": [["kind": "click", "time": "t"]]]))
        let stopped = await stopping.value
        precondition((stopped?["steps"] as? [[String: Any]])?.first?["kind"] as? String == "click", "recorded steps come back to the helper")

        let impostor = Process()
        impostor.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        impostor.arguments = ["-U", socketPath]
        impostor.standardInput = Pipe()
        impostor.standardOutput = FileHandle.nullDevice
        try impostor.run()
        let foreign = accept(server, nil, nil)
        precondition(!PeerSocket.peerIsSameBinary(foreign), "other processes are refused")
        close(foreign)
        impostor.terminate()

        close(server)
        precondition(BrowserBridge.query(path: socketPath, timeout: 1).isEmpty && !FileManager.default.fileExists(atPath: socketPath), "sockets of exited hosts are cleaned up")

        print("Motifs system, console, custom log, event buffer and browser bridge checks passed")
    }
}
