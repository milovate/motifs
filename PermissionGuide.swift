import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

@MainActor private func motifsIcon() -> NSImage {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: url) {
        return image
    }
    return NSApp.applicationIconImage
}

enum CapturePermission: Int, CaseIterable {
    case screenRecording, accessibility

    var title: String { self == .screenRecording ? "Screen Recording" : "Accessibility" }
    var symbol: String { self == .screenRecording ? "rectangle.dashed" : "accessibility" }
    var detail: String {
        switch self {
        case .screenRecording: return "Screenshots and recordings"
        case .accessibility: return "Window text and drafts · Optional"
        }
    }
    var settingsURL: URL {
        let pane = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")!
    }
    var granted: Bool {
        self == .screenRecording ? CGPreflightScreenCaptureAccess() : AXIsProcessTrusted()
    }
}

@MainActor final class PermissionGuide: NSObject, NSWindowDelegate {
    private let appURL = Bundle.main.bundleURL.standardizedFileURL
    private var window: NSWindow?
    private var panel: NSPanel?
    private var tile: PermissionAppTile?
    private var buttons: [NSButton] = []
    private var statuses: [NSTextField] = []
    private var notice: NSTextField?
    private var selected: CapturePermission?
    private var timer: Timer?
    private var sawSettings = false
    private var openedAt = Date()

