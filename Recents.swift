import AppKit
import ImageIO

// Saved capture bundles, most recently edited first. Choosing one reopens it in the composer.
@MainActor final class ComposerRecents: NSViewController {
    static let size = NSSize(width: 300, height: 460)
    static let limit = 30
    let list = ComposerContextPicker.FlippedStack()
    let output: String
    let current: String?
    var onOpen: ((String) -> Void)?
    private(set) var rows: [RecentRow] = []

    init(output: String, current: String?) {
        self.output = output
        self.current = current
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Recents")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Captures and edits are saved as you go")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let stack = NSStackView(views: [title, subtitle, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setCustomSpacing(12, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        reload()
    }

    func reload() {
        for row in list.arrangedSubviews { list.removeArrangedSubview(row); row.removeFromSuperview() }
        let root = URL(fileURLWithPath: output).resolvingSymlinksInPath()
        let open = current.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        rows = recentBundles(output: output, limit: Self.limit).map { bundle in
            let row = RecentRow(bundle: bundle, image: Self.thumbnail(bundle.thumbnail, root: root), when: formatter.localizedString(for: bundle.updatedAt, relativeTo: Date()), current: URL(fileURLWithPath: bundle.path).resolvingSymlinksInPath().path == open)
            row.onSelect = { [weak self] in self?.onOpen?(bundle.path) }
            return row
        }
        for row in rows {
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if rows.isEmpty { list.addArrangedSubview(ComposerContextPicker.emptyView("No captures yet. Press ⌥G to capture.")) }
    }

    // Thumbnails are read only from the captures folder, downsampled.
    static func thumbnail(_ path: String?, root: URL) -> NSImage? {
        guard let path else { return nil }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard file.deletingLastPathComponent() == root, file.pathExtension == "png",
              let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// One saved bundle: thumbnail, title, contents and when it was last edited.
@MainActor final class RecentRow: NSView {
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    var onSelect: (() -> Void)?
    let current: Bool
    private var hovering = false

    init(bundle: RecentBundle, image: NSImage?, when: String, current: Bool) {
        self.current = current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.control
        let preview = NSImageView()
        preview.image = image ?? NSImage(systemSymbolName: bundle.videos > 0 ? "record.circle" : "photo", accessibilityDescription: nil)
        preview.imageScaling = image == nil ? .scaleNone : .scaleProportionallyUpOrDown
        preview.contentTintColor = .tertiaryLabelColor
        preview.wantsLayer = true
        preview.layer?.cornerRadius = CornerRadius.small
        preview.layer?.masksToBounds = true
        preview.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        title.stringValue = bundle.title
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let parts = [bundle.screenshots > 0 ? "\(bundle.screenshots) screenshot\(bundle.screenshots == 1 ? "" : "s")" : nil, bundle.videos > 0 ? "\(bundle.videos) clip\(bundle.videos == 1 ? "" : "s")" : nil, current ? "open" : when].compactMap { $0 }
        detail.stringValue = parts.joined(separator: " · ")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [preview, text])
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            preview.widthAnchor.constraint(equalToConstant: 64),
            preview.heightAnchor.constraint(equalToConstant: 40),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = current ? "This capture is open" : "Reopen this capture in the composer"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(bundle.title), \(detail.stringValue)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let alpha: CGFloat = current ? 0.16 : (hovering ? 0.08 : 0)
        layer?.backgroundColor = (current ? NSColor.controlAccentColor : NSColor.labelColor).withAlphaComponent(alpha).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if !current { onSelect?() } }
    override func accessibilityPerformPress() -> Bool { if !current { onSelect?() }; return true }
}
