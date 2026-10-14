import Cocoa

final class ConfigWindow: NSObject {
    private var window: NSWindow?
    var windowNumber: Int? { window?.windowNumber }

    /// Dev aid: renders each tab's content to PNG files (path, path-1, path-2) without needing screen recording access.
    func snapshot(to path: String) {
        guard let w = window, let root = w.contentView, let tabs = root.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        for (i, item) in tabs.tabViewItems.enumerated() {
            tabs.selectTabViewItem(item)
            root.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
            root.cacheDisplay(in: root.bounds, to: rep)
            let url = URL(fileURLWithPath: i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png"))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        tabs.selectTabViewItem(at: 0)
    }
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
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        tabs.addTabViewItem(tab("General", page(generalBoxes())))
        tabs.addTabViewItem(tab("Apps", page(appBoxes())))
        tabs.addTabViewItem(tab("Hotkeys", hotkeysPage()))

        let path = NSTextField(labelWithString: Config.path.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        savedLabel = NSTextField(labelWithString: "Saved")
        savedLabel.textColor = .secondaryLabelColor
        savedLabel.isHidden = true
        let save = NSButton(title: "Save & Apply", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [path, NSView(), savedLabel, save])
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 0, right: 4)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 580))
        for v in [tabs, footer] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        let w = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "BetterWM Settings"
        w.contentView = root
        w.isReleasedWhenClosed = false
        return w
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        return item
    }

    private func page(_ boxes: [NSView]) -> NSView {
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func generalBoxes() -> [NSView] {
        let layout = box("Layout", rows: [
            sliderRow("Gap between windows", \.gap, 0...64),
            sliderRow("Gap around screen", \.outerGap, 0...64),
            sliderRow("Resize handle width", \.handleWidth, 4...32),
        ])

        autoTileCheck = NSButton(checkboxWithTitle: "Tile new windows automatically", target: nil, action: nil)
        strategyPopup = NSPopUpButton()
        for st in Config.AutoTileStrategy.allCases {
            strategyPopup.addItem(withTitle: st.title)
            strategyPopup.lastItem?.representedObject = st.rawValue
        }
        let mods = NSStackView()
        mods.spacing = 6
        for (key, label) in [("cmd", "⌘ Command"), ("alt", "⌥ Option"), ("ctrl", "⌃ Control"), ("shift", "⇧ Shift")] {
            let b = NSButton(title: label, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            modifierButtons[key] = b
            mods.addArrangedSubview(b)
        }
        let tiling = box("Tiling", rows: [
            [label("New windows"), autoTileCheck],
            [label("Placement"), strategyPopup],
            [label("Drag to tile with"), mods],
        ])
        return [layout, tiling]
    }

    private func appBoxes() -> [NSView] {
        ignoreText = NSTextView()
        ignoreText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        ignoreText.isRichText = false
        ignoreText.isAutomaticQuoteSubstitutionEnabled = false
        ignoreText.textContainerInset = NSSize(width: 6, height: 6)
        ignoreText.autoresizingMask = [.width]
        let ignoreScroll = NSScrollView()
        ignoreScroll.documentView = ignoreText
        ignoreScroll.hasVerticalScroller = true
        ignoreScroll.borderType = .bezelBorder
        ignoreScroll.translatesAutoresizingMaskIntoConstraints = false
        ignoreScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let addFront = NSButton(title: "Add Previous App", target: self, action: #selector(addFrontmostApp))
        let hint = NSTextField(wrappingLabelWithString: "Bundle identifiers, one per line. Listed apps are never tiled automatically; ⌥-drag still works.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(views: [hint, NSView(), addFront])
        toolbar.alignment = .top

        floatSmallCheck = NSButton(checkboxWithTitle: "Keep windows floating when smaller than", target: nil, action: nil)
        smallW = NSTextField(string: "500")
        smallH = NSTextField(string: "400")
        for f in [smallW!, smallH!] { f.widthAnchor.constraint(equalToConstant: 56).isActive = true; f.alignment = .right }
        let sizeRow = NSStackView(views: [floatSmallCheck, smallW, NSTextField(labelWithString: "×"), smallH, NSTextField(labelWithString: "pt")])
        sizeRow.spacing = 6
        sizeRow.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let separator = NSBox()
        separator.boxType = .separator

        let list = NSStackView(views: [ignoreScroll, toolbar, separator, sizeRow])
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        for v in [ignoreScroll, toolbar, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        return [box("Auto-tile Exclusions", rows: [[list]], twoColumn: false)]
    }

    private func hotkeysPage() -> NSView {
        var rows: [[NSView]] = []
        for a in Config.actions {
            let r = KeyRecorderView()
            recorders[a.key] = r
            rows.append([label(a.title), r])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 14
        grid.rowAlignment = .none
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 220
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }

        let hint = NSTextField(wrappingLabelWithString: "Click a field and press a key combination. Delete or Escape clears it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [hint, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return scroll
    }

    private func box(_ title: String, rows: [[NSView]], twoColumn: Bool = true) -> NSBox {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        if twoColumn {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 150
        }
        let b = NSBox()
        b.title = title
        b.titleFont = .boldSystemFont(ofSize: 12)
        b.contentViewMargins = NSSize(width: 14, height: 12)
        b.contentView = grid
        return b
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func sliderRow(_ title: String, _ kp: WritableKeyPath<Config, CGFloat>, _ range: ClosedRange<CGFloat>) -> [NSView] {
        let slider = NSSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.allowsTickMarkValuesOnly = false
        slider.widthAnchor.constraint(equalToConstant: 280).isActive = true
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
