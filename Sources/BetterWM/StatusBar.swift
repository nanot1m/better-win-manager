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
    private let media = MediaService()
    private var inputSourceObserver: NSObjectProtocol?
    var onSelectDesktop: ((Int) -> Void)?
    /// A desktop chip was dragged to a new position.
    var onReorderDesktop: ((Int, Int) -> Void)?
    /// The menu widget was clicked; the app pops its menu at the given view.
    var onMenuRequested: ((NSView) -> Void)?
    var desktopCount: () -> Int = { 0 }
    var currentDesktop: () -> Int? = { nil }
    var desktopApps: () -> [Int: [(pid: pid_t, windows: Int)]] = { [:] }
    /// While the user drags a window the bar stays as it is; any work on the main thread stalls the event tap.
    var isInteracting: () -> Bool = { false }
    /// Called whenever the bar is shown or hidden so the layout can reserve space.
    var onLayoutChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        weather = WeatherService(config: config)
        weather.onUpdate = { [weak self] _ in self?.refresh() }
        media.onUpdate = { [weak self] _ in self?.refresh() }
        if config.bar && config.barWidgets.contains(.media) { media.start() }
        events.onEvent = { [weak self] event, _ in
            switch event {
            case .frontChange, .spaceChange, .windowDestroy, .windowReorder: self?.refresh()
            default: break
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        clock = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        inputSourceObserver = InputSource.observe { [weak self] in self?.refresh() }
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
        if config.bar && config.barWidgets.contains(.media) { media.start() } else { media.stop() }
        self.config = config
        weather.apply(config)
        rebuild()
    }

    func focusChanged() { refresh() }

    /// Show Desktop / Mission Control: step aside, come back when it ends.
    var hiddenForSystemReveal = false {
        didSet {
            guard hiddenForSystemReveal != oldValue else { return }
            if hiddenForSystemReveal { windows.forEach { $0.orderOut(nil) } } else { refresh() }
        }
    }

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
            w.view.onReorderDesktop = { [weak self] from, to in self?.onReorderDesktop?(from, to) }
            w.view.onMenuRequested = { [weak self] v in self?.onMenuRequested?(v) }
            w.view.onPlayPause = { [weak self] in self?.media.togglePlayPause() }
            windows.append(w)
            w.orderBack(nil)
        }
        refresh()
        onLayoutChange?()
        maybeSuggestMenuBarAutoHide()
    }

    /// Events come in bursts and a refresh scans every window for the desktop chips; one pass per burst.
    private var refreshScheduled = false
    private func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.isInteracting() { self.refresh() } else { self.refreshNow() }
        }
    }

    private func refreshNow() {
        guard config.bar else { return }
        // A fullscreen app owns the whole screen; stay out of its way.
        for w in windows {
            let fullscreen = Spaces.isFullscreen(Spaces.current(for: w.targetScreen)) || hiddenForSystemReveal
            if fullscreen { w.orderOut(nil) } else if !w.isVisible { w.orderBack(nil) }
        }
        let focused = AXWindow.focused
        let app = focused.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.localizedName }
            ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let title = focused?.title ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = config.barClockFormat
        let model = BarView.Model(
            desktops: desktopCount(),
            current: currentDesktop(),
            apps: config.barDesktopApps ? desktopApps() : [:],
            app: app,
            title: title,
            clock: config.barClock ? formatter.string(from: Date()) : nil,
            weather: weather.reading.map { r in
                (String(format: "%.0f°", r.temperature), r.symbol)
            },
            battery: config.barBattery ? SystemStatus.battery() : nil,
            batteryPercent: config.barBatteryPercent,
            wifi: config.barWifi ? SystemStatus.wifiStrength() : nil,
            showWifi: config.barWifi,
            cpu: config.barCpu ? SystemStatus.cpuLoad() : nil,
            memory: config.barMemory ? SystemStatus.memoryUsed() : nil,
            disk: config.barDisk ? SystemStatus.diskFree() : nil,
            inputSource: config.barInputSource ? InputSource.current() : nil,
            media: config.barWidgets.contains(.media) ? media.current : nil,
            titleFormat: config.barTitleFormat
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
    /// Kept explicitly: `NSWindow.screen` is nil while the bar is hidden.
    let targetScreen: NSScreen

    init(frame: NSRect, screen: NSScreen) {
        view = BarView(screen: screen)
        targetScreen = screen
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Behind all app windows: tiled ones start below the bar anyway, floating ones may cover it.
        level = .normal
        acceptsMouseMovedEvents = true
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

/// Desktop number plus the icons of the apps open there. A non-key panel swallows the first click unless the
/// view accepts it.
private final class ChipView: NSView {
    var onClick: (() -> Void)?
    /// Called with the chip's centre x (in the superview) after it was dragged and released.
    var onDrop: ((CGFloat) -> Void)?
    let number = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var icons: [NSImageView] = []
    private static var iconCache: [String: NSImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(number)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 18), widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// One icon per window, so two Chrome windows show two Chrome icons.
    func setApps(_ apps: [(pid: pid_t, windows: Int)]) {
        let pids = apps.flatMap { Array(repeating: $0.pid, count: max(1, $0.windows)) }
        while icons.count < pids.count {
            let v = NSImageView()
            v.imageScaling = .scaleProportionallyUpOrDown
            v.widthAnchor.constraint(equalToConstant: 14).isActive = true
            v.heightAnchor.constraint(equalToConstant: 14).isActive = true
            icons.append(v)
            stack.addArrangedSubview(v)
        }
        for (i, v) in icons.enumerated() {
            v.isHidden = i >= pids.count
            guard i < pids.count else { continue }
            let pid = pids[i]
            let app = NSRunningApplication(processIdentifier: pid)
            let key = app?.bundleIdentifier ?? "\(pid)"
            if ChipView.iconCache[key] == nil, let icon = app?.icon { ChipView.iconCache[key] = icon }
            v.image = ChipView.iconCache[key]
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click selects the desktop; a drag past a few points slides the chip along and drops it in a new slot.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow.x
        var dragging = false
        var dx: CGFloat = 0
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            dx = e.locationInWindow.x - start
            if e.type == .leftMouseDragged {
                if !dragging, abs(dx) > 4 { dragging = true; layer?.zPosition = 10; alphaValue = 0.85 }
                if dragging { layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0)) }
            } else {
                break
            }
        }
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
        alphaValue = 1
        if dragging { onDrop?(frame.midX + dx) } else { onClick?() }
        (window as? NSPanel)?.orderBack(nil)
    }
}

