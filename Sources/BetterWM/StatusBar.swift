import BetterWMCore
import Cocoa

/// Top-of-screen bar living where the auto-hidden system menu bar would be. One window per screen; on notched
/// displays the content is laid out in the two strips beside the notch.
final class StatusBar {
    private var windows: [BarWindow] = []
    private var config: Config
    private let events = WindowServerEvents()
    /// One object per widget kind; the ones in `config.barWidgets` and `config.barLeftWidgets` are running and shown.
    private let widgets: [Config.BarWidget: BarWidget]
    /// What the left-side widgets ask of the manager; filled from the closures below so the app wires only these.
    private let context = BarContext()
    var onSelectDesktop: ((Int) -> Void)?
    var onSelectFullscreen: ((UInt64) -> Void)?
    var fullscreenSpaces: () -> [(space: UInt64, pids: [pid_t])] = { [] }
    /// A desktop chip was dragged to a new position.
    var onReorderDesktop: ((Int, Int) -> Void)?
    /// The menu widget was clicked; the app pops its menu at the given view.
    var onMenuRequested: ((NSView) -> Void)?
    /// Right-click on a desktop chip: the desktop and the chip to anchor a menu to.
    var onDesktopMenu: ((Int, NSView) -> Void)?
    /// Desktops living on a screen, the one it shows, and the active desktop across all screens.
    var desktopsOn: (NSScreen) -> [Int] = { _ in [] }
    var shownOn: (NSScreen) -> Int? = { _ in nil }
    var activeDesktop: () -> Int? = { nil }
    var focusedAXWindow: () -> AXWindow? = { nil }
    /// The name given to a window's tab, if any; shown in place of the formatted title.
    var tabLabel: (WindowID) -> String? = { _ in nil }
    var desktopApps: () -> [Int: [(pid: pid_t, windows: [WindowID])]] = { [:] }
    var focusedWindow: () -> WindowID? = { nil }
    /// While the user drags a window the bar stays as it is; any work on the main thread stalls the event tap.
    var isInteracting: () -> Bool = { false }
    /// Called whenever the bar is shown or hidden so the layout can reserve space.
    var onLayoutChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        widgets = BarWidgets.make(config: config, context: context)
        (widgets[.cats] as? CatsWidget)?.peer = { [weak self] in self?.widgets[$0] }
        context.desktopsOn = { [unowned self] in self.desktopsOn($0) }
        context.shownOn = { [unowned self] in self.shownOn($0) }
        context.activeDesktop = { [unowned self] in self.activeDesktop() }
        context.desktopApps = { [unowned self] in self.desktopApps() }
        context.focusedWindow = { [unowned self] in self.focusedWindow() }
        context.fullscreenSpaces = { [unowned self] in self.fullscreenSpaces() }
        context.focusedAXWindow = { [unowned self] in self.focusedAXWindow() }
        context.tabLabel = { [unowned self] in self.tabLabel($0) }
        context.onSelectDesktop = { [weak self] in self?.onSelectDesktop?($0) }
        context.onSelectFullscreen = { [weak self] in self?.onSelectFullscreen?($0) }
        context.onReorderDesktop = { [weak self] from, to in self?.onReorderDesktop?(from, to) }
        context.onDesktopMenu = { [weak self] d, v in self?.onDesktopMenu?(d, v) }
        for w in widgets.values { w.wantsRefresh = { [weak self] in self?.refresh() } }
        (widgets[.menu] as? MenuWidget)?.onPressed = { [weak self] v in self?.onMenuRequested?(v) }
        runWidgets()
        events.onEvent = { [weak self] event, _ in
            switch event {
            case .spaceChange: self?.stepAsideFromFullscreen(); self?.refresh()
            case .frontChange, .windowDestroy, .windowReorder: self?.refresh()
            default: break
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stepAsideFromFullscreen()
        }
        rebuild()
    }

    /// Starts the widgets in the bar and stops the rest, so a widget that is off costs nothing.
    private func runWidgets() {
        let inUse = inUseWidgets
        for (id, w) in widgets {
            if config.bar && inUse.contains(id) { w.apply(config); w.start() } else { w.stop() }
        }
    }

    private var inUseWidgets: [Config.BarWidget] { config.barLeftWidgets + config.barWidgets + (config.barCat ? [.cats] : []) }

    /// Distance from the screen's top edge to the bar's bottom edge; zero when the bar is off.
    func inset(for screen: NSScreen) -> CGFloat { config.bar ? config.barTopOffset + height(for: screen) : 0 }

    /// Dev aid: opens the sound popover on the first bar.
    func showSoundPopover() { (widgets[.sound] as? SoundWidget)?.showPopover() }

    /// At offset zero with no side margin the bar shares the top edge with the notch.
    private func atScreenTop(_ screen: NSScreen) -> Bool { config.barTopOffset == 0 && config.barMargin == 0 }

