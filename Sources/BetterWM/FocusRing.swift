import BetterWMCore
import Cocoa
import QuartzCore

final class FocusRing {
    private var window: UnconstrainedWindow
    private var layer: CALayer
    /// Ring windows that faded out at a previous target and can be used again.
    private var spareRings: [(window: UnconstrainedWindow, layer: CALayer)] = []
    private var config: Config
    private var timer: Timer?
    private let events = WindowServerEvents()
    private var current: CGWindowID?
    /// The window the ring is on; the bar outlines it. Electron apps report no focused window for a moment
    /// after a switch, so readers prefer this over asking Accessibility again.
    var currentWindowID: CGWindowID? { current }
    /// Called whenever the ring shows, moves or hides: its frame (Cocoa coordinates) or nil, whether it is grey,
    /// and how far its inner edge is from the frame.
    /// Frame, greyed, corner clearance (how far in from the ring's outer corner anything standing on the ring
    /// should start), line width, colour.
    var onChange: ((NSRect?, Bool, CGFloat, CGFloat, NSColor) -> Void)?
    private var currentColor = NSColor.controlAccentColor
    private func notify() { onChange?(shown ? placedFrame : nil, isInactive, current.map(clearance(for:)) ?? pad, config.ringButtonsOverlap, currentColor) }
    /// Whether the ring is meant to be on screen; `window.isVisible` lingers through a fade-out.
    private var shown = false
    private func hideRing() { shown = false; Fade.hide(window) }
    /// Whether a window frame's centre lies on a screen; parked and set-aside windows keep a sliver past a corner.
    private static func onScreen(_ f: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.toCocoa().contains(CGPoint(x: f.midX, y: f.midY)) }
    }
    private func retireRing() {
        let old = (window: window, layer: layer)
        Fade.hide(old.window) { [weak self] in self?.spareRings.append(old) }
        if let spare = spareRings.popLast() { (window, layer) = spare } else { layer = CALayer(); window = Self.makeWindow(layer) }
        shown = false
        placedFrame = .zero
    }
    private func showRing() { shown = true; Fade.show(window) { orderFront() } }
    /// Ordering a window front makes AppKit reassert the frame it knows; after WindowServer moves that is stale,
    /// so it is brought up to date first.
    private func orderFront() {
        if placedFrame != .zero, window.frame != placedFrame { window.setFrame(placedFrame, display: false, animate: false) }
        window.orderFrontRegardless()
    }
    private var filled: Bool { config.focusRingStyle == .filled }
    /// A filled band is a border as wide as the ring's reach, so its inner edge is the window's edge.
    private var lineWidth: CGFloat { filled ? pad : config.focusRingWidth }
    /// The frame the ring was last put at. A WindowServer move leaves AppKit's `window.frame` stale.
    private var placedFrame: NSRect = .zero
    /// The ring's outer corner radius as drawn; nothing should hang over the curve.
    var cornerRadius: CGFloat { shown ? layer.cornerRadius : 0 }
    /// Every tiled window on every desktop; the manager knows the grids.
    var tiledWindows: () -> [CGWindowID] = { [] }
    /// How far in from the ring's outer corner the tabs and the buttons start, so they never hang over the curve:
    /// the ring's reach plus the largest corner radius among all tiled windows. One value everywhere, so the row
    /// does not shift when another window comes to the front or another desktop shows.
    func clearance(for id: CGWindowID) -> CGFloat { (tiledWindows().map(radius(for:)).max() ?? radius(for: id)) + pad }
    /// Independent of whether the ring is up right now: a strip that moved every time the ring hid would jump.
    func tabClearance(for ids: [CGWindowID]) -> CGFloat {
        guard config.focusRing, let any = ids.first else { return 0 }
        return clearance(for: any)
    }
    /// The ring is on the window focus will come back to, greyed: no window has focus right now.
    private(set) var isInactive = false
    static let inactiveColor = NSColor(white: 0.55, alpha: 1)
    /// Corner radii rarely change for a window's lifetime, so one measurement per window ID is enough.
    private var radiusCache: [CGWindowID: CGFloat] = [:]
    /// Floating windows get a ring only when `focusRingFloating` is set; skipping them keeps drags cheap.
    var isTiled: (AXWindow) -> Bool = { _ in true }
    /// Same question by window ID, for callers that only have one (workspace switches, re-measures).
    var isTiledID: (CGWindowID) -> Bool = { _ in true }
    /// Fired after the ring window is (re)ordered so dependants like the gap handles can stack above it.
    var onReorder: (() -> Void)?
    /// Fired when the ringed window changes, including between windows of one app.
    var onFocusChange: (() -> Void)?
    var windowNumber: Int? { shown ? window.windowNumber : nil }

    /// Show Desktop is active: stay hidden until it ends.
    var hiddenForSystemReveal = false {
        didSet {
            guard hiddenForSystemReveal != oldValue else { return }
            if hiddenForSystemReveal { hideRing(); notify() } else { update() }
        }
    }

    /// Hidden briefly around a workspace switch so it never lingers on a parked window.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { hideRing(); notify() } else { update() }
        }
    }

    private static func makeWindow(_ layer: CALayer) -> UnconstrainedWindow {
        let w = UnconstrainedWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.animationBehavior = .none
        // Bound to the current desktop so it slides away with it during a switch instead of floating over the transition.
        w.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "backgroundColor": NSNull(),
                         "cornerRadius": NSNull(), "borderWidth": NSNull(), "hidden": NSNull()]
        w.contentView = view
        return w
    }

    init(config: Config) {
        self.config = config
        layer = CALayer()
        window = Self.makeWindow(layer)

        events.onEvent = { [weak self] event, wid in
            guard let self else { return }
            switch event {
            case .windowDestroy:
                if let wid { self.radiusCache[wid] = nil }
                self.update()
            case .windowResize:
                // Apps change corner style with size (e.g. entering split view); measure again.
                if let wid { self.radiusCache[wid] = nil }
                guard !self.suspended, wid == self.current else { return }
                self.scheduleUpdate()
            case .windowMove:
                // Moving a window never changes focus; only the ringed window matters, and it is followed straight
                // from WindowServer. An ⌥-drag of an unfocused window fires this per pixel, so no AX here.
                guard !self.suspended, wid == self.current, let id = wid, let f = WindowServerEvents.bounds(of: id) else { return }
                // Off to a corner (parked, or a tab set aside): no longer the window to ring. The ring hides rather
                // than following; the next focused window brings it back.
                guard Self.onScreen(f) else { self.hideRing(); self.notify(); return }
                self.place(frame: f)
            case .windowReorder, .frontChange, .windowLevel:
                if let wid, wid == self.current { self.reorder() }
                self.scheduleUpdate()
            case .spaceChange:
                self.hideRing()
                self.notify()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.update() }
            default:
                self.scheduleUpdate()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
        // Our own titled windows are followed through AppKit, since Accessibility is never asked about them.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let w = n.object as? NSWindow, w.styleMask.contains(.titled) else { return }
                self?.update()
            }
        }
        // Safety net only; WindowServer events do the real work.
        timer = Timer.scheduledTimer(withTimeInterval: WindowServerEvents.available ? 5.0 : 0.1, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func apply(_ config: Config) {
        self.config = config
        update()
    }

    /// Forget every measured corner radius and redraw; for when a window changed style without a resize.
    func remeasureCorners() {
        radiusCache.removeAll()
        if let id = current, let f = WindowServerEvents.bounds(of: id) {
            current = nil   // force a full present() so the radius is applied
            present(id: id, frame: f)
        } else {
            update()
        }
    }

    /// The ring sits on the slot's edge; a tiled window is `tileInset` inside it, a floating one gets the same gap.
    private var pad: CGFloat { config.focusRingOutset + config.tileInset }

    /// Shows the ring for a window we are about to focus, at the frame it will have, without waiting for the
    /// focus notification. Used when switching workspaces so ring and windows appear in the same frame.
    func show(windowID id: CGWindowID, frame: CGRect) {
        suspended = false
        guard config.focusRing else { return }
        present(id: id, frame: frame)
    }

    /// Reorder/level/front events arrive in bursts; one Accessibility round-trip per burst is enough.
    private var updateScheduled = false
    func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    /// Brings the ring back to the front of its level after anything that could have slipped a window above it.
    func reorder() {
        guard current != nil, shown, !suspended else { return }
        orderFront()
    }

    /// The focused window as the last snapshot saw it; the ring never asks Accessibility itself.
    var focusedWindow: () -> AXWindow? = { nil }
    /// Whether a window's desktop is on a screen. After a desktop switch the previous app stays frontmost until
    /// macOS grants the new one activation, so the snapshot's focused window sits parked at a corner for a moment.
    var isShown: (CGWindowID) -> Bool = { _ in true }

    func update() {
        guard !suspended, !hiddenForSystemReveal, config.focusRing else {
            // Stepping aside (Show Desktop, a drag) keeps the window in mind: when the windows come back with no
            // focus anywhere, the grey ring goes back on it. Only a disabled ring forgets.
            if !config.focusRing { current = nil }
            hideRing()
            notify()
            return
        }
        // Our own windows (Settings, Welcome) are never asked through Accessibility; AppKit knows them directly.
        if NSApp.isActive, let own = NSApp.keyWindow, own.styleMask.contains(.titled), own.isVisible {
            present(id: CGWindowID(own.windowNumber), frame: own.frame.toCocoa(), floating: true)
            return
        }
        guard let w = focusedWindow() else {
            // Electron apps briefly report no focused window while moving focus inside one; don't blink.
            if let id = current, let owner = CGWindowInfo.list(.optionOnScreenOnly).first(where: { $0.id == id }),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid { return }
            // Nothing has focus (the desktop, an app without windows): keep the ring on the last window, greyed,
            // so a tabbed stack still shows which window is in front.
            // Only a window really on a screen: a parked one keeps two points on screen at a corner.
            if let id = current, CGWindowInfo.isOnScreen(id), let f = WindowServerEvents.bounds(of: id),
               NSScreen.screens.contains(where: { $0.frame.toCocoa().contains(CGPoint(x: f.midX, y: f.midY)) }) {
                present(id: id, frame: f, inactive: true)
                return
            }
            current = nil
            hideRing()
            notify()
            return
        }
        if let id = w.windowID, !isShown(id) {
            // The focused window is on a desktop not shown (its app still frontmost right after a switch): keep the
            // ring where it is, unless its own window has gone too.
            if let c = current, !isShown(c) || WindowServerEvents.bounds(of: c).map(Self.onScreen) == false { hideRing(); notify() }
            return
        }
        // An app can report a window it keeps alive after closing (ChatGPT) as focused; ring only what is visible.
        // A window on no Space is mid-transition to or from fullscreen.
        guard config.focusRingFloating || isTiled(w), let id = w.windowID, CGWindowInfo.isOnScreen(id),
              case let spaces = Spaces.spaces(of: id), !spaces.isEmpty, spaces.allSatisfy(Spaces.isDesktop),
              !NSScreen.screens.contains(where: Spaces.showsFullscreen) else {
            current = nil
            hideRing()
            notify()
            return
        }
        let actual = WindowServerEvents.bounds(of: id) ?? w.frame
        // Focused but still parked past a corner (its desktop just switched in): the layout is about to place it
        // and the switch shows the ring where it will land; a ring at the corner meanwhile is wrong.
        guard Self.onScreen(actual) else { return }
        present(id: id, frame: actual, floating: !isTiled(w))
    }

    private func present(id: CGWindowID, frame: CGRect, floating: Bool? = nil, inactive: Bool = false) {
        let floating = floating ?? !isTiledID(id)
        // A new target elsewhere gets a ring of its own: the old one fades out where it is, the new one fades in.
        // Tabs of a stack share one frame; the ring simply stays.
        if current != id, shown, Fade.enabled, !placedFrame.approximatelyEquals(frame.insetBy(dx: -pad, dy: -pad).toCocoa(), tolerance: 1) { retireRing() }
        let wasHidden = !shown
        let targetChanged = current != id || isInactive != inactive
        if current != id {
            current = id
            events.watch([id])
        }
        isInactive = inactive
        if targetChanged { onFocusChange?() }
        let color = inactive ? Self.inactiveColor : config.ringColor(floating: floating)
        let colorChanged = currentColor != color
        currentColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = radius(for: id) + pad
        if wasHidden { layer.cornerRadius = r }
        layer.backgroundColor = nil
        if wasHidden || !colorChanged { layer.borderColor = color.cgColor }
        if wasHidden || !targetChanged { layer.borderWidth = lineWidth }
        CATransaction.commit()
        if !wasHidden {
            // The ring stays where it is: grey to colour (and back) is a cross-fade, a new corner radius (the next
            // tab of a stack, another app) eases over, and a new window in the same frame is marked by a short
            // swell of the line.
            if colorChanged { Fade.animate(layer, "borderColor", to: color.cgColor) }
            if layer.cornerRadius != r { Fade.animate(layer, "cornerRadius", to: r) }
            if targetChanged, !filled { pulse() }
        }
        place(frame: frame)
        // Above every normal window: the ring is drawn outside the window's frame, so it covers nothing of the
        // window itself, and it never has to chase the window's depth through raises and unhides.
        window.level = .floating
        if wasHidden || targetChanged {
            showRing()
            onReorder?()
        }
        notify()
    }

    private func pulse() {
        let w = lineWidth
        guard Fade.enabled else { layer.borderWidth = w; return }
        let anim = CAKeyframeAnimation(keyPath: "borderWidth")
        anim.values = [layer.presentation()?.borderWidth ?? w, w + 2, w]
        anim.keyTimes = [0, 0.4, 1]
        anim.duration = Fade.duration * 1.5
        anim.timingFunction = Fade.curve
        layer.add(anim, forKey: "borderWidth")
        layer.borderWidth = w
    }

    private func radius(for id: CGWindowID) -> CGFloat {
        guard config.focusRingAutoRadius else { return config.focusRingRadius }
        if let r = radiusCache[id] { return r }
        let r = config.ringRadius(for: id)
        radiusCache[id] = r
        return r
    }

    /// `frame` in AX (top-left origin) coordinates. Pure moves go straight to WindowServer; resizes need AppKit.
    private func place(frame: CGRect) {
        let padded = frame.insetBy(dx: -pad, dy: -pad)
        let target = padded.toCocoa()
        // AppKit throws on a frame that is not finite; the layout never means one, but never crash over it.
        guard !target.isNull, !target.isInfinite, target.width.isFinite, target.height.isFinite, target.origin.x.isFinite, target.origin.y.isFinite,
              placedFrame != target else { return }
        placedFrame = target
        // A WindowServer move only for a ring that is up: on a window ordered out it is lost when AppKit orders
        // the window back in at the frame it last set itself.
        if shown, window.frame.size == target.size, WindowServerEvents.move(CGWindowID(window.windowNumber), to: padded.origin) {
            notify()
            return
        }
        // After a WindowServer move AppKit still holds the old frame; asked for that same frame again it would do
        // nothing and leave the ring where the server put it.
        if window.frame == target { window.setFrameOrigin(NSPoint(x: target.minX + 1, y: target.minY)) }
        window.setFrame(target, display: false, animate: false)
        notify()
    }

    /// Called by the layout right as it moves the focused window, so the ring lands with the window, not after it.
    func anticipate(windowID: CGWindowID, frame: CGRect) {
        guard !suspended, config.focusRing, current == windowID, shown else { return }
        // Sent to another desktop: the plan parks it past a corner. Not a place for the ring.
        guard Self.onScreen(frame) else { hideRing(); notify(); return }
        place(frame: frame)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a: CGFloat = s.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        let shift: UInt64 = s.count == 8 ? 8 : 0
        self.init(srgbRed: CGFloat((v >> (16 + shift)) & 0xFF) / 255, green: CGFloat((v >> (8 + shift)) & 0xFF) / 255,
                  blue: CGFloat((v >> shift) & 0xFF) / 255, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int(round(c.redComponent * 255)), g = Int(round(c.greenComponent * 255)), b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        return a == 255 ? String(format: "%02X%02X%02X", r, g, b) : String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}

extension Config {
    var ringTiledColor: NSColor { NSColor(hex: focusRingColor) ?? .controlAccentColor }
    /// nil when the floating colour is "same" as the tiled one.
    var ringFloatingColorOverride: NSColor? {
        focusRingFloatingColor.lowercased() == "same" ? nil : (NSColor(hex: focusRingFloatingColor) ?? ringTiledColor)
    }
    func ringColor(floating: Bool) -> NSColor { floating ? (ringFloatingColorOverride ?? ringTiledColor) : ringTiledColor }
    func ringRadius(for id: CGWindowID) -> CGFloat {
        focusRingAutoRadius ? (WindowServerEvents.cornerRadius(of: id) ?? focusRingRadius) : focusRingRadius
    }
}
