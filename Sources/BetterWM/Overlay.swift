import BetterWMCore
import Cocoa

final class ZoneOverlay: NSWindow {
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

final class HandleWindow: NSWindow {
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var isVertical: Bool {
        get { (contentView as! HandleView).isVertical }
        set { (contentView as! HandleView).isVertical = newValue }
    }

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // Normal level: floating windows must cover the handles, which only need to show in the gaps between tiles.
        level = .normal
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = HandleView()
        (contentView as! HandleView).onDrag = { [weak self] p in self?.onDrag?(p) }
        (contentView as! HandleView).onDragEnd = { [weak self] in self?.onDragEnd?() }
    }

    override var canBecomeKey: Bool { false }

    /// Dev aid: renders the handle in a given state to PNG.
    func snapshot(hover: Bool, dragging: Bool, to path: String) {
        let v = contentView as! HandleView
        v.preview(hover: hover, dragging: dragging)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private final class HandleView: NSView {
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var isVertical = true
    private var hover = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }
    private var cursor: NSCursor { isVertical ? .resizeLeftRight : .resizeUpDown }

    func preview(hover: Bool, dragging: Bool) { self.hover = hover; self.dragging = dragging }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hover = true; cursor.set() }
    // Non-key floating windows lose cursor push/pop state, so re-assert on every move.
    override func mouseMoved(with e: NSEvent) { cursor.set() }
    override func mouseExited(with e: NSEvent) { hover = false; if !dragging { NSCursor.arrow.set() } }
    override func mouseDown(with e: NSEvent) { dragging = true; cursor.set() }
    override func mouseDragged(with e: NSEvent) { cursor.set(); onDrag?(NSEvent.mouseLocation.toAX()) }
    override func mouseUp(with e: NSEvent) {
        dragging = false
        if !hover { NSCursor.arrow.set() }
        onDragEnd?()
    }

    /// A short grip pill centred in the gap, like a trackpad divider: visible on hover, solid while dragging.
    override func draw(_ dirtyRect: NSRect) {
        guard hover || dragging else { return }
        let thickness: CGFloat = dragging ? 5 : 4
        let length = min(56, (isVertical ? bounds.height : bounds.width) * 0.4)
        let pill = isVertical
            ? NSRect(x: bounds.midX - thickness / 2, y: bounds.midY - length / 2, width: thickness, height: length)
            : NSRect(x: bounds.midX - length / 2, y: bounds.midY - thickness / 2, width: length, height: thickness)
        let path = NSBezierPath(roundedRect: pill, xRadius: thickness / 2, yRadius: thickness / 2)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: pill.insetBy(dx: -1, dy: -1), xRadius: thickness / 2 + 1, yRadius: thickness / 2 + 1).fill()
        (dragging ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.75)).setFill()
        path.fill()
        if dragging {
            // Faint full-length guide so the boundary being moved is obvious.
            let guide = isVertical
                ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
                : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            guide.fill()
        }
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
