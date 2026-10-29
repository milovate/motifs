import AppKit

func captureError(_ message: String) -> NSError { NSError(domain: "RegionCaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
func saveAnnotationFile(_ png: Data, output: String) throws -> URL { fatalError("Tests must never save a desktop capture") }
func saveCaptureManifest(_ shot: [String: Any], output: String) throws { fatalError("Tests must never save a desktop capture") }

@main struct RegionCaptureTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        precondition(screenRegionRect(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 100, y: 50), bounds: bounds) == CGRect(x: 100, y: 50, width: 200, height: 200), "dragging in either direction produces the same selected pixels")
        precondition(screenRegionRect(from: CGPoint(x: -40, y: -10), to: CGPoint(x: 900, y: 700), bounds: bounds) == bounds, "selection is clamped to its display")
        precondition(screenRegionRect(from: .zero, to: CGPoint(x: 1, y: 1), bounds: bounds) == nil, "a click or tiny gesture does not take a screenshot")
        precondition(screenRegionOutputSize(CGRect(x: 0, y: 0, width: 640, height: 400), scale: 2) == CGSize(width: 1280, height: 800), "region respects Retina scale")
        precondition(screenRegionOutputSize(CGRect(x: 0, y: 0, width: 4000, height: 2000), scale: 2) == CGSize(width: 2560, height: 1280), "large regions are bounded without changing aspect ratio")
        let panel = RegionSelectionPanel(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = RegionSelectionView(frame: bounds)
        panel.contentView = view
        var selected: CGRect?
        var cancellations = 0
        view.onSelect = { selected = $0 }
        view.onCancel = { cancellations += 1 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 300, y: 250)))
        precondition(selected == nil && view.selection != nil, "drag preview does not capture before release")
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 250)))
        precondition(selected == CGRect(x: 100, y: 50, width: 200, height: 200), "release confirms only the selected top-left display region")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        precondition(cancellations == 1, "Escape cancels without a capture")
        let safari = ScreenWindow(id: 42, pid: 7, app: "Safari", frame: CGRect(x: 1600, y: 100, width: 400, height: 300))
        precondition(overlayRect(safari.frame, screenFrame: CGRect(x: 1512, y: -100, width: 1920, height: 1080), primaryHeight: 982) == CGRect(x: 88, y: 98, width: 400, height: 300), "window frames map into the overlay of their display")
        var picked: ScreenWindow?
        var wholeScreen = 0
        view.onWindow = { picked = $0 }
        view.onDisplay = { wholeScreen += 1 }
        view.windows = [(safari, CGRect(x: 400, y: 300, width: 300, height: 200))]
        view.hover(at: CGPoint(x: 450, y: 350))
        precondition(view.hovered?.window == safari, "hovering highlights the window under the pointer")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 450, y: 350)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 450, y: 350)))
        precondition(picked == safari, "clicking a highlighted window picks it")
        view.hover(at: CGPoint(x: 20, y: 20))
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 20, y: 20)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 20, y: 20)))
        precondition(view.hovered == nil && wholeScreen == 1, "clicking the desktop picks the whole screen")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        view.keyDown(with: enter)
        precondition(wholeScreen == 2, "Return picks the whole screen")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jD1sAAAAASUVORK5CYII=")!
        let file = folder.appendingPathComponent("fixture.png")
        try png.write(to: file)
        let shot: [String: Any] = ["screenshot": file.path, "capturedAt": "fixture"]
        let multiple = try loadScreenshotAttachments(["screenshots": [shot, shot]], output: folder.path)
        let empty = try loadScreenshotAttachments(["screenshots": []], output: folder.path)
        let legacy = try loadScreenshotAttachments(shot, output: folder.path)
        precondition(multiple.count == 2, "multiple screenshots remain separate ordered image attachments")
        precondition(empty.isEmpty, "removing every screenshot allows text-only handoff")
        precondition(legacy.count == 1, "legacy single-capture manifests remain supported")
        let full = try loadScreenshotAttachments(["screenshots": Array(repeating: shot, count: 14)], output: folder.path)
        precondition(full.count == 14, "eight screenshots plus six recording frames fit")
        do { _ = try loadScreenshotAttachments(["screenshots": Array(repeating: shot, count: 15)], output: folder.path); fatalError("oversized collections must fail") } catch {}
        do { _ = try loadScreenshotAttachments(["screenshots": NSNull()], output: folder.path); fatalError("null does not mean an intentional empty collection") } catch {}
        do { _ = try loadScreenshotAttachments(["screenshot": "/outside.png"], output: folder.path); fatalError("outside files must fail") } catch {}
        print("Region selection, cancellation and screenshot attachment contract checks passed")
    }
}
