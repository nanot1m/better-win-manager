import BetterWMCore
import Cocoa
import QuartzCore

/// Mission Control for virtual desktops: a strip of every desktop along the top and the current desktop's windows
/// spread out below. `progress` runs 0 (closed, previews sit exactly over the real windows) to 1 (open), so a
/// trackpad gesture can scrub it; the key and the action animate it.
final class Overview {
    private let manager: WindowManager
    private let panel: NSPanel
    private let view = OverviewView()
    private var monitors: [Any] = []
    private var animator: Timer?
    /// Previews are recaptured while open so playing video and typing stay live; parked windows are on screen
    /// too (just in the corner), only hidden apps keep their last look.
    private var liveTimer: Timer?
    private var liveIDs: [WindowID] = []
    private(set) var progress: CGFloat = 0
    var isOpen: Bool { panel.isVisible && progress > 0 }
    /// Progress the current gesture started from, so a swipe down on an open overview scrubs it closed.
    private var gestureStart: CGFloat = 0

    init(manager: WindowManager) {
        self.manager = manager
        panel = .overlay(level: .screenSaver)
        panel.contentView = view
        view.onPickWindow = { [weak self] item in self?.pick(item) }
        view.onPickDesktop = { [weak self] d in self?.pickDesktop(d) }
        view.onDropWindow = { [weak self] item, d in self?.drop(item, onto: d) }
        view.onBackdrop = { [weak self] in self?.animate(to: 0) }
    }

    // MARK: Driving

    func toggle() { animate(to: isOpen ? 0 : 1) }

    func gestureBegan() {
        animator?.invalidate()
        if !panel.isVisible { present() }
        gestureStart = progress
    }

    /// `delta` is the gesture's travel as a fraction of the distance that fully opens the overview; up is positive.
    func gestureChanged(_ delta: CGFloat) {
        guard panel.isVisible else { return }
        set(progress: min(1, max(0, gestureStart + delta)))
    }

    func gestureEnded(velocity: CGFloat) {
        guard panel.isVisible else { return }
        let target: CGFloat = abs(velocity) > 0.8 ? (velocity > 0 ? 1 : 0) : (progress > 0.5 ? 1 : 0)
        animate(to: target)
    }

    // MARK: Horizontal swipe while open

    private var hAnimator: Timer?
    private var hOffset: CGFloat = 0

    func horizontalBegan() {
        guard isOpen else { return }
        hAnimator?.invalidate()
        hOffset = 0
        view.beginHorizontal()
    }

    /// `travel` in desktops, negative to the left (the next desktop comes in from the right).
    func horizontalChanged(_ travel: CGFloat) {
        guard isOpen else { return }
        var t = travel
        if t < 0, !view.hasNeighbour(1) { t *= 0.25 }
        if t > 0, !view.hasNeighbour(-1) { t *= 0.25 }
        hOffset = t * view.bounds.width
        view.horizontalOffset = hOffset
    }

    func horizontalEnded(velocity: CGFloat) {
        guard isOpen else { return }
        let w = view.bounds.width
        let travel = hOffset / w
        var target = 0
        if (velocity < -1.2 || travel < -0.5), view.hasNeighbour(1) { target = 1 }
        if (velocity > 1.2 || travel > 0.5), view.hasNeighbour(-1) { target = -1 }
        let destination = (manager.currentDesktop ?? 0) + target
        if target != 0 { manager.switchDesktop(destination) }
        let from = hOffset, to = CGFloat(-target) * w
        let duration = max(0.12, 0.3 * Double(abs(to - from) / w))
        hAnimator?.invalidate()
        hAnimator = Tween.run(duration: duration, step: { [weak self] e in
            guard let self else { return }
            self.hOffset = from + (to - from) * e
            self.view.horizontalOffset = self.hOffset
        }, done: { [weak self] in
            guard let self else { return }
            self.hAnimator = nil
            // The new current's layers land exactly where the neighbour's were drawn, so the swap is seamless.
            self.view.endHorizontal()
            if target != 0 { self.refresh() }
        })
    }

