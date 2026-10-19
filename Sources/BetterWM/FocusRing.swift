import BetterWMCore
import Cocoa
import QuartzCore

final class FocusRing {
    private let window: NSWindow
    private let layer = CALayer()
    private var config: Config
    private var timer: Timer?
    private let events = WindowServerEvents()
    private var current: CGWindowID?
    /// Corner radii rarely change for a window's lifetime, so one measurement per window ID is enough.
    private var radiusCache: [CGWindowID: CGFloat] = [:]
    /// Floating windows get a ring only when `focusRingFloating` is set; skipping them keeps drags cheap.
    var isTiled: (AXWindow) -> Bool = { _ in true }
    /// Same question by window ID, for callers that only have one (workspace switches, re-measures).
    var isTiledID: (CGWindowID) -> Bool = { _ in true }
    /// Fired after the ring window is (re)ordered so dependants like the gap handles can stack above it.
    var onReorder: (() -> Void)?
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
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        // Bound to the current desktop so it slides away with it during a switch instead of floating over the transition.
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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

    /// Puts the ring back directly beneath its window. Needed after the window is raised or its app unhidden,
    /// since both change the window's depth while the ring keeps its old one.
    func reorder() {
        guard let id = current, window.isVisible, !suspended else { return }
        window.order(.below, relativeTo: Int(id))
    }

    func update() {
        guard !suspended, !hiddenForSystemReveal, config.focusRing else {
            current = nil
            window.orderOut(nil)
            return
        }
        guard let w = AXWindow.focused else {
            // Electron apps briefly report no focused window while moving focus inside one; don't blink.
            if let id = current, let owner = Spaces.visibleWindows().first(where: { $0.windowID == id }),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.pid { return }
            current = nil
            window.orderOut(nil)
            return
        }
        guard config.focusRingFloating || isTiled(w), let id = w.windowID,
              !Spaces.spaces(of: id).contains(where: Spaces.isFullscreen) else {
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
        }
        let tiledColor = NSColor(hex: config.focusRingColor) ?? .controlAccentColor
        let color = floating && config.focusRingFloatingColor.lowercased() != "same"
            ? (NSColor(hex: config.focusRingFloatingColor) ?? tiledColor) : tiledColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius(for: id) + pad
        layer.borderWidth = config.focusRingWidth
        layer.borderColor = color.cgColor
        layer.backgroundColor = nil
        CATransaction.commit()
        place(frame: frame)
        // Always just beneath the window it belongs to: the outline is drawn outside the window's frame so it
        // stays visible, clicks that raise the window never put it on the wrong side, and a re-order (which
        // flashes) is needed only when the target changes.
        window.level = .normal
        if wasHidden || targetChanged {
            window.order(.below, relativeTo: Int(id))
            onReorder?()
        }
    }

    private func radius(for id: CGWindowID) -> CGFloat {
        guard config.focusRingAutoRadius else { return config.focusRingRadius }
        if let r = radiusCache[id] { return r }
        let r = WindowServerEvents.cornerRadius(of: id) ?? config.focusRingRadius
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
