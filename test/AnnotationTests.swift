import AppKit

@main
struct AnnotationTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        try closeAndReopen()
        try floatingToolbar()
        try inlineTextStickyToolsAndCrop()
        try objectEditing()
        geometryAndHistory()
        try pixelsAndExport()
        print("Annotation editor: geometry, history, pixels, dimensions and private export passed")
    }

    @MainActor static func closeAndReopen() throws {
        let image = NSImage(size: NSSize(width: 300, height: 160), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        var completions = 0
        for _ in 0..<3 {
            let editor = try AnnotationEditor(image: image, shot: ["app": "Test"], output: "/tmp")
            editor.completion = { result in
                expect(result == nil, "close cancels without exporting")
                completions += 1
            }
            editor.showWindow(nil)
            editor.window?.performClose(nil)
            expect(editor.completion == nil && editor.window?.isVisible == false, "close clears completion and hides window")
            editor.finish(nil)
        }
        expect(completions == 3, "repeated close and reopen completes exactly once per editor")
        let cursor = annotationCrosshairCursor()
        expect(cursor.hotSpot == CGPoint(x: 12, y: 12), "crosshair hotspot matches the plus center")
    }

    @MainActor static func floatingToolbar() throws {
        let image = NSImage(size: NSSize(width: 1200, height: 800), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let editor = try AnnotationEditor(image: image, shot: ["app": "Test"], output: "/tmp")
        let content = editor.window!.contentView!
        content.layoutSubtreeIfNeeded()
        expect(editor.canvas.frame == content.bounds, "canvas fills the content without toolbar footer or image padding")
        let before = editor.tray.frame
        editor.moveToolbar(by: CGPoint(x: 60, y: 100))
        expect(abs(editor.tray.frame.minX - before.minX - 60) < 0.01 && abs(editor.tray.frame.minY - before.minY - 100) < 0.01, "toolbar moves with the drag in both directions")
        editor.moveToolbar(by: CGPoint(x: 10000, y: 10000))
        expect(content.bounds.contains(editor.tray.frame), "toolbar remains reachable when dragged past the window edge")
        editor.window?.setContentSize(NSSize(width: 720, height: 480))
        editor.moveToolbar(by: .zero)
        expect(content.bounds.contains(editor.tray.frame), "toolbar stays inside a resized window")
        expect(editor.tray.layer?.borderWidth == 0, "toolbar has no outline")
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("appshots-annotation-\(UUID().uuidString)"))
        defer { testPasteboard.releaseGlobally() }
        editor.pasteboard = testPasteboard
        editor.canvas.document = AnnotationDocument(marks: [AnnotationMark(tool: .box, points: [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 90)], color: .red, width: 4)])
        editor.canvas.document.setCrop(CGRect(x: 0, y: 0, width: 600, height: 400))
        editor.copyImage()
        let copied = testPasteboard.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) }
        expect(copied?.pixelsWide == 600 && copied?.pixelsHigh == 400, "copy puts the cropped, annotated PNG on the clipboard")
        expect(editor.copyButton.keyEquivalent == "c" && editor.copyButton.keyEquivalentModifierMask == .command, "copy has ⌘C")
        expect(editor.canvas.document.marks.count == 1, "copying leaves the annotations editable")
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: content.convert(CGPoint(x: content.bounds.maxX - 20, y: content.bounds.maxY - 40), to: nil), modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        expect(editor.canvas.menu(for: click)?.items.map(\.title) == ["Copy Image"], "right-clicking the image offers Copy Image")
        editor.window?.close()
    }

    @MainActor static func objectEditing() throws {
        let size = CGSize(width: 300, height: 160)
        var box = AnnotationMark(tool: .box, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 60)], color: .red, width: 4)
        expect(annotationHit(box, point: CGPoint(x: 70, y: 40), tolerance: 4), "box interior selects the object")
        expect(!annotationHit(box, point: CGPoint(x: 180, y: 100), tolerance: 4), "empty canvas is not a hit")
        let moved = annotationDragged(AnnotationDrag(original: box, start: CGPoint(x: 70, y: 40), handle: nil), to: CGPoint(x: 100, y: 70), pixels: size)
        expect(moved.points == [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 90)] && moved.id == box.id, "move preserves object identity and size")
        let resized = annotationDragged(AnnotationDrag(original: box, start: box.points[1], handle: 2), to: CGPoint(x: 180, y: 100), pixels: size)
        expect(resized.points == [CGPoint(x: 20, y: 20), CGPoint(x: 180, y: 100)], "corner resize keeps opposite corner fixed")
        let bounded = annotationTranslated(box, delta: CGPoint(x: 500, y: 500), pixels: size)
        expect(annotationBounds(bounded).maxX == 300 && annotationBounds(bounded).maxY == 160, "moving stays inside image")
        let arrow = AnnotationMark(tool: .arrow, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 60)], color: .red, width: 4)
        expect(annotationHit(arrow, point: CGPoint(x: 35, y: 35), tolerance: 4), "arrow line can be selected")
        let endpoint = annotationDragged(AnnotationDrag(original: arrow, start: arrow.points[1], handle: 1), to: CGPoint(x: 90, y: 80), pixels: size)
        expect(endpoint.points == [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 80)], "arrow endpoint changes independently")
        let text = AnnotationMark(tool: .text, points: [CGPoint(x: 10, y: 80)], color: .black, width: 2, text: "Move me")
        let textBounds = annotationBounds(text)
        expect(annotationHit(text, point: CGPoint(x: textBounds.midX, y: textBounds.midY), tolerance: 4), "text uses rendered glyph bounds for selection")
        let larger = annotationDragged(AnnotationDrag(original: text, start: CGPoint(x: textBounds.maxX, y: textBounds.maxY), handle: 2), to: CGPoint(x: textBounds.minX + textBounds.width * 2, y: textBounds.maxY), pixels: size)
        expect(abs((larger.fontSize ?? 0) - 44) < 0.001, "text resize changes font size")
        var document = AnnotationDocument()
        document.append(box); document.replace(moved); document.replace(resized); document.remove(box.id)
        document.undo(); expect(document.marks == [resized], "undo restores a deleted object")
        document.undo(); expect(document.marks == [moved], "undo reverses resize")
        document.undo(); expect(document.marks == [box], "undo reverses move")
        document.redo(); expect(document.marks == [moved], "redo reapplies move")
        box.text = "changed"; document.replace(box)
        expect(document.redoHistory.isEmpty, "new object edit clears redo branch")
        let decoded = try JSONDecoder().decode([AnnotationMark].self, from: JSONEncoder().encode([moved, larger]))
        expect(decoded[0].id == moved.id && decoded[0].points == moved.points && abs((decoded[1].fontSize ?? 0) - 44) < 0.001 && decoded[1].text == "Move me", "save and reopen retain editable geometry and text")
        let image = NSImage(size: size, flipped: true) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let original = try saveAnnotationFile(annotationPNG(image: image, marks: []), output: folder)
        let editor = try AnnotationEditor(image: image, shot: ["app": "Test", "screenshot": original.path], output: folder)
        editor.showWindow(nil)
        editor.canvas.document = AnnotationDocument(marks: [text])
        editor.canvas.tool = .select
        editor.canvas.selectedID = text.id
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        // Procedural NSImage fixtures rasterize at Retina scale. Event locations
        // must use the canvas's actual source pixels, not the image's point size.
        let actualPixels = editor.canvas.pixels
        let rect = annotationImageRect(image: actualPixels, bounds: editor.canvas.bounds)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let viewPoint = CGPoint(x: rect.minX + point.x * rect.width / actualPixels.width, y: rect.minY + point.y * rect.height / actualPixels.height)
            return NSEvent.mouseEvent(with: type, location: editor.canvas.convert(viewPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let inside = CGPoint(x: textBounds.midX, y: textBounds.midY)
        let destination = CGPoint(x: inside.x + 30, y: inside.y + 20)
        editor.canvas.mouseDown(with: event(.leftMouseDown, inside))
        editor.canvas.mouseDragged(with: event(.leftMouseDragged, destination))
        editor.canvas.mouseUp(with: event(.leftMouseUp, destination))
        let movedPoint = editor.canvas.document.marks[0].points[0]
        expect(abs(movedPoint.x - 40) < 0.000001 && abs(movedPoint.y - 100) < 0.000001, "native mouse gesture moves selected text in source-pixel coordinates")
        expect(editor.canvas.document.undoHistory.count == 1, "one drag creates one undo step")
        editor.canvas.document.undo()
        expect(editor.canvas.document.marks[0].points == text.points, "undo native move restores original position")
        editor.canvas.duplicateSelection()
        expect(editor.canvas.document.marks.count == 2 && editor.canvas.selectedID != text.id, "duplicate selects a new independently editable object")
        editor.canvas.deleteSelection()
        expect(editor.canvas.document.marks.count == 1, "delete targets selected object only")
        var saved: [String: Any]?
        editor.completion = { saved = $0 }
        editor.insert()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder + "/latest.json"))) as! [String: Any]
        let objects = try JSONDecoder().decode([AnnotationMark].self, from: JSONSerialization.data(withJSONObject: manifest["annotations"]!))
        expect(saved != nil && objects.count == 1 && objects[0].id == text.id && manifest["originalScreenshot"] as? String == original.path, "editor export saves editable objects and a clean base screenshot")
    }

    @MainActor static func inlineTextStickyToolsAndCrop() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for y in 0..<160 { for x in 0..<300 { bitmap.setColor(white, atX: x, y: y) } }
        let image = NSImage(data: bitmap.representation(using: .png, properties: [:])!)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let original = try saveAnnotationFile(annotationPNG(image: image, marks: []), output: folder)
        let editor = try AnnotationEditor(image: image, shot: ["app": "Fixture", "screenshot": original.path, "text": "Private text outside the crop"], output: folder)
        editor.showWindow(nil)
        editor.window!.contentView!.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let rect = canvas.sourceRect
            let display = CGPoint(x: rect.minX + point.x * rect.width / canvas.pixels.width, y: rect.minY + point.y * rect.height / canvas.pixels.height)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(display, to: nil), modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20)))
        expect(canvas.inlineEditor != nil && editor.window!.sheets.isEmpty, "text starts in an inline editor, never a modal sheet")
        expect(editor.window!.firstResponder === canvas.inlineEditor, "inline text has a live insertion caret")
        canvas.inlineEditor!.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        canvas.commitInlineText()
        expect(canvas.document.marks.count == 1 && canvas.document.marks[0].text == "Hello", "inline text commits into editable image-space markup")
        expect(canvas.tool == .text, "Text remains active for another label")
        let beforeCancel = canvas.document.marks
        canvas.editText(at: CGPoint(x: 20, y: 20), existing: canvas.document.marks[0])
        canvas.inlineEditor!.string = "Cancelled edit"
        canvas.cancelInlineText()
        expect(canvas.document.marks == beforeCancel, "Escape/cancel does not overwrite existing text")
        canvas.tool = .arrow
        for offset in [CGFloat(0), 40] {
            canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 80 + offset, y: 30)))
            canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 110 + offset, y: 60)))
        }
        expect(canvas.tool == .arrow && canvas.document.marks.filter { $0.tool == .arrow }.count == 2, "Arrow stays active for consecutive gestures")
        canvas.tool = .draw
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 160, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 180, y: 40)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 60)))
        expect(canvas.tool == .draw, "Draw does not jump back to Select")
        let marks = canvas.document.marks
        canvas.tool = .crop
        canvas.cropSelection = CGRect(x: 10, y: 10, width: 150, height: 100)
        canvas.applyCropSelection()
        expect(canvas.document.crop == CGRect(x: 10, y: 10, width: 150, height: 100), "crop is stored in original source-pixel coordinates")
        expect(canvas.document.marks == marks, "cropping never flattens or translates editable annotations")
        let mapped = canvas.imagePoint(canvas.imageRect.origin, clamp: true)!
        expect(abs(mapped.x - 10) < 0.000001 && abs(mapped.y - 10) < 0.000001, "cropped viewport maps drawing back to the original image")
        canvas.document.undo()
        expect(canvas.document.crop == nil && canvas.document.marks == marks, "Undo restores the uncropped viewport and all objects")
        canvas.document.redo()
        expect(canvas.document.crop != nil, "Redo restores crop")
        var saved: [String: Any]?
        editor.completion = { saved = $0 }
        editor.insert()
        expect(saved?["text"] as? String == "", "cropping omits original-window accessibility text from delivery")
        expect(saved?["originalAccessibilityText"] as? String == "Private text outside the crop", "original context is retained locally for Reset Crop")
        expect(saved?["originalScreenshot"] as? String == original.path && saved?["crop"] != nil, "crop metadata preserves the clean original for reopening")
        let exported = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: saved!["screenshot"] as! String)))!
        expect(exported.pixelsWide == 150 && exported.pixelsHigh == 100, "cropped export uses only selected source pixels")
    }

    static func geometryAndHistory() {
        let pixels = CGSize(width: 300, height: 160)
        let rect = annotationImageRect(image: pixels, bounds: CGRect(x: 10, y: 20, width: 600, height: 400))
        expect(rect == CGRect(x: 10, y: 60, width: 600, height: 320), "aspect fit with centered letterboxing")
        expect(annotationImagePoint(CGPoint(x: 310, y: 220), pixels: pixels, rect: rect, clamp: false) == CGPoint(x: 150, y: 80), "canvas coordinates map to original pixels")
        expect(annotationImagePoint(CGPoint(x: 1, y: 1), pixels: pixels, rect: rect, clamp: false) == nil, "ignore drawing outside image")
        expect(annotationImagePoint(CGPoint(x: 900, y: 500), pixels: pixels, rect: rect, clamp: true) == CGPoint(x: 300, y: 160), "clamp drags at image edge")
        var document = AnnotationDocument()
        let mark = AnnotationMark(tool: .arrow, points: [.zero, CGPoint(x: 30, y: 30)], color: .red, width: 4)
        document.append(mark)
        document.undo()
        expect(document.marks.isEmpty && document.redoHistory.count == 1, "undo retains redo")
        document.redo()
        expect(document.marks.count == 1 && document.redoHistory.isEmpty, "redo restores mark")
        document.undo()
        document.append(mark)
        expect(document.redoHistory.isEmpty, "new drawing clears redo branch")
    }

    static func pixelsAndExport() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<160 {
            for x in 0..<300 { bitmap.setColor(y < 80 ? white : blue, atX: x, y: y) }
        }
        let image = NSImage(data: bitmap.representation(using: .png, properties: [:])!)!
        let marks = [
            AnnotationMark(tool: .box, points: [CGPoint(x: 20, y: 20), CGPoint(x: 120, y: 50)], color: .red, width: 4),
            AnnotationMark(tool: .arrow, points: [CGPoint(x: 40, y: 90), CGPoint(x: 160, y: 120)], color: .yellow, width: 4),
            AnnotationMark(tool: .draw, points: [CGPoint(x: 180, y: 20), CGPoint(x: 200, y: 40), CGPoint(x: 220, y: 20)], color: .green, width: 4),
            AnnotationMark(tool: .text, points: [CGPoint(x: 10, y: 55)], color: .black, width: 2, text: "Check this"),
        ]
        let png = try annotationPNG(image: image, marks: marks)
        try png.write(to: URL(fileURLWithPath: "/tmp/opencode-annotation-test.png"))
        let exported = NSBitmapImageRep(data: png)!
        expect(exported.pixelsWide == 300 && exported.pixelsHigh == 160, "preserve image dimensions")
        let red = exported.colorAt(x: 20, y: 35)!.usingColorSpace(.deviceRGB)!
        expect(red.redComponent > 0.9 && red.greenComponent < 0.3, "box is exported at the correct top-left pixel coordinates")
        let bottom = exported.colorAt(x: 250, y: 140)!.usingColorSpace(.deviceRGB)!
        expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.3, "source image stays upright")
        let top = exported.colorAt(x: 250, y: 10)!.usingColorSpace(.deviceRGB)!
        expect(top.redComponent > 0.9 && top.greenComponent > 0.9, "unmarked image area is preserved")
        let cropped = NSBitmapImageRep(data: try annotationPNG(image: image, marks: [marks[0]], crop: CGRect(x: 10, y: 10, width: 100, height: 100)))!
        expect(cropped.pixelsWide == 100 && cropped.pixelsHigh == 100, "crop export dimensions are exact")
        let cropMark = cropped.colorAt(x: 10, y: 25)!.usingColorSpace(.deviceRGB)!
        expect(cropMark.redComponent > 0.9 && cropMark.greenComponent < 0.3, "crop preserves source-space annotation alignment")
        let cropBottom = cropped.colorAt(x: 90, y: 90)!.usingColorSpace(.deviceRGB)!
        expect(cropBottom.blueComponent > 0.9 && cropBottom.redComponent < 0.3, "crop samples the original image without flipping")
        let large = NSImage(size: NSSize(width: 4000, height: 2000), flipped: true) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let resized = NSBitmapImageRep(data: try annotationPNG(image: large, marks: []))!
        expect(resized.pixelsWide == 2560 && resized.pixelsHigh == 1280, "large clipboard images are bounded without stretching")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let file = try saveAnnotationFile(png, output: folder)
        try saveCaptureManifest(["screenshot": file.path, "text": "original accessibility text", "annotationCount": 4], output: folder)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        expect(permissions.intValue == 0o600, "private image permissions")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: folder + "/latest.json"))) as! [String: Any]
        expect(manifest["text"] as? String == "original accessibility text", "export retains original context")
        try png.write(to: URL(fileURLWithPath: "/tmp/opencode-annotation-test.png"))
    }

    static func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
}

func captureError(_ message: String) -> NSError { NSError(domain: "AnnotationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
