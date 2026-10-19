import BetterWMCore
import Cocoa
import UniformTypeIdentifiers

/// Settings window laid out like System Settings: a sidebar of sections on the left, grouped rows on the right.
final class ConfigWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    var windowNumber: Int? { window?.windowNumber }

    private struct Section { let title: String; let symbol: String; let view: NSView }
    private var sections: [Section] = []
    private let sidebar = NSTableView()
    private let content = NSScrollView()

    func beginRecordingFirst() {
        guard let r = recorders[Config.actions[0].key], let i = sections.firstIndex(where: { $0.title == "Hotkeys" }) else { return }
        select(i)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(r)
    }
    var firstRecordedSpec: String? { recorders[Config.actions[0].key]?.spec }

    /// Dev aid: renders each section to PNG files (path, path-1, path-2…) without needing screen recording access.
    func snapshot(to path: String) {
        guard let w = window, let root = w.contentView else { return }
        for i in sections.indices {
            select(i)
            root.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { continue }
            root.cacheDisplay(in: root.bounds, to: rep)
            let url = URL(fileURLWithPath: i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png"))
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        select(0)
    }

    private var config = Config()
    private var onSave: ((Config) -> Void)?
    private var recorders: [String: KeyRecorderView] = [:]
    private var modifierButtons: [String: NSButton] = [:]
    private var strategyPopup: NSPopUpButton!
    private var autoTileSwitch: NSSwitch!
    private var tileOnStartSwitch: NSSwitch!
    private var restoreSwitch: NSSwitch!
    private var debugLogSwitch: NSSwitch!
    private var stackOffsetField: NSTextField!
    private var stackNarrowField: NSTextField!
    private var switcherThumbsSwitch: NSSwitch!
    private var switcherSwitch: NSSwitch!
    private var overlaySwitch: NSSwitch!
    private var sliders: [(KeyPath<Config, CGFloat>, WritableKeyPath<Config, CGFloat>, NSSlider, NSTextField)] = []
    private var savedLabel: NSTextField!
    private var ignoreText: NSTextView!
    private var floatSmallSwitch: NSSwitch!
    private var smallW: NSTextField!
    private var smallH: NSTextField!
    private var ringSwitch: NSSwitch!
    private var ringColor: NSColorWell!
    private var ringFloatingMode: NSPopUpButton!
    private var ringFloatingColor: NSColorWell!
    private var ringWidth: NSSlider!
    private var ringWidthLabel: NSTextField!
    private var ringRadius: NSSlider!
    private var ringRadiusLabel: NSTextField!
    private var ringAutoRadius: NSSwitch!
    private var ringFloating: NSSwitch!
    private var barSwitch: NSSwitch!
    private var barHeightField: NSTextField!
    private var barClockField: NSTextField!
    private var barTitleField: NSTextField!
    private var barDesktopAppsSwitch: NSSwitch!
    private var widgetOrder: [(Config.BarWidget, Bool)] = []
    private let widgetList = NSStackView()
    private var barBatteryPercentSwitch: NSSwitch!
    private var barCatSwitch: NSSwitch!
    private var barNotchPortalsSwitch: NSSwitch!
    private var barCatSheets: NSTextView!
    private var barFahrenheit: NSSwitch!
    private var barLocationPopup: NSPopUpButton!
    private var barLocationField: NSTextField!
    private var barBackgroundMode: NSPopUpButton!
    private var barBgColor: NSColorWell!
    private var barTextMode: NSPopUpButton!
    private var barTextColorWell: NSColorWell!
    private var barBorderColorWell: NSColorWell!
    private var barActiveMode: NSPopUpButton!
    private var barActiveColorWell: NSColorWell!
    private var barBorderWidthField: NSTextField!
    private var barRadiusField: NSTextField!
    private var barPaddingField: NSTextField!
    private var barMarginField: NSTextField!
    private var barTopOffsetField: NSTextField!

    func show(config: Config, onSave: @escaping (Config) -> Void) {
        self.config = config
        self.onSave = onSave
        if window == nil { window = build() }
        populate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Opening a settings window should not drop the cursor into the first text field.
        window?.makeFirstResponder(nil)
    }

    // MARK: Window chrome

    private func build() -> NSWindow {
        sections = [
            Section(title: "General", symbol: "gearshape", view: page("General", "Gaps, what happens on launch, logging.", generalGroups())),
            Section(title: "Tiling", symbol: "rectangle.split.3x1", view: page("Tiling", "How new windows are placed and how you tile by dragging.", tilingGroups())),
            Section(title: "Focus Ring", symbol: "scope", view: page("Focus Ring", "Outline drawn around the focused window.", ringGroups())),
            Section(title: "Status Bar", symbol: "menubar.rectangle", view: page("Status Bar", "The bar at the top of each screen, under the hidden system menu bar.", barGroups())),
            Section(title: "Widgets", symbol: "square.grid.2x2", view: page("Widgets", "What the right side of the bar shows, left to right.", widgetGroups())),
            Section(title: "Cats", symbol: "pawprint", view: page("Cats", "Pixel cats living in the free part of the bar.", catGroups())),
            Section(title: "Apps", symbol: "app.badge", view: page("Apps", "Windows that stay out of the tiling.", appGroups())),
            Section(title: "Hotkeys", symbol: "keyboard", view: page("Hotkeys", "Click a field and press a combination. Delete clears it, Escape keeps the current one. System shortcuts such as ⌃← (Mission Control) must be disabled in System Settings › Keyboard before they can be bound here.", hotkeyGroups())),
        ]

        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.selectionHighlightStyle = .sourceList
        sidebar.rowHeight = 28
        sidebar.intercellSpacing = NSSize(width: 0, height: 2)
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section")))
        sidebar.dataSource = self
        sidebar.delegate = self
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.drawsBackground = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.widthAnchor.constraint(equalToConstant: 190).isActive = true

        content.hasVerticalScroller = true
        content.drawsBackground = false
        content.translatesAutoresizingMaskIntoConstraints = false

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
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importConfig))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportConfig))
        let footer = NSStackView(views: [path, NSView(), importButton, exportButton, savedLabel, save])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerLine = NSBox(); footerLine.boxType = .separator; footerLine.translatesAutoresizingMaskIntoConstraints = false
        let sideLine = NSBox(); sideLine.boxType = .separator; sideLine.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        for v in [sidebarScroll, sideLine, content, footerLine, footer] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            sidebarScroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            sidebarScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            sideLine.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor),
            sideLine.topAnchor.constraint(equalTo: root.topAnchor),
            sideLine.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            sideLine.widthAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: sideLine.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footerLine.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerLine.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        let w = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "BetterWM Settings"
        w.contentView = root
        w.minSize = NSSize(width: 760, height: 520)
        w.isReleasedWhenClosed = false
        // Otherwise reopening pulls the user back to whichever desktop the window was last shown on.
        w.collectionBehavior = [.moveToActiveSpace]
        sidebar.reloadData()
        select(0)
        return w
    }

    /// Dev aid: open a section by index (`--settings-section N`).
    func selectSection(_ index: Int) { select(index) }

    private func select(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        if sidebar.selectedRow != index { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        let view = sections[index].view
        // A flipped document keeps short pages pinned to the top instead of sitting at the bottom of the scroll view.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(view)
        content.documentView = doc
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: content.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: content.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: content.contentView.widthAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: content.contentView.heightAnchor),
            view.topAnchor.constraint(equalTo: doc.topAnchor),
            view.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            view.widthAnchor.constraint(equalTo: doc.widthAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])
        content.contentView.scroll(to: .zero)
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: sections[row].symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let text = NSTextField(labelWithString: sections[row].title)
        text.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.imageView = icon
        cell.textField = text
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 20),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if sidebar.selectedRow >= 0 { select(sidebar.selectedRow) }
    }

    // MARK: Building blocks

    /// A section page: large title, one-line description, then the groups.
    private func page(_ title: String, _ subtitle: String, _ groups: [NSView]) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 22, weight: .bold)
        let s = NSTextField(wrappingLabelWithString: subtitle)
        s.font = .systemFont(ofSize: 12)
        s.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [t, s] + groups)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(4, after: t)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
        for g in groups { g.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true }
        s.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        return stack
    }

    /// Rounded container holding rows separated by hairlines, the way System Settings groups look.
    private func group(_ title: String? = nil, _ rows: [NSView]) -> NSView {
        let box = GroupBox()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .width
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox(); line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14), line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
                    line.topAnchor.constraint(equalTo: wrap.topAnchor), line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor), wrap.heightAnchor.constraint(equalToConstant: 1),
                ])
                inner.addArrangedSubview(wrap)
            }
            inner.addArrangedSubview(r)
        }
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor), inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor), inner.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        guard let title else { return box }
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [header, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// One setting: title and optional explanation on the left, control(s) on the right.
    private func row(_ title: String, _ subtitle: String? = nil, _ controls: [NSView]) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        var labels: [NSView] = [t]
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(s)
        }
        let left = NSStackView(views: labels)
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let right = NSStackView(views: controls)
        right.spacing = 8
        right.alignment = .centerY
        right.setHuggingPriority(.required, for: .horizontal)
        // Explicit constraints: the label block starts at the left edge, the controls end at the right edge,
        // whatever either side's natural width is.
        let h = NSView()
        for v in [left, right] { v.translatesAutoresizingMaskIntoConstraints = false; h.addSubview(v) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: h.leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: h.centerYAnchor),
            left.topAnchor.constraint(greaterThanOrEqualTo: h.topAnchor, constant: 10),
            left.bottomAnchor.constraint(lessThanOrEqualTo: h.bottomAnchor, constant: -10),
            right.trailingAnchor.constraint(equalTo: h.trailingAnchor, constant: -14),
            right.centerYAnchor.constraint(equalTo: h.centerYAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: h.topAnchor, constant: 8),
            right.bottomAnchor.constraint(lessThanOrEqualTo: h.bottomAnchor, constant: -8),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -16),
            h.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        // Prefer the compact height; without this the stack hands any slack to the first row.
        let compact = h.heightAnchor.constraint(equalToConstant: 44)
        compact.priority = .defaultLow
        compact.isActive = true
        return h
    }

    /// A row whose control spans the full width underneath the title (text views, lists).
    private func tallRow(_ title: String, _ subtitle: String? = nil, _ body: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        var views: [NSView] = [t]
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            views.append(s)
        }
        views.append(body)
        let v = NSStackView(views: views)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 8
        v.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28).isActive = true
        if let s = views.dropFirst().first as? NSTextField, s !== body as? NSTextField { s.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28).isActive = true }
        return v
    }

    /// A two-item choice where one option means "let the system decide" and the other enables a colour well.
    private func choice(_ titles: [String], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.target = self
        p.action = action
        return p
    }

    private func toggle(_ action: Selector? = nil) -> NSSwitch {
        let s = NSSwitch()
        s.controlSize = .small
        if let action { s.target = self; s.action = action }
        return s
    }

    private func numberField(_ initial: String, width: CGFloat = 60) -> NSTextField {
        let f = NSTextField(string: initial)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.alignment = .right
        return f
    }

    private func unit(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func well() -> NSColorWell {
        let w = NSColorWell()
        if #available(macOS 13, *) { w.colorWellStyle = .minimal }
        w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        w.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return w
    }

    private func sliderRow(_ title: String, _ subtitle: String?, _ kp: WritableKeyPath<Config, CGFloat>, _ range: ClosedRange<CGFloat>) -> NSView {
        let slider = NSSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: #selector(sliderChanged(_:)))
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let value = NSTextField(labelWithString: "0 pt")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sliders.append((kp, kp, slider, value))
        return row(title, subtitle, [slider, value])
    }

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let r = sliders.first(where: { $0.2 === s }) else { return }
        r.3.stringValue = "\(Int(s.doubleValue.rounded())) pt"
    }

    // MARK: Sections

    private func generalGroups() -> [NSView] {
        tileOnStartSwitch = toggle()
        restoreSwitch = toggle()
        debugLogSwitch = toggle()
        switcherSwitch = toggle(#selector(switcherChanged))
        switcherThumbsSwitch = toggle()
        overlaySwitch = toggle()
        return [
            group("Layout", [
                sliderRow("Gap between windows", nil, \.gap, 0...64),
                sliderRow("Gap around the screen", nil, \.outerGap, 0...64),
                sliderRow("Resize handle width", "The draggable bar in each gap.", \.handleWidth, 4...32),
            ]),
            group("Launch", [
                row("Tile existing windows", "When a desktop is seen for the first time, arrange the windows already on it.", [tileOnStartSwitch]),
                row("Remember layouts", "Save each desktop's grid and floating windows, and restore them on launch.", [restoreSwitch]),
            ]),
            group("Switcher", [
                row("⌥Tab window switcher", "Windows grouped by desktop; the hotkey is on the Hotkeys page.", [switcherSwitch]),
                row("Show window previews", "Needs Screen Recording permission; otherwise app icons are shown.", [switcherThumbsSwitch]),
            ]),
            group("Diagnostics", [
                row("Show pressed hotkey on screen", "Flashes the key combination and action at the bottom of the screen; handy for demos.", [overlaySwitch]),
                row("Write an action log", "log.txt next to the config file; Copy Diagnostics Report bundles it.", [debugLogSwitch]),
            ]),
        ]
    }

    private func tilingGroups() -> [NSView] {
        autoTileSwitch = toggle()
        strategyPopup = NSPopUpButton()
        for st in Config.AutoTileStrategy.allCases {
            strategyPopup.addItem(withTitle: st.title)
            strategyPopup.lastItem?.representedObject = st.rawValue
        }
        let mods = NSStackView()
        mods.spacing = 4
        for (key, label) in [("cmd", "⌘"), ("alt", "⌥"), ("ctrl", "⌃"), ("shift", "⇧")] {
            let b = NSButton(title: label, target: nil, action: nil)
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .rounded
            b.widthAnchor.constraint(equalToConstant: 40).isActive = true
            modifierButtons[key] = b
            mods.addArrangedSubview(b)
        }
        stackOffsetField = numberField("48")
        stackNarrowField = numberField("0")
        return [
            group("New windows", [
                row("Tile new windows automatically", "Off, new windows float until you tile them.", [autoTileSwitch]),
                row("Where a new window goes", nil, [strategyPopup]),
            ]),
            group("Drag to tile", [
                row("Hold while dragging", "Drag a window with these keys held to drop it into a column.", [mods]),
            ]),
            group("Stacked layout", [
                row("Cascade offset", "Windows cascade by this much so the ones behind stay visible. Toggle the layout per screen from the menu or with its hotkey.", [stackOffsetField, unit("pt")]),
                row("Start stacked on narrow screens", "Screens narrower than this begin in stacked layout; 0 never.", [stackNarrowField, unit("pt")]),
            ]),
        ]
    }

    private func ringGroups() -> [NSView] {
        ringSwitch = toggle()
        ringFloating = toggle()
        ringColor = well()
        ringFloatingMode = choice(["Same as tiled", "Custom colour"], #selector(floatingColorModeChanged))
        ringFloatingColor = well()
        ringWidth = NSSlider(value: 3, minValue: 1, maxValue: 12, target: self, action: #selector(ringSliderChanged(_:)))
        ringWidth.widthAnchor.constraint(equalToConstant: 220).isActive = true
        ringWidthLabel = NSTextField(labelWithString: "3 pt")
        ringRadius = NSSlider(value: 10, minValue: 0, maxValue: 30, target: self, action: #selector(ringSliderChanged(_:)))
        ringRadius.widthAnchor.constraint(equalToConstant: 220).isActive = true
        ringRadiusLabel = NSTextField(labelWithString: "10 pt")
        for l in [ringWidthLabel!, ringRadiusLabel!] {
            l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        ringAutoRadius = toggle(#selector(autoRadiusChanged))
        return [
            group(nil, [
                row("Highlight the focused window", nil, [ringSwitch]),
                row("Also highlight floating windows", "Untiled windows get the ring too.", [ringFloating]),
            ]),
            group("Colour", [
                row("Tiled windows", nil, [ringColor]),
                row("Floating windows", "Untiled windows can get their own ring colour.", [ringFloatingMode, ringFloatingColor]),
            ]),
            group("Shape", [
                row("Thickness", nil, [ringWidth, ringWidthLabel]),
                row("Match each window's corners", "Measures the window's own corner radius.", [ringAutoRadius]),
                row("Fallback corner radius", "Used when a window's corners cannot be measured.", [ringRadius, ringRadiusLabel]),
            ]),
        ]
    }

    private func barGroups() -> [NSView] {
        barSwitch = toggle()
        barHeightField = numberField("28")
        barTitleField = NSTextField(string: "")
        barTitleField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        barClockField = NSTextField(string: "")
        barClockField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        barDesktopAppsSwitch = toggle()
        barBatteryPercentSwitch = toggle()
        barBackgroundMode = choice(["Blur", "Colour"], #selector(barAppearanceChanged))
        barBgColor = well()
        barTextMode = choice(["System", "Custom colour"], #selector(barAppearanceChanged))
        barTextColorWell = well()
        barBorderColorWell = well()
        barActiveMode = choice(["System accent", "Custom colour"], #selector(barAppearanceChanged))
        barActiveColorWell = well()
        barBorderWidthField = numberField("0")
        barRadiusField = numberField("0")
        barPaddingField = numberField("12")
        barMarginField = numberField("0")
        barTopOffsetField = numberField("0")
        barFahrenheit = toggle()
        barLocationPopup = NSPopUpButton()
        barLocationPopup.addItems(withTitles: ["Use Location Services", "Fixed coordinates"])
        barLocationPopup.target = self
        barLocationPopup.action = #selector(locationModeChanged)
        barLocationField = NSTextField(string: "")
        barLocationField.placeholderString = "52.52, 13.40"
        barLocationField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        return [
            group(nil, [
                row("Show the status bar", "Set \"Automatically hide and show the menu bar\" to Always in System Settings › Control Center so the system bar does not overlap it. Tiled windows start below the bar.", [barSwitch]),
                row("Height", nil, [barHeightField, unit("pt")]),
            ]),
            group("Content", [
                row("App icons on desktop chips", "One icon per window open on that desktop.", [barDesktopAppsSwitch]),
                row("Active window label", "{app} and {title} are replaced; the rest is shown as is.", [barTitleField]),
                row("Clock format", "Unicode date pattern, for example EEE d MMM  HH:mm.", [barClockField]),
                row("Battery percentage", "Show the number next to the battery icon.", [barBatteryPercentSwitch]),
            ]),
            group("Appearance", [
                row("Background", "A translucent blur, or a solid colour.", [barBackgroundMode, barBgColor]),
                row("Text colour", nil, [barTextMode, barTextColorWell]),
                row("Active desktop chip", nil, [barActiveMode, barActiveColorWell]),
                row("Border", nil, [barBorderColorWell, barBorderWidthField, unit("pt")]),
                row("Corner radius", nil, [barRadiusField, unit("pt")]),
                row("Padding", "Space between the bar's edges and its content.", [barPaddingField, unit("pt")]),
                row("Side margin", "Above zero the bar floats away from the screen sides.", [barMarginField, unit("pt")]),
                row("Top offset", "Distance from the top edge; 0 sits where the hidden menu bar lives.", [barTopOffsetField, unit("pt")]),
            ]),
            group("Weather", [
                row("Fahrenheit", nil, [barFahrenheit]),
                row("Location", "Weather comes from Open-Meteo.", [barLocationPopup, barLocationField]),
            ]),
        ]
    }

    private func widgetGroups() -> [NSView] {
        widgetList.orientation = .vertical
        widgetList.alignment = .width
        widgetList.spacing = 0
        let box = GroupBox()
        widgetList.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(widgetList)
        NSLayoutConstraint.activate([
            widgetList.topAnchor.constraint(equalTo: box.topAnchor), widgetList.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            widgetList.leadingAnchor.constraint(equalTo: box.leadingAnchor), widgetList.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return [box]
    }

    private func rebuildWidgetRows() {
        widgetList.arrangedSubviews.forEach { widgetList.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, (w, on)) in widgetOrder.enumerated() {
            if i > 0 {
                let line = NSBox(); line.boxType = .separator
                line.translatesAutoresizingMaskIntoConstraints = false
                let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14), line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
                    line.topAnchor.constraint(equalTo: wrap.topAnchor), line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor), wrap.heightAnchor.constraint(equalToConstant: 1),
                ])
                widgetList.addArrangedSubview(wrap)
            }
            let sw = NSSwitch()
            sw.controlSize = .small
            sw.state = on ? .on : .off
            sw.tag = i
            sw.target = self
            sw.action = #selector(widgetToggled(_:))
            let up = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")!, target: self, action: #selector(widgetMoved(_:)))
            let down = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")!, target: self, action: #selector(widgetMoved(_:)))
            up.tag = i * 2; down.tag = i * 2 + 1
            up.isEnabled = i > 0; down.isEnabled = i < widgetOrder.count - 1
            for b in [up, down] { b.bezelStyle = .texturedRounded; b.setButtonType(.momentaryPushIn) }
            widgetList.addArrangedSubview(row(w.title, nil, [up, down, sw]))
        }
    }

    @objc private func widgetToggled(_ sender: NSSwitch) {
        guard widgetOrder.indices.contains(sender.tag) else { return }
        widgetOrder[sender.tag].1 = sender.state == .on
    }

    @objc private func widgetMoved(_ sender: NSButton) {
        let i = sender.tag / 2, down = sender.tag % 2 == 1
        let j = down ? i + 1 : i - 1
        guard widgetOrder.indices.contains(i), widgetOrder.indices.contains(j) else { return }
        widgetOrder.swapAt(i, j)
        rebuildWidgetRows()
    }

    private func catGroups() -> [NSView] {
        barCatSwitch = toggle()
        barNotchPortalsSwitch = toggle()
        barCatSheets = NSTextView()
        barCatSheets.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        barCatSheets.isRichText = false
        barCatSheets.isAutomaticQuoteSubstitutionEnabled = false
        barCatSheets.textContainerInset = NSSize(width: 6, height: 4)
        barCatSheets.autoresizingMask = [.width]
        let sheetsScroll = NSScrollView()
        sheetsScroll.documentView = barCatSheets
        sheetsScroll.hasVerticalScroller = true
        sheetsScroll.borderType = .bezelBorder
        sheetsScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let addSheet = NSButton(title: "Add Sheet…", target: self, action: #selector(chooseCatSheet))
        let addBuiltin = NSButton(title: "Add Built-in Cat", target: self, action: #selector(addBuiltinCat))
        let sheetLink = NSButton(title: "Get the free pack on itch.io", target: self, action: #selector(openCatPack))
        sheetLink.bezelStyle = .inline
        sheetLink.font = .systemFont(ofSize: 11)
        sheetLink.contentTintColor = .linkColor
        let buttons = NSStackView(views: [addSheet, addBuiltin, NSView(), sheetLink])
        let sheetsBody = NSStackView(views: [sheetsScroll, buttons])
        sheetsBody.orientation = .vertical
        sheetsBody.alignment = .width
        sheetsBody.spacing = 8
        return [
            group(nil, [
                row("Show cats in the bar", "They wander the free space, run to your pointer, and can be petted with a click.", [barCatSwitch]),
                row("Cross the notch through portals", "Off, cats stay on the left of the notch.", [barNotchPortalsSwitch]),
            ]),
            group("Sprite sheets", [
                tallRow("One cat per line", "A sprite sheet in Last tick's \"Pixel Cats 64x64\" layout, or \"builtin\" for the hand-drawn cat. Two or more cats play together. Sheets are not bundled; download them yourself.", sheetsBody),
            ]),
        ]
    }

    private func appGroups() -> [NSView] {
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
        ignoreScroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let addFront = NSButton(title: "Add Previous App", target: self, action: #selector(addFrontmostApp))
        let buttons = NSStackView(views: [addFront, NSView()])
        let body = NSStackView(views: [ignoreScroll, buttons])
        body.orientation = .vertical
        body.alignment = .width
        body.spacing = 8
        floatSmallSwitch = toggle()
        smallW = numberField("500", width: 56)
        smallH = numberField("400", width: 56)
        return [
            group("Never tile these apps", [
                tallRow("Bundle identifiers, one per line", "Listed apps are never tiled automatically; dragging them into a column still works. Add Previous App inserts the app that was active before you opened Settings.", body),
            ]),
            group("Small windows", [
                row("Keep small windows floating", "Dialog-sized windows are left alone.", [floatSmallSwitch]),
                row("Smaller than", nil, [smallW, unit("×"), smallH, unit("pt")]),
            ]),
        ]
    }

    private func hotkeyGroups() -> [NSView] {
        var rows: [NSView] = []
        for a in Config.actions {
            let r = KeyRecorderView()
            recorders[a.key] = r
            rows.append(row(a.title, nil, [r]))
        }
        return [group(nil, rows)]
    }

    // MARK: Dependent controls

    @objc private func switcherChanged() { switcherThumbsSwitch.isEnabled = switcherSwitch.state == .on }
    @objc private func autoRadiusChanged() { ringRadius.isEnabled = ringAutoRadius.state == .off }
    @objc private func floatingColorModeChanged() { ringFloatingColor.isEnabled = ringFloatingMode.indexOfSelectedItem == 1 }
    @objc private func ringSliderChanged(_ s: NSSlider) {
        (s === ringWidth ? ringWidthLabel : ringRadiusLabel)?.stringValue = "\(Int(s.doubleValue.rounded())) pt"
    }
    @objc private func barAppearanceChanged() {
        barBgColor.isEnabled = barBackgroundMode.indexOfSelectedItem == 1
        barTextColorWell.isEnabled = barTextMode.indexOfSelectedItem == 1
        barActiveColorWell.isEnabled = barActiveMode.indexOfSelectedItem == 1
    }
    @objc private func locationModeChanged() { barLocationField.isEnabled = barLocationPopup.indexOfSelectedItem == 1 }

    @objc private func chooseCatSheet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose sprite sheet PNGs from the Pixel Cats 64x64 pack"
        guard panel.runModal() == .OK else { return }
        appendCatEntries(panel.urls.map(\.path))
    }

    @objc private func addBuiltinCat() { appendCatEntries(["builtin"]) }

    private func appendCatEntries(_ entries: [String]) {
        var lines = barCatSheets.string.split(whereSeparator: \.isNewline).map(String.init)
        lines.append(contentsOf: entries)
        barCatSheets.string = lines.joined(separator: "\n")
    }

    @objc private func openCatPack() {
        NSWorkspace.shared.open(URL(string: "https://last-tick.itch.io/animated-pixel-cats-64x64")!)
    }

    @objc private func addFrontmostApp() {
        // Our own settings window is frontmost now; take the app that was active before it.
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        guard let id = (apps.first(where: \.isActive) ?? apps.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }))?.bundleIdentifier else { return }
        var ids = ignoreText.string.split(whereSeparator: \.isNewline).map(String.init)
        if !ids.contains(id) { ids.append(id) }
        ignoreText.string = ids.joined(separator: "\n")
    }

    // MARK: Model ↔ controls

    private func on(_ s: NSSwitch, _ value: Bool) { s.state = value ? .on : .off }
    private func isOn(_ s: NSSwitch) -> Bool { s.state == .on }

    private func populate() {
        for (kp, _, slider, value) in sliders {
            slider.doubleValue = Double(config[keyPath: kp])
            value.stringValue = "\(Int(config[keyPath: kp])) pt"
        }
        on(autoTileSwitch, config.autoTile)
        on(tileOnStartSwitch, config.tileExistingOnStart)
        on(restoreSwitch, config.restoreLayouts)
        on(debugLogSwitch, config.debugLog)
        stackOffsetField.stringValue = String(Int(config.stackOffset))
        stackNarrowField.stringValue = String(Int(config.stackScreensNarrowerThan))
        on(switcherThumbsSwitch, config.switcherThumbnails)
        on(switcherSwitch, config.switcher)
        switcherChanged()
        on(overlaySwitch, config.actionOverlay)
        strategyPopup.selectItem(at: Config.AutoTileStrategy.allCases.firstIndex(of: config.autoTileStrategy) ?? 0)
        let mods = config.dragModifiers.lowercased().split(separator: "+").map(String.init)
        for (k, b) in modifierButtons { b.state = mods.contains(k) ? .on : .off }
        for (k, r) in recorders { r.spec = config.hotkeys[k] }
        on(ringSwitch, config.focusRing)
        on(ringFloating, config.focusRingFloating)
        ringColor.color = NSColor(hex: config.focusRingColor) ?? .controlAccentColor
        let sameFloating = config.focusRingFloatingColor.lowercased() == "same"
        ringFloatingMode.selectItem(at: sameFloating ? 0 : 1)
        ringFloatingColor.color = sameFloating ? ringColor.color : (NSColor(hex: config.focusRingFloatingColor) ?? ringColor.color)
        floatingColorModeChanged()
        ringWidth.doubleValue = Double(config.focusRingWidth)
        ringRadius.doubleValue = Double(config.focusRingRadius)
        on(ringAutoRadius, config.focusRingAutoRadius)
        autoRadiusChanged()
        ringSliderChanged(ringWidth)
        ringSliderChanged(ringRadius)
        on(barSwitch, config.bar)
        barHeightField.stringValue = String(Int(config.barHeight))
        barClockField.stringValue = config.barClockFormat
        barTitleField.stringValue = config.barTitleFormat
        on(barDesktopAppsSwitch, config.barDesktopApps)
        on(barBatteryPercentSwitch, config.barBatteryPercent)
        on(barCatSwitch, config.barCat)
        on(barNotchPortalsSwitch, config.barNotchPortals)
        widgetOrder = config.barWidgets.map { ($0, true) } + Config.BarWidget.allCases.filter { !config.barWidgets.contains($0) }.map { ($0, false) }
        rebuildWidgetRows()
        barCatSheets.string = config.barCatSheets.joined(separator: "\n")
        on(barFahrenheit, config.barWeatherFahrenheit)
        let auto = config.barWeatherLocation.lowercased() == "auto"
        barLocationPopup.selectItem(at: auto ? 0 : 1)
        barLocationField.stringValue = auto ? "" : config.barWeatherLocation
        locationModeChanged()
        let blur = config.barBackground.lowercased() == "blur"
        barBackgroundMode.selectItem(at: blur ? 0 : 1)
        barBgColor.color = blur ? NSColor.windowBackgroundColor : (NSColor(hex: config.barBackground) ?? .windowBackgroundColor)
        let autoText = config.barTextColor.lowercased() == "auto"
        barTextMode.selectItem(at: autoText ? 0 : 1)
        barTextColorWell.color = autoText ? .labelColor : (NSColor(hex: config.barTextColor) ?? .labelColor)
        barBorderColorWell.color = NSColor(hex: config.barBorderColor) ?? .separatorColor
        let accent = config.barActiveColor.lowercased() == "accent"
        barActiveMode.selectItem(at: accent ? 0 : 1)
        barActiveColorWell.color = accent ? .controlAccentColor : (NSColor(hex: config.barActiveColor) ?? .controlAccentColor)
        barBorderWidthField.stringValue = String(Int(config.barBorderWidth))
        barRadiusField.stringValue = String(Int(config.barRadius))
        barPaddingField.stringValue = String(Int(config.barPadding))
        barMarginField.stringValue = String(Int(config.barMargin))
        barTopOffsetField.stringValue = String(Int(config.barTopOffset))
        barAppearanceChanged()
        ignoreText.string = config.ignoreApps.joined(separator: "\n")
        on(floatSmallSwitch, config.floatSmallWindows)
        smallW.stringValue = String(Int(config.smallWindowWidth))
        smallH.stringValue = String(Int(config.smallWindowHeight))
    }

    /// Reads every control back into a Config without touching disk.
    private func collect() -> Config {
        var config = self.config
        for (_, kp, slider, _) in sliders { config[keyPath: kp] = CGFloat(slider.doubleValue.rounded()) }
        config.autoTile = isOn(autoTileSwitch)
        config.tileExistingOnStart = isOn(tileOnStartSwitch)
        config.restoreLayouts = isOn(restoreSwitch)
        config.debugLog = isOn(debugLogSwitch)
        config.stackOffset = CGFloat(Double(stackOffsetField.stringValue) ?? 48)
        config.stackScreensNarrowerThan = CGFloat(Double(stackNarrowField.stringValue) ?? 0)
        config.switcherThumbnails = isOn(switcherThumbsSwitch)
        config.switcher = isOn(switcherSwitch)
        config.actionOverlay = isOn(overlaySwitch)
        if let raw = strategyPopup.selectedItem?.representedObject as? String, let st = Config.AutoTileStrategy(rawValue: raw) {
            config.autoTileStrategy = st
        }
        config.dragModifiers = ["cmd", "alt", "ctrl", "shift"].filter { modifierButtons[$0]?.state == .on }.joined(separator: "+")
        if config.dragModifiers.isEmpty { config.dragModifiers = "alt" }
        config.hotkeys = recorders.compactMapValues(\.spec)
        config.focusRing = isOn(ringSwitch)
        config.focusRingFloating = isOn(ringFloating)
        config.focusRingColor = ringColor.color.hexString
        config.focusRingFloatingColor = ringFloatingMode.indexOfSelectedItem == 0 ? "same" : ringFloatingColor.color.hexString
        config.focusRingWidth = CGFloat(ringWidth.doubleValue.rounded())
        config.focusRingRadius = CGFloat(ringRadius.doubleValue.rounded())
        config.focusRingAutoRadius = isOn(ringAutoRadius)
        config.bar = isOn(barSwitch)
        config.barHeight = CGFloat(Double(barHeightField.stringValue) ?? 28)
        config.barClockFormat = barClockField.stringValue.isEmpty ? "EEE d MMM  HH:mm" : barClockField.stringValue
        config.barTitleFormat = barTitleField.stringValue.isEmpty ? "{app}" : barTitleField.stringValue
        config.barDesktopApps = isOn(barDesktopAppsSwitch)
        config.barBatteryPercent = isOn(barBatteryPercentSwitch)
        config.barCat = isOn(barCatSwitch)
        config.barNotchPortals = isOn(barNotchPortalsSwitch)
        config.barWidgets = widgetOrder.filter(\.1).map(\.0)
        config.barCatSheets = barCatSheets.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.barWeatherFahrenheit = isOn(barFahrenheit)
        config.barWeatherLocation = barLocationPopup.indexOfSelectedItem == 0 ? "auto" : barLocationField.stringValue.trimmingCharacters(in: .whitespaces)
        config.barBackground = barBackgroundMode.indexOfSelectedItem == 0 ? "blur" : barBgColor.color.hexString
        config.barTextColor = barTextMode.indexOfSelectedItem == 0 ? "auto" : barTextColorWell.color.hexString
        config.barBorderColor = barBorderColorWell.color.hexString
        config.barActiveColor = barActiveMode.indexOfSelectedItem == 0 ? "accent" : barActiveColorWell.color.hexString
        config.barBorderWidth = CGFloat(Double(barBorderWidthField.stringValue) ?? 0)
        config.barRadius = CGFloat(Double(barRadiusField.stringValue) ?? 0)
        config.barPadding = CGFloat(Double(barPaddingField.stringValue) ?? 12)
        config.barMargin = CGFloat(Double(barMarginField.stringValue) ?? 0)
        config.barTopOffset = CGFloat(Double(barTopOffsetField.stringValue) ?? 0)
        config.ignoreApps = ignoreText.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.floatSmallWindows = isOn(floatSmallSwitch)
        config.smallWindowWidth = CGFloat(Double(smallW.stringValue) ?? 500)
        config.smallWindowHeight = CGFloat(Double(smallH.stringValue) ?? 400)
        return config
    }

    @objc private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "betterwm.conf"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Export the current settings (as shown, including unsaved edits)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? collect().serialized().write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import a BetterWM settings file; press Save & Apply afterwards to keep it"
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        config = Config.parse(text)
        populate()
    }

    @objc private func save() {
        config = collect()
        config.save()
        onSave?(config)
        savedLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.savedLabel.isHidden = true }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The rounded, slightly raised container System Settings uses for a group of rows; colours follow the appearance.
private final class GroupBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.7)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.08)).cgColor
        layer?.borderWidth = 1
    }
}

final class KeyRecorderView: NSView {
    /// The recorder currently waiting for keys; the global event tap feeds it so even system-reserved combos record.
    static weak var active: KeyRecorderView?

    var spec: String? { didSet { needsDisplay = true } }
    private var recording = false {
        didSet {
            needsDisplay = true
            if recording { KeyRecorderView.active = self } else if KeyRecorderView.active === self { KeyRecorderView.active = nil }
        }
    }

    /// Called from the event tap with a CGEvent key press. Returns true if consumed.
    func record(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard recording else { return false }
        switch keyCode {
        case 53: break                                   // Escape: keep the old binding
        case 51: spec = nil                               // Delete: unbind
        default:
            guard let s = HotKey.spec(keyCode: UInt32(keyCode), flags: flags) else { return false }
            spec = s
        }
        window?.makeFirstResponder(nil)
        return true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { recording = true; return true }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: break
        case 51: spec = nil
        default:
            guard let s = HotKey.spec(from: e) else { return }
            spec = s
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
