import BetterWMCore
import Cocoa

/// Top-of-screen bar living where the auto-hidden system menu bar would be. One window per screen; on notched
/// displays the content is laid out in the two strips beside the notch.
final class StatusBar {
    private var windows: [BarWindow] = []
    private var config: Config
    private let weather: WeatherService
    private let events = WindowServerEvents()
    private var clock: Timer?
    var onSelectDesktop: ((Int) -> Void)?
    /// Called whenever the bar is shown or hidden so the layout can reserve space.
    var onLayoutChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        weather = WeatherService(config: config)
        weather.onUpdate = { [weak self] _ in self?.refresh() }
        events.onEvent = { [weak self] event, _ in
            switch event {
            case .frontChange, .spaceChange, .windowDestroy, .windowReorder: self?.refresh()
            default: break
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        clock = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        rebuild()
    }

    /// Distance from the screen's top edge to the bar's bottom edge; zero when the bar is off.
    func inset(for screen: NSScreen) -> CGFloat { config.bar ? config.barTopOffset + height(for: screen) : 0 }

    /// At offset zero with no side margin the bar shares the top edge with the notch.
    private func atScreenTop(_ screen: NSScreen) -> Bool { config.barTopOffset == 0 && config.barMargin == 0 }

    private func height(for screen: NSScreen) -> CGFloat {
        // Beside a notch the bar must be as tall as the notch, or the notch pokes below it.
        atScreenTop(screen) ? max(config.barHeight, screen.safeAreaInsets.top) : config.barHeight
    }

    func apply(_ config: Config) {
        self.config = config
        weather.apply(config)
        rebuild()
    }

    func focusChanged() { refresh() }

    /// Dev aid: renders the first bar window's content to a PNG.
    func snapshot(to path: String) {
        guard let v = windows.first?.view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        guard config.bar else { onLayoutChange?(); return }
        for screen in NSScreen.screens {
            let h = height(for: screen), m = config.barMargin
            let frame = NSRect(x: screen.frame.minX + m, y: screen.frame.maxY - config.barTopOffset - h, width: screen.frame.width - 2 * m, height: h)
            let w = BarWindow(frame: frame, screen: screen)
            w.view.apply(config, avoidNotch: atScreenTop(screen))
            w.view.onSelectDesktop = { [weak self] i in self?.onSelectDesktop?(i) }
            windows.append(w)
            w.orderBack(nil)
        }
        refresh()
        onLayoutChange?()
        maybeSuggestMenuBarAutoHide()
    }

    private func refresh() {
        guard config.bar else { return }
        let focused = AXWindow.focused
        let app = focused.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
            ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let title = focused?.title ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = config.barClockFormat
        let model = BarView.Model(
            desktops: Spaces.desktops().count,
            current: Spaces.currentDesktopIndex(),
            app: app,
            title: title,
            clock: formatter.string(from: Date()),
            weather: weather.reading.map { r in
                (String(format: "%.0f°", r.temperature), r.symbol)
            },
            battery: config.barBattery ? SystemStatus.battery() : nil,
            batteryPercent: config.barBatteryPercent,
            wifi: config.barWifi ? SystemStatus.wifiStrength() : nil,
            showWifi: config.barWifi,
            cpu: config.barCpu ? SystemStatus.cpuLoad() : nil,
            memory: config.barMemory ? SystemStatus.memoryUsed() : nil,
            disk: config.barDisk ? SystemStatus.diskFree() : nil
        )
        windows.forEach { $0.view.render(model) }
    }

    /// The bar only makes sense with the system menu bar hidden; offer the setting once.
    private func maybeSuggestMenuBarAutoHide() {
        let key = "barMenuBarHintShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        let hidden = (global["_HIHideMenuBar"] as? Int) == 1 || (global["_HIHideMenuBar"] as? Bool) == true
        guard !hidden else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Hide the system menu bar"
        alert.informativeText = "BetterWM's bar sits where the menu bar is. In System Settings › Control Center (or Menu Bar), set \"Automatically hide and show the menu bar\" to Always so the two don't overlap. The system bar still appears when you move the mouse to the top edge."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let urls = ["x-apple.systempreferences:com.apple.Menu-Bar-Settings.extension",
                        "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"]
            for u in urls.compactMap(URL.init(string:)) where NSWorkspace.shared.open(u) { break }
        }
    }
}

final class BarWindow: NSPanel {
    let view: BarView

    init(frame: NSRect, screen: NSScreen) {
        view = BarView(screen: screen)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Behind all app windows: tiled ones start below the bar anyway, floating ones may cover it.
        level = .normal
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    // Clicking a desktop chip must not pull the bar in front of the windows.
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event); orderBack(nil) }

    // AppKit pushes windows below the menu-bar level out of the menu bar area; the bar must be allowed to sit there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A non-key panel swallows the first click unless the control accepts it.
