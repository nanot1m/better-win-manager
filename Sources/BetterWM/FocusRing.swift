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
    /// While the user drags a window the ring hides instead of chasing every mouse event; it returns on drop.
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
            case .windowMove, .windowResize:
                guard !self.suspended else { return }
                // Cheap path: the focused window moved; just follow it without re-resolving focus.
                if wid == self.current, let id = wid, let f = WindowServerEvents.bounds(of: id) { self.place(frame: f) } else { self.update() }
            case .spaceChange:
                self.window.orderOut(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.update() }
            default:
                self.update()
            }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
        // Safety net only; WindowServer events do the real work.
        timer = Timer.scheduledTimer(withTimeInterval: WindowServerEvents.available ? 1.0 : 0.1, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func apply(_ config: Config) {
        self.config = config
        update()
    }

    private var pad: CGFloat { config.focusRingStyle == .underneath ? config.focusRingWidth : config.focusRingWidth / 2 + 1 }

    func update() {
        guard !suspended, config.focusRing, let w = AXWindow.focused, config.focusRingFloating || isTiled(w), let id = w.windowID else {
            current = nil
            window.orderOut(nil)
            return
        }
        if current != id {
            current = id
            events.watch([id])
        }
        let color = NSColor(hex: config.focusRingColor) ?? .controlAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius(for: id) + pad
        if config.focusRingStyle == .outline {
            layer.borderWidth = config.focusRingWidth
            layer.borderColor = color.cgColor
            layer.backgroundColor = nil
        } else {
            layer.borderWidth = 0
            layer.backgroundColor = color.cgColor
        }
        CATransaction.commit()
        place(frame: WindowServerEvents.bounds(of: id) ?? w.frame)
        if config.focusRingStyle == .underneath {
            window.level = .normal
            window.order(.below, relativeTo: Int(id))
        } else {
            window.level = .floating
            window.orderFrontRegardless()
        }
    }

    private func radius(for id: CGWindowID) -> CGFloat {
        guard config.focusRingAutoRadius else { return config.focusRingRadius }
        if let r = radiusCache[id] { return r }
        let r = WindowServerEvents.cornerRadius(of: id) ?? config.focusRingRadius
        radiusCache[id] = r
        return r
    }

    /// `frame` in AX (top-left origin) coordinates.
    private func place(frame: CGRect) {
        let target = frame.insetBy(dx: -pad, dy: -pad).toCocoa()
        if window.frame != target { window.setFrame(target, display: false, animate: false) }
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