    private func animate(to target: CGFloat) {
        animator?.invalidate()
        if target > 0, !panel.isVisible { present() }
        let from = progress
        guard from != target else { if target == 0 { dismiss() }; return }
        animator = Tween.run(duration: 0.28 * Double(abs(target - from)), step: { [weak self] e in
            self?.set(progress: from + (target - from) * e)
        }, done: { [weak self] in
            self?.animator = nil
            if target == 0 { self?.dismiss() }
        })
    }

    /// Fires when `isOpen` flips; the event tap swallows scrolling while the overview is open.
    var onOpenChange: (() -> Void)?
    private func set(progress p: CGFloat) {
        let was = isOpen
        progress = p
        view.progress = p
        if isOpen != was { onOpenChange?() }
    }

    // MARK: Presentation

    private func present() {
        guard let screen = NSScreen.screens.first else { return }
        let model = Overview.model(manager: manager, screen: screen)
        panel.setFrame(screen.frame, display: false)
        // The screen as it is right now becomes the backdrop: the real windows are covered from the first frame
        // and the previews lift off a still image, as in Mission Control. A blurred copy fades in with progress.
        let screenAX = screen.frame.toCocoa()
        let shot = Overview.captureBackdrop(screenAX, topInset: manager.system.topInset(screen))
        if shot == nil { Log.write("overview", "backdrop capture failed; is Screen Recording allowed?") }
        view.setBackground(sharp: shot, blurred: nil)
        if let shot {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let blurred = Overview.blur(shot)
                DispatchQueue.main.async { self?.view.setBackground(sharp: shot, blurred: blurred) }
            }
        }
        view.configure(model: model, screenAX: screen.frame.toCocoa(), topInset: manager.system.topInset(screen))
        set(progress: 0)
        panel.orderFrontRegardless()
        manager.focusRing.suspended = true
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.animate(to: 0) }
        } as Any)
        if let lm = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { self?.animate(to: 0); return nil }
            return e
        }) { monitors.append(lm) }
        startLive(model)
    }

    private func startLive(_ model: OverviewModel) {
        liveIDs = model.desktops.flatMap { $0.windows }.filter { !(NSRunningApplication(processIdentifier: $0.window.pid)?.isHidden ?? false) }.map(\.id)
        liveTimer?.invalidate()
        let tick = { [weak self] in
            guard let self else { return }
            Thumbnails.refresh(self.liveIDs) { [weak self] id, image in self?.view.setThumbnail(image, for: id) }
        }
        tick()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in tick() }
    }

    private func dismiss() {
        liveTimer?.invalidate()
        liveTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        let was = isOpen
        panel.orderOut(nil)
        set(progress: 0)
        if was { onOpenChange?() }
        manager.focusRing.suspended = false
    }

    /// A desktop switch while open (hotkey, bar chip) is shown in place; the user closes when done.
    func desktopChanged() {
        guard panel.isVisible, animator == nil, hAnimator == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refresh()
        }
    }

    /// Rebuilds the model in place (after a switch or a move) so the open overview reflects it.
    private func refresh() {
        guard let screen = NSScreen.screens.first else { return }
        let model = Overview.model(manager: manager, screen: screen)
        view.configure(model: model, screenAX: screen.frame.toCocoa(), topInset: manager.system.topInset(screen))
        view.progress = progress
        startLive(model)
    }

    /// Every desktop with its windows as the strip shows them; shared with the drag-to-desktop strip.
    static func model(manager: WindowManager, screen: NSScreen) -> OverviewModel {
        let current = manager.currentDesktop ?? 0
        var desktops: [OverviewModel.Desktop] = []
        let byDesktop = Dictionary(uniqueKeysWithValues: manager.windowsByDesktop().map { ($0.desktop, $0.windows) })
        // Front to back, so overlapping windows (stacked layout, floating ones) draw in their real depth order.
        let depth = Dictionary(uniqueKeysWithValues: manager.frontToBack.enumerated().map { ($1, $0) })
        for d in 0..<max(manager.desktopCount, current + 1) {
            // On an inactive desktop the window that was focused there comes first: parking and hiding shuffle
            // the real z-order, and that is the one the user left on top.
            let top = d == current ? nil : manager.lastFocusedWindow(onDesktop: d)
            func rank(_ w: AXWindow) -> Int { let id = w.windowID ?? 0; return id == top ? -1 : (depth[id] ?? .max) }
            let windows = (byDesktop[d] ?? []).sorted { rank($0) < rank($1) }.compactMap { w -> OverviewModel.Window? in
                guard let id = w.windowID else { return nil }
                // The current desktop shows windows where they are; others where they would be when shown.
                let frame = d == current ? w.frame : (manager.layoutFrame(of: w) ?? w.frame)
                let app = NSRunningApplication(processIdentifier: w.pid)
                var item = OverviewModel.Window(window: w, id: id, desktop: d, frame: frame, title: w.title,
                                                icon: app?.icon, thumbnail: Thumbnails.cached(id))
                item.radius = manager.config.ringRadius(for: id)
                return item
            }
            desktops.append(OverviewModel.Desktop(index: d, windows: windows))
        }
        var model = OverviewModel(desktops: desktops, current: desktops.first { $0.index == current })
        if manager.config.focusRing, let f = manager.system.focused, let id = f.windowID {
            let tiled = manager.isTiled(f)
            model.focused = id
            model.ringColor = manager.config.ringColor(floating: !tiled)
            model.ringWidth = manager.config.focusRingWidth
        }
        return model
    }

    // MARK: Interaction

    private func pick(_ item: OverviewModel.Window) {
        manager.activate(item.window, onDesktop: item.desktop)
        animate(to: 0)
    }

    private func pickDesktop(_ d: Int) {
        if d != manager.currentDesktop {
            manager.switchDesktop(d)
            // Closing then plays the new desktop's windows growing into place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh(); self?.animate(to: 0) }
        } else {
            animate(to: 0)
        }
    }

    private func drop(_ item: OverviewModel.Window, onto d: Int) {
        guard d != item.desktop else { refresh(); return }
        manager.send(item.window, toDesktop: d)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    /// The screen without its windows: wallpaper and desktop icons (everything below the back-most window),
    /// with our own bar drawn back on top. The windows themselves are drawn as previews, so they visibly lift off.
    private static var backdropCache: (at: Date, area: CGRect, topInset: CGFloat, image: CGImage)?

    static func captureBackdrop(_ area: CGRect, topInset: CGFloat) -> CGImage? {
        // The wallpaper hardly changes; a gesture must not pay for it every time.
        if let c = backdropCache, c.area == area, c.topInset == topInset, Date().timeIntervalSince(c.at) < 60 { return c.image }
        let image = captureBackdropNow(area, topInset: topInset)
        if let image { backdropCache = (Date(), area, topInset, image) }
        return image
    }

    private static func captureBackdropNow(_ area: CGRect, topInset: CGFloat) -> CGImage? {
        let list = CGWindowInfo.list(.optionOnScreenOnly)
        guard !list.isEmpty else { return nil }
        let backmost = list.last { $0.layer >= 0 }?.id
        let bar = list.filter { $0.pid == getpid() && $0.bounds.maxY <= area.minY + topInset + 1 }
        let wallpaper = backmost.flatMap { CGWindowListCreateImage(area, .optionOnScreenBelowWindow, $0, [.bestResolution]) }
            ?? CGWindowListCreateImage(area, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        guard let wallpaper else { return nil }
        guard !bar.isEmpty, let ctx = CGContext(data: nil, width: wallpaper.width, height: wallpaper.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return wallpaper }
        let scale = CGFloat(wallpaper.width) / area.width
        ctx.draw(wallpaper, in: CGRect(x: 0, y: 0, width: wallpaper.width, height: wallpaper.height))
        for info in bar.reversed() {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, info.id, [.bestResolution, .boundsIgnoreFraming]) else { continue }
            let b = info.bounds
            let x = (b.minX - area.minX) * scale, w = b.width * scale, h = b.height * scale
            let yTop = (b.minY - area.minY) * scale
            ctx.draw(img, in: CGRect(x: x, y: CGFloat(wallpaper.height) - yTop - h, width: w, height: h))
        }
        return ctx.makeImage() ?? wallpaper
    }

    private static func blur(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(28, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage else { return nil }
        return CIContext().createCGImage(out, from: input.extent)
    }

    /// Dev aid: writes the open overview to `path`.
    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

struct OverviewModel {
    struct Window {
        let window: AXWindow
        let id: WindowID
        let desktop: Int
        /// AX coordinates.
        let frame: CGRect
        let title: String
        let icon: NSImage?
        var thumbnail: NSImage?
        /// The window's own corner radius, so the preview starts out looking exactly like it.
        var radius: CGFloat = 10
    }
    struct Desktop {
        let index: Int
        let windows: [Window]
    }
    let desktops: [Desktop]
    let current: Desktop?
    var focused: WindowID?
    var ringColor: NSColor = .controlAccentColor
    var ringWidth: CGFloat = 6
}

/// Window previews, captured on demand and kept: windows of hidden apps cannot be captured, so their last
/// visible look stands in. Needs Screen Recording permission; without it the app icon is all there is.
enum Thumbnails {
    private static var cache: [WindowID: NSImage] = [:]
    private static let queue = DispatchQueue(label: "betterwm.thumbnails", qos: .userInitiated)
    private static var busy = false

    static func cached(_ id: WindowID) -> NSImage? { cache[id] }

    static func refresh(_ ids: [WindowID], _ deliver: @escaping (WindowID, NSImage) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            defer { DispatchQueue.main.async { busy = false } }
            for id in ids {
                guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]),
                      cg.width > 1 else { continue }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                DispatchQueue.main.async {
                    cache[id] = img
                    deliver(id, img)
                }
            }
        }
    }

    /// Synchronous capture for windows about to leave the screen; a few milliseconds each at nominal resolution.
    static func captureNow(_ ids: [WindowID]) {
        for id in ids {
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]), cg.width > 1 else { continue }
            cache[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    static func forget(_ id: WindowID) { cache[id] = nil }
}

