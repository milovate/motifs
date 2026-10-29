import AppKit

func captureError(_ message: String) -> NSError { NSError(domain: "ComposerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
@MainActor func saveStatus(output: String, phase: String, details: [String: Any]) {}
@MainActor func openSessionDraft(sessionID: String, title: String, draftText: String, shot: [String: Any], output: String) async throws { fatalError("Tests must never hand a draft to the real desktop") }
@MainActor func captureScreenSelection(output: String) async throws -> [String: Any]? { fatalError("Tests must never capture the real desktop") }

@main struct ComposerTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = CommandLine.arguments[1]
        let icon = appshotStatusImage()
        precondition(icon.isTemplate && icon.size == NSSize(width: 18, height: 18), "compact template icon adapts to menu-bar appearance")
        precondition(NSBitmapImageRep(data: icon.tiffRepresentation!) != nil, "status icon renders without external assets")
        if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"] {
            let bitmap = NSBitmapImageRep(data: icon.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("appshots-menu-icon.png"))
        }
        let screenshot = URL(fileURLWithPath: output).appendingPathComponent("fixture.png")
        let image = NSImage(size: NSSize(width: 640, height: 400), flipped: false) { bounds in
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            bounds.fill()
            NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 365, width: 640, height: 35).fill()
            for index in 0..<6 {
                NSColor(calibratedWhite: 0.7 + CGFloat(index % 2) * 0.12, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 40, y: 280 - index * 30, width: 270 + index * 18, height: 10), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: screenshot)
        let composer = try AppshotComposer(shots: [["app": "Google Chrome", "title": "Sample page", "screenshot": screenshot.path]], note: "", context: [:], include: BundleInclude(), output: output, returnTo: nil)
        composer.endpoints = [ComposerEndpoint(directory: "/fixture/GooeyAI", port: 1, token: String(repeating: "a", count: 64))]
        composer.populateProjects()
        composer.projects.isEnabled = true
        composer.skillsButton.isEnabled = true
        composer.applyAvailableSkills([("report", "Report"), ("other", "Other")])
        composer.status.stringValue = "Only sent when you’re ready."
        composer.window!.contentView!.layoutSubtreeIfNeeded()
        composer.updateInputSize()
        composer.window!.contentView!.layoutSubtreeIfNeeded()
        precondition(composer.window!.frame.width == 640, "compact width")
        precondition(composer.window!.frame.height < 270, "compact height")
        precondition(!composer.window!.styleMask.contains(.titled), "no legacy title bar")
        precondition(composer.window!.contentView!.superview!.layer!.masksToBounds, "native frame is clipped, not only the inner material")
        precondition(composer.window!.contentView!.superview!.layer!.cornerRadius == 22, "native frame uses the same rounded contour")
        precondition(composer.window!.contentView!.superview!.layer!.borderWidth == 0, "no rectangular native-frame outline")
        precondition(composer.projects.titleOfSelectedItem == "GooeyAI", "project basename, not full path")
        precondition((composer.window!.contentView as! NSVisualEffectView).maskImage != nil, "behind-window blur is rounded, not a rectangle")
        precondition(composer.selectedSkills.isEmpty && composer.textView.string.isEmpty, "no skill is added automatically")
        precondition(composer.prefixButton.treatment == .quiet && composer.prefixMenu().items.first?.isEnabled == false, "no prefixes until one is saved")
        composer.textView.string = "@report Checkout:"
        composer.updateInputSize()
        composer.saveCurrentPrefix()
        composer.textView.string = "@other"
        composer.updateInputSize()
        composer.saveCurrentPrefix()
        precondition(composer.settings.prefixes == ["@other", "@report Checkout:"] && CaptureSettings.load(output: output).prefixes == composer.settings.prefixes, "prefixes are saved newest first")
        composer.textView.string = "button is broken"
        composer.updateInputSize()
        composer.applyPrefix("@report Checkout:")
        precondition(composer.textView.string == "@report Checkout: button is broken" && composer.selectedSkills == ["report"] && composer.activePrefix == "@report Checkout:", "choosing a prefix puts it at the start")
        precondition(composer.prefixButton.treatment == .chip && composer.prefixMenu().items[1].state == .on, "the active prefix is checked")
        composer.applyPrefix("@other")
        precondition(composer.textView.string == "@other button is broken" && composer.selectedSkills == ["other"], "choosing another prefix swaps it")
        composer.applyPrefix("@other")
        precondition(composer.textView.string == "button is broken" && composer.activePrefix == nil, "choosing the active prefix removes it")
        let removeItem = composer.prefixMenu().items.last!.submenu!.items[0]
        composer.removePrefix(removeItem)
        precondition(CaptureSettings.load(output: output).prefixes == ["@report Checkout:"], "prefixes can be removed")
        composer.updatePrefixes { $0.removeAll() }
        composer.textView.string = ""
        composer.updateInputSize()
        precondition(composer.sendButton.isEnabled, "a capture can continue without a note")
        let compactHeight = composer.window!.frame.height
        composer.textView.string = "@report The button does not respond when I click it."
        composer.updateInputSize()
        precondition(composer.sendButton.isEnabled, "typed drafts can send")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            composer.window!.appearance = NSAppearance(named: appearance)
            composer.window!.contentView!.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"] {
                let content = composer.window!.contentView!
                let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: representation) }
                try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("composer-\(name).png"))
                if let frame = content.superview, let full = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                    frame.effectiveAppearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: full) }
                    try full.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("composer-frame-\(name).png"))
                }
            }
        }
        composer.textView.string = "@report " + Array(repeating: "This is a longer report with enough detail to grow the composer.", count: 12).joined(separator: "\n")
        composer.updateInputSize()
        composer.window!.contentView!.layoutSubtreeIfNeeded()
        precondition(composer.window!.frame.height > compactHeight, "composer grows with input")
        precondition(composer.inputHeight.constant <= 180, "long reports scroll instead of filling the screen")
        composer.textView.string = "No skill here"
        composer.updateInputSize()
        precondition(composer.selectedSkills.isEmpty, "deleting the mention removes the skill")
        let picker = ComposerSkillPicker()
        picker.skills = composer.skills
        _ = picker.view
        picker.search.stringValue = "report"
        picker.rebuild()
        precondition(picker.rows.arrangedSubviews.count == 1, "search filters skills")
        precondition(!composer.speech.isRunning, "UI setup never starts microphone")
        composer.textView.string = "@re"
        composer.textView.setSelectedRange(NSRange(location: 3, length: 0))
        composer.updateInputSize()
        precondition(composer.mentionCompletion.candidates.first?.id == "report", "@ prefix opens matching completion")
        composer.mentionCompletion.show(near: composer.textView)
        let mentionRows = (composer.mentionCompletion.panel.contentView?.subviews.first as? NSStackView)?.arrangedSubviews.compactMap { $0 as? ComposerMentionRow } ?? []
        mentionRows.first?.layoutSubtreeIfNeeded()
        let mentionLabel = mentionRows.first?.subviews.first?.subviews.first
        precondition(mentionRows.first?.skillID == "report" && mentionRows.first?.selected == true && (mentionLabel?.frame.minX ?? 99) <= 10 && composer.mentionCompletion.panel.frame.width == ComposerMentionCompletion.width, "suggestions are compact and left-aligned")
        if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"], let surface = composer.mentionCompletion.panel.contentView {
            let detached = surface
            composer.mentionCompletion.panel.contentView = nil
            detached.appearance = NSAppearance(named: .darkAqua)
            let representation = detached.bitmapImageRepForCachingDisplay(in: detached.bounds)!
            detached.effectiveAppearance.performAsCurrentDrawingAppearance { detached.cacheDisplay(in: detached.bounds, to: representation) }
            try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("mentions.png"))
        }
        precondition(composer.handleMentionKey(36), "Enter selects the skill instead of submitting")
        precondition(composer.textView.string == "@report ", "completion replaces the query")
        precondition(composer.selectedSkills == ["report"], "recognized mention drives attachments")
        precondition(composer.sendButton.isEnabled == !composer.shots.isEmpty, "a skill alone continues only with a capture attached")
        let attributes = composer.textView.layoutManager!.temporaryAttributes(atCharacterIndex: 1, effectiveRange: nil)
        precondition(composer.textView.mentionRanges == [NSRange(location: 0, length: 7)], "recognized mentions have a custom rounded highlight")
        precondition(attributes[.font] == nil, "skill mentions inherit the exact body font instead of switching weight")
        precondition(attributes[.backgroundColor] == nil, "no square system highlight behind skill mentions")
        composer.textView.string = "@report broken button"
        composer.updateInputSize()
        let commandA = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: composer.window!.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(composer.textView.performKeyEquivalent(with: commandA), "Command-A is handled in the accessory app without a menu")
        precondition(composer.textView.selectedRange() == NSRange(location: 0, length: (composer.textView.string as NSString).length), "Command-A selects the whole draft")
        composer.textView.insertText("replacement", replacementRange: composer.textView.selectedRange())
        composer.updateInputSize()
        precondition(composer.textView.string == "replacement" && composer.selectedSkills.isEmpty, "replacing text removes stale skill state")
        composer.applyAvailableSkills(composer.skills)
        precondition(composer.textView.string == "replacement", "skill reload never resurrects a removed default")
        let matches = ComposerMentions.matches(in: "email user@report.com /@report @reporter @report", skills: ["report"])
        precondition(matches.count == 1 && matches[0].id == "report", "only full skill mentions are recognized")
        precondition(ComposerMentions.query(in: "@report", selection: NSRange(location: 3, length: 0)) == nil, "completion never replaces half a token")
        composer.textView.string = "🙂 @ot"
        composer.textView.setSelectedRange(NSRange(location: 6, length: 0))
        composer.updateInputSize()
        precondition(composer.handleMentionKey(36) && composer.textView.string == "🙂 @other ", "completion uses UTF-16 caret offsets")
        composer.mentionCompletion.dismiss()
        let originalShot = composer.shots[0]
        composer.shots.append(originalShot.merging(["app": "Region 2"]) { _, new in new })
        composer.selectedShotIndex = 1
        composer.refreshAttachments()
        let tiles = composer.thumbnailStrip.arrangedSubviews.compactMap { $0 as? ScreenshotThumbnailView }
        precondition(tiles.count == 2, "each screenshot has direct annotate/remove controls")
        precondition(tiles.allSatisfy { $0.removeButton.alphaValue == 0 && !$0.removeButton.isHidden }, "remove appears on hover but stays reachable for keyboard and VoiceOver")
        precondition(tiles[0].imageButton.menu?.items.map(\.title) == ["Copy Image", "Share…", "Show in Finder", "Copy Path"], "right-click offers copy and share")
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("appshots-test-\(UUID().uuidString)"))
        tiles[0].pasteboard = testPasteboard
        tiles[0].copyFile()
        precondition(testPasteboard.data(forType: .png) != nil, "Copy Image puts the PNG on the clipboard")
        tiles[0].copyPath()
        precondition(testPasteboard.string(forType: .string) == tiles[0].file?.path, "Copy Path copies the file path")
        testPasteboard.releaseGlobally()
        if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"] {
            composer.window!.appearance = NSAppearance(named: .aqua)
            composer.textView.string = "@report The second screenshot shows the issue."
            composer.updateInputSize()
            composer.window!.contentView!.layoutSubtreeIfNeeded()
            precondition(composer.textView.textContainer?.widthTracksTextView == true, "composer text wraps to the visible editor width")
            precondition((composer.textView.textContainer?.containerSize.width ?? 0) < 2000, "text container must not use an effectively infinite width")
            precondition(composer.textView.alignment == .left, "composer input is explicitly left-aligned")
            let paragraph = composer.textView.textStorage!.attribute(.paragraphStyle, at: composer.textView.string.distance(from: composer.textView.string.startIndex, to: composer.textView.string.firstIndex(of: "T")!), effectiveRange: nil) as? NSParagraphStyle
            precondition(paragraph?.alignment == .left && paragraph?.lineBreakMode == .byWordWrapping, "composer text uses normal word wrapping, not justified spacing")
            if let layout = composer.textView.layoutManager, let container = composer.textView.textContainer {
                layout.ensureLayout(for: container)
                let text = composer.textView.string as NSString
                for index in 0..<text.length where text.substring(with: NSRange(location: index, length: 1)) == " " {
                    let rect = layout.boundingRect(forGlyphRange: NSRange(location: index, length: 1), in: container)
                    precondition(rect.width < 8, "space glyphs keep normal body-font width instead of stale expanded layout attributes")
                }
            }
            let content = composer.window!.contentView!
            let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: representation) }
            try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("composer-multiple-screenshots.png"))
        }
        composer.removeScreenshot(at: 0)
        precondition(composer.shots.count == 1 && composer.selectedShotIndex == 0 && composer.shot["app"] as? String == "Region 2", "removing an earlier thumbnail preserves selection")
        composer.removeScreenshot(at: 0)
        precondition(composer.shots.isEmpty && (composer.screenshotBundle["screenshots"] as! [[String: Any]]).isEmpty, "removing the last screenshot leaves an intentional text-only draft")
        print("Composer compact layout, adaptive sizing, skill chips, search and consent checks passed")
        try captureStudioChecks(output: output, screenshot: screenshot.path)
    }

    @MainActor static func captureStudioChecks(output: String, screenshot: String) throws {
        let device = DeviceContext.collect(screens: [], locale: Locale(identifier: "en_IN"))
        precondition((device["os"] as? String)?.hasPrefix("macOS ") == true, "device context names the macOS version")
        precondition(["arm64", "x86_64"].contains(device["arch"] as? String ?? ""), "device context names the architecture")
        precondition(((device["memoryBytes"] as? NSNumber)?.uint64Value ?? 0) > 0, "device context includes physical memory")
        precondition(device["model"] is String && device["cpu"] is String, "model and CPU come from sysctl")
        precondition(device["locale"] as? String == "en_IN", "locale is recorded")
        precondition(Set(device.keys).isSubset(of: ["os", "arch", "memoryBytes", "displays", "locale", "model", "cpu"]), "no location, host or user identifiers")
        let summary = DeviceContext.summary(["os": "macOS 15.2", "arch": "arm64", "memoryBytes": 34_359_738_368 as UInt64, "displays": [["width": 3024, "height": 1964, "scale": 2.0]], "locale": "en_IN"])
        precondition(summary == ["macOS 15.2 (arm64)", "32 GB memory", "1 display (3024×1964@2x)", "Locale en_IN"], "device summary matches the JS rendering")
        precondition(formatTokenEstimate(characters: 4000) == "≈1.0k tokens" && formatTokenEstimate(characters: 40) == "≈10 tokens", "token estimate")
        let shots: [[String: Any]] = [["app": "Chrome", "screenshot": screenshot, "text": String(repeating: "a", count: 400)]]
        let deviceOnly: [String: Any] = ["device": device]
        precondition(contextCharacterCount(shots: shots, context: deviceOnly, include: BundleInclude(windowText: false, device: false)) == 0, "excluded sources add no context")
        precondition(contextCharacterCount(shots: shots, context: [:], include: BundleInclude()) == 400, "window text counts toward the estimate")
        var include = BundleInclude(windowText: false, device: true)
        include["console"] = false
        precondition(!include["console"] && include["network"] && BundleInclude(include.dictionary) == include, "every source has a flag that round-trips")
        let rich: [String: Any] = [
            "console": ["entries": [["time": "t1", "level": "error", "message": "boom", "source": "browser"]]],
            "network": ["entries": [["time": "t2", "method": "POST", "url": "https://x.test/api", "status": 500]]],
            "events": ["entries": [["time": "t3", "kind": "click", "app": "Chrome", "role": "AXButton", "title": "Pay"], ["time": "t4", "kind": "app-switch", "app": "Finder"]]],
            "customLogs": [["name": "app.log", "path": "/tmp/app.log", "text": "line"]],
        ]
        precondition(ContextText.render("console", shots: [], context: rich) == "[t1] ERROR page: boom", "console renders like the plugin")
        precondition(ContextText.render("network", shots: [], context: rich) == "[t2] POST 500 https://x.test/api", "network renders like the plugin")
        precondition(ContextText.render("events", shots: [], context: rich) == "[t3] Clicked button \"Pay\" in Chrome\n[t4] Switched to Finder", "events render like the plugin")
        precondition(["console", "network", "events", "customLogs"].map { ContextText.count($0, shots: [], context: rich) } == [1, 1, 2, 1], "per-source counts")
        precondition(contextCharacterCount(shots: [], context: rich, include: include) < contextCharacterCount(shots: [], context: rich, include: BundleInclude()), "excluding a source shrinks the estimate")

        let id = UUID()
        let path = try writeCaptureBundle(shots: shots, note: "Checkout overlaps\nsecond line", context: deviceOnly.merging(rich) { a, _ in a }, include: BundleInclude(windowText: false, device: true), output: output, id: id, now: Date(timeIntervalSince1970: 1_800_000_000))
        precondition(URL(fileURLWithPath: path).lastPathComponent == "bundle-\(id.uuidString.lowercased()).json", "bundles are named by id in the captures root")
        func mode(_ file: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue ?? 0 }
        let bundleMode = try mode(path)
        precondition(bundleMode == 0o600, "bundle manifests are owner-only")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        precondition(raw["schema"] as? String == captureBundleSchema && raw["note"] as? String == "Checkout overlaps\nsecond line", "bundle schema and note")
        precondition((raw["media"] as? [[String: Any]])?.first?["kind"] as? String == "image", "media entries are typed")
        precondition((raw["include"] as? [String: Bool]) == ["windowText": false, "device": true, "console": true, "network": true, "events": true, "customLogs": true], "include flags are stored")
        precondition(((raw["context"] as? [String: Any])?["device"] as? [String: Any])?["arch"] != nil, "device context is stored")
        let loaded = try loadCaptureBundle(path: path, output: output)
        precondition(loaded.shots.count == 1 && loaded.note.hasPrefix("Checkout") && loaded.include == BundleInclude(windowText: false, device: true) && loaded.missingScreenshots == 0, "bundles reopen with media, note and include flags")
        precondition(ContextText.count("network", shots: [], context: loaded.context) == 1, "bundles reopen with their stored context")
        precondition(loaded.shots[0]["kind"] == nil, "reopened shots match the composer shape")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-outside-\(UUID().uuidString).json")
        try Data(contentsOf: URL(fileURLWithPath: path)).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        var rejected = false
        do { _ = try loadCaptureBundle(path: outside.path, output: output) } catch { rejected = true }
        precondition(rejected, "bundles outside the captures folder are refused")
        let missingPath = try writeCaptureBundle(shots: [["app": "Gone", "screenshot": output + "/deleted.png"]], note: "", context: [:], include: BundleInclude(), output: output, now: Date(timeIntervalSince1970: 1_700_000_000))
        let missing = try loadCaptureBundle(path: missingPath, output: output)
        precondition(missing.missingScreenshots == 1, "deleted screenshots are reported, not silently attached")
        let recents = recentBundles(output: output)
        precondition(recents.map { URL(fileURLWithPath: $0.path).lastPathComponent } == [path, missingPath].map { URL(fileURLWithPath: $0).lastPathComponent }, "recent bundles are newest first")
        precondition(recents[0].title == "Checkout overlaps" && recents[1].title == "Gone" && recents[0].screenshots == 1, "recent titles use the note, then the app")

        let saving = try AppshotComposer(shots: shots, note: "", context: [:], include: BundleInclude(), output: output, returnTo: nil)
        saving.autosave()
        let saved = output + "/bundle-\(saving.bundleID.uuidString.lowercased()).json"
        precondition(saving.manifest == saved && FileManager.default.fileExists(atPath: saved), "a capture is saved as a bundle as soon as it opens")
        saving.textView.string = "Draft in progress"
        saving.textDidChange(Notification(name: NSText.didChangeNotification))
        precondition(saving.manifest == nil && saving.autosaveTimer != nil, "edits schedule a save")
        saving.autosave()
        let draftNote = try loadCaptureBundle(path: saved, output: output).note
        precondition(saving.manifest == saved && draftNote == "Draft in progress", "the same bundle is updated in place")
        let savedEntry = recentBundles(output: output).first { URL(fileURLWithPath: $0.path).lastPathComponent == URL(fileURLWithPath: saved).lastPathComponent }
        precondition(savedEntry?.title == "Draft in progress" && savedEntry!.updatedAt >= savedEntry!.createdAt, "the saved draft is listed in Recents with its edit time")
        saving.openRecent(path)
        precondition(saving.manifest == path && saving.textView.string.hasPrefix("Checkout overlaps") && !saving.include.windowText && saving.bundleID == id, "Recents reopens a saved bundle in the composer")
        saving.textView.string = "Checkout overlaps, edited"
        saving.textDidChange(Notification(name: NSText.didChangeNotification))
        saving.autosave()
        let reopenedNote = try loadCaptureBundle(path: path, output: output).note
        let previousNote = try loadCaptureBundle(path: saved, output: output).note
        precondition(reopenedNote == "Checkout overlaps, edited" && previousNote == "Draft in progress", "edits go to the reopened bundle and leave the previous one intact")
        let recentsList = ComposerRecents(output: output, current: path)
        _ = recentsList.view
        precondition(recentsList.rows.count >= 3 && recentsList.rows.filter(\.current).count == 1, "Recents lists saved bundles and marks the open one")
        precondition(ComposerRecents.thumbnail(screenshot, root: URL(fileURLWithPath: output).resolvingSymlinksInPath()) != nil && ComposerRecents.thumbnail(outside.path, root: URL(fileURLWithPath: output).resolvingSymlinksInPath()) == nil, "thumbnails come only from the captures folder")

        var settings = CaptureSettings.load(output: output)
        precondition(settings.defaultDestination == "opencode" && settings.knownDestinations.map(\.id) == ["opencode", "clipboard", "folder"], "settings default to OpenCode")
        settings.defaultDestination = "clipboard"
        try settings.save(output: output)
        precondition(CaptureSettings.load(output: output) == settings, "default destination persists")
        precondition(!settings.recordClicks && settings.customLogFiles.isEmpty, "click recording and custom logs are off by default")
        settings.recordClicks = true
        settings.customLogFiles = ["/tmp/a.log", "relative.log", "/tmp/b.log", "/tmp/c.log", "/tmp/d.log", "/tmp/e.log"]
        try settings.save(output: output)
        let reloaded = CaptureSettings.load(output: output)
        precondition(reloaded.recordClicks && reloaded.customLogFiles == ["/tmp/a.log", "/tmp/b.log", "/tmp/c.log"], "at most 4 absolute log paths persist")
        settings.recordClicks = false
        settings.customLogFiles = []
        precondition(!settings.instantReplay, "instant replay is off by default")
        settings.instantReplay = true
        try settings.save(output: output)
        precondition(CaptureSettings.load(output: output).instantReplay, "instant replay persists")
        settings.include = BundleInclude(windowText: false, device: true)
        try settings.save(output: output)
        precondition(CaptureSettings.load(output: output).include == BundleInclude(windowText: false, device: true), "context switches are remembered")
        settings.include = BundleInclude()
        settings.instantReplay = false
        try settings.save(output: output)

        let movie = output + "/replay-fixture.mp4"
        FileManager.default.createFile(atPath: movie, contents: Data([0, 0, 0, 24]))
        let frameFiles = (1...3).map { output + "/replay-fixture-frame-\($0).png" }
        for file in frameFiles { try FileManager.default.copyItem(atPath: screenshot, toPath: file) }
        let video: [String: Any] = ["video": movie, "source": "replay", "startedAt": "2026-10-29T10:00:00Z", "durationSeconds": 30, "frames": frameFiles.enumerated().map { ["screenshot": $1, "offsetSeconds": Double($0) * 10] } + [["screenshot": output + "/gone.png", "offsetSeconds": 29]]]
        let videoPath = try writeCaptureBundle(shots: shots, videos: [video, video, video, video], note: "With replay", context: [:], include: BundleInclude(), output: output)
        let videoRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: videoPath))) as! [String: Any]
        let videoMedia = (videoRaw["media"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "video" }
        precondition(videoMedia.count == 3 && videoMedia[0]["video"] as? String == movie, "bundles store up to three typed video entries after the screenshots")
        let reopened = try loadCaptureBundle(path: videoPath, output: output)
        precondition(reopened.shots.count == 1 && reopened.videos.count == 3 && (reopened.videos[0]["frames"] as? [[String: Any]])?.count == 3 && reopened.missingScreenshots == 0, "reopened bundles restore the recording and drop missing frames")
        precondition(recentBundles(output: output).first { $0.path.hasSuffix(URL(fileURLWithPath: videoPath).lastPathComponent) }?.screenshots == 1, "recent bundles count screenshots only")
        try FileManager.default.removeItem(atPath: movie)
        let withoutMovie = try loadCaptureBundle(path: videoPath, output: output)
        precondition(withoutMovie.videos.isEmpty && withoutMovie.missingScreenshots == 3, "deleted recordings are reported")
        FileManager.default.createFile(atPath: movie, contents: Data([0, 0, 0, 24]))

        let withVideo = try AppshotComposer(shots: shots, videos: [video], note: "", context: [:], include: BundleInclude(), output: output, returnTo: nil)
        let handoff = withVideo.screenshotBundle["screenshots"] as? [[String: Any]] ?? []
        precondition(handoff.count == 5 && handoff[0]["screenshot"] as? String == screenshot && handoff[1]["title"] as? String == "Frame 1 of 4", "recording frames follow the screenshots in the OpenCode handoff")
        precondition(handoff.dropFirst().allSatisfy { $0["capturedAt"] == nil && $0["app"] as? String == "Instant replay" }, "frames never become the insertion marker")
        precondition(withVideo.thumbnailStrip.arrangedSubviews.contains { $0 is VideoThumbnailView }, "the recording shows as an attachment")
        precondition(withVideo.preparingFrames && !withVideo.sendButton.isEnabled, "a clip with the wrong number of frames is re-extracted before sending")
        withVideo.preparingFrames = false
        withVideo.removeVideo(at: 0)
        precondition(withVideo.videos.isEmpty && !withVideo.thumbnailStrip.arrangedSubviews.contains { $0 is VideoThumbnailView } && (withVideo.screenshotBundle["screenshots"] as? [[String: Any]])?.count == 1, "removing the recording drops it and its frames")
        let videoOnly = try AppshotComposer(shots: [], videos: [video], note: "", context: [:], include: BundleInclude(), output: output, returnTo: nil)
        precondition(!videoOnly.thumbnailStrip.arrangedSubviews.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("No attachments") == true }, "a recording alone is a valid capture")

        func clip(_ frames: Int, source: String = "recording") -> [String: Any] {
            ["video": movie, "source": source, "startedAt": "2026-10-29T10:00:00Z", "durationSeconds": 20, "frames": Array(frameFiles.prefix(frames)).enumerated().map { ["screenshot": $1, "offsetSeconds": Double($0)] }]
        }
        let three = try AppshotComposer(shots: shots, videos: [clip(2), clip(2), clip(2), clip(2)], note: "", context: [:], include: BundleInclude(), output: output, returnTo: nil)
        let threeHandoff = three.screenshotBundle["screenshots"] as? [[String: Any]] ?? []
        precondition(three.videos.count == 3 && !three.preparingFrames && three.thumbnailStrip.arrangedSubviews.filter { $0 is VideoThumbnailView }.count == 3, "up to three clips, two frames each")
        precondition(threeHandoff.count == 7 && threeHandoff[3]["app"] as? String == "Screen recording 2" && threeHandoff[6]["title"] as? String == "Frame 2 of 2", "several clips are numbered in the handoff")
        AppshotComposer.onRecord = nil
        precondition(!three.canAddRecording, "recording needs the menu-bar helper")
        var asked: AppshotComposer?
        AppshotComposer.onRecord = { asked = $0 }
        precondition(!three.canAddRecording, "no fourth clip")
        three.removeVideo(at: 1)
        precondition(three.videos.count == 2 && three.preparingFrames && !three.sendButton.isEnabled, "removing a clip re-splits the frames before sending")
        three.preparingFrames = false
        three.refreshAttachments()
        precondition(three.canAddRecording && three.addRecordingButton.isEnabled && three.addRecordingButton.title == "2/3", "the record button offers another clip and shows how many are used")
        three.addRecording()
        precondition(asked === three && three.recordingClip && !three.canEditAttachments && !three.sendButton.isEnabled && three.windowShouldClose(three.window!) == false, "recording hides the composer and locks it until the clip arrives")
        three.recordingFinished(nil)
        precondition(!three.recordingClip && three.videos.count == 2, "a cancelled recording changes nothing")
        three.addRecording()
        let freshEvents: [[String: Any]] = [["time": "2026-10-29T10:00:04Z", "kind": "click", "app": "Safari", "role": "AXButton", "title": "Buy"]]
        three.recordingFinished(clip(3), events: freshEvents)
        precondition(three.videos.count == 3 && ContextText.entries(three.context, "events").count == 1 && three.status.stringValue.hasPrefix("Recording added"), "a finished recording is added with the clicks made while recording")
        AppshotComposer.onRecord = nil

        let markerContext: [String: Any] = [
            "events": ["entries": freshEvents + [["time": "2026-10-29T09:00:00Z", "kind": "click", "app": "Old"]]],
            "console": ["entries": [["time": "2026-10-29T10:00:06.500Z", "level": "error", "message": "boom"], ["time": "2026-10-29T10:00:07Z", "level": "warning", "message": "slow"], ["time": "2026-10-29T10:00:08Z", "level": "log", "message": "noise"]]],
            "network": ["entries": [["time": "2026-10-29T10:00:09Z", "method": "POST", "status": 500, "url": "https://x.test/pay"]]],
        ]
        let markers = clipMarkers(clip(2), context: markerContext)
        precondition(markers.map(\.kind) == [.click, .error, .warning, .error] && markers.map(\.time) == [4, 6.5, 7, 9] && markers[3].label == "POST 500 /pay" && markers[0].title == "Click · 0:04.0", "clicks, errors, warnings and failed requests become timeline markers (\(markers))")
        let review = ClipReviewController(video: clip(2), context: markerContext, frameCount: 2)
        precondition(review.timeline.markers.count == 4 && !review.trimmed && review.useButton.title == "Use clip", "the review opens untrimmed")
        review.timeline.trimIn = 5
        review.timeline.trimOut = 12
        review.refreshSelection()
        precondition(review.trimmed && review.useButton.title == "Use trimmed clip" && review.selection.stringValue == "0:05.0 in · 0:07.0 selected of 0:20.0 · 0:12.0 out", "trim handles describe the selection (\(review.selection.stringValue))")
        review.timeline.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        precondition(abs(review.timeline.time(review.timeline.x(7)) - 7) < 0.01, "timeline positions map to clip time")
        precondition(review.timeline.marker(near: review.timeline.x(9) + 3)?.label == "POST 500 /pay" && review.timeline.marker(near: review.timeline.x(2)) == nil, "hovering near a marker finds it")
        precondition(review.window is ComposerPanel && !review.window!.styleMask.contains(.titled) && (review.window!.contentView as? NSVisualEffectView)?.maskImage != nil, "the review is a rounded glass panel like the composer")

        precondition(RecordingControls.format(65) == "01:05", "controls show minutes and seconds")
        let controls = RecordingControls()
        controls.update(seconds: 280, paused: true, limit: 300)
        precondition(controls.time.stringValue == "04:40 · 20s left" && controls.pauseButton.symbolName == "play.fill" && controls.panel.sharingType == .none, "controls warn near the limit, show resume while paused and are never recorded")
        controls.update(seconds: 12, paused: false, limit: 300)
        precondition(controls.time.stringValue == "00:12" && controls.time.textColor == .labelColor, "the timer stays neutral until the last 30 s")
        controls.update(seconds: 280, paused: false, limit: 300)
        precondition(controls.time.textColor == .systemOrange, "the timer turns orange near the limit")
        if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"] {
            func render(_ view: NSView, _ name: String, dark: Bool) throws {
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: representation) }
                try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            try render(controls.panel.contentView!, "recording-controls", dark: true)
            review.timeline.frames = (0..<ClipReviewController.filmstripCount).map { index in
                NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
                    NSColor(calibratedHue: CGFloat(index) / 14, saturation: 0.35, brightness: 0.85, alpha: 1).setFill()
                    rect.fill()
                    NSColor.white.withAlphaComponent(0.7).setFill()
                    NSRect(x: 12, y: 60, width: 90, height: 10).fill()
                    return true
                }
            }
            review.timeline.frame = NSRect(x: 0, y: 0, width: 700, height: 70)
            try render(review.timeline, "clip-timeline", dark: true)
            let reviewContent = review.window!.contentView!
            review.window!.contentView = nil
            reviewContent.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
            try render(reviewContent, "clip-review", dark: true)
            let picker = ComposerContextPicker()
            picker.shots = shots
            picker.context = markerContext
            _ = picker.view
            picker.view.frame = NSRect(origin: .zero, size: ComposerContextPicker.size)
            for dark in [false] {
                picker.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                picker.select("console")
                try render(picker.view, "context-console-\(dark ? "dark" : "light")", dark: dark)
                picker.select("network")
                try render(picker.view, "context-network-\(dark ? "dark" : "light")", dark: dark)
                picker.select("events")
                try render(picker.view, "context-clicks-\(dark ? "dark" : "light")", dark: dark)
            }
            picker.shots = [["app": "Cursor", "text": (0..<30).map { String(repeating: "    ", count: $0 % 4) + "container button (expanded) text opencode-appshots-fork New Agent \($0)" }.joined(separator: "\n")]]
            picker.select("windowText")
            try render(picker.view, "context-window-text", dark: true)
            let recentsPreview = ComposerRecents(output: output, current: path)
            recentsPreview.view.frame = NSRect(origin: .zero, size: ComposerRecents.size)
            try render(recentsPreview.view, "recents", dark: false)
        }
        let tree = (0..<40).map { String(repeating: "    ", count: $0 % 5) + "container button (expanded) text opencode-appshots-fork New Agent content list \($0)" }.joined(separator: "\n")
        let clickPicker = ComposerContextPicker()
        clickPicker.shots = [["app": "Cursor", "text": tree]]
        clickPicker.context = markerContext
        let clickWindow = NSWindow(contentRect: NSRect(origin: .zero, size: ComposerContextPicker.size), styleMask: [.titled], backing: .buffered, defer: false)
        clickWindow.contentViewController = clickPicker
        clickWindow.setContentSize(ComposerContextPicker.size)
        clickWindow.orderFront(nil)
        clickWindow.layoutIfNeeded()
        var changed: BundleInclude?
        clickPicker.onChange = { changed = $0 }
        let deviceToggle = clickPicker.rows["device"]!.toggle
        let togglePoint = deviceToggle.convert(NSPoint(x: deviceToggle.bounds.midX, y: deviceToggle.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: togglePoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: clickWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
        clickWindow.sendEvent(mouse(.leftMouseDown))
        precondition(changed?["device"] == false && deviceToggle.state == .off, "clicking a source switch turns it off (state \(deviceToggle.state.rawValue), changed \(String(describing: changed?["device"])))")
        let consoleRow = clickPicker.rows["console"]!
        precondition(deviceToggle.acceptsFirstMouse(for: nil) && consoleRow.acceptsFirstMouse(for: nil), "the switch and row respond in a popover that never becomes key")
        let nameCenter = consoleRow.convert(NSPoint(x: consoleRow.name.frame.midX + 8, y: consoleRow.bounds.midY), to: consoleRow.superview)
        precondition(consoleRow.hitTest(nameCenter) === consoleRow && consoleRow.hitTest(consoleRow.toggle.convert(NSPoint(x: consoleRow.toggle.bounds.midX, y: consoleRow.toggle.bounds.midY), to: consoleRow.superview)) === consoleRow.toggle, "clicking a row's name selects it; its switch still toggles")
        consoleRow.mouseDown(with: mouse(.leftMouseDown))
        precondition(clickPicker.selectedSource == "console", "clicking a row shows its source")
        clickPicker.select("windowText")
        clickWindow.layoutIfNeeded()
        let visible = clickPicker.detailScroll.contentView.bounds
        precondition(clickPicker.detail.frame.width <= visible.width + 0.5 && visible.minX == 0, "window text fits the pane instead of scrolling sideways (\(clickPicker.detail.frame.width) vs \(visible))")
        clickWindow.close()
        precondition(appshotStatusImage(.recording).isTemplate && appshotStatusImage(.replay).tiffRepresentation != appshotStatusImage(.ready).tiffRepresentation, "replay and recording have distinct menu-bar states")
        let settingsMode = try mode(output + "/settings.json")
        precondition(settingsMode == 0o600, "settings are owner-only")

        func listed(_ directory: String) -> [[String: Any]] {
            [
                ["id": "opencode", "label": "OpenCode", "status": "ready", "targets": [["id": directory, "label": URL(fileURLWithPath: directory).lastPathComponent, "detail": directory, "actionLabel": "Review in OpenCode", "hint": "You press Enter."]]],
                ["id": "clipboard", "label": "Clipboard", "status": "ready", "targets": [["id": "markdown", "label": "Markdown", "actionLabel": "Copy Markdown", "hint": "Nothing is pasted for you."]]],
                ["id": "linear", "label": "Linear", "status": "needs-auth", "targets": []],
            ]
        }
        let merged = mergeDestinations([(endpoint: 0, destinations: listed("/fixture/alpha")), (endpoint: 1, destinations: listed("/fixture/beta"))])
        precondition(merged.map(\.id) == ["opencode", "clipboard", "linear"], "destinations merge by id in plugin order")
        precondition(merged[0].targets.map(\.endpoint) == [0, 1] && merged[0].targets.map(\.label) == ["alpha", "beta"], "each project is an OpenCode target on its own endpoint")
        precondition(merged[1].targets.count == 1, "shared targets are not duplicated")
        let legacy = mergeDestinations([(endpoint: 0, destinations: [legacyOpenCodeDestination(ComposerEndpoint(directory: "/fixture/old", port: 1, token: ""))])])
        precondition(legacy.first?.targets.first?.actionLabel == "Review in OpenCode", "older plugins still offer OpenCode drafts")

        let composer = try AppshotComposer(shots: shots, note: "@report Reopened note", context: loaded.context, include: BundleInclude(windowText: false, device: true), output: output, returnTo: nil)
        precondition(composer.textView.string == "@report Reopened note", "reopened bundles restore the note")
        composer.applyAvailableSkills([("report", "Report")])
        precondition(composer.textView.string == "@report Reopened note", "loading skills leaves a reopened note unchanged")
        precondition(composer.contextButton.toolTip?.contains("Window off") == true && composer.contextButton.toolTip?.contains("Network 1") == true, "reopened bundles keep include flags and stored context")

        let live = try AppshotComposer(shots: shots, note: "", context: deviceOnly, include: BundleInclude(), output: output, returnTo: nil)
        let slow = Task { @MainActor () -> [String: Any] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return ["console": ["entries": [["time": "t", "level": "fault", "message": "late", "source": "app"]]]]
        }
        live.collect(slow)
        precondition(live.contextButton.detail == "collecting…", "the chip says slow sources are still collecting")
        live.showWindow(nil)
        live.showContext()
        let picker = live.contextPopover.contentViewController as! ComposerContextPicker
        _ = picker.view
        precondition(picker.rows.count == 6 && picker.sidebar.arrangedSubviews.count == 7, "the picker lists every context source")
        let deadline = Date().addingTimeInterval(3)
        while live.collecting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!live.collecting && ContextText.count("console", shots: shots, context: live.context) == 1, "slow sources merge when they finish")
        precondition(picker.rows["console"]?.count.stringValue == "1" && picker.rows["console"]?.count.textColor == .systemRed, "the open picker updates its counts and flags errors")
        picker.select("console")
        precondition(picker.detailText.contains("late") && picker.detailText.contains("FAULT"), "the picker shows the selected source as readable rows")
        picker.rows["console"]!.toggle.state = .off
        picker.rows["console"]!.toggled()
        precondition(!picker.banner.isHidden, "a switched-off source says it is not sent")
        precondition(!live.include["console"], "unchecking a source excludes it from the bundle")
        live.contextPopover.close()
        composer.endpoints = ["/fixture/alpha", "/fixture/beta"].map { ComposerEndpoint(directory: $0, port: 1, token: String(repeating: "a", count: 64)) }
        composer.applyDestinations(merged)
        precondition(!composer.destinationButton.isHidden && composer.destinationButton.itemTitles == ["OpenCode", "Clipboard", "Linear"], "destination picker lists every destination")
        precondition(composer.destinationButton.item(at: 2)?.isEnabled == false, "destinations that are not ready cannot be chosen")
        precondition(composer.selectedDestination?.id == "clipboard", "saved default destination is preselected")
        precondition(composer.projects.itemTitles == ["Markdown"] && composer.shortcut.stringValue.hasPrefix("Copy Markdown"), "target picker and action label follow the destination")
        precondition(composer.prepareBody(text: "x", skills: [])["destination"] as? String == "clipboard" && composer.prepareBody(text: "x", skills: [])["target"] as? String == "markdown", "prepare names the chosen destination and target")
        composer.destinationButton.selectItem(at: 0)
        composer.destinationChanged()
        precondition(composer.projects.itemTitles == ["alpha", "beta"] && composer.shortcut.stringValue.hasPrefix("Review in OpenCode"), "OpenCode targets are projects")
        precondition(CaptureSettings.load(output: output).defaultDestination == "opencode", "choosing a destination remembers it")
        composer.projects.selectItem(at: 1)
        composer.projectChanged()
        precondition(composer.selectedEndpoint?.directory == "/fixture/beta", "targets route to the endpoint that offered them")
        precondition(composer.sendButton.toolTip?.contains("You press Enter.") == true, "send button explains the handoff")
        precondition(CaptureSettings.load(output: output).knownDestinations.map(\.id) == ["opencode", "clipboard", "linear"], "menu bar learns available destinations")
        composer.include = BundleInclude()
        composer.refreshContextSummary()
        precondition(composer.contextButton.title == "Context" && Int(composer.contextButton.detail) ?? 0 > 0 && composer.contextButton.toolTip?.contains("tokens") == true, "context chip counts included sources and keeps the estimate in its tooltip")
        if let directory = ProcessInfo.processInfo.environment["APPSHOTS_COMPOSER_PREVIEW_DIR"] {
            let content = composer.window!.contentView!
            composer.window!.appearance = NSAppearance(named: .darkAqua)
            content.layoutSubtreeIfNeeded()
            let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: representation) }
            try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent("context-chip.png"))
            composer.window!.appearance = nil
        }
        for unsupported in [["action": "send-message"], ["title": "no session"]] as [[String: Any]] {
            var thrown = false
            var finished = false
            Task { @MainActor in
                do { try await composer.completeHandoff(unsupported) } catch { thrown = true }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(thrown && !composer.submitted, "unknown handoff actions are refused and nothing is marked sent")
        }
        print("Capture Studio device context, bundle manifest, recents, settings and destination wiring checks passed")
    }
}