final class BarView: NSView {
    struct Model {
        var desktops: Int
        var current: Int?
        var apps: [Int: [(pid: pid_t, windows: Int)]]
        var app: String
        var title: String
        var clock: String?
        var weather: (String, String)?
        var battery: SystemStatus.Battery?
        var batteryPercent: Bool
        var wifi: Double?
        var showWifi: Bool
        var cpu: Double?
        var memory: Double?
        var disk: Int64?
        var inputSource: String?
        var media: MediaService.NowPlaying?
        var titleFormat: String
    }

    var onSelectDesktop: ((Int) -> Void)?
    var onReorderDesktop: ((Int, Int) -> Void)?
    var onMenuRequested: ((NSView) -> Void)?
    var onPlayPause: (() -> Void)?
    private let screen: NSScreen
    private let background = NSVisualEffectView()
    private let solid = NSView()
    private var avoidNotch = false
    private var notchPortals = true
    private var catsEnabled = true
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
    private let inputLabel = NSTextField(labelWithString: "")
    private let wifiIcon = NSImageView()
    private let batteryIcon = NSImageView()
    private let batteryLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let menuButton = ChipButton(title: "", target: nil, action: nil)
    private let mediaButton = ChipButton(title: "", target: nil, action: nil)
    private let mediaLabel = NSTextField(labelWithString: "")
    private let cat = BarCat(frame: .zero)
    /// One container per right-side widget; `apply` arranges them in the configured order.
    private var widgetViews: [Config.BarWidget: NSStackView] = [:]
    private var chips: [ChipView] = []
    private var lastDesktop: Int?
    private var warnedBatteryLow = false
    private var lastLoadReaction = Date.distantPast
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

