import AppKit
import Darwin
import IOKit.ps

// Point-in-time system state, read only when the user captures.
enum SystemContext {
    static func collect(app: NSRunningApplication?) -> [String: Any] {
        var memory: [String: Any] = ["physicalBytes": ProcessInfo.processInfo.physicalMemory, "pressure": memoryPressure()]
        if let pid = app?.processIdentifier, let footprint = footprint(pid: pid) { memory["appFootprintBytes"] = footprint }
        var system: [String: Any] = ["memory": memory, "thermal": thermal(ProcessInfo.processInfo.thermalState), "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled]
        if let battery = battery() { system["battery"] = battery }
        if let storage = storage() { system["storage"] = storage }
        return system
    }

    static func memoryPressure() -> String {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return "unknown" }
        return pressureName(level)
    }

    static func pressureName(_ level: Int32) -> String {
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "unknown"
        }
    }

    static func footprint(pid: pid_t) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 && usage.ri_phys_footprint > 0 ? usage.ri_phys_footprint : nil
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func battery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let battery = batteryDescription(description) { return battery }
        }
        return nil
    }

    static func batteryDescription(_ description: [String: Any]) -> [String: Any]? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        var battery: [String: Any] = ["level": Double(current) * 100 / Double(maximum), "charging": description[kIOPSIsChargingKey] as? Bool ?? false]
        if let source = description[kIOPSPowerSourceStateKey] as? String { battery["source"] = source }
        return battery
    }

    static func storage(home: String = NSHomeDirectory()) -> [String: Any]? {
        guard let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let available = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity else { return nil }
        return ["availableBytes": available, "totalBytes": total]
    }

    static func appInfo(_ app: NSRunningApplication?) -> [String: Any]? {
        guard let app, let name = app.localizedName else { return nil }
        var info: [String: Any] = ["name": name]
        if let bundleID = app.bundleIdentifier { info["bundleID"] = bundleID }
        if let url = app.bundleURL, let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { info["version"] = version }
        return info
    }
}

// Errors and faults the captured app wrote to the unified log. Private values
// stay redacted by macOS as <private>.
enum ConsoleContext {
    static func unifiedLog(pid: pid_t, minutes: Int = 5, limit: Int = 200) async -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "\(minutes)m", "--style", "ndjson", "--predicate", "processID == \(pid) AND messageType IN {16, 17}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = await Task.detached { pipe.fileHandleForReading.readData(ofLength: 4_000_000) }.value
        timeout.cancel()
        if process.isRunning { process.terminate() }
        return parse(ndjson: data, limit: limit)
    }

    static func parse(ndjson data: Data, limit: Int) -> [[String: Any]] {
        let entries: [[String: Any]] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = raw["eventMessage"] as? String, !message.isEmpty else { return nil }
            var entry: [String: Any] = [
                "time": raw["timestamp"] as? String ?? "",
                "level": (raw["messageType"] as? String ?? "error").lowercased(),
                "message": String(message.prefix(2000)),
                "source": "app",
            ]
            if let subsystem = raw["subsystem"] as? String, !subsystem.isEmpty { entry["subsystem"] = subsystem }
            return entry
        }
        return Array(entries.suffix(limit))
    }
}

// Tails the log files the user chose in the menu bar.
enum CustomLogs {
    static func tail(paths: [String], maxBytes: Int = 64_000) -> [[String: Any]] {
        paths.prefix(4).compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return nil }
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var text = String(decoding: data, as: UTF8.self)
            if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
            return ["name": url.lastPathComponent, "path": path, "text": text, "truncated": start > 0]
        }
    }
}

enum CaptureContext {
    // Fast sources, ready before the composer opens.
    @MainActor static func immediate(app: NSRunningApplication?, settings: CaptureSettings, events: [[String: Any]]) -> [String: Any] {
        var context: [String: Any] = ["device": DeviceContext.collect(), "system": SystemContext.collect(app: app)]
        if let info = SystemContext.appInfo(app) { context["app"] = info }
        if !events.isEmpty { context["events"] = ["entries": events] }
        let logs = CustomLogs.tail(paths: settings.customLogFiles)
        if !logs.isEmpty { context["customLogs"] = logs }
        return context
    }

    // Slow sources: the unified log for native apps, the extension for browsers.
    static func slow(pid: pid_t?, bundleID: String?, windowTitle: String) async -> [String: Any] {
        if let bundleID, BrowserBridge.isChromium(bundleID) {
            guard let snapshot = await BrowserBridge.requestSnapshot(bundleID: bundleID, windowTitle: windowTitle) else { return [:] }
            return BrowserBridge.context(from: snapshot)
        }
        guard let pid else { return [:] }
        let entries = await ConsoleContext.unifiedLog(pid: pid)
        return entries.isEmpty ? [:] : ["console": ["entries": entries]]
    }
}
