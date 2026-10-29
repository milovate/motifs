import AppKit

struct ComposerEndpoint: Decodable {
    let directory: String
    let port: Int
    let token: String

    func request(_ route: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard (1...65535).contains(port), token.count == 64,
              let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { throw captureError("Invalid local composer endpoint.") }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 3 : 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw captureError(result["error"] as? String ?? "OpenCode could not accept the request.")
        }
        return result
    }
}

@MainActor func composeCapture(shots: [[String: Any]], videos: [[String: Any]], context: [String: Any], pending: Task<[String: Any], Never>?, output: String, returnTo: NSRunningApplication?) async throws {
    let composer = try AppshotComposer(shots: shots, videos: videos, note: "", context: context, include: BundleInclude(), output: output, returnTo: returnTo)
    if let pending { composer.collect(pending) }
    await presentComposer(composer)
}

@MainActor func composeBundle(path: String, output: String, returnTo: NSRunningApplication?) async throws {
    let bundle = try loadCaptureBundle(path: path, output: output)
    let composer = try AppshotComposer(shots: bundle.shots, videos: bundle.videos, note: bundle.note, context: bundle.context, include: bundle.include, output: output, returnTo: returnTo)
    if bundle.missingScreenshots > 0 { composer.status.stringValue = "\(bundle.missingScreenshots) screenshot\(bundle.missingScreenshots == 1 ? " was" : "s were") deleted since this bundle was saved." }
    await presentComposer(composer)
}

@MainActor func presentComposer(_ composer: AppshotComposer) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        composer.completion = { continuation.resume() }
        AppshotComposer.current = composer
        composer.showWindow(nil)
        composer.positionNearBottom()
        composer.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        composer.window?.makeFirstResponder(composer.textView)
        composer.discoverProjects()
    }
    withExtendedLifetime(composer) {}
}