/// Layer-backed canvas. Every window of the current desktop has a layer interpolated between its real frame and
/// its spread-out slot; the desktop strip slides in from above the screen; the backdrop darkens with progress.
final class OverviewView: NSView {
    var onPickWindow: ((OverviewModel.Window) -> Void)?
    var onPickDesktop: ((Int) -> Void)?
    var onDropWindow: ((OverviewModel.Window, Int) -> Void)?
    var onBackdrop: (() -> Void)?

    private var model = OverviewModel(desktops: [], current: nil)
    private var screenAX = CGRect.zero
    private var topInset: CGFloat = 0
    private let screenshot = CALayer()
    private let blurred = CALayer()
    private let backdrop = CALayer()
    private var windowLayers: [WindowID: WindowLayer] = [:]
    private let strip = DesktopStripLayer()
    private var slots: [WindowID: CGRect] = [:]
    private let titleLayer = CATextLayer()
    private var hovered: WindowID?
    private var dragging: (item: OverviewModel.Window, start: CGPoint, origin: CGRect, moved: Bool)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var progress: CGFloat = 0 { didSet { layoutForProgress() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for l in [screenshot, blurred] {
            l.contentsGravity = .resize
            layer?.addSublayer(l)
        }
        blurred.opacity = 0
        backdrop.backgroundColor = NSColor.black.cgColor
        backdrop.opacity = 0
        layer?.addSublayer(backdrop)
        layer?.addSublayer(strip)
        titleLayer.fontSize = 13
        titleLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLayer.foregroundColor = NSColor.white.cgColor
        titleLayer.alignmentMode = .center
        titleLayer.truncationMode = .end
        titleLayer.contentsScale = 2
        titleLayer.opacity = 0
        layer?.addSublayer(titleLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(model: OverviewModel, screenAX: CGRect, topInset: CGFloat) {
        self.model = model
        self.screenAX = screenAX
        self.topInset = topInset
        for l in windowLayers.values { l.removeFromSuperlayer() }
        windowLayers.removeAll()
        hovered = nil
        let scale = window?.backingScaleFactor ?? 2
        strip.configure(desktops: model.desktops, current: model.current?.index, screenSize: screenAX.size, scale: scale)
        for w in model.current?.windows.reversed() ?? [] {
            let l = WindowLayer(item: w, scale: scale)
            if w.id == model.focused { l.setRing(color: model.ringColor, width: model.ringWidth) }
            windowLayers[w.id] = l
            layer?.addSublayer(l)
        }
        layer?.addSublayer(titleLayer)
        computeSlots()
        layoutForProgress()
    }

    func setBackground(sharp: CGImage?, blurred image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenshot.contents = sharp
        blurred.contents = image
        CATransaction.commit()
    }

    func setThumbnail(_ image: NSImage, for id: WindowID) {
        windowLayers[id]?.setThumbnail(image)
        strip.setThumbnail(image, for: id)
    }

    // MARK: Geometry

    private func local(_ ax: CGRect) -> CGRect { CGRect(x: ax.minX - screenAX.minX, y: ax.minY - screenAX.minY, width: ax.width, height: ax.height) }

    private var stripFrame: CGRect { DesktopStripLayer.stripFrame(in: bounds, topInset: topInset) }

    /// Spread-out slots, Exposé style: one cell per window in reading order, each window scaled to fit its cell,
    /// so every window is fully visible whatever the layout.
    private func computeSlots() { slots = slots(for: model.current?.windows ?? []) }

    private func slots(for windows: [OverviewModel.Window]) -> [WindowID: CGRect] {
        var slots: [WindowID: CGRect] = [:]
        let area = CGRect(x: 48, y: stripFrame.maxY + 36, width: bounds.width - 96, height: bounds.height - stripFrame.maxY - 36 - 40)
        guard bounds.width > 0, bounds.height > 0, area.width > 0, area.height > 0 else { return slots }
        let frames = windows.map { local($0.frame) }
        guard !windows.isEmpty else { return slots }
        // Reading order so the cells follow the screen, however the windows are stacked.
        let order = windows.indices.sorted { (frames[$0].minX / 40).rounded() == (frames[$1].minX / 40).rounded() ? frames[$0].minY < frames[$1].minY : frames[$0].minX < frames[$1].minX }
        let n = order.count
        let cols = max(1, Int((CGFloat(n) * area.width / area.height).squareRoot().rounded(.up)))
        let rows = max(1, Int((CGFloat(n) / CGFloat(cols)).rounded(.up)))
        let gap: CGFloat = 28
        let cellW = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols), cellH = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for (k, i) in order.enumerated() {
            let r = k / cols, c = k % cols
            let inRow = r == rows - 1 ? n - r * cols : cols
            let rowX0 = area.minX + (area.width - (CGFloat(inRow) * cellW + gap * CGFloat(inRow - 1))) / 2
            let cell = CGRect(x: rowX0 + CGFloat(c) * (cellW + gap), y: area.minY + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
            let f = frames[i]
            let s = min(cell.width / f.width, cell.height / f.height, 1)
            let w = f.width * s, h = f.height * s
            slots[windows[i].id] = CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
        }
        return slots
    }

    // MARK: Horizontal scrub between desktops

    /// Neighbouring desktops' windows at their own spread-out slots, one screen width to either side.
    private var neighbourLayers: [(layer: WindowLayer, slot: CGRect, side: CGFloat)] = []
    var horizontalOffset: CGFloat = 0 { didSet { layoutForProgress() } }

    func hasNeighbour(_ side: Int) -> Bool {
        guard let current = model.current?.index else { return false }
        return model.desktops.contains { $0.index == current + side }
    }

    func beginHorizontal() {
        endHorizontal()
        guard let current = model.current?.index else { return }
        let scale = window?.backingScaleFactor ?? 2
        for side in [-1, 1] {
            guard let d = model.desktops.first(where: { $0.index == current + side }) else { continue }
            for (w, slot) in slots(for: d.windows).sorted(by: { $0.key < $1.key }) {
                guard let item = d.windows.first(where: { $0.id == w }) else { continue }
                let l = WindowLayer(item: item, scale: scale)
                layer?.insertSublayer(l, below: titleLayer)
                neighbourLayers.append((l, slot, CGFloat(side)))
            }
        }
        layoutForProgress()
    }

    func endHorizontal() {
        for n in neighbourLayers { n.layer.removeFromSuperlayer() }
        neighbourLayers.removeAll()
        horizontalOffset = 0
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        screenshot.frame = bounds
        blurred.frame = bounds
        computeSlots()
        layoutForProgress()
    }

    private func layoutForProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = progress
        screenshot.frame = bounds
        blurred.frame = bounds
        backdrop.frame = bounds
        blurred.opacity = Float(p)
        backdrop.opacity = Float(p * 0.35)
        strip.frame = bounds
        strip.layout(in: bounds, topInset: topInset, progress: p)
        for w in model.current?.windows ?? [] {
            guard let l = windowLayers[w.id], let slot = slots[w.id] else { continue }
            if let d = dragging, d.item.id == w.id { continue }
            let real = local(w.frame)
            l.frame = CGRect(x: real.minX + (slot.minX - real.minX) * p + horizontalOffset, y: real.minY + (slot.minY - real.minY) * p,
                             width: real.width + (slot.width - real.width) * p, height: real.height + (slot.height - real.height) * p)
            l.setProgress(p)
        }
        for n in neighbourLayers {
            n.layer.frame = n.slot.offsetBy(dx: horizontalOffset + n.side * bounds.width, dy: 0)
            n.layer.setProgress(1)
        }
        titleLayer.opacity = p >= 1 && hovered != nil ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Mouse

    private func windowItem(at point: CGPoint) -> OverviewModel.Window? {
        // Top-most first: layers were added back to front.
        for w in model.current?.windows ?? [] where windowLayers[w.id]?.frame.contains(point) == true { return w }
        return nil
    }

    private func previewIndex(at point: CGPoint) -> Int? { strip.index(at: point) }

    private func desktop(forPreview i: Int) -> Int { strip.desktop(forPreview: i) }

    override func mouseMoved(with event: NSEvent) {
        guard progress >= 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let item = windowItem(at: point)
        if item?.id != hovered {
            hovered = item?.id
            for (id, l) in windowLayers { l.setHovered(id == hovered) }
            if let item, let f = windowLayers[item.id]?.frame {
                titleLayer.string = item.title
                titleLayer.frame = CGRect(x: f.midX - 200, y: f.maxY + 6, width: 400, height: 18)
            }
            titleLayer.opacity = hovered != nil ? 1 : 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard progress >= 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let item = windowItem(at: point), let l = windowLayers[item.id] {
            dragging = (item, point, l.frame, false)
            return
        }
        dragging = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - d.start.x, dy = point.y - d.start.y
        if !d.moved, hypot(dx, dy) < 4 { return }
        d.moved = true
        dragging = d
        guard let l = windowLayers[d.item.id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let over = previewIndex(at: point) != nil
        let k: CGFloat = over ? 0.35 : 1
        l.frame = CGRect(x: point.x - d.origin.width * k / 2, y: point.y - d.origin.height * k / 2, width: d.origin.width * k, height: d.origin.height * k)
        l.zPosition = 10
        strip.setTarget(previewIndex(at: point))
        titleLayer.opacity = 0
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { dragging = nil }
        if let d = dragging {
            if d.moved {
                strip.setTarget(nil)
                if let i = previewIndex(at: point) {
                    onDropWindow?(d.item, desktop(forPreview: i))
                } else if let l = windowLayers[d.item.id] {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    l.frame = d.origin; l.zPosition = 0
                    CATransaction.commit()
                }
            } else {
                onPickWindow?(d.item)
            }
            return
        }
        guard progress >= 1 else { return }
        if let i = previewIndex(at: point) { onPickDesktop?(desktop(forPreview: i)); return }
        onBackdrop?()
    }
}

/// One window of the current desktop: its preview (or a dark card with the app icon) with a shadow and rounded corners.
private final class WindowLayer: CALayer {
    private let image = CALayer()
    private let icon = CALayer()
    private let highlight = CALayer()
    private let ring = CALayer()
    private var ringWidth: CGFloat = 0
    private var baseRadius: CGFloat = 10

    init(item: OverviewModel.Window, scale: CGFloat) {
        baseRadius = item.radius
        super.init()
        contentsScale = scale
        image.contentsScale = scale
        image.contentsGravity = .resize
        image.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        image.masksToBounds = true
        if let t = item.thumbnail { image.contents = t }
        addSublayer(image)
        icon.contentsScale = scale
        icon.contents = item.icon
        icon.contentsGravity = .resizeAspect
        addSublayer(icon)
        highlight.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        highlight.borderWidth = 3
        highlight.opacity = 0
        addSublayer(highlight)
        ring.opacity = 0
        insertSublayer(ring, at: 0)
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0
        shadowRadius = 18
        shadowOffset = CGSize(width: 0, height: 8)
        // Without an explicit path Core Animation re-derives the shadow from the layer's pixels on every move.
        shadowPath = CGPath(rect: .zero, transform: nil)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ t: NSImage) { image.contents = t }

    /// The focused window keeps its ring in the overview, so the eye finds it there too.
    func setRing(color: NSColor, width: CGFloat) {
        ring.borderColor = color.cgColor
        ring.borderWidth = width
        ringWidth = width
        ring.opacity = 1
    }

    func setProgress(_ p: CGFloat) {
        image.frame = bounds
        highlight.frame = bounds.insetBy(dx: -3, dy: -3)
        let r = baseRadius + (10 - baseRadius) * p
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        image.cornerRadius = r
        highlight.cornerRadius = r + 3
        let pad = ringWidth / 2 + 1
        ring.frame = bounds.insetBy(dx: -pad, dy: -pad)
        ring.cornerRadius = r + pad
        let side = min(64, bounds.width * 0.25, bounds.height * 0.25)
        icon.frame = CGRect(x: bounds.midX - side / 2, y: bounds.maxY - side * 0.75, width: side, height: side)
        icon.opacity = Float(p)
        shadowOpacity = Float(p * 0.5)
    }

    func setHovered(_ on: Bool) { highlight.opacity = on ? 1 : 0 }
}

/// The strip of desktops along the top: one miniature per desktop and a trailing "+". Shared by the overview
/// and the drag-to-desktop strip, so both look and move the same. Coordinates are those of a flipped view
/// covering the screen; `progress` 0 is slid out above the screen, 1 is in place.
final class DesktopStripLayer: CALayer {
    private var previews: [PreviewLayer] = []
    private var desktops: [OverviewModel.Desktop] = []

    static func stripFrame(in bounds: CGRect, topInset: CGFloat) -> CGRect {
        CGRect(x: 0, y: topInset + 20, width: bounds.width, height: bounds.height * 0.12)
    }

    static func previewFrame(at i: Int, count: Int, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        guard bounds.height > 0 else { return .zero }
        let strip = stripFrame(in: bounds, topInset: topInset)
        let ph = strip.height, pw = ph * bounds.width / max(1, bounds.height), gap: CGFloat = 18
        let total = CGFloat(count) * pw + CGFloat(count - 1) * gap
        let x0 = (bounds.width - total) / 2
        return CGRect(x: x0 + CGFloat(i) * (pw + gap), y: strip.minY, width: pw, height: ph)
    }

    func configure(desktops: [OverviewModel.Desktop], current: Int?, screenSize: CGSize, scale: CGFloat) {
        previews.forEach { $0.removeFromSuperlayer() }
        previews = []
        self.desktops = desktops
        for d in desktops {
            let p = PreviewLayer(desktop: d, screenSize: screenSize, isCurrent: d.index == current, scale: scale)
            previews.append(p)
            addSublayer(p)
        }
        let plus = PreviewLayer(desktop: nil, screenSize: screenSize, isCurrent: false, scale: scale)
        previews.append(plus)
        addSublayer(plus)
    }

    func layout(in bounds: CGRect, topInset: CGFloat, progress p: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in previews.enumerated() {
            var f = Self.previewFrame(at: i, count: previews.count, in: bounds, topInset: topInset)
            f.origin.y = f.minY - (1 - p) * (f.maxY + 20)
            l.frame = f
            l.opacity = Float(p)
        }
        CATransaction.commit()
    }

    func index(at point: CGPoint) -> Int? { previews.firstIndex { $0.frame.insetBy(dx: -9, dy: -9).contains(point) } }
    func frame(ofPreview i: Int) -> CGRect? { previews.indices.contains(i) ? previews[i].frame : nil }
    /// The desktop a preview stands for; the trailing "+" is the next new one.
    func desktop(forPreview i: Int) -> Int { i < desktops.count ? desktops[i].index : desktops.count }
    func setTarget(_ index: Int?) { for (i, p) in previews.enumerated() { p.setTarget(i == index) } }
    func setThumbnail(_ image: NSImage, for id: WindowID) { for p in previews { p.setThumbnail(image, for: id) } }
}

/// A desktop in the strip: the screen in miniature with its windows at their layout positions. `desktop == nil`
/// is the trailing "new desktop" target.
private final class PreviewLayer: CALayer {
    private var tiles: [WindowID: CALayer] = [:]
    private let screenSize: CGSize
    private let label = CATextLayer()
    private let isCurrent: Bool
    private let isNew: Bool
    private var windows: [OverviewModel.Window] = []

    init(desktop: OverviewModel.Desktop?, screenSize: CGSize, isCurrent: Bool, scale: CGFloat) {
        self.screenSize = screenSize
        self.isCurrent = isCurrent
        self.isNew = desktop == nil
        super.init()
        contentsScale = scale
        backgroundColor = NSColor(white: isNew ? 0.1 : 0.18, alpha: 1).cgColor
        cornerRadius = 8
        masksToBounds = false
        borderWidth = isCurrent ? 3 : 1.5
        borderColor = (isCurrent ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).cgColor
        windows = desktop?.windows ?? []
        for w in windows.reversed() {
            let t = CALayer()
            t.contentsScale = scale
            t.contentsGravity = .resize
            t.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
            t.masksToBounds = true
            t.cornerRadius = 2
            if let img = w.thumbnail { t.contents = img }
            else if let icon = w.icon {
                let i = CALayer()
                i.contents = icon
                i.contentsGravity = .resizeAspect
                i.contentsScale = scale
                i.name = "icon"
                t.addSublayer(i)
            }
            tiles[w.id] = t
            addSublayer(t)
        }
        label.string = desktop.map { "Desktop \($0.index + 1)" } ?? "+"
        label.fontSize = isNew ? 28 : 12
        label.font = NSFont.systemFont(ofSize: label.fontSize, weight: isNew ? .light : .semibold)
        label.foregroundColor = NSColor.white.withAlphaComponent(isNew ? 0.6 : 0.9).cgColor
        label.alignmentMode = .center
        label.contentsScale = scale
        // Readable over a light wallpaper too: the drag strip has no darkened backdrop behind it.
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.7
        label.shadowRadius = 2
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSublayer(label)
    }
    override init(layer: Any) {
        let l = layer as? PreviewLayer
        screenSize = l?.screenSize ?? .zero
        isCurrent = l?.isCurrent ?? false
        isNew = l?.isNew ?? false
        super.init(layer: layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSublayers() {
        super.layoutSublayers()
        let s = bounds.width / max(1, screenSize.width)
        for w in windows {
            guard let t = tiles[w.id] else { continue }
            let f = CGRect(x: w.frame.minX * s, y: w.frame.minY * s, width: w.frame.width * s, height: w.frame.height * s)
            t.frame = f
            if let i = t.sublayers?.first(where: { $0.name == "icon" }) {
                let side = min(f.width, f.height) * 0.6
                i.frame = CGRect(x: f.width / 2 - side / 2, y: f.height / 2 - side / 2, width: side, height: side)
            }
        }
        if isNew {
            label.frame = CGRect(x: 0, y: bounds.midY - 18, width: bounds.width, height: 36)
        } else {
            label.frame = CGRect(x: 0, y: bounds.maxY + 6, width: bounds.width, height: 16)
        }
    }

    func setThumbnail(_ image: NSImage, for id: WindowID) {
        guard let t = tiles[id] else { return }
        t.contents = image
        t.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    func setTarget(_ on: Bool) {
        borderColor = (on ? NSColor.systemBlue : isCurrent ? NSColor.white : NSColor.white.withAlphaComponent(0.25)).cgColor
        borderWidth = on || isCurrent ? 3 : 1.5
    }
}
