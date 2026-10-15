import BetterWMCore
import Cocoa

final class ConfigWindow: NSObject {
    private var window: NSWindow?
    var windowNumber: Int? { window?.windowNumber }

    func beginRecordingFirst() {
        guard let r = recorders[Config.actions[0].key], let root = window?.contentView,
              let tabs = root.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        tabs.selectTabViewItem(at: 2)
        root.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(r)
    }
    var firstRecordedSpec: String? { recorders[Config.actions[0].key]?.spec }

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
    private var tileOnStartCheck: NSButton!
    private var overlayCheck: NSButton!
    private var sliders: [(KeyPath<Config, CGFloat>, WritableKeyPath<Config, CGFloat>, NSSlider, NSTextField)] = []
    private var savedLabel: NSTextField!
    private var ignoreText: NSTextView!
    private var floatSmallCheck: NSButton!
    private var smallW: NSTextField!
    private var smallH: NSTextField!
    private var ringCheck: NSButton!
    private var ringStyle: NSPopUpButton!
    private var ringColor: NSColorWell!
    private var ringWidth: NSSlider!
    private var ringWidthLabel: NSTextField!
    private var ringRadius: NSSlider!
    private var ringRadiusLabel: NSTextField!
    private var ringAutoRadius: NSButton!
    private var ringFloating: NSButton!
    private var barCheck: NSButton!
    private var barHeightField: NSTextField!
    private var barClockField: NSTextField!
    private var barWeatherCheck: NSButton!
    private var barBatteryCheck: NSButton!
    private var barBatteryPercentCheck: NSButton!
    private var barWifiCheck: NSButton!
    private var barCatCheck: NSButton!
    private var barFahrenheit: NSButton!
    private var barLocationAuto: NSButton!
    private var barLocationFixed: NSButton!
    private var barLocationField: NSTextField!
    private var barBlur: NSButton!
    private var barBgColor: NSColorWell!
    private var barTextAuto: NSButton!
    private var barTextColorWell: NSColorWell!
    private var barBorderColorWell: NSColorWell!
    private var barActiveAccent: NSButton!
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
    }

    private func build() -> NSWindow {
        let tabs = NSTabView()
        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        tabs.addTabViewItem(tab("General", page(generalBoxes())))
        tabs.addTabViewItem(tab("Apps", page(appBoxes())))
        tabs.addTabViewItem(tab("Bar", page(barBoxes())))
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
        // Otherwise reopening pulls the user back to whichever desktop the window was last shown on.
        w.collectionBehavior = [.moveToActiveSpace]
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
        for b in boxes { b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
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
        tileOnStartCheck = NSButton(checkboxWithTitle: "Tile existing windows when a desktop is first seen", target: nil, action: nil)
        overlayCheck = NSButton(checkboxWithTitle: "Show pressed hotkey and action on screen (for demos)", target: nil, action: nil)
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
            [label("On launch"), tileOnStartCheck],
            [label("Placement"), strategyPopup],
            [label("Drag to tile with"), mods],
            [label("Action overlay"), overlayCheck],
        ])
        ringCheck = NSButton(checkboxWithTitle: "Highlight the focused window", target: nil, action: nil)
        ringFloating = NSButton(checkboxWithTitle: "Also highlight floating (untiled) windows", target: nil, action: nil)
        ringStyle = NSPopUpButton()
        for st in Config.FocusRingStyle.allCases {
            ringStyle.addItem(withTitle: st.title)
            ringStyle.lastItem?.representedObject = st.rawValue
        }
        ringColor = NSColorWell()
        ringColor.widthAnchor.constraint(equalToConstant: 60).isActive = true
        ringColor.heightAnchor.constraint(equalToConstant: 24).isActive = true
        ringWidth = NSSlider(value: 3, minValue: 1, maxValue: 12, target: self, action: #selector(ringSliderChanged(_:)))
        ringWidth.widthAnchor.constraint(equalToConstant: 200).isActive = true
        ringWidthLabel = NSTextField(labelWithString: "3 pt")
        ringWidthLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        ringWidthLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        ringRadius = NSSlider(value: 10, minValue: 0, maxValue: 30, target: self, action: #selector(ringSliderChanged(_:)))
        ringRadius.widthAnchor.constraint(equalToConstant: 200).isActive = true
        ringRadiusLabel = NSTextField(labelWithString: "10 pt")
        ringRadiusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        ringRadiusLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        ringAutoRadius = NSButton(checkboxWithTitle: "Match each window's own corners", target: self, action: #selector(autoRadiusChanged))
        let ring = box("Focus Ring", rows: [
            [label("Focused window"), ringCheck],
            [NSView(), ringFloating],
            [label("Style"), ringStyle],
            [label("Color"), ringColor],
            [label("Thickness"), NSStackView(views: [ringWidth, ringWidthLabel])],
            [label("Corners"), ringAutoRadius],
            [label("Fallback radius"), NSStackView(views: [ringRadius, ringRadiusLabel])],
        ])
        return [layout, tiling, ring]
    }

    @objc private func autoRadiusChanged() {
        ringRadius.isEnabled = ringAutoRadius.state == .off
    }

    @objc private func ringSliderChanged(_ s: NSSlider) {
        (s === ringWidth ? ringWidthLabel : ringRadiusLabel)?.stringValue = "\(Int(s.doubleValue.rounded())) pt"
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

    private func barBoxes() -> [NSView] {
        barCheck = NSButton(checkboxWithTitle: "Show status bar at the top of each screen", target: nil, action: nil)
        barHeightField = NSTextField(string: "28")
        barHeightField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        barHeightField.alignment = .right
        barClockField = NSTextField(string: "")
        barClockField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let clockHint = NSTextField(labelWithString: "Unicode date pattern, e.g. EEE d MMM  HH:mm")
        clockHint.font = .systemFont(ofSize: 11)
        clockHint.textColor = .secondaryLabelColor
        let hint = NSTextField(wrappingLabelWithString: "Set \"Automatically hide and show the menu bar\" to Always in System Settings › Control Center so the system bar doesn't overlap this one. Tiled windows start below the bar.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        barBatteryCheck = NSButton(checkboxWithTitle: "Battery", target: nil, action: nil)
        barBatteryPercentCheck = NSButton(checkboxWithTitle: "with percentage", target: nil, action: nil)
        barWifiCheck = NSButton(checkboxWithTitle: "Wi-Fi signal", target: nil, action: nil)
        barCatCheck = NSButton(checkboxWithTitle: "Pixel cat", target: nil, action: nil)
        let general = box("Status Bar", rows: [
            [label("Bar"), barCheck],
            [label("Show"), NSStackView(views: [barBatteryCheck, barBatteryPercentCheck, barWifiCheck, barCatCheck])],
            [label("Height"), NSStackView(views: [barHeightField, NSTextField(labelWithString: "pt")])],
            [label("Clock"), NSStackView(views: [barClockField, clockHint])],
            [NSView(), hint],
        ])

        barWeatherCheck = NSButton(checkboxWithTitle: "Show weather", target: nil, action: nil)
        barFahrenheit = NSButton(checkboxWithTitle: "Fahrenheit", target: nil, action: nil)
        barLocationAuto = NSButton(radioButtonWithTitle: "Use Location Services", target: self, action: #selector(locationModeChanged))
        barLocationFixed = NSButton(radioButtonWithTitle: "Fixed coordinates", target: self, action: #selector(locationModeChanged))
        barLocationField = NSTextField(string: "")
        barLocationField.placeholderString = "latitude, longitude"
        barLocationField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let weather = box("Weather (Open-Meteo)", rows: [
            [label("Weather"), NSStackView(views: [barWeatherCheck, barFahrenheit])],
            [label("Location"), barLocationAuto],
            [NSView(), NSStackView(views: [barLocationFixed, barLocationField])],
        ])
        func num(_ v: String) -> NSTextField {
            let f = NSTextField(string: v); f.widthAnchor.constraint(equalToConstant: 56).isActive = true; f.alignment = .right; return f
        }
        func well() -> NSColorWell {
            let w = NSColorWell(); w.widthAnchor.constraint(equalToConstant: 60).isActive = true; w.heightAnchor.constraint(equalToConstant: 24).isActive = true; return w
        }
        barBlur = NSButton(checkboxWithTitle: "Blurred background", target: self, action: #selector(barAppearanceChanged))
        barBgColor = well()
        barTextAuto = NSButton(checkboxWithTitle: "System text colour", target: self, action: #selector(barAppearanceChanged))
        barTextColorWell = well()
        barBorderColorWell = well()
        barActiveAccent = NSButton(checkboxWithTitle: "System accent colour", target: self, action: #selector(barAppearanceChanged))
        barActiveColorWell = well()
        barBorderWidthField = num("0")
        barRadiusField = num("0")
        barPaddingField = num("12")
        barMarginField = num("0")
        barTopOffsetField = num("0")
        let appearance = box("Bar Appearance", rows: [
            [label("Background"), NSStackView(views: [barBlur, barBgColor])],
            [label("Text"), NSStackView(views: [barTextAuto, barTextColorWell])],
            [label("Active desktop"), NSStackView(views: [barActiveAccent, barActiveColorWell])],
            [label("Border"), NSStackView(views: [barBorderColorWell, barBorderWidthField, NSTextField(labelWithString: "pt")])],
            [label("Corner radius"), NSStackView(views: [barRadiusField, NSTextField(labelWithString: "pt")])],
            [label("Padding"), NSStackView(views: [barPaddingField, NSTextField(labelWithString: "pt inside")])],
            [label("Side margin"), NSStackView(views: [barMarginField, NSTextField(labelWithString: "pt from the screen sides")])],
            [label("Top offset"), NSStackView(views: [barTopOffsetField, NSTextField(labelWithString: "pt from the top edge; 0 sticks to the top")])],
        ])
        return [general, appearance, weather]
    }

    @objc private func barAppearanceChanged() {
        barBgColor.isEnabled = barBlur.state == .off
        barTextColorWell.isEnabled = barTextAuto.state == .off
        barActiveColorWell.isEnabled = barActiveAccent.state == .off
    }

    @objc private func locationModeChanged() {
        barLocationField.isEnabled = barLocationFixed.state == .on
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

        let hint = NSTextField(wrappingLabelWithString: "Click a field and press a key combination. Delete or Escape clears it.\nSystem shortcuts such as ⌃← / ⌃→ (Mission Control) never reach apps; disable them in System Settings › Keyboard › Keyboard Shortcuts to bind them here.")
        hint.alignment = .center
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 480).isActive = true
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
        tileOnStartCheck.state = config.tileExistingOnStart ? .on : .off
        overlayCheck.state = config.actionOverlay ? .on : .off
        strategyPopup.selectItem(at: Config.AutoTileStrategy.allCases.firstIndex(of: config.autoTileStrategy) ?? 0)
        let mods = config.dragModifiers.lowercased().split(separator: "+").map(String.init)
        for (k, b) in modifierButtons { b.state = mods.contains(k) ? .on : .off }
        for (k, r) in recorders { r.spec = config.hotkeys[k] }
        ringCheck.state = config.focusRing ? .on : .off
        ringFloating.state = config.focusRingFloating ? .on : .off
        ringStyle.selectItem(at: Config.FocusRingStyle.allCases.firstIndex(of: config.focusRingStyle) ?? 0)
        ringColor.color = NSColor(hex: config.focusRingColor) ?? .controlAccentColor
        ringWidth.doubleValue = Double(config.focusRingWidth)
        ringRadius.doubleValue = Double(config.focusRingRadius)
        ringAutoRadius.state = config.focusRingAutoRadius ? .on : .off
        autoRadiusChanged()
        ringSliderChanged(ringWidth)
        ringSliderChanged(ringRadius)
        barCheck.state = config.bar ? .on : .off
        barHeightField.stringValue = String(Int(config.barHeight))
        barClockField.stringValue = config.barClockFormat
        barWeatherCheck.state = config.barWeather ? .on : .off
        barBatteryCheck.state = config.barBattery ? .on : .off
        barBatteryPercentCheck.state = config.barBatteryPercent ? .on : .off
        barWifiCheck.state = config.barWifi ? .on : .off
        barCatCheck.state = config.barCat ? .on : .off
        barFahrenheit.state = config.barWeatherFahrenheit ? .on : .off
        let auto = config.barWeatherLocation.lowercased() == "auto"
        barLocationAuto.state = auto ? .on : .off
        barLocationFixed.state = auto ? .off : .on
        barLocationField.stringValue = auto ? "" : config.barWeatherLocation
        locationModeChanged()
        let blur = config.barBackground.lowercased() == "blur"
        barBlur.state = blur ? .on : .off
        barBgColor.color = blur ? NSColor.windowBackgroundColor : (NSColor(hex: config.barBackground) ?? .windowBackgroundColor)
        let autoText = config.barTextColor.lowercased() == "auto"
        barTextAuto.state = autoText ? .on : .off
        barTextColorWell.color = autoText ? .labelColor : (NSColor(hex: config.barTextColor) ?? .labelColor)
        barBorderColorWell.color = NSColor(hex: config.barBorderColor) ?? .separatorColor
        let accent = config.barActiveColor.lowercased() == "accent"
        barActiveAccent.state = accent ? .on : .off
        barActiveColorWell.color = accent ? .controlAccentColor : (NSColor(hex: config.barActiveColor) ?? .controlAccentColor)
        barBorderWidthField.stringValue = String(Int(config.barBorderWidth))
        barRadiusField.stringValue = String(Int(config.barRadius))
        barPaddingField.stringValue = String(Int(config.barPadding))
        barMarginField.stringValue = String(Int(config.barMargin))
        barTopOffsetField.stringValue = String(Int(config.barTopOffset))
        barAppearanceChanged()
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
        config.tileExistingOnStart = tileOnStartCheck.state == .on
        config.actionOverlay = overlayCheck.state == .on
        if let raw = strategyPopup.selectedItem?.representedObject as? String, let st = Config.AutoTileStrategy(rawValue: raw) {
            config.autoTileStrategy = st
        }
        config.dragModifiers = ["cmd", "alt", "ctrl", "shift"].filter { modifierButtons[$0]?.state == .on }.joined(separator: "+")
        if config.dragModifiers.isEmpty { config.dragModifiers = "alt" }
        config.hotkeys = recorders.compactMapValues(\.spec)
        config.focusRing = ringCheck.state == .on
        config.focusRingFloating = ringFloating.state == .on
        if let raw = ringStyle.selectedItem?.representedObject as? String, let st = Config.FocusRingStyle(rawValue: raw) {
            config.focusRingStyle = st
        }
        config.focusRingColor = ringColor.color.hexString
        config.focusRingWidth = CGFloat(ringWidth.doubleValue.rounded())
        config.focusRingRadius = CGFloat(ringRadius.doubleValue.rounded())
        config.focusRingAutoRadius = ringAutoRadius.state == .on
        config.bar = barCheck.state == .on
        config.barHeight = CGFloat(Double(barHeightField.stringValue) ?? 28)
        config.barClockFormat = barClockField.stringValue.isEmpty ? "EEE d MMM  HH:mm" : barClockField.stringValue
        config.barWeather = barWeatherCheck.state == .on
        config.barBattery = barBatteryCheck.state == .on
        config.barBatteryPercent = barBatteryPercentCheck.state == .on
        config.barWifi = barWifiCheck.state == .on
        config.barCat = barCatCheck.state == .on
        config.barWeatherFahrenheit = barFahrenheit.state == .on
        config.barWeatherLocation = barLocationAuto.state == .on ? "auto" : barLocationField.stringValue.trimmingCharacters(in: .whitespaces)
        config.barBackground = barBlur.state == .on ? "blur" : barBgColor.color.hexString
        config.barTextColor = barTextAuto.state == .on ? "auto" : barTextColorWell.color.hexString
        config.barBorderColor = barBorderColorWell.color.hexString
        config.barActiveColor = barActiveAccent.state == .on ? "accent" : barActiveColorWell.color.hexString
        config.barBorderWidth = CGFloat(Double(barBorderWidthField.stringValue) ?? 0)
        config.barRadius = CGFloat(Double(barRadiusField.stringValue) ?? 0)
        config.barPadding = CGFloat(Double(barPaddingField.stringValue) ?? 12)
        config.barMargin = CGFloat(Double(barMarginField.stringValue) ?? 0)
        config.barTopOffset = CGFloat(Double(barTopOffsetField.stringValue) ?? 0)
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
        if keyCode == 53 || keyCode == 51 {
            spec = nil
        } else if let s = HotKey.spec(keyCode: UInt32(keyCode), flags: flags) {
            spec = s
        } else {
            return false
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
