import BetterWMCore
import Cocoa

/// Appears along the top of the screen while a window is dragged up to its edge: one tile per desktop of that
/// screen, plus one for a new desktop. Dropping the window on a tile sends it there. Frames come from the
/// manager's own state and the last snapshot, so showing it costs no Accessibility round trips.
final class DesktopDropStrip {
    private let manager: WindowManager
    private let panel: NSPanel
    private let view = StripView()
    /// AX frames of the tiles on screen, with the desktop each stands for.
    private var tiles: [(frame: CGRect, desktop: Int)] = []
    private var screen: NSScreen?
    /// The desktop under the cursor, if any; read on mouse-up.
    private(set) var target: Int?
    var isVisible: Bool { panel.isVisible }

    private static let height: CGFloat = 104
    /// How far from the top edge the strip appears, and how far below it the cursor may go before it hides.
    private static let showWithin: CGFloat = 12
    private static let hideBeyond: CGFloat = 48

    init(manager: WindowManager) {
        self.manager = manager
        panel = .overlay(level: .screenSaver, ignoresMouse: true)
        panel.contentView = view
    }

    /// `p` in AX coordinates. Shows the strip when the cursor reaches the top of its screen, follows the cursor
    /// over the tiles, and hides it once the cursor has moved well below.
    func update(cursor p: CGPoint, dragging id: WindowID?) {
        guard manager.config.dragToDesktops else { return }
        if let screen, panel.isVisible {
            let bottom = (tiles.map(\.frame.maxY).max() ?? 0) + Self.hideBeyond
            guard screen.frame.toCocoa().contains(p), p.y <= bottom else { hide(); return }
            let hovered = tiles.first { $0.frame.insetBy(dx: -6, dy: -6).contains(p) }?.desktop
            if hovered != target {
                target = hovered
                view.highlight(tiles.firstIndex { $0.desktop == hovered })
            }
            return
        }
        guard let s = NSScreen.screens.first(where: { $0.frame.toCocoa().contains(p) }) else { return }
        let top = s.frame.toCocoa().minY + manager.system.topInset(s)
        guard p.y <= top + Self.showWithin else { return }
        show(on: s, excluding: id)
    }

    private func show(on s: NSScreen, excluding dragged: WindowID?) {
        screen = s
        target = nil
        let area = s.frame.toCocoa()
        let inset = manager.system.topInset(s)
        var desktops = manager.desktopList(on: s)
        // Room for one more, as long as the hotkeys can still reach it.
        let newDesktop = manager.desktopCount < 9 ? manager.desktopCount : nil
        if let newDesktop { desktops.append(newDesktop) }
        let h = Self.height, w = (h * area.width / max(1, area.height)).rounded(), gap: CGFloat = 14
        let total = CGFloat(desktops.count) * w + CGFloat(desktops.count - 1) * gap
        let x0 = area.midX - total / 2, y = area.minY + inset + 10
        tiles = desktops.enumerated().map { i, d in (CGRect(x: x0 + CGFloat(i) * (w + gap), y: y, width: w, height: h), d) }
        let stripAX = CGRect(x: area.minX, y: y - 10, width: area.width, height: h + 20)
        panel.setFrame(stripAX.toCocoa(), display: false)
        let shown = manager.shownDesktop(on: s)
        let models = desktops.map { d -> StripView.Tile in
            let items = d == newDesktop ? [] : manager.previewItems(desktop: d).filter { $0.id != dragged }
            return StripView.Tile(label: d == newDesktop ? "+" : "\(d + 1)", isCurrent: d == shown, isNew: d == newDesktop,
                                  windows: items.map { ($0.pid, CGRect(x: $0.frame.minX - area.minX, y: $0.frame.minY - area.minY,
                                                                      width: $0.frame.width, height: $0.frame.height)) })
        }
        view.configure(tiles: models, frames: tiles.map { CGRect(x: $0.frame.minX - stripAX.minX, y: $0.frame.minY - stripAX.minY,
                                                                 width: $0.frame.width, height: $0.frame.height) },
                       screenSize: area.size, scale: s.backingScaleFactor)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        Log.write("drag", "desktop strip on \(WindowManager.displayID(s).prefix(8)): desktops \(desktops.map { $0 + 1 })")
    }

