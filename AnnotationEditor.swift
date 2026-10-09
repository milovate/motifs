import AppKit

@MainActor func annotateScreenshot(_ shot: [String: Any], output: String, returnTo: NSRunningApplication? = nil) async throws -> [String: Any]? {
    let savedMarks = try (shot["annotations"] as? [[String: Any]]).map {
        try JSONDecoder().decode([AnnotationMark].self, from: JSONSerialization.data(withJSONObject: $0))
    } ?? []
    let sourcePath = shot["annotations"] == nil ? shot["screenshot"] : shot["originalScreenshot"]
    guard let path = sourcePath as? String,
          URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path == URL(fileURLWithPath: output).resolvingSymlinksInPath().path,
          let image = NSImage(contentsOfFile: path) else {
        throw captureError("The saved screenshot could not be opened for annotation.")
    }
    let foreground = NSWorkspace.shared.frontmostApplication
    let sourceApp = returnTo ?? (foreground?.bundleIdentifier != "local.opencode.appshots" ? foreground : nil) ?? (shot["bundleID"] as? String).flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }
    let editor = try AnnotationEditor(image: image, shot: shot, output: output)
    editor.canvas.document = AnnotationDocument(marks: savedMarks)
    let result = await withCheckedContinuation { continuation in
        editor.completion = { continuation.resume(returning: $0) }
        editor.showWindow(nil)
        editor.window?.center()
        editor.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    withExtendedLifetime(editor) {}
    if result == nil, let sourceApp, !sourceApp.isTerminated,
       sourceApp.bundleIdentifier != "local.opencode.appshots" {
        sourceApp.activate(options: [.activateAllWindows])
    }
    return result
}

@MainActor func clipboardSnapshot(output: String) throws -> [String: Any] {
    let pasteboard = NSPasteboard.general
    guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
          data.count <= 20_000_000, let image = NSImage(data: data) else {
        throw captureError("Copy an image first, then choose Annotate clipboard image. Images must be under 20 MB.")
    }
    let png = try annotationPNG(image: image, marks: [])
    let file = try saveAnnotationFile(png, output: output)
    return ["app": "Clipboard", "title": "Clipboard image", "capturedAt": ISO8601DateFormatter().string(from: Date()), "screenshot": file.path, "text": "", "warnings": []]
}

@MainActor final class AnnotationEditor: NSWindowController, NSWindowDelegate {
    let canvas: AnnotationCanvas
    let shot: [String: Any]
    let output: String
    var completion: (([String: Any]?) -> Void)?
    var undoButton: NSButton!
    var redoButton: NSButton!
    var colorWell: NSColorWell!
    var tools: NSSegmentedControl!
    var widthControl: NSPopUpButton!
    var tray: NSVisualEffectView!
    var trayCenter: NSLayoutConstraint!
    var trayBottom: NSLayoutConstraint!

