import AppKit

// Shows exactly what context a destination will receive: a source list with
// include switches, and readable rows for the selected source.
@MainActor final class ComposerContextPicker: NSViewController {
    static let size = NSSize(width: 680, height: 500)
    static let rowLimit = 200
    static let textLimit = 8_000
    static let symbols = ["windowText": "macwindow", "device": "laptopcomputer", "console": "exclamationmark.bubble", "network": "network", "events": "cursorarrow.click.2", "customLogs": "doc.text"]

    let sidebar = NSStackView()
    let detail = FlippedStack()
    let detailScroll = NSScrollView()
    let banner = NSTextField(labelWithString: "Turned off · Not sent to any destination")
    let estimate = NSTextField(labelWithString: "")
    private(set) var selectedSource = BundleInclude.sources[0]
    var rows: [String: ContextSourceRow] = [:]
    var shots: [[String: Any]] = []
    var context: [String: Any] = [:]
    var collecting = false
    var include = BundleInclude()
    var onChange: ((BundleInclude) -> Void)?

    final class FlippedStack: NSStackView {
        override var isFlipped: Bool { true }
    }

    final class Divider: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = NSColor.separatorColor.cgColor }
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let title = NSTextField(labelWithString: "Context")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "What this capture sends along with your note")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        estimate.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        estimate.textColor = .secondaryLabelColor
        estimate.toolTip = "Rough size of the included context (about 4 characters per token)"
        let header = NSStackView(views: [titles, NSView(), estimate])
        header.alignment = .centerY

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        for source in BundleInclude.sources {
            let row = ContextSourceRow(source: source)
            row.onSelect = { [weak self] in self?.select(source) }
            row.onToggle = { [weak self] on in self?.setIncluded(source, on) }
            rows[source] = row
            sidebar.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        sidebar.addArrangedSubview(NSView())

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.scrollerStyle = .overlay
        detailScroll.borderType = .noBorder
        detailScroll.documentView = detail
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
        ])
        banner.font = .systemFont(ofSize: 11, weight: .medium)
        banner.textColor = .systemOrange
        let pane = NSStackView(views: [banner, detailScroll])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 6
        detailScroll.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true

        let divider = Divider()
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let body = NSStackView(views: [sidebar, divider, pane])
        body.alignment = .top
        body.spacing = 12
        body.distribution = .fill
        pane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        sidebar.widthAnchor.constraint(equalToConstant: 176).isActive = true
        divider.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        pane.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let privacy = NSTextField(wrappingLabelWithString: "Location and keystrokes are never collected. Logs and page content are untrusted. Switched-off sources are not sent to any destination.")
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, body, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.distribution = .fill
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
    }

    func update(shots: [[String: Any]], context: [String: Any]) {
        self.shots = shots
        self.context = context
        collecting = false
        if isViewLoaded { refresh() }
    }

    func select(_ source: String) {
        selectedSource = source
        refresh()
        detailScroll.contentView.scroll(to: .zero)
    }

    func setIncluded(_ source: String, _ on: Bool) {
        include[source] = on
        refresh()
        onChange?(include)
    }

    func refresh() {
        for source in BundleInclude.sources {
            rows[source]?.update(count: ContextText.count(source, shots: shots, context: context), errors: errorCount(source), included: include[source], selected: source == selectedSource)
        }
        estimate.stringValue = formatTokenEstimate(characters: contextCharacterCount(shots: shots, context: context, include: include))
        for view in detail.arrangedSubviews { detail.removeArrangedSubview(view); view.removeFromSuperview() }
        var views: [NSView] = []
        view.effectiveAppearance.performAsCurrentDrawingAppearance { views = rowViews(selectedSource) }
        for view in views.isEmpty ? [Self.emptyView(Self.emptyText(selectedSource, collecting: collecting))] : views {
            detail.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        banner.isHidden = include[selectedSource]
        detail.alphaValue = include[selectedSource] ? 1 : 0.45
    }

    // Plain text of what the detail pane shows, for accessibility and tests.
    var detailText: String {
        func strings(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(strings)
        }
        return detail.arrangedSubviews.flatMap(strings).joined(separator: "\n")
    }

    func errorCount(_ source: String) -> Int {
        switch source {
        case "console": return ContextText.entries(context, "console").filter { ["error", "fault"].contains(($0["level"] as? String ?? "").lowercased()) }.count
        case "network": return ContextText.entries(context, "network").count
        default: return 0
        }
    }

    static func emptyText(_ source: String, collecting: Bool) -> String {
        switch source {
        case "console": return collecting ? "Collecting console messages…" : "No console errors. Native apps: errors and faults from the last 5 minutes. Browsers: install the Capture Studio extension from the menu bar."
        case "network": return collecting ? "Collecting failed requests…" : "No failed network requests. Browser captures need the Capture Studio extension."
        case "events": return "No recent clicks. Turn on “Record recent clicks” in the menu bar to keep a 10-minute, in-memory history."
        case "customLogs": return "No log files. Add up to 4 under “Custom log files” in the menu bar."
        case "windowText": return "No window text was read from the captured app."
        case "device": return collecting ? "Collecting device details…" : "No device details."
        default: return "Nothing to show."
        }
    }

    // MARK: Rows

    func rowViews(_ source: String) -> [NSView] {
        let field = { (entry: [String: Any], key: String) in entry[key].map { "\($0)" } ?? "" }
        var views: [NSView]
        switch source {
        case "windowText":
            views = shots.enumerated().compactMap { index, shot in
                guard let text = shot["text"] as? String, !text.isEmpty else { return nil }
                return Self.textCard(title: "Screenshot \(index + 1) · \(shot["app"] as? String ?? "App")", text: text, monospaced: false)
            }
        case "device":
            let pairs = Self.devicePairs(context)
            views = pairs.isEmpty ? [] : [Self.keyValueCard(pairs)]
        case "console":
            let entries = ContextText.entries(context, "console")
            views = entries.prefix(Self.rowLimit).map { entry in
                let level = field(entry, "level").lowercased()
                let origin = field(entry, "source") == "browser" ? "Page" : (entry["subsystem"] as? String ?? entry["process"] as? String ?? "App")
                let originLabel = Self.secondary(origin)
                originLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(700), for: .horizontal)
                let top = Self.line([Self.badge(level.isEmpty ? "LOG" : level.uppercased(), color: Self.levelColor(level)), originLabel, NSView(), Self.clock(field(entry, "time"))])
                return Self.card([top, Self.body(field(entry, "message"), monospaced: true)])
            }
            if entries.count > Self.rowLimit { views.append(Self.secondary("\(entries.count - Self.rowLimit) more not shown")) }
        case "network":
            let entries = ContextText.entries(context, "network")
            views = entries.prefix(Self.rowLimit).map { entry in
                let url = URLComponents(string: field(entry, "url"))
                let status = (entry["status"] as? NSNumber)?.intValue
                let statusText = status.map(String.init) ?? "Failed"
                let path = url.map { ($0.path.isEmpty ? "/" : $0.path) + ($0.query.map { "?" + $0 } ?? "") } ?? field(entry, "url")
                let title = Self.body(path, monospaced: true)
                title.maximumNumberOfLines = 2
                let top = Self.line([Self.badge(field(entry, "method").isEmpty ? "GET" : field(entry, "method"), color: .secondaryLabelColor), Self.badge(statusText, color: (status ?? 500) >= 500 ? .systemRed : .systemOrange), title, NSView(), Self.clock(field(entry, "time"))])
                var lines: [NSView] = [top]
                let host = [url?.host, field(entry, "error").isEmpty ? nil : field(entry, "error")].compactMap { $0 }.joined(separator: " · ")
                if !host.isEmpty { lines.append(Self.secondary(host)) }
                return Self.card(lines)
            }
            if entries.count > Self.rowLimit { views.append(Self.secondary("\(entries.count - Self.rowLimit) more not shown")) }
        case "events":
            let entries = ContextText.entries(context, "events")
            views = entries.suffix(Self.rowLimit).reversed().map { entry in
                let click = entry["kind"] as? String == "click"
                let role = (entry["role"] as? String).map { $0.hasPrefix("AX") ? String($0.dropFirst(2)).lowercased() : $0 } ?? "element"
                let text = click ? "Clicked \(role)" + ((entry["title"] as? String).map { " “\($0)”" } ?? "") : "Switched to \(field(entry, "app"))"
                let icon = NSImageView(image: NSImage(systemSymbolName: click ? "cursorarrow.click" : "arrow.left.arrow.right", accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = click ? .systemBlue : .secondaryLabelColor
                let label = Self.body(text, monospaced: false)
                label.maximumNumberOfLines = 2
                var parts: [NSView] = [icon, label, NSView()]
                if click { parts.append(Self.secondary(field(entry, "app"))) }
                parts.append(Self.clock(field(entry, "time")))
                return Self.card([Self.line(parts)])
            }
        case "customLogs":
            views = (context["customLogs"] as? [[String: Any]] ?? []).map { Self.textCard(title: field($0, "name"), text: field($0, "text"), monospaced: true) }
        default:
            views = []
        }
        return views
    }

    static func devicePairs(_ context: [String: Any]) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let device = context["device"] as? [String: Any] ?? [:]
        let text = { (dictionary: [String: Any], key: String) in dictionary[key].map { "\($0)" } }
        if let os = text(device, "os") { pairs.append(("System", os + (text(device, "arch").map { " (\($0))" } ?? ""))) }
        if let model = text(device, "model") { pairs.append(("Model", model)) }
        if let cpu = text(device, "cpu") { pairs.append(("Processor", cpu)) }
        if let memory = (device["memoryBytes"] as? NSNumber)?.doubleValue, memory > 0 { pairs.append(("Memory", "\(Int((memory / 1_073_741_824).rounded())) GB")) }
        let displays = device["displays"] as? [[String: Any]] ?? []
        if !displays.isEmpty { pairs.append(("Displays", displays.map { "\(($0["width"] as? NSNumber)?.intValue ?? 0)×\(($0["height"] as? NSNumber)?.intValue ?? 0) @\(($0["scale"] as? NSNumber)?.stringValue ?? "1")x" }.joined(separator: ", "))) }
        if let locale = text(device, "locale") { pairs.append(("Locale", locale)) }
        if let app = context["app"] as? [String: Any], let name = text(app, "name") { pairs.append(("Captured app", name + (text(app, "version").map { " " + $0 } ?? ""))) }
        if let browser = context["browser"] as? [String: Any] { pairs.append(("Browser page", [text(browser, "title"), text(browser, "url")].compactMap { $0 }.joined(separator: "\n"))) }
        if let system = context["system"] as? [String: Any] {
            if let pressure = (system["memory"] as? [String: Any]).flatMap({ text($0, "pressure") }) { pairs.append(("Memory pressure", pressure)) }
            if let battery = system["battery"] as? [String: Any], let level = (battery["level"] as? NSNumber)?.doubleValue { pairs.append(("Battery", "\(Int(level.rounded()))%" + (battery["charging"] as? Bool == true ? ", charging" : ""))) }
            if let free = ((system["storage"] as? [String: Any])?["availableBytes"] as? NSNumber)?.doubleValue { pairs.append(("Storage", String(format: "%.0f GB free", free / 1_073_741_824))) }
            if let thermal = text(system, "thermal") { pairs.append(("Thermal state", thermal)) }
        }
        return pairs
    }

    static func clock(_ time: String) -> NSTextField {
        var text = time
        if let date = ReplayWriter.parseDate(time) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            text = formatter.string(from: date)
        }
        let label = secondary(text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    static func levelColor(_ level: String) -> NSColor {
        if ["error", "fault"].contains(level) { return .systemRed }
        if level.hasPrefix("warn") { return .systemOrange }
        return .secondaryLabelColor
    }

    static func badge(_ text: String, color: NSColor) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = CornerRadius.small
        box.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    static func secondary(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func body(_ text: String, monospaced: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 6
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func line(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    static func card(_ lines: [NSView]) -> NSView {
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = CornerRadius.control
        stack.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        for line in lines { line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true }
        return stack
    }

    static func textCard(title: String, text: String, monospaced: Bool) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let shown = text.count > textLimit ? String(text.prefix(textLimit)) + "\n… \(text.count - textLimit) more characters" : text
        let content = body(shown, monospaced: monospaced)
        content.maximumNumberOfLines = 0
        return card([heading, content])
    }

    static func keyValueCard(_ pairs: [(String, String)]) -> NSView {
        let grid = NSGridView(views: pairs.map { key, value in
            let name = secondary(key)
            name.alignment = .right
            let content = body(value, monospaced: false)
            return [name, content]
        })
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 110
        return card([grid])
    }

    static func emptyView(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        let stack = NSStackView(views: [label])
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 24, bottom: 24, right: 24)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        return stack
    }
}

// One source in the sidebar: icon, name, count (red when it has errors) and an include switch.
@MainActor final class ContextSourceRow: NSView {
    let source: String
    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let toggle = NSSwitch()
    var onSelect: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    private var selected = false

    init(source: String) {
        self.source = source
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CornerRadius.control
        let label = ContextText.labels[source] ?? source
        icon.image = NSImage(systemSymbolName: ComposerContextPicker.symbols[source] ?? "circle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        name.stringValue = label
        name.font = .systemFont(ofSize: 13)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.toolTip = "Send \(label.lowercased()) with this capture"
        toggle.setAccessibilityLabel("Include \(label.lowercased())")
        let row = NSStackView(views: [icon, name, count, NSView(), toggle])
        row.alignment = .centerY
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        setAccessibilityRole(.button)
        setAccessibilityLabel("Show \(label.lowercased())")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(count value: Int, errors: Int, included: Bool, selected: Bool) {
        self.selected = selected
        count.stringValue = value > 0 ? "\(value)" : ""
        count.textColor = errors > 0 ? .systemRed : .secondaryLabelColor
        toggle.state = included ? .on : .off
        name.textColor = included ? .labelColor : .tertiaryLabelColor
        icon.contentTintColor = selected ? .controlAccentColor : (included ? .secondaryLabelColor : .tertiaryLabelColor)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }

    @objc func clicked() { onSelect?() }
    @objc func toggled() { onToggle?(toggle.state == .on) }
}