    /// Dev aid: shows the strip on the main screen as a drag to its top edge would, hovering the second tile.
    func preview() {
        guard let s = NSScreen.screens.first else { return }
        let top = s.frame.toCocoa().minY + manager.system.topInset(s)
        update(cursor: CGPoint(x: s.frame.midX, y: top + 2), dragging: nil)
        if tiles.count > 1 { update(cursor: CGPoint(x: tiles[1].frame.midX, y: tiles[1].frame.midY), dragging: nil) }
    }

    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func hide() {
        guard panel.isVisible else { return }
        target = nil
        screen = nil
        panel.orderOut(nil)
    }
}

private final class StripView: NSView {
    struct Tile {
        let label: String
        let isCurrent: Bool
        let isNew: Bool
        /// Window frames relative to the screen's top-left, in points.
        let windows: [(pid: pid_t, frame: CGRect)]
    }

    private var layers: [CALayer] = []
    private var highlighted: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// `frames` are in this view's (flipped, top-left) coordinates.
    func configure(tiles: [Tile], frames: [CGRect], screenSize: CGSize, scale: CGFloat) {
        layers.forEach { $0.removeFromSuperlayer() }
        layers = []
        highlighted = nil
        for (t, f) in zip(tiles, frames) {
            let l = CALayer()
            l.frame = f
            l.contentsScale = scale
            l.backgroundColor = NSColor(white: t.isNew ? 0.1 : 0.16, alpha: 0.92).cgColor
            l.cornerRadius = 8
            l.borderWidth = t.isCurrent ? 2.5 : 1.5
            l.borderColor = (t.isCurrent ? NSColor.white : NSColor.white.withAlphaComponent(0.3)).cgColor
            l.shadowOpacity = 0.5
            l.shadowRadius = 10
            l.shadowOffset = CGSize(width: 0, height: 4)
            let s = f.width / max(1, screenSize.width)
            for w in t.windows.reversed() {
                let tile = CALayer()
                tile.frame = CGRect(x: w.frame.minX * s, y: w.frame.minY * s, width: w.frame.width * s, height: w.frame.height * s)
                tile.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
                tile.cornerRadius = 2
                tile.masksToBounds = true
                tile.contentsScale = scale
                if let icon = NSRunningApplication(processIdentifier: w.pid)?.icon {
                    let i = CALayer()
                    let side = min(tile.bounds.width, tile.bounds.height) * 0.6
                    i.frame = CGRect(x: tile.bounds.midX - side / 2, y: tile.bounds.midY - side / 2, width: side, height: side)
                    i.contents = icon
                    i.contentsGravity = .resizeAspect
                    i.contentsScale = scale
                    tile.addSublayer(i)
                }
                l.addSublayer(tile)
            }
            let label = CATextLayer()
            label.string = t.label
            label.fontSize = t.isNew ? 26 : 13
            label.font = NSFont.systemFont(ofSize: label.fontSize, weight: t.isNew ? .light : .semibold)
            label.foregroundColor = NSColor.white.withAlphaComponent(t.isNew ? 0.6 : 0.9).cgColor
            label.alignmentMode = .center
            label.contentsScale = scale
            let lh = label.fontSize + 6
            label.frame = t.isNew ? CGRect(x: 0, y: f.height / 2 - lh / 2, width: f.width, height: lh)
                                  : CGRect(x: 0, y: f.height - lh - 4, width: f.width, height: lh)
            l.addSublayer(label)
            layer?.addSublayer(l)
            layers.append(l)
        }
    }

    func highlight(_ index: Int?) {
        guard index != highlighted else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        if let old = highlighted, layers.indices.contains(old) {
            layers[old].transform = CATransform3DIdentity
            layers[old].backgroundColor = NSColor(white: 0.16, alpha: 0.92).cgColor
        }
        if let new = index, layers.indices.contains(new) {
            layers[new].transform = CATransform3DMakeScale(1.08, 1.08, 1)
            layers[new].backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        }
        CATransaction.commit()
        highlighted = index
    }
}
