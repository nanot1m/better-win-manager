import Cocoa

final class FocusRing {
    private let window: NSWindow
    private let view = RingView()
    private var config: Config
    private var timer: Timer?

    init(config: Config) {
        self.config = config
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Bound to the current desktop so it slides away with it during a switch instead of floating over the transition.
        window.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.update() }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.window.orderOut(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.update() }
        }
        // AX notifications are occasionally dropped; a slow poll keeps the ring honest.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    func apply(_ config: Config) {
        self.config = config
        update()
    }

    func update() {
        guard config.focusRing, let w = AXWindow.focused, w.isValid, Spaces.visibleWindows().contains(w) else {
            window.orderOut(nil)
            return
        }
        let pad = config.focusRingStyle == .underneath ? config.focusRingWidth : config.focusRingWidth / 2 + 1
        let frame = w.frame.insetBy(dx: -pad, dy: -pad).toCocoa()
        view.style = config.focusRingStyle
        view.width = config.focusRingWidth
        view.radius = config.focusRingRadius + pad
        view.color = NSColor(hex: config.focusRingColor) ?? .controlAccentColor
        window.setFrame(frame, display: true)
        view.needsDisplay = true
        if config.focusRingStyle == .underneath, let id = w.windowID {
            window.level = .normal
            window.order(.below, relativeTo: Int(id))
        } else {
            window.level = .floating
            window.orderFrontRegardless()
        }
    }
}

private final class RingView: NSView {
    var style: Config.FocusRingStyle = .outline
    var width: CGFloat = 3
    var radius: CGFloat = 10
    var color: NSColor = .controlAccentColor

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .outline:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        case .underneath:
            color.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
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
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
