import BetterWMCore
import Cocoa

/// Covers the parking corner of a screen with a picture of it taken without the parked windows: their two points
/// and the shadows they throw disappear. Tiled windows reaching into the corner are cut out of it.
final class ParkingMatWindow: UnconstrainedWindow {
    /// Above every app window, under the ring, the tab strips and the buttons.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    /// How far from the corner the shadows of the parked windows reach.
    static let size: CGFloat = 64
    private let image = CALayer()
    private let mask = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Layer first, then wantsLayer: a layer-hosting view, whose layer AppKit leaves alone.
        let v = NSView()
        v.layer = image
        v.wantsLayer = true
        image.contentsGravity = .resize
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        image.mask = mask
        contentView = v
    }

    override var canBecomeKey: Bool { false }

    /// `area` in AX coordinates; `cutouts` are the tiled windows' frames with their corner radii; `wallpaper` the
    /// picture of the corner square.
    func show(area: CGRect, cutouts: [(CGRect, CGFloat)], wallpaper: CGImage) {
        let corner = CGRect(x: area.maxX - Self.size, y: area.maxY - Self.size, width: Self.size, height: Self.size)
        let frame = corner.toCocoa()
        if self.frame != frame { setFrame(frame, display: false) }
        image.contents = wallpaper
        func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - corner.minX, y: corner.maxY - r.maxY, width: r.width, height: r.height) }
        var path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        for (w, r) in cutouts where w.intersects(corner) {
            let l = local(w)
            let radius = min(r, l.width / 2, l.height / 2)
            path = path.subtracting(CGPath(roundedRect: l, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        mask.frame = CGRect(origin: .zero, size: frame.size)
        mask.path = path
        if !isVisible { orderFrontRegardless() }
    }

    func hide() { orderOut(nil) }
}
