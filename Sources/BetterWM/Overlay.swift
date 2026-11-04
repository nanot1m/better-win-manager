import BetterWMCore
import Cocoa

/// A borderless window placed wherever we say. AppKit otherwise keeps a window's top below the menu bar area,
/// which shifts an overlay drawn around a window that reaches the top of the screen.
class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class ZoneOverlay: UnconstrainedWindow {
    private let view = ZoneView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = view
    }

    /// `rect` in AX (top-left origin) coordinates.
    func show(zone rect: CGRect?) {
        guard let rect else { view.rect = nil; view.needsDisplay = true; return }
        let cocoaRect = rect.toCocoa()
        if let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaRect) }) {
            if frame != targetScreen.frame { setFrame(targetScreen.frame, display: false) }
        }
        view.rect = convertFromScreen(cocoaRect)
        view.needsDisplay = true
        if !isVisible { orderFrontRegardless() }
    }

    func hide() { view.rect = nil; orderOut(nil) }
}

private final class ZoneView: NSView {
    var rect: NSRect?
    override func draw(_ dirtyRect: NSRect) {
        guard let rect else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}


extension CGRect {
    /// AX top-left-origin <-> Cocoa bottom-left-origin; the transform is its own inverse.
    func toCocoa() -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}

extension CGPoint {
    func toAX() -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        return CGPoint(x: x, y: h - y)
    }
}

extension NSPanel {
    /// Borderless, transparent, never takes focus, on every space.
    static func overlay(level: NSWindow.Level, shadow: Bool = false, ignoresMouse: Bool = false,
                        behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = level
        p.hasShadow = shadow
        p.ignoresMouseEvents = ignoresMouse
        p.animationBehavior = .none
        p.collectionBehavior = behavior
        return p
    }
}

enum Tween {
    /// Ease-out cubic (or linear) from 0 to 1 over `duration`; runs during event tracking too.
    @discardableResult
    static func run(duration: TimeInterval, linear: Bool = false, step: @escaping (CGFloat) -> Void, done: @escaping () -> Void = {}) -> Timer {
        let start = Date()
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { t in
            let x = min(1, Date().timeIntervalSince(start) / max(0.01, duration))
            step(CGFloat(linear ? x : 1 - pow(1 - x, 3)))
            if x >= 1 { t.invalidate(); done() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
