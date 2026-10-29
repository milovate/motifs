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

// An app window on screen; `frame` is in global display coordinates (top-left of the main display).
struct ScreenWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let frame: CGRect
}

enum ScreenChoice: Equatable {
    case area(CGRect, display: CGDirectDisplayID, scale: CGFloat)
    case window(ScreenWindow)
    case display(CGDirectDisplayID, scale: CGFloat, size: CGSize)
}

// Visible app windows, front to back, excluding Capture Studio's own.
func visibleWindows() -> [ScreenWindow] {
    let own = ProcessInfo.processInfo.processIdentifier
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return info.compactMap { entry in
        guard entry[kCGWindowLayer as String] as? Int == 0, let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != own,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width >= 40, frame.height >= 40, (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
        return ScreenWindow(id: id, pid: pid, app: entry[kCGWindowOwnerName as String] as? String ?? "App", frame: frame)
    }
}

// Global display coordinates to the flipped overlay view covering `screenFrame`.
func overlayRect(_ global: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
    global.offsetBy(dx: -screenFrame.minX, dy: -(primaryHeight - screenFrame.maxY))
}

@MainActor final class RegionSelectionView: NSView {
    var start: CGPoint?
    var selection: CGRect?
    var windows: [(window: ScreenWindow, rect: CGRect)] = []
    private(set) var hovered: (window: ScreenWindow, rect: CGRect)?
    var onSelect: ((CGRect) -> Void)?
    var onWindow: ((ScreenWindow) -> Void)?
    var onDisplay: (() -> Void)?
    var onCancel: (() -> Void)?
    var hint = "Drag to capture a region · Escape to cancel"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        let shade = NSBezierPath(rect: bounds)
        if let hole = selection ?? hovered?.rect { shade.appendRect(hole) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill(); shade.fill()
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.6)]
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection); border.lineWidth = 1.5; border.stroke()
            let text = "\(Int(selection.width)) × \(Int(selection.height))"
            (text as NSString).draw(at: CGPoint(x: min(bounds.maxX - 110, selection.minX + 6), y: max(8, selection.minY - 24)), withAttributes: label)
            return
        }
        if let hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill(); hovered.rect.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: hovered.rect.insetBy(dx: 1, dy: 1)); border.lineWidth = 3; border.stroke()
            (" \(hovered.window.app) " as NSString).draw(at: CGPoint(x: max(8, hovered.rect.minX + 8), y: max(8, hovered.rect.minY + 8)), withAttributes: label)
        }
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let size = (hint as NSString).size(withAttributes: [.font: font])
        let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - size.height - 64, width: size.width + 28, height: size.height + 14)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (hint as NSString).draw(at: CGPoint(x: pill.minX + 14, y: pill.minY + 7), withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
    func hover(at point: CGPoint) {
        let next = windows.first { $0.rect.contains(point) }
        guard next?.window != hovered?.window else { return }
        hovered = next
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
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
        if let selection { onSelect?(selection) } else if let hovered { onWindow?(hovered.window) } else { onDisplay?() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76: onDisplay?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor final class RegionSelectionController {
    var panels: [NSPanel] = []
    var completion: ((ScreenChoice?) -> Void)?
    var activationObserver: NSObjectProtocol?
    var hint: String?

    func show() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                guard !NSApp.isActive else { return }
                self?.finish(nil)
            }
        }
        let windows = visibleWindows()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
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
            panel.acceptsMouseMovedEvents = true
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            if let hint { view.hint = hint }
            view.windows = windows.compactMap { window in
                let rect = overlayRect(window.frame, screenFrame: screen.frame, primaryHeight: primaryHeight).intersection(view.bounds)
                return rect.isNull || rect.isEmpty ? nil : (window, rect)
            }
            view.onSelect = { [weak self] rect in self?.finish(.area(rect, display: number.uint32Value, scale: screen.backingScaleFactor)) }
            view.onWindow = { [weak self] window in self?.finish(.window(window)) }
            view.onDisplay = { [weak self] in self?.finish(.display(number.uint32Value, scale: screen.backingScaleFactor, size: screen.frame.size)) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            view.hover(at: view.convert(panel.mouseLocationOutsideOfEventStream, from: nil))
            if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        if panels.isEmpty { finish(nil) }
    }

    func finish(_ choice: ScreenChoice?) {
        guard let completion else { return }
        self.completion = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll()
        completion(choice)
    }
}

// The overlay dims the live desktop; no full-screen image is saved. Only what the user
// picks is captured: a dragged area, a clicked window, or the whole screen.
@MainActor func chooseScreenTarget(hint: String) async -> ScreenChoice? {
    let picker = RegionSelectionController()
    picker.hint = hint
    let selected = await withCheckedContinuation { continuation in
        picker.completion = { continuation.resume(returning: $0) }
        picker.show()
        NSApp.activate(ignoringOtherApps: true)
    }
    withExtendedLifetime(picker) {}
    return selected
}

// Captures display-local `region` in points; the whole display when it covers it.
@MainActor func captureScreenArea(_ region: CGRect, displayID: CGDirectDisplayID, scale: CGFloat, output: String, wholeDisplay: Bool = false) async throws -> [String: Any] {
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
    let shot: [String: Any] = ["app": wholeDisplay ? "Screen" : "Screen region", "title": wholeDisplay ? "Full screen \(Int(region.width)) × \(Int(region.height))" : "\(Int(region.width)) × \(Int(region.height)) selection", "capturedAt": ISO8601DateFormatter().string(from: Date()), "screenshot": file.path, "text": "", "warnings": [wholeDisplay ? "Full-screen capture: no accessibility text was collected." : "Region capture: only selected pixels are shared; no outside accessibility text was collected."], "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height, "displayID": displayID]]
    try saveCaptureManifest(shot, output: output)
    return shot
}