        for l in [appLabel, titleLabel, weatherLabel, cpuLabel, memLabel, diskLabel, inputLabel, batteryLabel, clockLabel] {
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
        func widget(_ w: Config.BarWidget, _ views: [NSView], spacing: CGFloat = 3) {
            let st = NSStackView(views: views)
            st.orientation = .horizontal
            st.alignment = .centerY
            st.spacing = spacing
            widgetViews[w] = st
        }
        widget(.weather, [weatherIcon, weatherLabel])
        widget(.cpu, [cpuIcon, cpuLabel])
        widget(.memory, [memIcon, memLabel])
        widget(.disk, [diskIcon, diskLabel])
        inputLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        inputLabel.wantsLayer = true
        inputLabel.layer?.cornerRadius = 4
        inputLabel.alignment = .center
        inputLabel.widthAnchor.constraint(equalToConstant: 26).isActive = true
        widget(.keyboard, [inputLabel])
        widget(.wifi, [wifiIcon])
        widget(.battery, [batteryIcon, batteryLabel], spacing: 4)
        widget(.clock, [clockLabel])
        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "BetterWM menu")
        menuButton.imageScaling = .scaleProportionallyDown
        // Generous hit area: the icon is 16pt but the whole bar height and a wide margin should take the click.
        menuButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        menuButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        menuButton.target = self
        menuButton.action = #selector(menuPressed)
        menuButton.toolTip = "BetterWM"
        widget(.menu, [menuButton])
        mediaButton.isBordered = false
        mediaButton.imageScaling = .scaleProportionallyDown
        mediaButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        mediaButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        mediaButton.target = self
        mediaButton.action = #selector(playPausePressed)
        mediaLabel.font = .systemFont(ofSize: 12)
        mediaLabel.lineBreakMode = .byTruncatingTail
        mediaLabel.maximumNumberOfLines = 1
        mediaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        widget(.media, [mediaButton, mediaLabel], spacing: 2)
        right.spacing = 12
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
        for l in [appLabel, weatherLabel, cpuLabel, memLabel, diskLabel, inputLabel, batteryLabel, clockLabel] { l.textColor = textColor }
        inputLabel.layer?.backgroundColor = textColor.withAlphaComponent(0.12).cgColor
        titleLabel.textColor = textColor.withAlphaComponent(0.65)
        for icon in [weatherIcon, cpuIcon, memIcon, diskIcon, wifiIcon, batteryIcon] { icon.contentTintColor = textColor }
        menuButton.contentTintColor = textColor
        mediaButton.contentTintColor = textColor
        mediaLabel.textColor = textColor
        cat.isHidden = !config.barCat
        catsEnabled = config.barCat
        notchPortals = config.barNotchPortals
        cat.configure(sheets: config.barCatSheets, color: textColor, barHeight: config.barHeight)
        right.arrangedSubviews.forEach { right.removeArrangedSubview($0); $0.removeFromSuperview() }
        for w in config.barWidgets { if let v = widgetViews[w] { right.addArrangedSubview(v) } }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep content out of the notch: the auxiliary areas are the usable strips either side of it.
        if avoidNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // A long title would otherwise run right up to the notch and leave the cats nowhere to stand.
            let catRoom: CGFloat = catsEnabled ? 110 : 0
            leftTrailing.constant = -(bounds.width - (l.maxX - screen.frame.minX)) - 8 - catRoom
            rightLeading.constant = (r.minX - screen.frame.minX) + 8
        } else {
            leftTrailing.constant = -padding
            rightLeading.constant = padding
        }
        // The cats roam whatever is free between the left content and the right content; the notch in between is
        // crossed through portals rather than avoided.
        var freeStart = left.frame.maxX + 16
        var freeEnd = right.frame.minX - 16
        if avoidNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let notchLeft = l.maxX - screen.frame.minX - 8, notchRight = r.minX - screen.frame.minX + 8
            if notchPortals, freeStart < notchLeft - 70 {
                cat.gap = notchLeft...notchRight
            } else if notchPortals {
                // No room left of the notch at all: the cats live on the right of it.
                cat.gap = nil
                freeStart = max(freeStart, notchRight)
            } else {
                cat.gap = nil
                freeEnd = min(freeEnd, notchLeft)
            }
        } else {
            cat.gap = nil
        }
        cat.roam = freeStart...max(freeStart, freeEnd)
    }

    func render(_ m: Model) {
        while chips.count < m.desktops {
            let c = ChipView()
            let i = chips.count
            c.onClick = { [weak self] in self?.onSelectDesktop?(i) }
            c.onDrop = { [weak self] midX in self?.dropChip(i, at: midX) }
            chips.append(c)
            left.insertArrangedSubview(c, at: chips.count - 1)
        }
        for (i, c) in chips.enumerated() {
            c.isHidden = i >= m.desktops
            let current = i == m.current
            c.number.attributedStringValue = NSAttributedString(string: "\(i + 1)", attributes: [
                .foregroundColor: current ? activeColor.contrastingText : textColor.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
            c.layer?.backgroundColor = current ? activeColor.cgColor : textColor.withAlphaComponent(0.1).cgColor
            c.setApps(m.apps[i] ?? [])
        }
        if appLabel.superview == nil {
            let sep = NSBox(); sep.boxType = .separator
            sep.heightAnchor.constraint(equalToConstant: 14).isActive = true
            left.addArrangedSubview(sep)
            left.addArrangedSubview(appLabel)
            left.addArrangedSubview(titleLabel)
        }
        appLabel.isHidden = true
        titleLabel.attributedStringValue = BarView.formatTitle(m.titleFormat, app: m.app, title: m.title, color: textColor)
        show(.media, m.media != nil)
        if let np = m.media {
            mediaButton.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: np.playing ? "Pause" : "Play")
            mediaLabel.stringValue = np.text
            mediaLabel.toolTip = np.text
        }
        func show(_ w: Config.BarWidget, _ visible: Bool) { widgetViews[w]?.isHidden = !visible }
        show(.weather, m.weather != nil)
        if let (text, symbol) = m.weather {
            weatherIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            weatherLabel.stringValue = text
        }
        func value(_ w: Config.BarWidget, _ label: NSTextField, _ text: String?) {
            show(w, text != nil)
            if let text { label.stringValue = text }
        }
        value(.cpu, cpuLabel, m.cpu.map { BarView.percent($0 * 100) })
        value(.memory, memLabel, m.memory.map { BarView.percent($0 * 100) })
        value(.disk, diskLabel, m.disk.map(SystemStatus.formatBytes))
        value(.keyboard, inputLabel, m.inputSource)
        show(.wifi, m.showWifi)
        if m.showWifi {
            wifiIcon.image = m.wifi.map { NSImage(systemSymbolName: "wifi", variableValue: $0, accessibilityDescription: nil) }
                ?? NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: nil)
        }
        show(.battery, m.battery != nil)
        if let b = m.battery {
            batteryLabel.isHidden = !m.batteryPercent
            batteryIcon.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: nil)
            batteryLabel.stringValue = BarView.percent(Double(b.percent))
            batteryIcon.toolTip = "\(b.percent)%"
            batteryIcon.contentTintColor = b.percent <= 15 && !b.charging ? .systemRed : textColor
        }
        show(.clock, m.clock != nil)
        clockLabel.stringValue = m.clock ?? ""
        notifyCats(m)
    }

    /// Hands the cats the things worth reacting to: a new active desktop, a low battery, a busy machine.
    private func notifyCats(_ m: Model) {
        guard !cat.isHidden else { return }
        if let current = m.current, current != lastDesktop {
            if lastDesktop != nil, chips.indices.contains(current) {
                cat.react(.desktopSwitched(towardX: chips[current].convert(chips[current].bounds, to: cat).midX))
            }
            lastDesktop = current
        }
        if let b = m.battery {
            if b.percent <= 15, !b.charging, !warnedBatteryLow, let w = widgetViews[.battery], !w.isHidden {
                warnedBatteryLow = true
                cat.react(.batteryLow(x: w.convert(w.bounds, to: cat).midX))
            } else if warnedBatteryLow, b.charging, let w = widgetViews[.battery] {
                warnedBatteryLow = false
                cat.react(.charging(x: w.convert(w.bounds, to: cat).midX))
            } else if b.percent > 20 {
                warnedBatteryLow = false
            }
        }
        if let load = m.cpu, load > 0.8, Date().timeIntervalSince(lastLoadReaction) > 120 {
            lastLoadReaction = Date()
            cat.react(.load)
        }
    }

    /// The dropped chip's new index is the number of other visible chips whose centre lies left of the drop point.
    private func dropChip(_ index: Int, at midX: CGFloat) {
        let others = chips.enumerated().filter { !$0.element.isHidden && $0.offset != index }
        let target = others.filter { $0.element.frame.midX < midX }.count
        if target != index { onReorderDesktop?(index, target) }
    }

    @objc private func menuPressed() { onMenuRequested?(menuButton) }
    @objc private func playPausePressed() { onPlayPause?() }

    /// Expands {app} and {title} in `format`; the app name is bold, everything else dimmer. With no title (or a
    /// title equal to the app name) only the app is shown.
    static func formatTitle(_ format: String, app: String, title: String, color: NSColor) -> NSAttributedString {
        // Attributed strings carry their own paragraph style; without this the label wraps instead of truncating.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color, .paragraphStyle: para]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color.withAlphaComponent(0.65), .paragraphStyle: para]
        guard !title.isEmpty, title != app, format.contains("{title}") else {
            return NSAttributedString(string: app, attributes: bold)
        }
        let out = NSMutableAttributedString()
        var rest = Substring(format)
        while let open = rest.range(of: "{") , let close = rest[open.upperBound...].range(of: "}") {
            out.append(NSAttributedString(string: String(rest[..<open.lowerBound]), attributes: dim))
            let key = rest[open.upperBound..<close.lowerBound]
            switch key {
            case "app": out.append(NSAttributedString(string: app, attributes: bold))
            case "title": out.append(NSAttributedString(string: title, attributes: dim))
            default: out.append(NSAttributedString(string: "{\(key)}", attributes: dim))
            }
            rest = rest[close.upperBound...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: dim))
        return out
    }

    /// Two digits minimum, padded with a figure space so the monospaced labels keep a stable width.
    static func percent(_ value: Double) -> String {
        let n = Int(value.rounded())
        return (n < 10 ? "\u{2007}" : "") + "\(n)%"
    }

}

extension NSColor {
    /// Black or white, whichever reads better on this colour.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}
