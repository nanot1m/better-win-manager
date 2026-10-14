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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = view
    }

    /// `rect` in AX (top-left origin) coordinates.
    func show(zone rect: CGRect?) {
        guard let rect else { view.rect = nil; view.needsDisplay = true; return }
        view.rect = convertFromScreen(rect.toCocoa())
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
        level = .floating
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        contentView = HandleView()
        (contentView as! HandleView).onDrag = { [weak self] p in self?.onDrag?(p) }
        (contentView as! HandleView).onDragEnd = { [weak self] in self?.onDragEnd?() }
    }

    override var canBecomeKey: Bool { false }
}

private final class HandleView: NSView {
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var isVertical = true
    private var hover = false
    private var cursor: NSCursor { isVertical ? .resizeLeftRight : .resizeUpDown }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true; cursor.set() }
    // Non-key floating windows lose cursor push/pop state, so re-assert on every move.
    override func mouseMoved(with e: NSEvent) { cursor.set() }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseDown(with e: NSEvent) { hover = true; needsDisplay = true; cursor.set() }
    override func mouseDragged(with e: NSEvent) { cursor.set(); onDrag?(NSEvent.mouseLocation.toAX()) }
    override func mouseUp(with e: NSEvent) { onDragEnd?() }
    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.6).setFill()
        let inset = isVertical ? CGSize(width: 1, height: 0) : CGSize(width: 0, height: 1)
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset.width, dy: inset.height), xRadius: 3, yRadius: 3).fill()
    }
}

extension CGRect {
    /// AX top-left-origin <-> Cocoa bottom-left-origin; the transform is its own inverse.
    func toCocoa() -> CGRect {
        let h = NSScreen.screens[0].frame.height
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}

extension CGPoint {
    func toAX() -> CGPoint {
        CGPoint(x: x, y: NSScreen.screens[0].frame.height - y)
    }
}