private final class ChipButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class BarView: NSView {
    struct Model {
        var desktops: Int
        var current: Int?
        var app: String
        var title: String
        var clock: String
        var weather: (String, String)?
        var battery: SystemStatus.Battery?
        var batteryPercent: Bool
        var wifi: Double?
        var showWifi: Bool
        var cpu: Double?
        var memory: Double?
        var disk: Int64?
    }

    var onSelectDesktop: ((Int) -> Void)?
    private let screen: NSScreen
    private let background = NSVisualEffectView()
    private let solid = NSView()
    private var avoidNotch = false
    private var textColor: NSColor = .labelColor
    private var activeColor: NSColor = .controlAccentColor
    private var padding: CGFloat = 12
    private let left = NSStackView()
    private let right = NSStackView()
    private let appLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let weatherIcon = NSImageView()
    private let weatherLabel = NSTextField(labelWithString: "")
    private let cpuIcon = NSImageView()
    private let cpuLabel = NSTextField(labelWithString: "")
    private let memIcon = NSImageView()
    private let memLabel = NSTextField(labelWithString: "")
    private let diskIcon = NSImageView()
    private let diskLabel = NSTextField(labelWithString: "")
    private let wifiIcon = NSImageView()
    private let batteryIcon = NSImageView()
    private let batteryLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let cat = BarCat(frame: .zero)
    private var chips: [NSButton] = []
    private var leftLeading: NSLayoutConstraint!
    private var leftTrailing: NSLayoutConstraint!
    private var rightTrailing: NSLayoutConstraint!
    private var rightLeading: NSLayoutConstraint!

    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: .zero)
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        solid.wantsLayer = true
        solid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(solid)
        wantsLayer = true
        layer?.masksToBounds = true

        for l in [appLabel, titleLabel, weatherLabel, cpuLabel, memLabel, diskLabel, batteryLabel, clockLabel] {
            l.font = .systemFont(ofSize: 12, weight: l === appLabel ? .semibold : .regular)
            l.textColor = .labelColor
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
        }
        titleLabel.textColor = .secondaryLabelColor
        clockLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for icon in [weatherIcon, cpuIcon, memIcon, diskIcon, wifiIcon, batteryIcon] {
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = .labelColor
            icon.widthAnchor.constraint(equalToConstant: icon === batteryIcon ? 22 : 16).isActive = true
        }
        cpuIcon.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        memIcon.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil)
        diskIcon.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil)
        for l in [cpuLabel, memLabel, diskLabel] { l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }

        left.orientation = .horizontal
        left.spacing = 10
        left.alignment = .centerY
        right.orientation = .horizontal
        right.spacing = 8
        right.alignment = .centerY
        right.addArrangedSubview(weatherIcon)
        right.addArrangedSubview(weatherLabel)
        for (icon, label) in [(cpuIcon, cpuLabel), (memIcon, memLabel), (diskIcon, diskLabel)] {
            right.addArrangedSubview(icon)
            right.addArrangedSubview(label)
            right.setCustomSpacing(3, after: icon)
            right.setCustomSpacing(12, after: label)
        }
        right.addArrangedSubview(wifiIcon)
        right.addArrangedSubview(batteryIcon)
        right.addArrangedSubview(batteryLabel)
        right.setCustomSpacing(4, after: batteryIcon)
        right.addArrangedSubview(clockLabel)
        right.setCustomSpacing(14, after: weatherLabel)
        right.setCustomSpacing(14, after: batteryLabel)
        for v in [left, right] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        cat.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cat)
        NSLayoutConstraint.activate([
            cat.topAnchor.constraint(equalTo: topAnchor), cat.bottomAnchor.constraint(equalTo: bottomAnchor),
            cat.leadingAnchor.constraint(equalTo: leadingAnchor), cat.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        leftLeading = left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        leftTrailing = left.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        rightTrailing = right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        rightLeading = right.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            solid.topAnchor.constraint(equalTo: topAnchor), solid.bottomAnchor.constraint(equalTo: bottomAnchor),
            solid.leadingAnchor.constraint(equalTo: leadingAnchor), solid.trailingAnchor.constraint(equalTo: trailingAnchor),
            left.centerYAnchor.constraint(equalTo: centerYAnchor), right.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftLeading, leftTrailing, rightTrailing, rightLeading,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ config: Config, avoidNotch: Bool) {
        self.avoidNotch = avoidNotch
        padding = config.barPadding
        leftLeading.constant = padding
        rightTrailing.constant = -padding
        textColor = config.barTextColor.lowercased() == "auto" ? .labelColor : (NSColor(hex: config.barTextColor) ?? .labelColor)
        activeColor = config.barActiveColor.lowercased() == "accent" ? .controlAccentColor : (NSColor(hex: config.barActiveColor) ?? .controlAccentColor)
        let blur = config.barBackground.lowercased() == "blur"
        background.isHidden = !blur
        solid.isHidden = blur
        solid.layer?.backgroundColor = blur ? nil : (NSColor(hex: config.barBackground) ?? .windowBackgroundColor).cgColor
        layer?.cornerRadius = config.barRadius
        layer?.borderWidth = config.barBorderWidth
        layer?.borderColor = (NSColor(hex: config.barBorderColor) ?? .separatorColor).cgColor
        for l in [appLabel, weatherLabel, cpuLabel, memLabel, diskLabel, batteryLabel, clockLabel] { l.textColor = textColor }
        titleLabel.textColor = textColor.withAlphaComponent(0.65)
        for icon in [weatherIcon, cpuIcon, memIcon, diskIcon, wifiIcon, batteryIcon] { icon.contentTintColor = textColor }
        cat.color = textColor
        cat.isHidden = !config.barCat
        cat.useSheet(path: config.barCatSheet, barHeight: config.barHeight)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep content out of the notch: the auxiliary areas are the usable strips either side of it.
        if avoidNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            leftTrailing.constant = -(bounds.width - (l.maxX - screen.frame.minX)) - 8
            rightLeading.constant = (r.minX - screen.frame.minX) + 8
        } else {
            leftTrailing.constant = -padding
            rightLeading.constant = padding
        }
        // The cat roams whatever is free between the left content and the right content (or the notch).
        let freeStart = left.frame.maxX + 16
        var freeEnd = right.frame.minX - 16
        if avoidNotch, let l = screen.auxiliaryTopLeftArea { freeEnd = min(freeEnd, l.maxX - screen.frame.minX - 8) }
        cat.roam = freeStart...max(freeStart, freeEnd)
    }

    func render(_ m: Model) {
        while chips.count < m.desktops {
            let b = ChipButton(title: "", target: self, action: #selector(chipPressed(_:)))
            b.isBordered = false
            b.font = .systemFont(ofSize: 11, weight: .semibold)
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            chips.append(b)
            left.insertArrangedSubview(b, at: chips.count - 1)
        }
        for (i, b) in chips.enumerated() {
            b.isHidden = i >= m.desktops
            b.tag = i
            let current = i == m.current
            b.attributedTitle = NSAttributedString(string: "\(i + 1)", attributes: [
                .foregroundColor: current ? activeColor.contrastingText : textColor.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
            b.layer?.backgroundColor = current ? activeColor.cgColor : textColor.withAlphaComponent(0.1).cgColor
        }
        if appLabel.superview == nil {
            let sep = NSBox(); sep.boxType = .separator
            sep.heightAnchor.constraint(equalToConstant: 14).isActive = true
            left.addArrangedSubview(sep)
            left.addArrangedSubview(appLabel)
            left.addArrangedSubview(titleLabel)
        }
        appLabel.stringValue = m.app
        titleLabel.stringValue = m.title.isEmpty || m.title == m.app ? "" : "— " + m.title
        if let (text, symbol) = m.weather {
            weatherIcon.isHidden = false
            weatherLabel.isHidden = false
            weatherIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            weatherLabel.stringValue = text
        } else {
            weatherIcon.isHidden = true
            weatherLabel.isHidden = true
        }
        func show(_ icon: NSImageView, _ label: NSTextField, _ text: String?) {
            icon.isHidden = text == nil
            label.isHidden = text == nil
            if let text { label.stringValue = text }
        }
        show(cpuIcon, cpuLabel, m.cpu.map { BarView.percent($0 * 100) })
        show(memIcon, memLabel, m.memory.map { BarView.percent($0 * 100) })
        show(diskIcon, diskLabel, m.disk.map(SystemStatus.formatBytes))
        wifiIcon.isHidden = !m.showWifi
        if m.showWifi {
            wifiIcon.image = m.wifi.map { NSImage(systemSymbolName: "wifi", variableValue: $0, accessibilityDescription: nil) }
                ?? NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
        }
        if let b = m.battery {
            batteryIcon.isHidden = false
            batteryLabel.isHidden = !m.batteryPercent
            batteryIcon.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: nil)
            batteryLabel.stringValue = BarView.percent(Double(b.percent))
            batteryIcon.toolTip = "\(b.percent)%"
            batteryIcon.contentTintColor = b.percent <= 15 && !b.charging ? .systemRed : textColor
        } else {
            batteryIcon.isHidden = true
            batteryLabel.isHidden = true
        }
        clockLabel.stringValue = m.clock
    }

    /// Two digits minimum, padded with a figure space so the monospaced labels keep a stable width.
    static func percent(_ value: Double) -> String {
        let n = Int(value.rounded())
        return (n < 10 ? "\u{2007}" : "") + "\(n)%"
    }

    @objc private func chipPressed(_ sender: NSButton) { onSelectDesktop?(sender.tag) }
}

extension NSColor {
    /// Black or white, whichever reads better on this colour.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}
