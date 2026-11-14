import AppKit

let helperBundleID = Bundle.main.bundleIdentifier ?? "local.motifs"

@MainActor func annotateScreenshot(_ shot: [String: Any], output: String, returnTo: NSRunningApplication? = nil, confirmationTitle: String = "Insert") async throws -> [String: Any]? {
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
    let sourceApp = returnTo ?? (foreground?.bundleIdentifier != helperBundleID ? foreground : nil) ?? (shot["bundleID"] as? String).flatMap {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }
    let editor = try AnnotationEditor(image: image, shot: shot, output: output, confirmationTitle: confirmationTitle)
    let savedCrop = (shot["crop"] as? [String: Double]).flatMap { value -> CGRect? in
        guard let x = value["x"], let y = value["y"], let width = value["width"], let height = value["height"] else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    editor.canvas.document = AnnotationDocument(marks: savedMarks, crop: savedCrop.flatMap { annotationValidCrop($0, pixels: editor.canvas.pixels) })
    let result = await withCheckedContinuation { continuation in
        editor.completion = { continuation.resume(returning: $0) }
        editor.showWindow(nil)
        editor.window?.center()
        editor.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    withExtendedLifetime(editor) {}
    if result == nil, let sourceApp, !sourceApp.isTerminated,
       sourceApp.bundleIdentifier != helperBundleID {
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
    let confirmationTitle: String
    var completion: (([String: Any]?) -> Void)?
    var undoButton: NSButton!
    var redoButton: NSButton!
    var colorWell: NSColorWell!
    var tools: NSSegmentedControl!
    var widthControl: NSPopUpButton!
    var tray: NSVisualEffectView!
    var trayCenter: NSLayoutConstraint!
    var trayBottom: NSLayoutConstraint!
    var cropActions: NSStackView!
    var applyCropButton: NSButton!
    var copyButton: NSButton!
    var pasteboard = NSPasteboard.general

    init(image: NSImage, shot: [String: Any], output: String, confirmationTitle: String = "Insert") throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0, cgImage.width <= 16_384, cgImage.height <= 16_384 else {
            throw captureError("This image cannot be annotated. Its dimensions must be between 1 and 16384 pixels.")
        }
        self.shot = shot
        self.output = output
        self.confirmationTitle = confirmationTitle
        canvas = AnnotationCanvas(image: image, pixels: CGSize(width: cgImage.width, height: cgImage.height))
        let available = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 12, dy: 12)
        let frame = annotationImageRect(image: canvas.pixels, bounds: available)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Annotate — " + (shot["app"] as? String ?? "Image")
        window.minSize = NSSize(width: 720, height: 480)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier("motifs-annotation")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func buildContent() {
        guard let content = window?.contentView else { return }
        let symbols = ["cursorarrow", "arrow.up.right", "rectangle", "pencil.tip", "textformat", "crop"]
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
        copyButton = iconButton("Copy image (⌘C)", symbol: "doc.on.doc", action: #selector(copyImage), key: "c")
        let cancel = iconButton("Cancel", symbol: "xmark", action: #selector(cancel), key: "", modifiers: [])
        let insert = button(confirmationTitle, action: #selector(insert), key: "\r")
        insert.bezelColor = .controlAccentColor
        insert.contentTintColor = .white
        insert.toolTip = confirmationTitle == "Insert" ? "Insert into OpenCode’s draft (⌘Return)" : "Return to composer (⌘Return)"
        insert.setAccessibilityLabel(confirmationTitle == "Insert" ? "Insert into OpenCode" : "Return to composer")
        let handle = AnnotationToolbarHandle()
        handle.didDrag = { [weak self] delta in self?.moveToolbar(by: delta) }
        let controls = NSStackView(views: [handle, tools, separator(), colorWell, width, separator(), undoButton, redoButton, separator(), copyButton, cancel, insert])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        applyCropButton = button("Apply Crop", action: #selector(applyCrop), key: "")
        applyCropButton.isEnabled = false
        let resetCrop = button("Reset Crop", action: #selector(resetCrop), key: "")
        let cancelCrop = button("Cancel Crop", action: #selector(cancelCrop), key: "")
        cropActions = NSStackView(views: [applyCropButton, resetCrop, cancelCrop])
        cropActions.spacing = 8
        cropActions.isHidden = true
        let toolbar = NSStackView(views: [controls, cropActions])
        toolbar.orientation = .vertical
        toolbar.spacing = 8
        toolbar.alignment = .centerX
        let tray = NSVisualEffectView()
        self.tray = tray
        tray.material = .popover
        tray.blendingMode = .withinWindow
        tray.state = .active
        tray.wantsLayer = true
        tray.layer?.cornerRadius = 16
        tray.addSubview(toolbar)
        for view in [canvas, tray] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        trayCenter = tray.centerXAnchor.constraint(equalTo: content.centerXAnchor)
        trayBottom = tray.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            trayCenter,
            trayBottom,
            toolbar.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: tray.topAnchor, constant: 10),
            toolbar.bottomAnchor.constraint(equalTo: tray.bottomAnchor, constant: -10),
        ])
        canvas.didChange = { [weak self] in self?.updateHistory(); self?.syncSelection() }
        canvas.didChangeTool = { [weak self] tool in
            self?.tools.selectedSegment = AnnotationTool.allCases.firstIndex(of: tool) ?? 0
            self?.cropActions.isHidden = tool != .crop
            self?.moveToolbar(by: .zero)
        }
        canvas.didChangeCrop = { [weak self] in self?.applyCropButton.isEnabled = self?.canvas.cropSelection != nil }
        canvas.copyImage = { [weak self] in self?.copyImage() }
        updateHistory()
    }

    @objc func copyImage() {
        if let editor = canvas.inlineEditor { editor.copy(nil); return }
        do {
            copyPNG(try annotationPNG(image: canvas.image, marks: canvas.document.marks, crop: canvas.document.crop), to: pasteboard)
            copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy image")
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not copy the image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc func insert() {
        do {
            canvas.commitInlineText()
            if canvas.tool == .crop, canvas.cropSelection != nil {
                canvas.applyCropSelection()
            }
            // Export before closing; a failed write leaves annotations available to retry.
            let png = try annotationPNG(image: canvas.image, marks: canvas.document.marks, crop: canvas.document.crop)
            let file = try saveAnnotationFile(png, output: output)
            var result = shot
            result["originalScreenshot"] = (shot["annotations"] == nil ? shot["screenshot"] : shot["originalScreenshot"]) ?? shot["screenshot"]
            result["screenshot"] = file.path
            result["annotatedAt"] = ISO8601DateFormatter().string(from: Date())
            result["annotationCount"] = canvas.document.marks.count
            result["annotations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(canvas.document.marks))
            if let crop = canvas.document.crop {
                result["crop"] = ["x": Double(crop.minX), "y": Double(crop.minY), "width": Double(crop.width), "height": Double(crop.height)]
                result["originalAccessibilityText"] = shot["originalAccessibilityText"] ?? shot["text"] ?? ""
                result["text"] = ""
                var warnings = shot["warnings"] as? [String] ?? []
                if !warnings.contains(annotationCropWarning) { warnings.append(annotationCropWarning) }
                result["warnings"] = warnings
            } else {
                result.removeValue(forKey: "crop")
                result["text"] = shot["originalAccessibilityText"] ?? shot["text"] ?? ""
                result["warnings"] = (shot["warnings"] as? [String] ?? []).filter { $0 != annotationCropWarning }
            }
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

    @objc func applyCrop() { canvas.applyCropSelection(); updateHistory(); moveToolbar(by: .zero) }
    @objc func resetCrop() { canvas.document.setCrop(nil); canvas.cropSelection = nil; canvas.clearGesture(); canvas.didChange?() }
    @objc func cancelCrop() { canvas.cropSelection = nil; canvas.tool = .select; canvas.needsDisplay = true }

    @objc func changeColor(_ sender: NSColorWell) { canvas.color = sender.color; canvas.restyleSelection(color: sender.color) }

    @objc func changeWidth(_ sender: NSPopUpButton) { canvas.strokeWidth = [CGFloat(2), 4, 8][sender.indexOfSelectedItem]; canvas.restyleSelection(width: canvas.strokeWidth) }

    @objc func undoMark() {
        if let editor = canvas.inlineEditor { editor.undoManager?.undo(); return }
        canvas.document.undo(); canvas.cropSelection = nil; canvas.clearGesture(); updateHistory(); syncSelection()
    }

    @objc func redoMark() {
        if let editor = canvas.inlineEditor { editor.undoManager?.redo(); return }
        canvas.document.redo(); canvas.cropSelection = nil; canvas.clearGesture(); updateHistory()
    }

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

@MainActor final class AnnotationCanvas: NSView, NSTextViewDelegate {
    let image: NSImage
    let pixels: CGSize
    var document = AnnotationDocument()
    var tool = AnnotationTool.arrow {
        didSet {
            if oldValue != tool { commitInlineText(); cropSelection = nil; cropStart = nil }
            window?.invalidateCursorRects(for: self); didChangeTool?(tool); needsDisplay = true
        }
    }
    var color = NSColor.systemRed
    var strokeWidth: CGFloat = 4
    var selectedID: UUID?
    var pending: AnnotationMark?
    var drag: AnnotationDrag?
    var didChange: (() -> Void)?
    var didChangeTool: ((AnnotationTool) -> Void)?
    var didChangeCrop: (() -> Void)?
    var copyImage: (() -> Void)?
    var cropSelection: CGRect? { didSet { didChangeCrop?(); needsDisplay = true } }
    var cropStart: CGPoint?
    var inlineEditor: AnnotationInlineTextView?
    var editingMark: AnnotationMark?

    var visiblePixels: CGRect { document.crop ?? CGRect(origin: .zero, size: pixels) }
    var imageRect: CGRect { annotationImageRect(image: visiblePixels.size, bounds: bounds) }
    var sourceRect: CGRect {
        let crop = visiblePixels, rect = imageRect
        let scale = rect.width / crop.width
        return CGRect(x: rect.minX - crop.minX * scale, y: rect.minY - crop.minY * scale, width: pixels.width * scale, height: pixels.height * scale)
    }

    func imagePoint(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard let mapped = annotationImagePoint(point, pixels: visiblePixels.size, rect: imageRect, clamp: clamp) else { return nil }
        return CGPoint(x: mapped.x + visiblePixels.minX, y: mapped.y + visiblePixels.minY)
    }

    var selectedMark: AnnotationMark? {
        if let editingMark, editingMark.id == selectedID { return editingMark }
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
        toolTip = "V Select · A Arrow · R Box · P Draw · T Text · C Crop. Text edits directly on the image. Drawing tools stay active."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        layoutInlineText()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = imageRect
        addCursorRect(rect, cursor: tool == .select ? .arrow : tool == .text ? .iBeam : annotationCrosshairCursor())
        if tool == .select, let mark = selectedMark {
            let scale = sourceRect.width / pixels.width
            let box = annotationBounds(mark)
            addCursorRect(CGRect(x: sourceRect.minX + box.minX * scale, y: sourceRect.minY + box.minY * scale, width: max(12, box.width * scale), height: max(12, box.height * scale)), cursor: .openHand)
            for point in annotationHandles(mark) {
                addCursorRect(CGRect(x: sourceRect.minX + point.x * scale - 7, y: sourceRect.minY + point.y * scale - 7, width: 14, height: 14), cursor: .crosshair)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if inlineEditor != nil { cancelInlineText(); return }
        if tool == .crop { cropSelection = nil; cropStart = nil; tool = .select; return }
        if selectedID != nil || pending != nil { selectedID = nil; clearGesture() }
        else { window?.performClose(sender) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let rect = sourceRect
        var marks = document.marks.filter { $0.id != editingMark?.id }
        if let pending {
            if let index = marks.firstIndex(where: { $0.id == pending.id }) { marks[index] = pending }
            else { marks.append(pending) }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        drawAnnotationImage(image, marks: marks, pixels: pixels, rect: rect)
        if tool == .select, let mark = selectedMark, inlineEditor == nil { drawAnnotationSelection(mark, pixels: pixels, rect: rect) }
        if tool == .crop, let cropSelection {
            let scale = rect.width / pixels.width
            let selection = CGRect(x: rect.minX + cropSelection.minX * scale, y: rect.minY + cropSelection.minY * scale, width: cropSelection.width * scale, height: cropSelection.height * scale)
            let shade = NSBezierPath(rect: imageRect)
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill(); shade.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        commitInlineText()
        window?.makeFirstResponder(self)
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: false) else { selectedID = nil; clearGesture(); return }
        if tool == .crop { cropStart = point; cropSelection = nil; return }
        let tolerance = 8 * pixels.width / sourceRect.width
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
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: true) else { return }
        if tool == .crop, let start = cropStart {
            cropSelection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            return
        }
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
        if tool == .crop { cropStart = nil; return }
        defer { clearGesture(); didChange?() }
        guard let mark = pending else { return }
        if drag != nil { document.replace(mark); return }
        if let first = mark.points.first, let last = mark.points.last,
           hypot(last.x - first.x, last.y - first.y) > 2 || (mark.tool == .draw && mark.points.count > 2) {
            document.append(mark)
            selectedID = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 36, tool == .crop { applyCropSelection(); return }
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
           let mode = ["v": AnnotationTool.select, "a": .arrow, "r": .box, "p": .draw, "t": .text, "c": .crop][event.charactersIgnoringModifiers?.lowercased() ?? ""] {
            clearGesture(); tool = mode; return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        guard let point = imagePoint(convert(event.locationInWindow, from: nil), clamp: false),
              let mark = document.marks.reversed().first(where: { annotationHit($0, point: point, tolerance: 8 * pixels.width / sourceRect.width) }) else {
            menu.addItem(withTitle: "Copy Image", action: #selector(copyAnnotatedImage), keyEquivalent: "").target = self
            return menu
        }
        selectedID = mark.id; tool = .select; needsDisplay = true
        if mark.tool == .text { menu.addItem(withTitle: "Edit text…", action: #selector(editSelectionText), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelection), keyEquivalent: "").target = self
        return menu
    }

    @objc func copyAnnotatedImage() { copyImage?() }

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
        if var mark = editingMark {
            if let color { mark.color = color }
            if let width { mark.width = width }
            editingMark = mark
            layoutInlineText()
            return
        }
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
        commitInlineText()
        var mark = existing ?? AnnotationMark(tool: .text, points: [point], color: color, width: strokeWidth)
        if existing == nil { mark.fontSize = max(22, 18 * pixels.width / sourceRect.width) }
        editingMark = mark
        let editor = AnnotationInlineTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.string = mark.text
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.backgroundColor = .white.withAlphaComponent(0.9)
        editor.insertionPointColor = .controlAccentColor
        editor.delegate = self
        editor.onCommit = { [weak self] in self?.commitInlineText() }
        editor.onCancel = { [weak self] in self?.cancelInlineText() }
        editor.setAccessibilityLabel("Edit annotation text directly on the image")
        inlineEditor = editor
        addSubview(editor)
        layoutInlineText()
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (mark.text as NSString).length, length: 0))
        needsDisplay = true
    }

    func textDidChange(_ notification: Notification) { layoutInlineText() }
    func textDidEndEditing(_ notification: Notification) { commitInlineText() }

    func layoutInlineText() {
        guard let editor = inlineEditor, let mark = editingMark else { return }
        let scale = sourceRect.width / pixels.width
        editor.font = .systemFont(ofSize: (mark.fontSize ?? max(22, mark.width * 7)) * scale, weight: .semibold)
        editor.textColor = mark.color
        let point = mark.points[0]
        let origin = CGPoint(x: sourceRect.minX + point.x * scale, y: sourceRect.minY + point.y * scale)
        let size = NSAttributedString(string: editor.string.isEmpty ? " " : editor.string, attributes: [.font: editor.font!]).size()
        editor.frame = CGRect(origin: origin, size: CGSize(width: max(30, min(max(140, size.width + 12), imageRect.maxX - origin.x)), height: max(26, size.height + 6)))
    }

    func commitInlineText() {
        guard let editor = inlineEditor, var mark = editingMark else { return }
        inlineEditor = nil; editingMark = nil
        let wasFocused = window?.firstResponder === editor
        mark.text = editor.string
        editor.delegate = nil
        editor.removeFromSuperview()
        if wasFocused { window?.makeFirstResponder(self) }
        if mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { document.remove(mark.id) }
        else if document.marks.contains(where: { $0.id == mark.id }) { document.replace(mark) }
        else { document.append(mark) }
        selectedID = tool == .select ? mark.id : nil
        needsDisplay = true
        didChange?()
    }

    func cancelInlineText() {
        inlineEditor?.delegate = nil
        inlineEditor?.removeFromSuperview()
        inlineEditor = nil; editingMark = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func applyCropSelection() {
        guard let selection = cropSelection, let crop = annotationValidCrop(selection, pixels: pixels) else { return }
        document.setCrop(crop)
        cropSelection = nil; cropStart = nil; selectedID = nil
        clearGesture(); didChange?()
    }
}

@MainActor final class AnnotationInlineTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !hasMarkedText() { onCommit?(); return }
        super.keyDown(with: event)
    }
}

enum AnnotationTool: String, CaseIterable, Codable {
    case select = "Select", arrow = "Arrow", box = "Box", draw = "Draw", text = "Text", crop = "Crop"
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
        guard rgba.count == 4, !points.isEmpty, tool != .select, tool != .crop else { throw captureError("Invalid saved annotation.") }
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

struct AnnotationState: Equatable {
    var marks: [AnnotationMark]
    var crop: CGRect?
}

struct AnnotationDocument {
    var marks: [AnnotationMark] = []
    var crop: CGRect?
    var undoHistory: [AnnotationState] = []
    var redoHistory: [AnnotationState] = []

    mutating func append(_ mark: AnnotationMark) { commit(marks + [mark]) }
    mutating func replace(_ mark: AnnotationMark) { commit(marks.map { $0.id == mark.id ? mark : $0 }) }
    mutating func remove(_ id: UUID) { commit(marks.filter { $0.id != id }) }
    mutating func setCrop(_ next: CGRect?) { commitState(AnnotationState(marks: marks, crop: next)) }

    mutating func undo() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(AnnotationState(marks: marks, crop: crop)); marks = previous.marks; crop = previous.crop
    }

    mutating func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(AnnotationState(marks: marks, crop: crop)); marks = next.marks; crop = next.crop
    }

    mutating func commit(_ next: [AnnotationMark]) {
        commitState(AnnotationState(marks: next, crop: crop))
    }

    mutating func commitState(_ next: AnnotationState) {
        let current = AnnotationState(marks: marks, crop: crop)
        guard next != current else { return }
        undoHistory.append(current); marks = next.marks; crop = next.crop; redoHistory.removeAll()
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

let annotationCropWarning = "Cropped screenshot: original-window accessibility text is omitted so content outside the crop is not shared."

func annotationValidCrop(_ rect: CGRect, pixels: CGSize) -> CGRect? {
    guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
    let result = rect.standardized.integral.intersection(CGRect(origin: .zero, size: pixels))
    return result.isNull || result.width < 2 || result.height < 2 ? nil : result
}

@MainActor func copyPNG(_ png: Data, to pasteboard: NSPasteboard) {
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

func annotationPNG(image: NSImage, marks: [AnnotationMark], crop: CGRect? = nil) throws -> Data {
    guard let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          original.width > 0, original.height > 0, original.width <= 16_384, original.height <= 16_384 else {
        throw captureError("Image dimensions must be between 1 and 16384 pixels.")
    }
    let pixels = CGSize(width: original.width, height: original.height)
    let viewport: CGRect
    if let crop {
        guard let valid = annotationValidCrop(crop, pixels: pixels) else { throw captureError("Crop must contain at least 2 × 2 image pixels.") }
        viewport = valid
    } else { viewport = CGRect(origin: .zero, size: pixels) }
    let scale = min(1, 2560 / max(viewport.width, viewport.height))
    let width = max(1, Int(viewport.width * scale))
    let height = max(1, Int(viewport.height * scale))
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw captureError("Could not create the annotated image.")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
    drawAnnotationImage(image, marks: marks, pixels: pixels, rect: NSRect(x: -viewport.minX * scale, y: -viewport.minY * scale, width: pixels.width * scale, height: pixels.height * scale))
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
