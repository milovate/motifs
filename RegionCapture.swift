import AppKit
import ScreenCaptureKit

func screenRegionRect(from start: CGPoint, to end: CGPoint, bounds: CGRect) -> CGRect? {
    let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    return rect.isNull || rect.width < 3 || rect.height < 3 ? nil : rect
}

func screenRegionOutputSize(_ region: CGRect, scale: CGFloat) -> CGSize {
    guard region.width.isFinite, region.height.isFinite, region.width > 0, region.height > 0, scale.isFinite else { return .zero }
    let factor = min(max(1, scale), 2560 / max(region.width, region.height))
    return CGSize(width: max(1, Int(region.width * factor)), height: max(1, Int(region.height * factor)))
}

@MainActor final class RegionSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RegionSelectionView: NSView {
    var start: CGPoint?
    var selection: CGRect?
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if let selection { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
            let text = "\(Int(selection.width)) × \(Int(selection.height))"
            (text as NSString).draw(at: CGPoint(x: min(bounds.maxX - 110, selection.minX + 6), y: max(8, selection.minY - 24)), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)])
        } else {
            let hint = "Drag to capture a region · Escape to cancel"
            let size = (hint as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)])
            (hint as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        selection = screenRegionRect(from: start, to: convert(event.locationInWindow, from: nil), bounds: bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        start = nil
        if let selection { onSelect?(selection) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return }
        super.keyDown(with: event)
    }
}

@MainActor final class RegionSelectionController {
    var panels: [NSPanel] = []
    var completion: (((CGRect, CGDirectDisplayID, CGFloat)?) -> Void)?
    var activationObserver: NSObjectProtocol?

    func show() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                guard !NSApp.isActive else { return }
                self?.finish(nil)
            }
        }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let panel = RegionSelectionPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.identifier = NSUserInterfaceItemIdentifier("appshot-region")
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in self?.finish((rect, number.uint32Value, screen.backingScaleFactor)) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        if panels.isEmpty { finish(nil) }
    }

    func finish(_ selection: (CGRect, CGDirectDisplayID, CGFloat)?) {
        guard let completion else { return }
        self.completion = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        completion(selection)
    }
}

// The overlay dims the live desktop; no full-screen image is saved. Only the
// user's completed region is captured, and no outside accessibility text is read.
@MainActor func captureScreenRegion(output: String) async throws -> [String: Any]? {
    guard CGPreflightScreenCaptureAccess() else { throw captureError("Screen Recording permission is required to capture a region.") }
    let picker = RegionSelectionController()
    let selected = await withCheckedContinuation { continuation in
        picker.completion = { continuation.resume(returning: $0) }
        picker.show()
        NSApp.activate(ignoringOtherApps: true)
    }
    withExtendedLifetime(picker) {}
    guard let (region, displayID, scale) = selected else { return nil }
    // Let the overlay leave the compositor before starting the capture.
    try await Task.sleep(nanoseconds: 150_000_000)
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw captureError("The selected display is no longer available.") }
    let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
    let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
    let config = SCStreamConfiguration()
    config.sourceRect = region
    let size = screenRegionOutputSize(region, scale: scale)
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw captureError("Could not encode the selected region.") }
    guard png.count <= 15_000_000 else { throw captureError("The selected region exceeds 15 MB. Select a smaller region.") }
    let file = try saveAnnotationFile(png, output: output)
    let shot: [String: Any] = ["app": "Screen region", "title": "\(Int(region.width)) × \(Int(region.height)) selection", "capturedAt": ISO8601DateFormatter().string(from: Date()), "screenshot": file.path, "text": "", "warnings": ["Region capture: only selected pixels are shared; no outside accessibility text was collected."], "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height, "displayID": displayID]]
    try saveCaptureManifest(shot, output: output)
    return shot
}
