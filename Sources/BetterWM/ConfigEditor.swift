import Cocoa

final class ConfigWindow: NSObject {
    private var window: NSWindow?
    var windowNumber: Int? { window?.windowNumber }
    private var config = Config()
    private var onSave: ((Config) -> Void)?
    private var recorders: [String: KeyRecorderView] = [:]
    private var modifierButtons: [String: NSButton] = [:]
    private var strategyPopup: NSPopUpButton!
    private var autoTileCheck: NSButton!
    private var sliders: [(KeyPath<Config, CGFloat>, WritableKeyPath<Config, CGFloat>, NSSlider, NSTextField)] = []
    private var savedLabel: NSTextField!
    private var ignoreText: NSTextView!
    private var floatSmallCheck: NSButton!
    private var smallW: NSTextField!
    private var smallH: NSTextField!

    func show(config: Config, onSave: @escaping (Config) -> Void) {
        self.config = config
        self.onSave = onSave
        if window == nil { window = build() }
        populate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() -> NSWindow {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        content.addArrangedSubview(section("Layout", grid: [
            sliderRow("Gap between windows", \.gap, 0...64),
            sliderRow("Gap around screen", \.outerGap, 0...64),
            sliderRow("Resize handle width", \.handleWidth, 4...32),
        ]))

        autoTileCheck = NSButton(checkboxWithTitle: "Auto-tile new windows", target: nil, action: nil)
        strategyPopup = NSPopUpButton()
        for st in Config.AutoTileStrategy.allCases {
            strategyPopup.addItem(withTitle: st.title)
            strategyPopup.lastItem?.representedObject = st.rawValue
        }
        let mods = NSStackView()
        for (key, label) in [("cmd", "⌘ Command"), ("alt", "⌥ Option"), ("ctrl", "⌃ Control"), ("shift", "⇧ Shift")] {
            let b = NSButton(title: label, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            modifierButtons[key] = b
            mods.addArrangedSubview(b)
        }
        content.addArrangedSubview(section("Tiling", grid: [
            [autoTileCheck, NSView()],
            [label("Placement"), strategyPopup],
            [label("Drag to tile with"), mods],
        ]))

        ignoreText = NSTextView()
        ignoreText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ignoreText.isRichText = false
        ignoreText.isAutomaticQuoteSubstitutionEnabled = false
        ignoreText.textContainerInset = NSSize(width: 4, height: 6)
        let ignoreScroll = NSScrollView()
        ignoreScroll.documentView = ignoreText
        ignoreScroll.hasVerticalScroller = true
        ignoreScroll.borderType = .bezelBorder
        ignoreScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        ignoreScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        ignoreText.autoresizingMask = [.width]
        let addFront = NSButton(title: "Add Frontmost App", target: self, action: #selector(addFrontmostApp))
        let ignoreHint = NSTextField(wrappingLabelWithString: "Bundle identifiers, one per line. These apps are never tiled automatically; ⌥-drag still works.")
        ignoreHint.font = .systemFont(ofSize: 11)
        ignoreHint.textColor = .secondaryLabelColor
        floatSmallCheck = NSButton(checkboxWithTitle: "Keep windows floating when smaller than", target: nil, action: nil)
        smallW = NSTextField(string: "500")
        smallH = NSTextField(string: "400")
        for f in [smallW!, smallH!] { f.widthAnchor.constraint(equalToConstant: 56).isActive = true; f.alignment = .right }
        let sizeRow = NSStackView(views: [floatSmallCheck, smallW, NSTextField(labelWithString: "×"), smallH, NSTextField(labelWithString: "pt")])
        content.addArrangedSubview(section("Ignored Apps", grid: [
            [label("Never auto-tile"), NSStackView(views: [ignoreScroll])],
            [NSView(), NSStackView(views: [addFront])],
            [NSView(), ignoreHint],
            [NSView(), sizeRow],
        ]))

        var hotkeyRows: [[NSView]] = []
        for a in Config.actions {
            let r = KeyRecorderView()
            recorders[a.key] = r
            hotkeyRows.append([label(a.title), r])
        }
        let hint = NSTextField(wrappingLabelWithString: "Click a field and press a combination. Delete or Escape clears it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hotkeyRows.append([hint, NSView()])
        content.addArrangedSubview(section("Hotkeys", grid: hotkeyRows))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true

        let path = NSTextField(labelWithString: Config.path.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        savedLabel = NSTextField(labelWithString: "Saved")
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.isHidden = true
        let save = NSButton(title: "Save & Apply", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [path, NSView(), savedLabel, save])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)
        path.setContentHuggingPriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [scroll, footer])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        root.distribution = .fill
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "BetterWM Settings"
        w.contentView = root
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 400)
        return w
    }

    private func section(_ title: String, grid rows: [[NSView]]) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: 13)
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 180
        grid.rowAlignment = .firstBaseline
        let box = NSStackView(views: [header, grid])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 10
        return box
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func sliderRow(_ title: String, _ kp: WritableKeyPath<Config, CGFloat>, _ range: ClosedRange<CGFloat>) -> [NSView] {
        let slider = NSSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.allowsTickMarkValuesOnly = false
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let value = NSTextField(labelWithString: "0 pt")
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        sliders.append((kp, kp, slider, value))
        return [label(title), NSStackView(views: [slider, value])]
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let row = sliders.first(where: { $0.2 === s }) else { return }
        row.3.stringValue = "\(Int(s.doubleValue.rounded())) pt"
    }

    private func populate() {
        for (kp, _, slider, value) in sliders {
            slider.doubleValue = Double(config[keyPath: kp])
            value.stringValue = "\(Int(config[keyPath: kp])) pt"
        }
        autoTileCheck.state = config.autoTile ? .on : .off
        strategyPopup.selectItem(at: Config.AutoTileStrategy.allCases.firstIndex(of: config.autoTileStrategy) ?? 0)
        let mods = config.dragModifiers.lowercased().split(separator: "+").map(String.init)
        for (k, b) in modifierButtons { b.state = mods.contains(k) ? .on : .off }
        for (k, r) in recorders { r.spec = config.hotkeys[k] }
        ignoreText.string = config.ignoreApps.joined(separator: "\n")
        floatSmallCheck.state = config.floatSmallWindows ? .on : .off
        smallW.stringValue = String(Int(config.smallWindowWidth))
        smallH.stringValue = String(Int(config.smallWindowHeight))
    }

    @objc private func addFrontmostApp() {
        // Our own settings window is frontmost now; take the app that was active before it.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        guard let id = (apps.first(where: \.isActive) ?? apps.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }))?.bundleIdentifier else { return }
        var ids = ignoreText.string.split(whereSeparator: \.isNewline).map(String.init)
        if !ids.contains(id) { ids.append(id) }
        ignoreText.string = ids.joined(separator: "\n")
    }

    @objc private func save() {
        for (_, kp, slider, _) in sliders { config[keyPath: kp] = CGFloat(slider.doubleValue.rounded()) }
        config.autoTile = autoTileCheck.state == .on
        if let raw = strategyPopup.selectedItem?.representedObject as? String, let st = Config.AutoTileStrategy(rawValue: raw) {
            config.autoTileStrategy = st
        }
        config.dragModifiers = ["cmd", "alt", "ctrl", "shift"].filter { modifierButtons[$0]?.state == .on }.joined(separator: "+")
        if config.dragModifiers.isEmpty { config.dragModifiers = "alt" }
        config.hotkeys = recorders.compactMapValues(\.spec)
        config.ignoreApps = ignoreText.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.floatSmallWindows = floatSmallCheck.state == .on
        config.smallWindowWidth = CGFloat(Double(smallW.stringValue) ?? 500)
        config.smallWindowHeight = CGFloat(Double(smallH.stringValue) ?? 400)
        config.save()
        onSave?(config)
        savedLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.savedLabel.isHidden = true }
    }
}

final class KeyRecorderView: NSView {
    var spec: String? { didSet { needsDisplay = true } }
    private var recording = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { recording = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 || e.keyCode == 51 {
            spec = nil
        } else if let s = HotKey.spec(from: e) {
            spec = s
        } else {
            return
        }
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
        let text = recording ? "Press keys…" : (spec.map(KeyRecorderView.pretty) ?? "None")
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: spec == nil && !recording ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: text, attributes: attrs).draw(in: bounds.insetBy(dx: 6, dy: 4))
    }

    static func pretty(_ spec: String) -> String {
        spec.split(separator: "+").map { part -> String in
            switch part {
            case "cmd": return "⌘"
            case "alt": return "⌥"
            case "ctrl": return "⌃"
            case "shift": return "⇧"
            case "space": return "Space"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            default: return part.uppercased()
            }
        }.joined()
    }
}