    init(image: NSImage, shot: [String: Any], output: String) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0, cgImage.width <= 16_384, cgImage.height <= 16_384 else {
            throw captureError("This image cannot be annotated. Its dimensions must be between 1 and 16384 pixels.")
        }
        self.shot = shot
        self.output = output
        canvas = AnnotationCanvas(image: image, pixels: CGSize(width: cgImage.width, height: cgImage.height))
        let available = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 12, dy: 12)
        let frame = annotationImageRect(image: canvas.pixels, bounds: available)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Annotate — " + (shot["app"] as? String ?? "Image")
        window.minSize = NSSize(width: 720, height: 480)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier("appshot-annotation")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func buildContent() {
        guard let content = window?.contentView else { return }
        let symbols = ["cursorarrow", "arrow.up.right", "rectangle", "pencil.tip", "textformat"]
        let images = zip(symbols, AnnotationTool.allCases).map {
            NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1.rawValue)!
        }
        tools = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(changeTool(_:)))
        tools.selectedSegment = 1
        tools.segmentStyle = .rounded
        tools.setAccessibilityLabel("Annotation tool")
        for (index, tool) in AnnotationTool.allCases.enumerated() {
            tools.setWidth(30, forSegment: index)
            tools.setToolTip(tool.rawValue, forSegment: index)
            tools.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        colorWell = NSColorWell()
        colorWell.colorWellStyle = .minimal
        colorWell.color = .systemRed
        colorWell.target = self
        colorWell.action = #selector(changeColor(_:))
        colorWell.setAccessibilityLabel("Annotation color")
        colorWell.toolTip = "Color"
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([colorWell.widthAnchor.constraint(equalToConstant: 28), colorWell.heightAnchor.constraint(equalToConstant: 28)])
        let width = NSPopUpButton()
        widthControl = width
        width.addItems(withTitles: ["Thin", "Medium", "Thick"])
        width.selectItem(at: 1)
        width.target = self
        width.action = #selector(changeWidth(_:))
        width.setAccessibilityLabel("Stroke width")
        width.toolTip = "Stroke width"
        undoButton = iconButton("Undo", symbol: "arrow.uturn.backward", action: #selector(undoMark), key: "z")
        redoButton = iconButton("Redo", symbol: "arrow.uturn.forward", action: #selector(redoMark), key: "z", modifiers: [.command, .shift])
        let cancel = iconButton("Cancel", symbol: "xmark", action: #selector(cancel), key: "", modifiers: [])
        let insert = button("Insert", action: #selector(insert), key: "\r")
        insert.bezelColor = .controlAccentColor
        insert.contentTintColor = .white
        insert.toolTip = "Insert into OpenCode’s draft (⌘Return)"
        insert.setAccessibilityLabel("Insert into OpenCode")
        let handle = AnnotationToolbarHandle()
        handle.didDrag = { [weak self] delta in self?.moveToolbar(by: delta) }
        let controls = NSStackView(views: [handle, tools, separator(), colorWell, width, separator(), undoButton, redoButton, separator(), cancel, insert])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        let tray = NSVisualEffectView()
        self.tray = tray
        tray.material = .popover
        tray.blendingMode = .withinWindow
        tray.state = .active
        tray.wantsLayer = true
        tray.layer?.cornerRadius = 16
        tray.addSubview(controls)
        for view in [canvas, tray] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        controls.translatesAutoresizingMaskIntoConstraints = false
        trayCenter = tray.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        trayBottom = tray.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            trayCenter,
            trayBottom,
            controls.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: tray.topAnchor, constant: 10),
            controls.bottomAnchor.constraint(equalTo: tray.bottomAnchor, constant: -10),
        ])
        canvas.didChange = { [weak self] in self?.updateHistory(); self?.syncSelection() }
        canvas.didChangeTool = { [weak self] tool in self?.tools.selectedSegment = AnnotationTool.allCases.firstIndex(of: tool) ?? 0 }
        updateHistory()
    }

    @objc func insert() {
        do {
            // Export before closing; a failed write leaves annotations available to retry.
            let png = try annotationPNG(image: canvas.image, marks: canvas.document.marks)
            let file = try saveAnnotationFile(png, output: output)
            var result = shot
            result["originalScreenshot"] = (shot["annotations"] == nil ? shot["screenshot"] : shot["originalScreenshot"]) ?? shot["screenshot"]
            result["screenshot"] = file.path
            result["annotatedAt"] = ISO8601DateFormatter().string(from: Date())
            result["annotationCount"] = canvas.document.marks.count
            result["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(canvas.document.marks))
            try saveCaptureManifest(result, output: output)
            finish(result)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save annotations"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func cancel() { finish(nil) }

    func windowWillClose(_ notification: Notification) { finish(nil, closeWindow: false) }

    func windowDidResize(_ notification: Notification) { moveToolbar(by: .zero) }

    func moveToolbar(by delta: CGPoint) {
        guard let content = window?.contentView, let tray, let trayCenter, let trayBottom else { return }
        content.layoutSubtreeIfNeeded()
        let halfTravel = max(0, (content.bounds.width - tray.bounds.width) / 2 - 8)
        trayCenter.constant = min(halfTravel, max(-halfTravel, trayCenter.constant + delta.x))
        let maxHeight = max(8, content.bounds.height - tray.bounds.height - 36)
        trayBottom.constant = -min(maxHeight, max(8, -trayBottom.constant + delta.y))
        content.layoutSubtreeIfNeeded()
    }

    func finish(_ result: [String: Any]?, closeWindow: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        colorWell.deactivate()
        if closeWindow {
            window?.orderOut(nil)
            window?.close()
        }
        completion(result)
    }

    @objc func changeTool(_ sender: NSSegmentedControl) {
        canvas.tool = AnnotationTool.allCases[sender.selectedSegment]
        window?.makeFirstResponder(canvas)
    }

    @objc func changeColor(_ sender: NSColorWell) { canvas.color = sender.color; canvas.restyleSelection(color: sender.color) }

    @objc func changeWidth(_ sender: NSPopUpButton) { canvas.strokeWidth = [CGFloat(2), 4, 8][sender.indexOfSelectedItem]; canvas.restyleSelection(width: canvas.strokeWidth) }

    @objc func undoMark() { canvas.document.undo(); canvas.clearGesture(); updateHistory(); syncSelection() }

    @objc func redoMark() { canvas.document.redo(); canvas.clearGesture(); updateHistory() }

    func updateHistory() {
        undoButton.isEnabled = !canvas.document.undoHistory.isEmpty
        redoButton.isEnabled = !canvas.document.redoHistory.isEmpty
    }

    func syncSelection() {
        guard let mark = canvas.selectedMark else { return }
        colorWell.color = mark.color
        let widths: [CGFloat] = [2, 4, 8]
        let index = widths.indices.min { abs(widths[$0] - mark.width) < abs(widths[$1] - mark.width) } ?? 1
        widthControl.selectItem(at: index)
    }

    func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([separator.widthAnchor.constraint(equalToConstant: 1), separator.heightAnchor.constraint(equalToConstant: 20)])
        return separator
    }

    func iconButton(_ title: String, symbol: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSButton {
        let control = button("", action: action, key: key, modifiers: modifiers)
        control.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        control.imagePosition = .imageOnly
        control.isBordered = false
        control.toolTip = title
        control.setAccessibilityLabel(title)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return control
    }

    func button(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        return button
    }
}

@MainActor final class AnnotationToolbarHandle: NSImageView {
    var didDrag: ((CGPoint) -> Void)?
    var lastPoint: CGPoint?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move annotation toolbar")
        contentTintColor = .secondaryLabelColor
        toolTip = "Drag to move toolbar"
        setAccessibilityLabel("Move annotation toolbar")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 20), heightAnchor.constraint(equalToConstant: 28)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        lastPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastPoint else { return }
        let point = event.locationInWindow
        didDrag?(CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
        self.lastPoint = point
    }

    override func mouseUp(with event: NSEvent) {
        if lastPoint != nil { NSCursor.pop() }
        lastPoint = nil
    }
}

@MainActor final class AnnotationCanvas: NSView {
    let image: NSImage
    let pixels: CGSize
    var document = AnnotationDocument()
    var tool = AnnotationTool.arrow {
        didSet { window?.invalidateCursorRects(for: self); didChangeTool?(tool) }
    }
    var color = NSColor.systemRed
    var strokeWidth: CGFloat = 4
    var selectedID: UUID?
    var pending: AnnotationMark?
    var drag: AnnotationDrag?
    var didChange: (() -> Void)?
    var didChangeTool: ((AnnotationTool) -> Void)?

    var selectedMark: AnnotationMark? {
        if let pending, pending.id == selectedID { return pending }
        return document.marks.first { $0.id == selectedID }
    }

    init(image: NSImage, pixels: CGSize) {
        self.image = image
        self.pixels = pixels
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel("Screenshot annotation canvas")
        setAccessibilityRole(.image)
        toolTip = "V Select · A Arrow · R Box · P Draw · T Text. Drag to move, handles to resize. Double-click text to edit."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = annotationImageRect(image: pixels, bounds: bounds)
        addCursorRect(rect, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : annotationCrosshairCursor())
        if tool == .select, let mark = selectedMark {
            let scale = rect.width / pixels.width
            let box = annotationBounds(mark)
            addCursorRect(CGRect(x: rect.minX + box.minX * scale, y: rect.minY + box.minY * scale, width: max(12, box.width * scale), height: max(12, box.height * scale)), cursor: .openHand)
            for point in annotationHandles(mark) {
                addCursorRect(CGRect(x: rect.minX + point.x * scale - 7, y: rect.minY + point.y * scale - 7, width: 14, height: 14), cursor: .crosshair)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if selectedID != nil || pending != nil { selectedID = nil; clearGesture() }
        else { window?.performClose(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let rect = annotationImageRect(image: pixels, bounds: bounds)
        var marks = document.marks
        if let pending {
            if let index = marks.firstIndex(where: { $0.id == pending.id }) { marks[index] = pending }
            else { marks.append(pending) }
        }
        drawAnnotationImage(image, marks: marks, pixels: pixels, rect: rect)
        if let mark = selectedMark { drawAnnotationSelection(mark, pixels: pixels, rect: rect) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let rect = annotationImageRect(image: pixels, bounds: bounds)
        guard let point = annotationImagePoint(convert(event.locationInWindow, from: nil), pixels: pixels, rect: rect, clamp: false) else { selectedID = nil; clearGesture(); return }
        let tolerance = 8 * pixels.width / rect.width
        if tool == .select {
            if let mark = selectedMark, let handle = annotationHandles(mark).firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= tolerance }) {
                drag = AnnotationDrag(original: mark, start: point, handle: handle)
                return
            }
            let hit = document.marks.reversed().first { annotationHit($0, point: point, tolerance: tolerance) }
            selectedID = hit?.id
            if let hit {
                if hit.tool == .text && event.clickCount == 2 { editText(at: point, existing: hit); return }
                drag = AnnotationDrag(original: hit, start: point, handle: nil)
            }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        selectedID = nil
        if tool == .text { editText(at: point); return }
        pending = AnnotationMark(tool: tool, points: [point, point], color: color, width: strokeWidth)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let rect = annotationImageRect(image: pixels, bounds: bounds)
        guard let point = annotationImagePoint(convert(event.locationInWindow, from: nil), pixels: pixels, rect: rect, clamp: true) else { return }
        if let drag {
            pending = annotationDragged(drag, to: point, pixels: pixels)
            needsDisplay = true
            return
        }
        guard var mark = pending else { return }
        if mark.tool == .draw { mark.points.append(point) }
        else { mark.points[1] = point }
        pending = mark
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        defer { clearGesture(); didChange?() }
        guard let mark = pending else { return }
        if drag != nil { document.replace(mark); return }
        if let first = mark.points.first, let last = mark.points.last,
           hypot(last.x - first.x, last.y - first.y) > 2 || (mark.tool == .draw && mark.points.count > 2) {
            document.append(mark)
            selectedID = mark.id
            tool = .select
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if [51, 117].contains(event.keyCode) { deleteSelection(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" { duplicateSelection(); return }
        if [123, 124, 125, 126].contains(event.keyCode), let mark = selectedMark {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta = [123: CGPoint(x: -step, y: 0), 124: CGPoint(x: step, y: 0), 125: CGPoint(x: 0, y: step), 126: CGPoint(x: 0, y: -step)][Int(event.keyCode)]!
            document.replace(annotationTranslated(mark, delta: delta, pixels: pixels))
            clearGesture(); didChange?(); return
        }
        if event.keyCode == 36, let mark = selectedMark, mark.tool == .text { editText(at: mark.points[0], existing: mark); return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let mode = ["v": AnnotationTool.select, "a": .arrow, "r": .box, "p": .draw, "t": .text][event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            clearGesture(); tool = mode; return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let rect = annotationImageRect(image: pixels, bounds: bounds)
        guard let point = annotationImagePoint(convert(event.locationInWindow, from: nil), pixels: pixels, rect: rect, clamp: false),
              let mark = document.marks.reversed().first(where: { annotationHit($0, point: point, tolerance: 8 * pixels.width / rect.width) }) else { return nil }
        selectedID = mark.id; tool = .select; needsDisplay = true
        let menu = NSMenu()
        if mark.tool == .text { menu.addItem(withTitle: "Edit text…", action: #selector(editSelectionText), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelection), keyEquivalent: "").target = self
        return menu
    }

    @objc func editSelectionText() {
        guard let mark = selectedMark, mark.tool == .text else { return }
        editText(at: mark.points[0], existing: mark)
    }

    @objc func deleteSelection() {
        guard let selectedID else { return }
        document.remove(selectedID)
        self.selectedID = nil
        clearGesture(); didChange?()
    }

    @objc func duplicateSelection() {
        guard let mark = selectedMark else { return }
        var copy = annotationTranslated(mark, delta: CGPoint(x: 20, y: 20), pixels: pixels)
        copy.id = UUID()
        document.append(copy)
        selectedID = copy.id
        clearGesture(); didChange?()
    }

    func restyleSelection(color: NSColor? = nil, width: CGFloat? = nil) {
        guard var mark = selectedMark else { return }
        if let color { mark.color = color }
        if let width { mark.width = width }
        document.replace(mark)
        clearGesture(); didChange?()
    }

    func clearGesture() {
        pending = nil; drag = nil
        if !document.marks.contains(where: { $0.id == selectedID }) { selectedID = nil }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func editText(at point: CGPoint, existing: AnnotationMark? = nil) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add a text annotation" : "Edit text annotation"
        alert.addButton(withTitle: existing == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        input.placeholderString = "Label or instruction"
        input.stringValue = existing?.text ?? ""
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        let color = color
        let width = strokeWidth
        alert.beginSheetModal(for: window) { [weak self] response in
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !text.isEmpty, let self else { return }
            var mark = existing ?? AnnotationMark(tool: .text, points: [point], color: color, width: width)
            mark.text = text
            if existing == nil { self.document.append(mark) }
            else { self.document.replace(mark) }
            self.selectedID = mark.id
            self.tool = .select
            self.clearGesture(); self.didChange?()
        }
    }
}

enum AnnotationTool: String, CaseIterable, Codable {
    case select = "Select", arrow = "Arrow", box = "Box", draw = "Draw", text = "Text"
}

struct AnnotationDrag {
    var original: AnnotationMark
    var start: CGPoint
    var handle: Int?
}

struct AnnotationMark: Equatable, Codable {
    var id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat?

    enum CodingKeys: String, CodingKey { case id, tool, points, color, width, text, fontSize }

    init(tool: AnnotationTool, points: [CGPoint], color: NSColor, width: CGFloat, text: String = "") {
        self.tool = tool; self.points = points; self.color = color; self.width = width; self.text = text
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        tool = try values.decode(AnnotationTool.self, forKey: .tool)
        points = try values.decode([CGPoint].self, forKey: .points)
        width = try values.decode(CGFloat.self, forKey: .width)
        text = try values.decode(String.self, forKey: .text)
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        let rgba = try values.decode([CGFloat].self, forKey: .color)
        guard rgba.count == 4, !points.isEmpty, tool != .select else { throw captureError("Invalid saved annotation.") }
        color = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(tool, forKey: .tool)
        try values.encode(points, forKey: .points); try values.encode(width, forKey: .width)
        try values.encode(text, forKey: .text); try values.encodeIfPresent(fontSize, forKey: .fontSize)
        let rgba = color.usingColorSpace(.sRGB) ?? .red
        try values.encode([rgba.redComponent, rgba.greenComponent, rgba.blueComponent, rgba.alphaComponent], forKey: .color)
    }
}

struct AnnotationDocument {
    var marks: [AnnotationMark] = []
    var undoHistory: [[AnnotationMark]] = []
    var redoHistory: [[AnnotationMark]] = []

    mutating func append(_ mark: AnnotationMark) { commit(marks + [mark]) }
    mutating func replace(_ mark: AnnotationMark) { commit(marks.map { $0.id == mark.id ? mark : $0 }) }
    mutating func remove(_ id: UUID) { commit(marks.filter { $0.id != id }) }

    mutating func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(marks); marks = previous
    }

    mutating func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(marks); marks = next
    }

    mutating func commit(_ next: [AnnotationMark]) {
        guard next != marks else { return }
        undoHistory.append(marks); marks = next; redoHistory.removeAll()
    }
}

func annotationCrosshairCursor() -> NSCursor {
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: 12, y: 3)); cross.line(to: NSPoint(x: 12, y: 21))
        cross.move(to: NSPoint(x: 3, y: 12)); cross.line(to: NSPoint(x: 21, y: 12))
        NSColor.white.setStroke(); cross.lineWidth = 3; cross.stroke()
        NSColor.black.setStroke(); cross.lineWidth = 1; cross.stroke()
        return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
}

func annotationPNG(image: NSImage, marks: [AnnotationMark]) throws -> Data {
    guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          original.width > 0, original.height > 0, original.width <= 16_384, original.height <= 16_384 else {
        throw captureError("Image dimensions must be between 1 and 16384 pixels.")
    }
    let pixels = CGSize(width: original.width, height: original.height)
    let scale = min(1, 2560 / max(pixels.width, pixels.height))
    let width = max(1, Int(pixels.width * scale))
    let height = max(1, Int(pixels.height * scale))
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw captureError("Could not create the annotated image.")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    drawAnnotationImage(image, marks: marks, pixels: pixels, rect: NSRect(x: 0, y: 0, width: width, height: height))
    guard let data = bitmap.representation(using: .png, properties: [:]), data.count <= 15_000_000 else {
        throw captureError("The annotated PNG exceeds 15 MB. Use a smaller image.")
    }
    return data
}

func drawAnnotationImage(_ image: NSImage, marks: [AnnotationMark], pixels: CGSize, rect: NSRect) {
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    let scale = rect.width / pixels.width
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scale(by: scale)
    transform.concat()
    NSBezierPath(rect: NSRect(origin: .zero, size: pixels)).addClip()
    for mark in marks {
        guard let start = mark.points.first else { continue }
        mark.color.setStroke()
        mark.color.setFill()
        if mark.tool == .text {
            let attributes = annotationTextAttributes(mark)
            NSAttributedString(string: mark.text, attributes: attributes).draw(at: start)
            continue
        }
        guard let end = mark.points.last else { continue }
        let path = NSBezierPath()
        path.lineWidth = mark.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if mark.tool == .box {
            path.appendRect(NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)))
        } else {
            path.move(to: start)
            for point in mark.points.dropFirst() { path.line(to: point) }
            if mark.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(16, mark.width * 4)
                for offset in [CGFloat.pi / 6, -CGFloat.pi / 6] {
                    path.move(to: end)
                    path.line(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
                }
            }
        }
        path.stroke()
    }
}

func drawAnnotationSelection(_ mark: AnnotationMark, pixels: CGSize, rect: CGRect) {
    let scale = rect.width / pixels.width
    let box = annotationBounds(mark)
    let bounds = CGRect(x: rect.minX + box.minX * scale, y: rect.minY + box.minY * scale, width: box.width * scale, height: box.height * scale).insetBy(dx: -5, dy: -5)
    NSColor.controlAccentColor.setStroke()
    let outline = NSBezierPath(rect: bounds)
    outline.lineWidth = 1.5
    outline.setLineDash([4, 3], count: 2, phase: 0)
    outline.stroke()
    for point in annotationHandles(mark) {
        let handle = NSBezierPath(ovalIn: CGRect(x: rect.minX + point.x * scale - 4, y: rect.minY + point.y * scale - 4, width: 8, height: 8))
        NSColor.white.setFill(); handle.fill()
        NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1.5; handle.stroke()
    }
}

func annotationDragged(_ drag: AnnotationDrag, to point: CGPoint, pixels: CGSize) -> AnnotationMark {
    let original = drag.original
    guard let handle = drag.handle else {
        return annotationTranslated(original, delta: CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y), pixels: pixels)
    }
    var result = original
    if original.tool == .arrow {
        result.points[handle == 0 ? 0 : result.points.count - 1] = point
        return result
    }
    let bounds = annotationBounds(original)
    let corners = annotationHandles(original)
    let anchor = corners[(handle + 2) % 4]
    let resized = CGRect(x: min(point.x, anchor.x), y: min(point.y, anchor.y), width: max(8, abs(point.x - anchor.x)), height: max(8, abs(point.y - anchor.y)))
    if original.tool == .text {
        let scale = max(0.2, min(10, resized.width / max(1, bounds.width)))
        result.fontSize = min(400, max(10, (original.fontSize ?? max(22, original.width * 7)) * scale))
        let size = annotationBounds(result).size
        result.points = [CGPoint(x: handle == 0 || handle == 3 ? anchor.x - size.width : anchor.x, y: handle < 2 ? anchor.y - size.height : anchor.y)]
        return result
    }
    result.points = original.points.map {
        CGPoint(x: resized.minX + ($0.x - bounds.minX) / max(1, bounds.width) * resized.width, y: resized.minY + ($0.y - bounds.minY) / max(1, bounds.height) * resized.height)
    }
    return result
}

func annotationTranslated(_ mark: AnnotationMark, delta: CGPoint, pixels: CGSize) -> AnnotationMark {
    let bounds = annotationBounds(mark)
    let x = max(-bounds.minX, min(delta.x, pixels.width - bounds.maxX))
    let y = max(-bounds.minY, min(delta.y, pixels.height - bounds.maxY))
    var result = mark
    result.points = mark.points.map { CGPoint(x: $0.x + x, y: $0.y + y) }
    return result
}

func annotationHit(_ mark: AnnotationMark, point: CGPoint, tolerance: CGFloat) -> Bool {
    let box = annotationBounds(mark)
    if mark.tool == .text || mark.tool == .box { return box.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    if zip(mark.points, mark.points.dropFirst()).contains(where: { annotationSegmentDistance(point, from: $0.0, to: $0.1) <= tolerance + mark.width / 2 }) { return true }
    guard mark.tool == .arrow, let end = mark.points.last else { return false }
    return hypot(end.x - point.x, end.y - point.y) <= max(16, mark.width * 4) + tolerance
}

func annotationHandles(_ mark: AnnotationMark) -> [CGPoint] {
    if mark.tool == .arrow { return [mark.points.first!, mark.points.last!] }
    let rect = annotationBounds(mark)
    return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
}

func annotationBounds(_ mark: AnnotationMark) -> CGRect {
    guard let first = mark.points.first else { return .zero }
    if mark.tool == .text {
        let size = NSAttributedString(string: mark.text, attributes: annotationTextAttributes(mark)).size()
        return CGRect(origin: first, size: size)
    }
    let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

func annotationTextAttributes(_ mark: AnnotationMark) -> [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: mark.fontSize ?? max(22, mark.width * 7), weight: .semibold), .foregroundColor: mark.color, .backgroundColor: NSColor.white.withAlphaComponent(0.9)]
}

func annotationSegmentDistance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
    let dx = end.x - start.x, dy = end.y - start.y
    let length = dx * dx + dy * dy
    guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
    return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy)
}

func annotationImageRect(image: CGSize, bounds: CGRect) -> CGRect {
    guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / image.width, bounds.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
}

func annotationImagePoint(_ point: CGPoint, pixels: CGSize, rect: CGRect, clamp: Bool) -> CGPoint? {
    guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
    let x = min(rect.maxX, max(rect.minX, point.x))
    let y = min(rect.maxY, max(rect.minY, point.y))
    return CGPoint(x: (x - rect.minX) * pixels.width / rect.width, y: (y - rect.minY) * pixels.height / rect.height)
}

func saveAnnotationFile(_ png: Data, output: String) throws -> URL {
    let folder = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let file = folder.appendingPathComponent(UUID().uuidString + ".png")
    try png.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return file
}

func saveCaptureManifest(_ shot: [String: Any], output: String) throws {
    let file = URL(fileURLWithPath: output + "/latest.json")
    let data = try JSONSerialization.data(withJSONObject: shot, options: [.sortedKeys])
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}
