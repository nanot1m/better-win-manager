import BetterWMCore
import Cocoa
import QuartzCore

final class FocusRing {
    private let window: UnconstrainedWindow
    private let layer = CALayer()
    private var config: Config
    private var timer: Timer?
    private let events = WindowServerEvents()
    private var current: CGWindowID?
    /// The window the ring is on; the bar outlines it. Electron apps report no focused window for a moment
    /// after a switch, so readers prefer this over asking Accessibility again.
    var currentWindowID: CGWindowID? { current }
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
    var windowNumber: Int? { window.isVisible ? window.windowNumber : nil }

    /// Show Desktop is active: stay hidden until it ends.
    var hiddenForSystemReveal = false {
        didSet {
            guard hiddenForSystemReveal != oldValue else { return }
            if hiddenForSystemReveal { window.orderOut(nil) } else { update() }
        }
    }

    /// Hidden briefly around a workspace switch so it never lingers on a parked window.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { window.orderOut(nil) } else { update() }
        }
    }

    init(config: Config) {
        self.config = config
        window = UnconstrainedWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        // Bound to the current desktop so it slides away with it during a switch instead of floating over the transition.
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "borderColor": NSNull(), "backgroundColor": NSNull(),
                         "cornerRadius": NSNull(), "borderWidth": NSNull(), "hidden": NSNull()]
        window.contentView = view

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
                self.place(frame: f)
            case .windowReorder, .frontChange, .windowLevel:
                if let wid, wid == self.current { self.reorder() }
                self.scheduleUpdate()
            case .spaceChange:
                self.window.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.update() }
            default:
                self.scheduleUpdate()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
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

    private var pad: CGFloat { config.focusRingWidth / 2 + 1 }

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
        guard current != nil, window.isVisible, !suspended else { return }
        window.orderFrontRegardless()
    }

    /// The focused window as the last snapshot saw it; the ring never asks Accessibility itself.
    var focusedWindow: () -> AXWindow? = { nil }

    func update() {
        guard !suspended, !hiddenForSystemReveal, config.focusRing else {
            current = nil
            window.orderOut(nil)
            return
        }
        guard let w = focusedWindow() else {
            // Electron apps briefly report no focused window while moving focus inside one; don't blink.
            if let id = current, let owner = CGWindowInfo.list(.optionOnScreenOnly).first(where: { $0.id == id }),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid { return }
            current = nil
            window.orderOut(nil)
            return
        }
        // An app can report a window it keeps alive after closing (ChatGPT) as focused; ring only what is visible.
        guard config.focusRingFloating || isTiled(w), let id = w.windowID, CGWindowInfo.isOnScreen(id),
              Spaces.spaces(of: id).allSatisfy(Spaces.isDesktop) else {
            current = nil
            window.orderOut(nil)
            return
        }
        present(id: id, frame: WindowServerEvents.bounds(of: id) ?? w.frame, floating: !isTiled(w))
    }

    private func present(id: CGWindowID, frame: CGRect, floating: Bool? = nil) {
        let floating = floating ?? !isTiledID(id)
        let wasHidden = !window.isVisible
        let targetChanged = current != id
        if current != id {
            current = id
            events.watch([id])
            onFocusChange?()
        }
        let color = config.ringColor(floating: floating)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius(for: id) + pad
        layer.borderWidth = config.focusRingWidth
        layer.borderColor = color.cgColor
        layer.backgroundColor = nil
        CATransaction.commit()
        place(frame: frame)
        // Above every normal window: the outline is drawn outside the window's frame, so it covers nothing of
        // the window itself, and it never has to chase the window's depth through raises and unhides.
        window.level = .floating
        if wasHidden || targetChanged {
            window.orderFrontRegardless()
            onReorder?()
        }
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
        guard window.frame != target else { return }
        if window.frame.size == target.size, window.isVisible,
           WindowServerEvents.move(CGWindowID(window.windowNumber), to: padded.origin) {
            return
        }
        window.setFrame(target, display: false, animate: false)
    }

    /// Called by the layout right as it moves the focused window, so the ring lands with the window, not after it.
    func anticipate(windowID: CGWindowID, frame: CGRect) {
        guard !suspended, config.focusRing, current == windowID, window.isVisible else { return }
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