    func show(focusing permission: CapturePermission? = nil) {
        if window == nil { makeWindow() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let permission { window?.makeFirstResponder(buttons[permission.rawValue]) }
        if timer == nil {
            timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        closeGuide()
    }

    private func makeWindow() {
        let setup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 223),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        setup.title = "Motifs Permissions"
        setup.titleVisibility = .hidden
        setup.titlebarAppearsTransparent = true
        setup.identifier = NSUserInterfaceItemIdentifier("capture-studio-permissions")
        setup.isReleasedWhenClosed = false
        setup.delegate = self
        setup.center()
        guard let content = setup.contentView else { return }
        let logo = NSImageView(frame: NSRect(x: 16, y: 172, width: 40, height: 40))
        logo.image = motifsIcon()
        content.addSubview(logo)
        let heading = label("Motifs Permissions", size: 21, weight: .semibold)
        heading.frame = NSRect(x: 64, y: 176, width: 330, height: 32)
        content.addSubview(heading)

        let card = NSBox(frame: NSRect(x: 20, y: 45, width: 380, height: 116))
        card.boxType = .custom
        card.cornerRadius = CornerRadius.popup
        card.fillColor = .controlBackgroundColor
        card.borderColor = .separatorColor
        content.addSubview(card)
        let divider = NSBox(frame: NSRect(x: 44, y: 57, width: 322, height: 1))
        divider.boxType = .separator
        card.addSubview(divider)

        for permission in CapturePermission.allCases {
            let y = 58 - CGFloat(permission.rawValue) * 58
            let icon = NSImageView(frame: NSRect(x: 14, y: y + 18, width: 20, height: 20))
            icon.image = NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)
            icon.contentTintColor = .secondaryLabelColor
            card.addSubview(icon)
            let title = label(permission.title, size: 14, weight: .semibold)
            title.frame = NSRect(x: 46, y: y + 30, width: 177, height: 18)
            card.addSubview(title)
            let status = label("", size: 11, weight: .medium, color: .secondaryLabelColor)
            status.alignment = .right
            status.frame = NSRect(x: 232, y: y + 20, width: 42, height: 16)
            card.addSubview(status)
            statuses.append(status)
            let detail = label(permission.detail, size: 11, color: .secondaryLabelColor)
            detail.frame = NSRect(x: 46, y: y + 12, width: 181, height: 16)
            card.addSubview(detail)

            let button = NSButton(title: "Settings", target: self, action: #selector(openSettings(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.frame = NSRect(x: 286, y: y + 15, width: 83, height: 28)
            button.tag = permission.rawValue
            button.setAccessibilityLabel("Open \(permission.title) settings")
            card.addSubview(button)
            buttons.append(button)
        }

        let notice = NSTextField(wrappingLabelWithString: "")
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.frame = NSRect(x: 20, y: 8, width: 264, height: 30)
        content.addSubview(notice)
        self.notice = notice
        if appURL.pathExtension == "app" {
            let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealApp))
            reveal.bezelStyle = .inline
            reveal.frame = NSRect(x: 289, y: 12, width: 111, height: 22)
            content.addSubview(reveal)
        }
        window = setup
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let permission = CapturePermission(rawValue: sender.tag) else { return }
        closeGuide()
        notice?.stringValue = ""
        guard NSWorkspace.shared.open(permission.settingsURL) else {
            notice?.stringValue = "Find \(permission.title) in Privacy & Security."
            return
        }
        if permission.granted { return }
        guard appURL.pathExtension == "app" else { return }
        selected = permission
        openedAt = Date()
        sawSettings = false
        makeGuide(for: permission)
        refresh()
    }

    private func makeGuide(for permission: CapturePermission) {
        let size = NSSize(width: 368, height: 113)
        let guide = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        guide.title = "Add Motifs"
        guide.identifier = NSUserInterfaceItemIdentifier("capture-studio-permission-guide")
        guide.isFloatingPanel = true
        guide.level = .floating
        guide.hidesOnDeactivate = false
        guide.isReleasedWhenClosed = false
        guide.isOpaque = false
        guide.backgroundColor = .clear
        guide.hasShadow = true
        guide.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = ComposerSurface(frame: NSRect(origin: .zero, size: size))
        guide.contentView = content
        let instruction = label("Drag into \(permission.title), then turn it on.", size: 12, weight: .medium)
        instruction.frame = NSRect(x: 14, y: 80, width: 310, height: 18)
        content.addSubview(instruction)
        let close = NSButton(title: "×", target: self, action: #selector(dismissGuide))
        close.isBordered = false
        close.font = .systemFont(ofSize: 20)
        close.setAccessibilityLabel("Close permission guide")
        close.frame = NSRect(x: 330, y: 75, width: 24, height: 27)
        content.addSubview(close)

        let tile = PermissionAppTile(frame: NSRect(x: 14, y: 31, width: 340, height: 42), appURL: appURL)
        content.addSubview(tile)
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealApp))
        reveal.bezelStyle = .inline
        reveal.frame = NSRect(x: 246, y: 7, width: 108, height: 20)
        content.addSubview(reveal)
        self.tile = tile
        panel = guide
    }

    private func refresh() {
        for permission in CapturePermission.allCases {
            let granted = permission.granted
            let status = statuses[permission.rawValue]
            status.stringValue = granted ? "✓ On" : "Off"
            status.textColor = granted ? .systemGreen : .secondaryLabelColor
        }
        guard let selected, let panel else { return }
        if selected.granted {
            notice?.stringValue = "\(selected.title) is enabled."
            closeGuide()
            return
        }
        let workspace = NSWorkspace.shared
        guard let front = workspace.frontmostApplication?.bundleIdentifier,
              front == "com.apple.systempreferences" || front == "com.apple.finder" || front == Bundle.main.bundleIdentifier else {
            panel.orderOut(nil)
            if !sawSettings && Date().timeIntervalSince(openedAt) > 8 { closeGuide() }
            return
        }
        if front == "com.apple.systempreferences" {
            guard let frame = guideFrame(panel: panel) else {
                panel.orderOut(nil)
                if !sawSettings && Date().timeIntervalSince(openedAt) > 8 { closeGuide() }
                return
            }
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible {
                let animate = !sawSettings && !workspace.accessibilityDisplayShouldReduceMotion
                panel.alphaValue = animate ? 0 : 1
                panel.orderFrontRegardless()
                if animate {
                    tile?.animateArrival()
                    NSAnimationContext.runAnimationGroup { animation in
                        animation.duration = 0.2
                        panel.animator().alphaValue = 1
                    }
                }
            }
            sawSettings = true
        } else if front != "com.apple.finder" {
            panel.orderOut(nil)
        }
    }

    private func guideFrame(panel: NSPanel) -> NSRect? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let screensTop = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let bounds = windows.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == settings.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.width >= 350, rect.height >= 280 else { return nil }
            return NSRect(x: rect.minX, y: screensTop - rect.maxY, width: rect.width, height: rect.height)
        }.first
        guard let bounds,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: bounds.midX, y: bounds.midY)) }) ?? NSScreen.main else { return nil }
        let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
        let size = panel.frame.size
        let x = min(max(bounds.maxX - size.width - 16, visible.minX), visible.maxX - size.width)
        let y = min(max(bounds.minY - size.height - 10, visible.minY), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
    @objc private func dismissGuide() { closeGuide() }

    private func closeGuide() {
        panel?.orderOut(nil)
        panel = nil
        tile = nil
        selected = nil
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
}

@MainActor private final class PermissionAppTile: NSView, NSDraggingSource {
    private let appURL: URL
    private let icon: NSImage
    private var dragStart: NSEvent?

    init(frame: NSRect, appURL: URL) {
        self.appURL = appURL
        icon = motifsIcon()
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Motifs app. Drag into System Settings, or use Show in Finder.")
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: CornerRadius.control, yRadius: CornerRadius.control).fill()
        icon.draw(in: NSRect(x: 9, y: 7, width: 30, height: 30))
        ("Motifs" as NSString).draw(at: NSPoint(x: 48, y: 13), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        let grip = NSBezierPath()
        for column in 0..<2 {
            for row in 0..<3 {
                grip.appendOval(in: NSRect(x: bounds.width - 20 + CGFloat(column) * 4,
                                           y: bounds.midY - 5 + CGFloat(row) * 4, width: 2, height: 2))
            }
        }
        NSColor.secondaryLabelColor.setFill()
        grip.fill()
    }

    override func mouseDown(with event: NSEvent) { dragStart = event }
    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let delta = NSPoint(x: event.locationInWindow.x - start.locationInWindow.x,
                            y: event.locationInWindow.y - start.locationInWindow.y)
        guard hypot(delta.x, delta.y) >= 3 else { return }
        dragStart = nil
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        let point = convert(start.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44), contents: icon)
        beginDraggingSession(with: [item], event: start, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func animateArrival() {
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -24
        rise.toValue = 0
        rise.damping = 16
        rise.stiffness = 180
        rise.duration = rise.settlingDuration
        layer?.add(rise, forKey: "arrival")
    }
}