    private func height(for screen: NSScreen) -> CGFloat {
        // Beside a notch the bar must be as tall as the notch, or the notch pokes below it.
        atScreenTop(screen) ? max(config.barHeight, screen.safeAreaInsets.top) : config.barHeight
    }

    func apply(_ config: Config) {
        self.config = config
        runWidgets()
        rebuild()
    }

    func focusChanged() { refresh() }

    /// The desktop chip under a point in AX coordinates, on any bar.
    func desktop(at pointAX: CGPoint) -> Int? {
        (widgets[.desktops] as? DesktopsWidget)?.chipDesktop(atScreenPoint: CGRect(origin: pointAX, size: .zero).toCocoa().origin)
    }

    /// Lights up one desktop's chip (on every bar showing it) while a dragged window is over it.
    func highlightDrop(_ desktop: Int?) { (widgets[.desktops] as? DesktopsWidget)?.setDropTarget(desktop) }

    /// A screen switching to a fullscreen Space: hide at once, before the first frame of the animation; the
    /// deferred refresh decides what comes back.
    private func stepAsideFromFullscreen() {
        let leaving = windows.filter { Spaces.showsFullscreen($0.targetScreen) }
        guard !leaving.isEmpty else { return }
        leaving.forEach { $0.orderOut(nil) }
    }

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
        widgets.values.forEach { $0.dropViews() }
        guard config.bar else { onLayoutChange?(); return }
        for screen in NSScreen.screens {
            let h = height(for: screen), m = config.barMargin
            let frame = NSRect(x: screen.frame.minX + m, y: screen.frame.maxY - config.barTopOffset - h, width: screen.frame.width - 2 * m, height: h)
            let w = BarWindow(frame: frame, screen: screen)
            w.view.apply(config, avoidNotch: atScreenTop(screen))
            w.view.setLeftWidgets(config.barLeftWidgets.compactMap { widgets[$0]?.makeView(for: screen) })
            w.view.setRightWidgets(config.barWidgets.compactMap { widgets[$0]?.makeView(for: screen) })
            w.view.setFreeView(config.barCat ? widgets[.cats]?.makeView(for: screen) as? BarFreeView : nil)
            windows.append(w)
            // Entering fullscreen hides the menu bar, which lands here too: a fullscreen screen gets no bar.
            if !Spaces.showsFullscreen(screen) { w.orderFrontRegardless() }
        }
        refresh()
        onLayoutChange?()
        maybeSuggestMenuBarAutoHide()
    }

    /// Events come in bursts and a refresh scans every window for the desktop chips; one pass per burst.
    private var refreshScheduled = false
    /// A refresh mid-drag would stutter the gesture; it waits for `interactionEnded`.
    private var refreshAfterInteraction = false
    func interactionEnded() {
        guard refreshAfterInteraction else { return }
        refreshAfterInteraction = false
        refresh()
    }
    private func refresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.isInteracting() { self.refreshAfterInteraction = true } else { self.refreshNow() }
        }
    }

    private func refreshNow() {
        guard config.bar else { return }
        Spaces.withSpaceTypesCached { buildAndRender() }
    }

    private func buildAndRender() {
        // A fullscreen app owns the whole screen; stay out of its way.
        for w in windows {
            let fullscreen = Spaces.showsFullscreen(w.targetScreen) || hiddenForSystemReveal
            if fullscreen { w.orderOut(nil) } else if !w.isVisible { w.orderFrontRegardless() }
        }
        // The cats come last: they read the battery and CPU from the other widgets' fresh readings.
        if let v = windows.first?.view {
            let style = BarStyle(textColor: v.textColor, activeColor: v.activeColor, focusOutline: v.focusOutline, config: config)
            for id in inUseWidgets { widgets[id]?.render(style) }
        }
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
        // Above app windows, like the menu bar it replaces: a floating or dragged window never covers it, and it is
        // a drop target. One step above the focus ring's level too, so a ring around a window right under the
        // bar does not draw over it. Not a fullscreen auxiliary: macOS then never carries it into a fullscreen
        // Space, not even for the first frames of the transition.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    // Clicking a desktop chip must not pull the bar in front of the windows.
    override func mouseDown(with event: NSEvent) { super.mouseDown(with: event) }

    // AppKit pushes windows below the menu-bar level out of the menu bar area; the bar must be allowed to sit there.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Desktop number plus the icons of the apps open there. A non-key panel swallows the first click unless the
/// view accepts it.
final class ChipView: NSView {
    var onClick: (() -> Void)?
    var onContextMenu: (() -> Void)?

    /// A dragged window is over this chip: a ring in the accent colour, and the chip grows a little.
    func setDropTarget(_ on: Bool, color: NSColor) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer?.borderWidth = on ? 2 : 0
        layer?.borderColor = color.cgColor
        layer?.transform = on ? CATransform3DMakeScale(1.12, 1.12, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
    /// A drag past a few points: began, moved by `dx` from the press, released.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
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

    /// One icon per window, so two Chrome windows show two Chrome icons; the focused window's icon is outlined.
    func setApps(_ apps: [(pid: pid_t, windows: [WindowID])], focused: WindowID?, color: NSColor) {
        let pids = apps.flatMap { app in app.windows.isEmpty ? [(app.pid, WindowID(0))] : app.windows.map { (app.pid, $0) } }
        while icons.count < pids.count {
            let v = NSImageView()
            v.imageScaling = .scaleProportionallyUpOrDown
            v.wantsLayer = true
            v.layer?.cornerRadius = 4
            v.widthAnchor.constraint(equalToConstant: 14).isActive = true
            v.heightAnchor.constraint(equalToConstant: 14).isActive = true
            icons.append(v)
            stack.addArrangedSubview(v)
        }
        for (i, v) in icons.enumerated() {
            v.isHidden = i >= pids.count
            guard i < pids.count else { continue }
            let (pid, id) = pids[i]
            let isFocused = focused != nil && id == focused
            v.layer?.borderWidth = isFocused ? 1.5 : 0
            v.layer?.borderColor = color.cgColor
            let app = NSRunningApplication(processIdentifier: pid)
            let key = app?.bundleIdentifier ?? "\(pid)"
            if ChipView.iconCache[key] == nil, let icon = app?.icon { ChipView.iconCache[key] = icon }
            v.image = ChipView.iconCache[key]
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?() }

    /// A click selects the desktop; a drag past a few points slides the chip along, the others making room.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow.x
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = e.locationInWindow.x - start
            if e.type == .leftMouseDragged {
                if !dragging, abs(dx) > 4 { dragging = true; onDragBegan?() }
                if dragging { onDragMoved?(dx) }
            } else {
                break
            }
        }
        if dragging { onDragEnded?() } else { onClick?() }
        (window as? NSPanel)?.orderFrontRegardless()
    }
}

final class BarView: NSView {
    private let screen: NSScreen
    private let background = NSVisualEffectView()
    private let solid = NSView()
    private var avoidNotch = false
    private var notchPortals = true
    private(set) var textColor: NSColor = .labelColor
    private(set) var activeColor: NSColor = .controlAccentColor
    private(set) var focusOutline: NSColor?
    private var padding: CGFloat = 12
    private let left = NSStackView()
    private let right = NSStackView()
    private var free: (any BarFreeView)?
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

        left.orientation = .horizontal
        left.spacing = 10
        left.alignment = .centerY
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = 12
        for v in [left, right] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
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
        textColor = BarStyle.textColor(of: config)
        activeColor = config.barActiveColor.lowercased() == "accent" ? .controlAccentColor : (NSColor(hex: config.barActiveColor) ?? .controlAccentColor)
        focusOutline = config.barFocusOutlineColor.lowercased() == "auto" ? nil : NSColor(hex: config.barFocusOutlineColor)
        let blur = config.barBackground.lowercased() == "blur"
        background.isHidden = !blur
        solid.isHidden = blur
        solid.layer?.backgroundColor = blur ? nil : (NSColor(hex: config.barBackground) ?? .windowBackgroundColor).cgColor
        layer?.cornerRadius = config.barRadius
        layer?.borderWidth = config.barBorderWidth
        layer?.borderColor = (NSColor(hex: config.barBorderColor) ?? .separatorColor).cgColor
        notchPortals = config.barNotchPortals
        needsLayout = true
    }

    /// The view spanning the whole bar that gets the free span after each layout; nil for none.
    func setFreeView(_ v: (any BarFreeView)?) {
        free?.removeFromSuperview()
        free = v
        guard let v else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        needsLayout = true
    }

    /// The left side, in display order; each view belongs to a widget that updates it.
    func setLeftWidgets(_ views: [NSView]) {
        left.arrangedSubviews.forEach { left.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach(left.addArrangedSubview)
        needsLayout = true
    }

    /// The right side, in display order; each view belongs to a widget that updates it.
    func setRightWidgets(_ views: [NSView]) {
        right.arrangedSubviews.forEach { right.removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach(right.addArrangedSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep content out of the notch: the auxiliary areas are the usable strips either side of it.
        if avoidNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // A long title would otherwise run right up to the notch and leave the cats nowhere to stand.
            let catRoom: CGFloat = free != nil ? 110 : 0
            leftTrailing.constant = -(bounds.width - (l.maxX - screen.frame.minX)) - 8 - catRoom
            rightLeading.constant = (r.minX - screen.frame.minX) + 8
        } else {
            leftTrailing.constant = -padding
            rightLeading.constant = padding
        }
        guard let cat = free else { return }
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

}

extension NSColor {
    /// Black or white, whichever reads better on this colour.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}