@MainActor final class AppshotComposer: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    // The menu-bar helper records the screen; the composer only asks for a clip.
    static var onRecord: ((AppshotComposer) -> Void)?
    static weak var current: AppshotComposer?
    var shots: [[String: Any]]
    var selectedShotIndex = 0
    var shot: [String: Any] {
        get { shots.indices.contains(selectedShotIndex) ? shots[selectedShotIndex] : [:] }
        set { if shots.indices.contains(selectedShotIndex) { shots[selectedShotIndex] = newValue } }
    }
    let output: String
    let returnTo: NSRunningApplication?
    var endpoints: [ComposerEndpoint]
    var destinations: [ComposerDestination] = []
    var settings: CaptureSettings
    var videos: [[String: Any]]
    var context: [String: Any]
    var collecting = false
    var include: BundleInclude
    let textView = ComposerTextView()
    let destinationButton = ComposerProjectButton()
    let projects = ComposerProjectButton()
    let contextButton = ComposerButton("Context", symbol: "info.circle", treatment: .chip)
    let contextPopover = NSPopover()
    let shortcut = NSTextField(labelWithString: "Review in OpenCode  ·  ⌘↵")
    let skillsButton = ComposerButton(symbol: "at")
    let microphone = ComposerButton(symbol: "mic")
    let sendButton = ComposerButton(symbol: "arrow.up", treatment: .primary)
    let annotateButton = ComposerButton("Annotate", symbol: "pencil.tip", treatment: .chip)
    let closeButton = ComposerButton(symbol: "xmark")
    let status = ComposerStatusField(wrappingLabelWithString: "")
    let thumbnailStrip = NSStackView()
    let addScreenshotButton = ComposerButton("Add", symbol: "plus", treatment: .chip)
    var addingScreenshot = false
    var recordingClip = false
    var reviewingClip = false
    var preparingFrames = false
    var frameGeneration = UUID()
    let scroll = NSScrollView()
    let contentStack = NSStackView()
    let skillPopover = NSPopover()
    let mentionCompletion = ComposerMentionCompletion()
    var didPrefillReport = false
    var updatingMentions = false
    var inputHeight: NSLayoutConstraint!
    let speech = ComposerSpeech()
    var skills: [(id: String, name: String)] = []
    var selectedSkills = Set<String>()
    var completion: (() -> Void)?
    var sending = false
    var submitted = false
    var returnAfterHandoff = false
    var requestID = UUID().uuidString
    var manifest: String?
    var preparedSession: [String: Any]?
    var skillLoadID = UUID()
    var dictationBase = ""

    init(shots: [[String: Any]], videos: [[String: Any]] = [], note: String, context: [String: Any], include: BundleInclude, output: String, returnTo: NSRunningApplication?) throws {
        self.shots = shots
        self.videos = Array(videos.prefix(ReplayWriter.maxClips))
        self.context = context
        self.include = include
        self.output = output
        self.returnTo = returnTo
        settings = CaptureSettings.load(output: output)
        let folder = URL(fileURLWithPath: output + "/composers")
        endpoints = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ComposerEndpoint.self, from: Data(contentsOf: $0)) }
            .sorted { $0.directory < $1.directory } ?? []
        let panel = ComposerPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 214), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Appshot composer"
        panel.identifier = NSUserInterfaceItemIdentifier("appshot-composer")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildContent()
        if !note.isEmpty {
            // A reopened bundle keeps its own skill mentions; never add a second default.
            didPrefillReport = true
            textView.string = note
            updateInputSize()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func buildContent() {
        let content = ComposerSurface(frame: NSRect(x: 0, y: 0, width: 640, height: 214))
        window?.contentView = content
        let attachmentScroll = NSScrollView()
        attachmentScroll.drawsBackground = false
        attachmentScroll.hasHorizontalScroller = true
        attachmentScroll.scrollerStyle = .overlay
        attachmentScroll.documentView = thumbnailStrip
        attachmentScroll.translatesAutoresizingMaskIntoConstraints = false
        attachmentScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        attachmentScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        thumbnailStrip.orientation = .horizontal
        thumbnailStrip.spacing = 4
        thumbnailStrip.alignment = .centerY
        thumbnailStrip.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbnailStrip.leadingAnchor.constraint(equalTo: attachmentScroll.contentView.leadingAnchor),
            thumbnailStrip.topAnchor.constraint(equalTo: attachmentScroll.contentView.topAnchor),
            thumbnailStrip.heightAnchor.constraint(equalTo: attachmentScroll.contentView.heightAnchor),
            thumbnailStrip.widthAnchor.constraint(greaterThanOrEqualTo: attachmentScroll.contentView.widthAnchor),
        ])
        annotateButton.target = self
        annotateButton.action = #selector(annotate)
        annotateButton.compact = true
        annotateButton.toolTip = "Annotate the screenshot"
        addScreenshotButton.target = self
        addScreenshotButton.action = #selector(showAddMenu)
        addScreenshotButton.compact = true
        addScreenshotButton.toolTip = "Add a screenshot of a region or a screen recording"
        addScreenshotButton.setAccessibilityLabel("Add a screenshot or a screen recording")
        closeButton.target = self
        closeButton.action = #selector(closeComposer)
        closeButton.compact = true
        closeButton.toolTip = "Close without sending (Escape)"
        closeButton.setAccessibilityLabel("Close without sending")
        contextButton.target = self
        contextButton.action = #selector(showContext)
        contextButton.compact = true
        contextButton.setAccessibilityLabel("Review context sent with this capture")
        refreshContextSummary()
        let attachment = NSStackView(views: [attachmentScroll, contextButton, addScreenshotButton, closeButton])
        attachment.alignment = .centerY
        attachment.spacing = 10

        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = textView
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.onCompletionKey = { [weak self] key in self?.handleMentionKey(key) ?? false }
        mentionCompletion.onChoose = { [weak self] id in self?.insertSkillMention(id) }
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .controlAccentColor
        textView.textColor = .labelColor
        textView.alignment = .left
        textView.frame = NSRect(x: 0, y: 0, width: 604, height: 52)
        textView.minSize = NSSize(width: 0, height: 52)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: textView.frame.width, height: CGFloat.greatestFiniteMagnitude)
        applyComposerParagraphStyle()
        textView.setAccessibilityLabel("Describe what is wrong")
        textView.toolTip = "Describe what felt wrong. Type here, or use Dictate. Nothing is sent until you click Send."
        scroll.translatesAutoresizingMaskIntoConstraints = false
        inputHeight = scroll.heightAnchor.constraint(equalToConstant: 52)
        inputHeight.isActive = true

        destinationButton.symbol = "paperplane"
        destinationButton.placeholder = "Destination"
        destinationButton.isBordered = false
        destinationButton.focusRingType = .exterior
        destinationButton.setAccessibilityLabel("Where to send this capture")
        destinationButton.toolTip = "Where to send this capture"
        destinationButton.target = self
        destinationButton.action = #selector(destinationChanged)
        destinationButton.isEnabled = false
        destinationButton.isHidden = true
        destinationButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        populateProjects()
        projects.isBordered = false
        projects.focusRingType = .exterior
        projects.setAccessibilityLabel("Target within the destination")
        projects.target = self
        projects.action = #selector(projectChanged)
        projects.isEnabled = !endpoints.isEmpty
        projects.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projects.toolTip = "Project for the new session"
        skillsButton.target = self
        skillsButton.action = #selector(showSkills)
        skillsButton.isEnabled = false
        skillsButton.toolTip = "Add a skill"
        skillsButton.setAccessibilityLabel("Choose skills")
        microphone.target = self
        microphone.action = #selector(toggleDictation)
        microphone.toolTip = "On-device voice-to-text. Review the transcript before sending."
        microphone.setAccessibilityLabel("Start dictation")
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.symbolName = "arrow.up.right"
        sendButton.toolTip = "Open a new OpenCode session with an unsent draft (⌘Return)"
        sendButton.setAccessibilityLabel("Continue in a new OpenCode session")
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.isEnabled = false
        let spacer = NSView()
        let actions = NSStackView(views: [skillsButton, destinationButton, projects, spacer, microphone, sendButton])
        actions.distribution = .fill
        actions.spacing = 6
        actions.alignment = .centerY
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        status.preferredMaxLayoutWidth = 440
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.font = .systemFont(ofSize: 10)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [status, NSView(), shortcut])
        footer.alignment = .centerY
        footer.spacing = 8
        let stack = contentStack
        for view in [attachment, scroll, actions, footer] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for view in [attachment, scroll, actions, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshAttachments()
        redistributeFrames()
        status.onChange = { [weak self] in
            Task { @MainActor in self?.resizeToFit() }
        }
        speech.onTranscript = { [weak self] text in
            guard let self else { return }
            self.textView.string = self.dictationBase + text
            self.updateInputSize()
        }
        speech.onState = { [weak self] message in
            guard let self else { return }
            self.status.stringValue = message
            saveStatus(output: self.output, phase: "dictation", details: ["dictationStage": message, "dictation": ComposerSpeech.diagnostics()])
        }
        speech.onStop = { [weak self] error in
            guard let self else { return }
            self.microphone.title = ""
            self.microphone.symbolName = "mic"
            self.microphone.treatment = .quiet
            self.microphone.setAccessibilityLabel("Start dictation")
            self.textView.isEditable = true
            self.refreshSendAvailability()
            self.status.stringValue = error ?? "Transcript ready to review."
            saveStatus(output: self.output, phase: "composing", details: ["dictationStage": error == nil ? "stopped" : "failed", "dictationError": error ?? "", "dictation": ComposerSpeech.diagnostics()])
        }
    }

    func positionNearBottom() {
        guard let window else { return }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.minY + min(80, frame.height * 0.1)))
    }

    var selectedDestination: ComposerDestination? {
        destinations.indices.contains(destinationButton.indexOfSelectedItem) ? destinations[destinationButton.indexOfSelectedItem] : nil
    }

    var selectedTarget: ComposerTarget? {
        guard let targets = selectedDestination?.targets, targets.indices.contains(projects.indexOfSelectedItem) else { return nil }
        return targets[projects.indexOfSelectedItem]
    }

    // Before destinations load, each endpoint is one OpenCode project.
    var selectedEndpoint: ComposerEndpoint? {
        if !destinations.isEmpty { return selectedTarget.flatMap { endpoints.indices.contains($0.endpoint) ? endpoints[$0.endpoint] : nil } }
        return endpoints.indices.contains(projects.indexOfSelectedItem) ? endpoints[projects.indexOfSelectedItem] : nil
    }

    func populateProjects() {
        let selected = projects.indexOfSelectedItem
        projects.removeAllItems()
        if let destination = selectedDestination {
            for target in destination.targets {
                projects.menu?.addItem(NSMenuItem(title: target.label, action: nil, keyEquivalent: ""))
                projects.lastItem?.toolTip = target.detail ?? target.label
            }
            if destination.targets.isEmpty { projects.addItem(withTitle: destination.status == "ready" ? "No targets" : "Unavailable") }
            projects.symbol = destination.id == "opencode" ? "folder" : destination.id == "clipboard" ? "doc.on.clipboard" : "tray.and.arrow.down"
            if destination.targets.indices.contains(selected) { projects.selectItem(at: selected) }
        } else {
            for endpoint in endpoints {
                let name = URL(fileURLWithPath: endpoint.directory).lastPathComponent
                projects.menu?.addItem(NSMenuItem(title: name.isEmpty ? "Project" : name, action: nil, keyEquivalent: ""))
                projects.lastItem?.toolTip = endpoint.directory
            }
            if endpoints.isEmpty { projects.addItem(withTitle: "No projects") }
            if endpoints.indices.contains(selected) { projects.selectItem(at: selected) }
        }
        projects.invalidateIntrinsicContentSize()
        refreshTargetDetails()
    }

    func applyDestinations(_ merged: [ComposerDestination]) {
        destinations = merged
        destinationButton.removeAllItems()
        for destination in merged {
            destinationButton.addItem(withTitle: destination.label)
            destinationButton.lastItem?.isEnabled = destination.status == "ready"
            destinationButton.lastItem?.toolTip = destination.status == "ready" ? nil : "\(destination.label): \(destination.status)"
        }
        destinationButton.autoenablesItems = false
        let preferred = merged.firstIndex { $0.id == settings.defaultDestination && $0.status == "ready" } ?? merged.firstIndex { $0.status == "ready" } ?? 0
        if merged.indices.contains(preferred) { destinationButton.selectItem(at: preferred) }
        destinationButton.isHidden = merged.count < 2
        destinationButton.isEnabled = merged.count > 1 && textView.isEditable
        destinationButton.invalidateIntrinsicContentSize()
        let known = merged.map { (id: $0.id, label: $0.label) }
        if !known.isEmpty, known.map(\.id) != settings.knownDestinations.map(\.id) || known.map(\.label) != settings.knownDestinations.map(\.label) {
            settings.knownDestinations = known
            try? settings.save(output: output)
        }
        populateProjects()
    }

    func refreshTargetDetails() {
        guard let target = selectedTarget else { return }
        shortcut.stringValue = target.actionLabel + "  ·  ⌘↵"
        sendButton.toolTip = target.actionLabel + " (⌘Return). " + target.hint
        sendButton.setAccessibilityLabel(target.actionLabel)
        projects.toolTip = target.detail ?? target.label
    }

    @objc func destinationChanged() {
        guard let destination = selectedDestination else { return }
        projects.selectItem(at: 0)
        populateProjects()
        settings.defaultDestination = destination.id
        try? settings.save(output: output)
        loadSkills()
    }

    // Slow sources (unified log, browser extension) arrive after the composer opens.
    func collect(_ pending: Task<[String: Any], Never>) {
        collecting = true
        refreshContextSummary()
        Task { @MainActor in
            let slow = await pending.value
            collecting = false
            if manifest == nil { context.merge(slow) { _, new in new } }
            refreshContextSummary()
            (contextPopover.contentViewController as? ComposerContextPicker)?.update(shots: shots, context: context)
        }
    }

    func refreshContextSummary() {
        let characters = contextCharacterCount(shots: shots, context: context, include: include)
        contextButton.title = "Context · " + (collecting ? "collecting…" : formatTokenEstimate(characters: characters).replacingOccurrences(of: " tokens", with: ""))
        let parts = BundleInclude.sources.compactMap { source -> String? in
            let count = ContextText.count(source, shots: shots, context: context)
            return count == 0 ? nil : "\(ContextText.labels[source] ?? source) \(include[source] ? "\(count)" : "off")"
        }
        contextButton.toolTip = (parts.isEmpty ? "No context" : parts.joined(separator: " · ")) + ". Click to review."
    }

    @objc func showContext() {
        guard !sending, !submitted else { return }
        if contextPopover.isShown { contextPopover.close(); return }
        let picker = ComposerContextPicker()
        picker.shots = shots
        picker.context = context
        picker.collecting = collecting
        picker.include = include
        picker.onChange = { [weak self] include in
            guard let self, self.textView.isEditable, self.preparedSession == nil else { return }
            self.include = include
            self.manifest = nil
            self.refreshContextSummary()
        }
        contextPopover.contentViewController = picker
        contextPopover.contentSize = NSSize(width: 420, height: 360)
        contextPopover.behavior = .transient
        contextPopover.show(relativeTo: contextButton.bounds, of: contextButton, preferredEdge: .maxY)
    }

    func textDidChange(_ notification: Notification) { updateInputSize() }
    func textViewDidChangeSelection(_ notification: Notification) { updateMentionCompletion() }

    func updateMentionCompletion() {
        guard !updatingMentions, textView.isEditable, skillsButton.isEnabled, !speech.isRunning else { mentionCompletion.dismiss(); return }
        mentionCompletion.update(textView: textView, skills: skills, display: window?.isVisible == true && window?.firstResponder === textView)
    }

    func handleMentionKey(_ key: UInt16) -> Bool {
        guard !mentionCompletion.candidates.isEmpty else { return false }
        switch key {
        case 125: mentionCompletion.move(1, near: textView)
        case 126: mentionCompletion.move(-1, near: textView)
        case 36, 48, 76:
            insertSkillMention(mentionCompletion.candidates[mentionCompletion.selectedIndex].id)
        case 53: mentionCompletion.dismiss()
        default: return false
        }
        return true
    }

    func insertSkillMention(_ id: String) {
        guard textView.isEditable, skills.contains(where: { $0.id == id }) else { return }
        let range = ComposerMentions.query(in: textView.string, selection: textView.selectedRange())?.range ?? textView.selectedRange()
        mentionCompletion.dismiss()
        textView.insertText("@" + id + " ", replacementRange: range)
        updateInputSize()
        window?.makeFirstResponder(textView)
    }

    func synchronizeMentions() {
        guard !updatingMentions else { return }
        updatingMentions = true
        defer { updatingMentions = false }
        let mentions = ComposerMentions.matches(in: textView.string, skills: skills.map(\.id))
        textView.mentionRanges = mentions.map(\.range)
        selectedSkills = Set(mentions.map(\.id))
        if let layout = textView.layoutManager {
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            for mention in mentions {
                // Preserve the editor's exact font metrics and weight. The
                // text view draws a soft rounded tint behind the mention.
                layout.addTemporaryAttributes([.foregroundColor: NSColor.controlAccentColor], forCharacterRange: mention.range)
            }
        }
        updateSkillsTitle()
    }

    func applyAvailableSkills(_ available: [(id: String, name: String)]) {
        skills = available
        if !didPrefillReport {
            didPrefillReport = true
            if skills.contains(where: { $0.id == "report" }), !ComposerMentions.matches(in: textView.string, skills: ["report"]).contains(where: { $0.id == "report" }) {
                let selection = textView.selectedRange()
                textView.insertText("@report ", replacementRange: NSRange(location: 0, length: 0))
                textView.setSelectedRange(NSRange(location: min((textView.string as NSString).length, selection.location + 8), length: selection.length))
            }
        }
        synchronizeMentions()
        updateInputSize()
    }

    func updateInputSize() {
        synchronizeMentions()
        applyComposerParagraphStyle()
        textView.textContainer?.containerSize = NSSize(width: max(1, textView.bounds.width), height: CGFloat.greatestFiniteMagnitude)
        textView.needsDisplay = true
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            inputHeight.constant = min(180, max(52, ceil(layout.usedRect(for: container).height) + 14))
        }
        refreshSendAvailability()
        resizeToFit()
        updateMentionCompletion()
    }

    func applyComposerParagraphStyle() {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.hyphenationFactor = 0
        style.allowsDefaultTighteningForTruncation = false
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        if full.length > 0 {
            textView.textStorage?.addAttributes([.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.labelColor, .paragraphStyle: style, .kern: 0, .expansion: 0], range: full)
        }
        textView.defaultParagraphStyle = style
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.labelColor, .paragraphStyle: style, .kern: 0, .expansion: 0]
        textView.alignment = .left
    }

    func refreshSendAvailability() {
        sendButton.isEnabled = !sending && !submitted && !speech.isRunning && !preparingFrames && !recordingClip && !reviewingClip && selectedEndpoint != nil && skillsButton.isEnabled && hasDescription
    }

    var hasDescription: Bool {
        let text = NSMutableString(string: textView.string)
        for range in ComposerMentions.matches(in: textView.string, skills: skills.map(\.id)).map(\.range).reversed() { text.replaceCharacters(in: range, with: "") }
        return !(text as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func resizeToFit() {
        guard let window, inputHeight != nil else { return }
        let height = max(214, contentStack.fittingSize.height + 34)
        var frame = window.frame
        frame.size.height = min(440, height)
        if let screen = window.screen { frame.origin.y = max(screen.visibleFrame.minY + 16, min(frame.origin.y, screen.visibleFrame.maxY - frame.height - 16)) }
        if abs(frame.height - window.frame.height) > 1 {
            window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && window.isVisible)
        }
    }

    @objc func closeComposer() { window?.performClose(nil) }

    // Recording frames follow the screenshots, matching the numbering in the draft.
    // They carry no capturedAt so insertion is verified against a screenshot or the text.
    var screenshotBundle: [String: Any] {
        let frames = videos.enumerated().flatMap { number, video in
            let label = (video["source"] as? String == "recording" ? "Screen recording" : "Instant replay") + (videos.count > 1 ? " \(number + 1)" : "")
            let list = video["frames"] as? [[String: Any]] ?? []
            return list.enumerated().compactMap { index, frame -> [String: Any]? in
                guard let path = frame["screenshot"] as? String else { return nil }
                return ["screenshot": path, "app": label, "title": "Frame \(index + 1) of \(list.count)"]
            }
        }
        return ["screenshots": shots + frames]
    }

    func refreshAttachments() {
        for view in thumbnailStrip.arrangedSubviews { thumbnailStrip.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, shot) in shots.enumerated() {
            let thumbnail = ScreenshotThumbnailView(shot: shot, index: index, selected: shots.count > 1 && index == selectedShotIndex)
            thumbnail.onAnnotate = { [weak self] in
                guard let self, self.textView.isEditable, !self.addingScreenshot else { return }
                self.selectedShotIndex = index
                self.refreshAttachments()
                self.annotate()
            }
            thumbnail.onRemove = { [weak self] in self?.removeScreenshot(at: index) }
            thumbnail.setEnabled(textView.isEditable && !sending)
            thumbnailStrip.addArrangedSubview(thumbnail)
        }
        for (index, video) in videos.enumerated() {
            let thumbnail = VideoThumbnailView(video: video)
            thumbnail.onOpen = { [weak self] in self?.reviewVideo(at: index) }
            thumbnail.onRemove = { [weak self] in self?.removeVideo(at: index) }
            thumbnail.setEnabled(textView.isEditable && !sending)
            thumbnailStrip.addArrangedSubview(thumbnail)
        }
        if shots.isEmpty && videos.isEmpty {
            let empty = NSTextField(labelWithString: "No attachments · Add a screenshot or recording ↗")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            thumbnailStrip.addArrangedSubview(empty)
        }
        thumbnailStrip.addArrangedSubview(NSView())
        addScreenshotButton.isEnabled = textView.isEditable && !sending && (shots.count < 8 || canAddRecording)
        refreshContextSummary()
    }

    var canAddRecording: Bool { AppshotComposer.onRecord != nil && videos.count < ReplayWriter.maxClips }
    var canEditAttachments: Bool { textView.isEditable && !sending && !addingScreenshot && !recordingClip && !reviewingClip && preparedSession == nil }

    @objc func showAddMenu() {
        guard canEditAttachments else { return }
        let menu = NSMenu()
        let screenshot = NSMenuItem(title: "Screenshot of a region", action: shots.count < 8 ? #selector(addScreenshot) : nil, keyEquivalent: "")
        screenshot.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        let recording = NSMenuItem(title: videos.isEmpty ? "Screen recording…" : "Another screen recording… (\(videos.count) of \(ReplayWriter.maxClips))", action: canAddRecording ? #selector(addRecording) : nil, keyEquivalent: "")
        recording.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil)
        recording.toolTip = "Hides the composer while you record the display, a window or an area, then adds the clip here. ⌥⇧G also works."
        for item in [screenshot, recording] {
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addScreenshotButton.bounds.height + 4), in: addScreenshotButton)
    }

    @objc func addRecording() {
        guard canEditAttachments, canAddRecording, let record = AppshotComposer.onRecord else { return }
        recordingClip = true
        speech.cancel()
        skillPopover.close()
        contextPopover.close()
        mentionCompletion.dismiss()
        refreshSendAvailability()
        window?.orderOut(nil)
        record(self)
    }

    // Called by the helper when the clip is saved, or with nil when recording was cancelled.
    func recordingFinished(_ video: [String: Any]?, events: [[String: Any]] = []) {
        guard recordingClip else { return }
        recordingClip = false
        if let video, videos.count < ReplayWriter.maxClips {
            videos.append(video)
            if !events.isEmpty { context["events"] = ["entries": events] }
            manifest = nil
            status.stringValue = "Recording added · Click it to review or trim."
        }
        refreshAttachments()
        redistributeFrames()
        refreshSendAvailability()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
    }

    // Each clip gets its share of the six key frames sent to OpenCode.
    func redistributeFrames() {
        let count = ReplayWriter.framesPerClip(videos.count)
        guard videos.contains(where: { ($0["frames"] as? [[String: Any]])?.count != count }) else { return }
        let generation = UUID()
        frameGeneration = generation
        preparingFrames = true
        refreshSendAvailability()
        let current = videos
        Task { @MainActor in
            var updated: [[String: Any]] = []
            for video in current { updated.append((try? await ReplayWriter.reframe(video, count: count)) ?? video) }
            guard frameGeneration == generation else { return }
            videos = updated
            preparingFrames = false
            manifest = nil
            refreshAttachments()
            refreshSendAvailability()
        }
    }

    func reviewVideo(at index: Int) {
        guard canEditAttachments, !preparingFrames, videos.indices.contains(index) else { return }
        let review = ClipReviewController(video: videos[index], context: context, frameCount: ReplayWriter.framesPerClip(videos.count))
        reviewingClip = true
        refreshSendAvailability()
        Task { @MainActor in
            let result = await review.run()
            reviewingClip = false
            switch result {
            case .keep: break
            case .remove:
                removeVideo(at: index)
            case let .replace(trimmed):
                if videos.indices.contains(index) {
                    videos[index] = trimmed
                    manifest = nil
                    status.stringValue = "Clip trimmed to \(Int(((trimmed["durationSeconds"] as? NSNumber)?.doubleValue ?? 0).rounded())) s."
                }
            }
            refreshAttachments()
            refreshSendAvailability()
            window?.makeKeyAndOrderFront(nil)
            withExtendedLifetime(review) {}
        }
    }

    func removeScreenshot(at index: Int) {
        guard textView.isEditable, !sending, !addingScreenshot, preparedSession == nil, shots.indices.contains(index) else { return }
        shots.remove(at: index)
        if index < selectedShotIndex { selectedShotIndex -= 1 }
        selectedShotIndex = min(selectedShotIndex, max(0, shots.count - 1))
        manifest = nil
        refreshAttachments()
    }

    func removeVideo(at index: Int) {
        guard canEditAttachments, videos.indices.contains(index) else { return }
        videos.remove(at: index)
        manifest = nil
        refreshAttachments()
        redistributeFrames()
    }

    @objc func addScreenshot() {
        guard canEditAttachments, shots.count < 8 else { return }
        addingScreenshot = true
        speech.cancel()
        skillPopover.close()
        mentionCompletion.dismiss()
        window?.orderOut(nil)
        Task { @MainActor in
            defer {
                addingScreenshot = false
                refreshAttachments()
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window?.makeFirstResponder(textView)
            }
            do {
                if let captured = try await captureScreenRegion(output: output) {
                    shots.append(captured)
                    selectedShotIndex = shots.count - 1
                    manifest = nil
                    status.stringValue = "Screenshot added · Click a thumbnail to annotate."
                }
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    @objc func projectChanged() { skillPopover.close(); refreshTargetDetails(); loadSkills() }

    func discoverProjects() {
        projects.isEnabled = false
        microphone.isEnabled = false
        status.stringValue = "Finding connected OpenCode projects…"
        let candidates = endpoints
        Task { @MainActor in
            let live = await withTaskGroup(of: (Int, [[String: Any]])?.self, returning: [(Int, [[String: Any]])].self) { group in
                for (index, endpoint) in candidates.enumerated() {
                    group.addTask {
                        do { _ = try await endpoint.request("/skills") } catch { return nil }
                        let listed = try? await endpoint.request("/destinations")
                        return (index, listed?["destinations"] as? [[String: Any]] ?? [legacyOpenCodeDestination(endpoint)])
                    }
                }
                var results: [(Int, [[String: Any]])] = []
                for await result in group { if let result { results.append(result) } }
                return results.sorted { $0.0 < $1.0 }
            }
            guard completion != nil else { return }
            endpoints = live.map { candidates[$0.0] }
            applyDestinations(mergeDestinations(live.enumerated().map { (endpoint: $0.offset, destinations: $0.element.1) }))
            projects.isEnabled = !endpoints.isEmpty
            microphone.isEnabled = true
            loadSkills()
        }
    }

    func loadSkills() {
        guard let endpoint = selectedEndpoint else {
            status.stringValue = endpoints.isEmpty ? "Open a project in OpenCode with the Capture Studio plugin loaded." : "\(selectedDestination?.label ?? "This destination") is not available right now."
            refreshSendAvailability()
            return
        }
        let loadID = UUID()
        skillLoadID = loadID
        sendButton.isEnabled = false
        skillsButton.isEnabled = false
        selectedSkills.removeAll()
        updateSkillsTitle()
        status.stringValue = "Connecting to OpenCode…"
        Task { @MainActor in
            do {
                let result = try await endpoint.request("/skills")
                guard skillLoadID == loadID else { return }
                let available: [(id: String, name: String)] = (result["skills"] as? [[String: Any]] ?? []).compactMap {
                    guard let id = $0["id"] as? String else { return nil }
                    return (id, $0["name"] as? String ?? id)
                }
                skillsButton.isEnabled = true
                applyAvailableSkills(available)
                refreshSendAvailability()
                if let target = selectedTarget, selectedDestination?.id != "opencode" {
                    status.stringValue = target.hint
                } else {
                    status.stringValue = selectedSkills.contains("report") ? "" : "Report unavailable · Choose another skill or continue without one."
                }
            } catch {
                guard skillLoadID == loadID else { return }
                status.stringValue = "Could not connect. Open this project in OpenCode and reopen the composer. " + error.localizedDescription
            }
        }
    }

    func updateSkillsTitle() {
        let ids = selectedSkills.sorted()
        skillsButton.toolTip = ids.isEmpty ? "Add a skill" : "Skills: " + ids.map { "@" + $0 }.joined(separator: ", ") + " — click to add or remove"
    }

    @objc func showSkills() {
        guard !sending, !submitted, skillsButton.isEnabled else { return }
        if skillPopover.isShown { skillPopover.close(); return }
        let picker = ComposerSkillPicker()
        picker.skills = skills
        picker.selected = selectedSkills
        picker.onToggle = { [weak self] id in
            guard let self else { return }
            if self.selectedSkills.contains(id) {
                for range in ComposerMentions.matches(in: self.textView.string, skills: [id]).map(\.range).reversed() { self.textView.insertText("", replacementRange: range) }
                self.updateInputSize()
            } else { self.insertSkillMention(id) }
        }
        skillPopover.contentViewController = picker
        skillPopover.contentSize = NSSize(width: 300, height: 310)
        skillPopover.behavior = .transient
        skillPopover.show(relativeTo: skillsButton.bounds, of: skillsButton, preferredEdge: .maxY)
    }

    @objc func toggleDictation() {
        if speech.isRunning { speech.stop(); return }
        dictationBase = textView.string + (textView.string.isEmpty || textView.string.hasSuffix(" ") ? "" : " ")
        textView.isEditable = false
        sendButton.isEnabled = false
        microphone.title = "Stop"
        microphone.symbolName = "waveform"
        microphone.treatment = .recording
        microphone.setAccessibilityLabel("Stop dictation")
        mentionCompletion.dismiss()
        speech.start()
    }

    @objc func annotate() {
        guard !sending, !submitted, !addingScreenshot, annotateButton.isEnabled, shots.indices.contains(selectedShotIndex) else { return }
        speech.cancel()
        mentionCompletion.dismiss()
        window?.orderOut(nil)
        annotateButton.isEnabled = false
        Task { @MainActor in
            defer {
                annotateButton.isEnabled = true
                window?.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            do {
                if let edited = try await annotateScreenshot(shot, output: output, confirmationTitle: "Done") {
                    shot = edited
                    manifest = nil
                    refreshAttachments()
                }
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    @objc func send() {
        guard !sending, !submitted, !speech.isRunning, !preparingFrames, !recordingClip, !reviewingClip, let endpoint = selectedEndpoint else { return }
        guard hasDescription else {
            status.stringValue = "Describe the problem before continuing."
            window?.makeFirstResponder(textView)
            return
        }
        guard textView.string.utf16.count <= 16_000 else { status.stringValue = "Keep the description under 16000 characters."; return }
        let text = textView.string
        let selected = Array(selectedSkills).sorted()
        var body = prepareBody(text: text, skills: selected)
        sending = true
        setEditingEnabled(false)
        status.stringValue = "Preparing \(selectedTarget?.actionLabel.lowercased() ?? "a new OpenCode draft")…"
        Task { @MainActor in
            defer { sending = false }
            do {
                if manifest == nil {
                    // The bundle, including the note, is saved only now, on an explicit handoff.
                    manifest = try writeCaptureBundle(shots: shots, videos: videos, note: text, context: context, include: include, output: output)
                }
                body["manifest"] = manifest!
                if preparedSession == nil {
                    preparedSession = try await endpoint.request("/prepare", body: body)
                }
                try await completeHandoff(preparedSession ?? [:])
            } catch {
                status.stringValue = error.localizedDescription + " Nothing was run. Your draft is still here."
                // Same request ID for an unchanged retry; the bridge never resubmits it.
                sendButton.isEnabled = true
                window?.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    func prepareBody(text: String, skills: [String]) -> [String: Any] {
        var body: [String: Any] = ["requestID": requestID, "text": text, "skills": skills]
        if let destination = selectedDestination, let target = selectedTarget {
            body["destination"] = destination.id
            body["target"] = target.id
        }
        return body
    }

    // Every action stops short of sending: OpenCode gets an unsent draft, the
    // clipboard is filled without pasting, and folders are only revealed.
    func completeHandoff(_ result: [String: Any]) async throws {
        let action = result["action"] as? String ?? (result["sessionID"] == nil ? "" : "opencode-draft")
        switch action {
        case "opencode-draft":
            guard let id = result["sessionID"] as? String, let title = result["title"] as? String, let draftText = result["draftText"] as? String else { throw captureError("OpenCode returned an invalid draft handoff.") }
            status.stringValue = "Opening the new session in OpenCode…"
            window?.orderOut(nil)
            try await openSessionDraft(sessionID: id, title: title, draftText: draftText, shot: screenshotBundle, output: output)
            submitted = true
            saveStatus(output: output, phase: "composer_draft_inserted", details: ["sessionID": id])
        case "copy-text":
            guard let text = result["text"] as? String else { throw captureError("The clipboard destination returned no text.") }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { throw captureError("Could not write to the clipboard.") }
            submitted = true
            returnAfterHandoff = true
            saveStatus(output: output, phase: "composer_copied", details: ["message": result["message"] as? String ?? ""])
        case "reveal-folder":
            guard let path = result["path"] as? String, path.hasPrefix("/") else { throw captureError("The folder destination returned an invalid path.") }
            submitted = true
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            saveStatus(output: output, phase: "composer_saved", details: ["path": path])
        default:
            throw captureError("This destination returned an unsupported handoff (\(action.isEmpty ? "none" : action)).")
        }
        window?.close()
    }

    func setEditingEnabled(_ enabled: Bool) {
        destinationButton.isEnabled = enabled && destinations.count > 1
        contextButton.isEnabled = enabled
        textView.isEditable = enabled
        projects.isEnabled = enabled
        skillsButton.isEnabled = enabled
        microphone.isEnabled = enabled
        annotateButton.isEnabled = enabled
        addScreenshotButton.isEnabled = enabled && (shots.count < 8 || canAddRecording)
        for case let thumbnail as ScreenshotThumbnailView in thumbnailStrip.arrangedSubviews { thumbnail.setEnabled(enabled) }
        for case let thumbnail as VideoThumbnailView in thumbnailStrip.arrangedSubviews { thumbnail.setEnabled(enabled) }
        skillPopover.close()
        contextPopover.close()
        mentionCompletion.dismiss()
        sendButton.isEnabled = enabled
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !sending && !addingScreenshot && !recordingClip && !reviewingClip }

    func windowWillClose(_ notification: Notification) {
        if AppshotComposer.current === self { AppshotComposer.current = nil }
        skillPopover.close()
        contextPopover.close()
        mentionCompletion.dismiss()
        speech.cancel()
        skillLoadID = UUID()
        let done = completion
        completion = nil
        done?()
        if !submitted || returnAfterHandoff { returnTo?.activate(options: [.activateAllWindows]) }
    }
}
