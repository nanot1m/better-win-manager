import BetterWMCore
import Cocoa

/// The overview's desktop strip, slid in by a drag towards the top of the screen: the closer the cursor gets to
/// the edge, the further in it comes, exactly as the F3 overview draws and moves it. Dropping the window on a
/// desktop sends it there. The model comes from the manager's state and the last snapshot, so showing it costs
/// no Accessibility round trips.
final class DesktopDropStrip {
    private let manager: WindowManager
    private let panel: NSPanel
    private let view = StripHostView()
    private var screen: NSScreen?
    private var areaAX = CGRect.zero
    private var topInset: CGFloat = 0
    private var progress: CGFloat = 0
    /// The desktop under the cursor, if any; read on mouse-up.
    private(set) var target: Int?
    var isVisible: Bool { panel.isVisible }

    /// The strip is fully in once the cursor reaches where its bottom edge (labels included) will be, and starts
    /// to appear one strip height further down, so the cursor seems to pull it in.
    private func edges(for s: NSScreen) -> (near: CGFloat, far: CGFloat) {
        let bounds = CGRect(origin: .zero, size: s.frame.size)
        let strip = DesktopStripLayer.stripFrame(in: bounds, topInset: manager.system.topInset(s))
        let near = strip.maxY + 24 - manager.system.topInset(s)
        return (near, near + strip.height)
    }

    init(manager: WindowManager) {
        self.manager = manager
        panel = .overlay(level: .screenSaver, ignoresMouse: true)
        panel.contentView = view
    }

    /// `p` in AX coordinates. Slides the strip in and out with the cursor's distance from the top of its screen
    /// and tracks the tile under the cursor once the strip is mostly in.
    func update(cursor p: CGPoint, dragging id: WindowID?) {
        guard manager.config.dragToDesktops else { return }
        guard let s = screen.flatMap({ $0.frame.toCocoa().contains(p) ? $0 : nil })
            ?? NSScreen.screens.first(where: { $0.frame.toCocoa().contains(p) }) else { hide(); return }
        let top = s.frame.toCocoa().minY + manager.system.topInset(s)
        let distance = p.y - top
        let (near, far) = edges(for: s)
        let wanted = min(1, max(0, (far - distance) / (far - near)))
        guard wanted > 0 else { hide(); return }
        if screen != s || !panel.isVisible { show(on: s, excluding: id) }
        set(progress: wanted)
        let local = CGPoint(x: p.x - areaAX.minX, y: p.y - areaAX.minY)
        let i = progress >= 0.8 ? view.strip.index(at: local) : nil
        let hovered = i.map(view.strip.desktop(forPreview:))
        if hovered != target {
            target = hovered
            view.strip.setTarget(i)
        }
    }

    private func show(on s: NSScreen, excluding dragged: WindowID?) {
        screen = s
        target = nil
        areaAX = s.frame.toCocoa()
        topInset = manager.system.topInset(s)
        var model = Overview.model(manager: manager, screen: s)
        // The window in hand is not sitting on its desktop right now.
        model = OverviewModel(desktops: model.desktops.map { d in
            OverviewModel.Desktop(index: d.index, windows: d.windows.filter { $0.id != dragged })
        }, current: model.current)
        let stripFrame = DesktopStripLayer.stripFrame(in: CGRect(origin: .zero, size: areaAX.size), topInset: topInset)
        let hostAX = CGRect(x: areaAX.minX, y: areaAX.minY, width: areaAX.width, height: stripFrame.maxY + 40)
        panel.setFrame(hostAX.toCocoa(), display: false)
        view.screenBounds = CGRect(origin: .zero, size: areaAX.size)
        view.topInset = topInset
        view.strip.configure(desktops: model.desktops, current: model.current?.index, screenSize: areaAX.size, scale: s.backingScaleFactor)
        progress = 0
        view.layoutStrip(progress: 0)
        panel.orderFrontRegardless()
        let ids = model.desktops.flatMap(\.windows).filter { !(NSRunningApplication(processIdentifier: $0.window.pid)?.isHidden ?? false) }.map(\.id)
        Thumbnails.refresh(ids) { [weak self] id, image in self?.view.strip.setThumbnail(image, for: id) }
        Log.write("drag", "desktop strip on \(WindowManager.displayID(s).prefix(8)): \(model.desktops.count) desktop(s)")
    }

    private func set(progress p: CGFloat) {
        guard p != progress else { return }
        progress = p
        view.layoutStrip(progress: p)
    }

    /// Dev aid: the strip fully in on the main screen, hovering the second tile.
    func preview() {
        guard let s = NSScreen.screens.first else { return }
        let top = s.frame.toCocoa().minY + manager.system.topInset(s)
        update(cursor: CGPoint(x: s.frame.midX, y: top + 10), dragging: nil)
        guard let f = view.strip.frame(ofPreview: 1) else { return }
        update(cursor: CGPoint(x: areaAX.minX + f.midX, y: areaAX.minY + f.midY), dragging: nil)
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
        progress = 0
        panel.orderOut(nil)
    }
}

/// Hosts the shared strip layer in the top part of the screen, in the same coordinates the overview uses.
private final class StripHostView: NSView {
    let strip = DesktopStripLayer()
    var screenBounds = CGRect.zero
    var topInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(strip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func layoutStrip(progress: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = CGRect(origin: .zero, size: screenBounds.size)
        CATransaction.commit()
        strip.layout(in: screenBounds, topInset: topInset, progress: progress)
    }
}
