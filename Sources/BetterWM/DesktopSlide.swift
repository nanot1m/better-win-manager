import BetterWMCore
import Cocoa
import QuartzCore

/// Horizontal swipe between desktops, drawn like Spaces: the current desktop's windows slide out as previews
/// while the neighbour's slide in, following the fingers. Real windows cannot be moved that smoothly, so the
/// panel covers the screen for the duration and the real switch happens behind it on release.
final class DesktopSlide {
    private let manager: WindowManager
    private let panel: NSPanel
    private let view = SlideView()
    private var animator: Timer?
    private var offset: CGFloat = 0
    private var width: CGFloat = 1
    private var hasPrevious = false, hasNext = false
    private var current = 0
    var isActive: Bool { panel.isVisible }

    init(manager: WindowManager) {
        self.manager = manager
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.contentView = view
    }

    func began() {
        animator?.invalidate()
        guard !panel.isVisible, let screen = NSScreen.screens.first, let current = manager.currentDesktop else { return }
        self.current = current
        let screenAX = screen.frame.toCocoa()
        width = screenAX.width
        let byDesktop = Dictionary(uniqueKeysWithValues: manager.windowsByDesktop().map { ($0.desktop, $0.windows) })
        let depth = Dictionary(uniqueKeysWithValues: manager.frontToBack.enumerated().map { ($1, $0) })
        let focusedNow = manager.focusRing.currentWindowID
        let ringColor = NSColor(hex: manager.config.focusRingColor) ?? .controlAccentColor
        let floatingColor = manager.config.focusRingFloatingColor.lowercased() == "same" ? ringColor : (NSColor(hex: manager.config.focusRingFloatingColor) ?? ringColor)
        func slide(_ d: Int) -> [SlideView.Item] {
            // The ring travels with the slide: on the focused window here, on the one that will be focused there.
            let top = d == current ? focusedNow : manager.lastFocusedWindow(onDesktop: d)
            func rank(_ w: AXWindow) -> Int { let id = w.windowID ?? 0; return id == top ? -1 : (depth[id] ?? .max) }
            return (byDesktop[d] ?? []).sorted { rank($0) < rank($1) }.compactMap { w in
                guard let id = w.windowID else { return nil }
                let frame = d == current ? w.frame : (manager.layoutFrame(of: w) ?? w.frame)
                let local = CGRect(x: frame.minX - screenAX.minX, y: frame.minY - screenAX.minY, width: frame.width, height: frame.height)
                let ring: NSColor? = manager.config.focusRing && id == top && (manager.config.focusRingFloating || manager.isTiled(w))
                    ? (manager.isTiled(w) ? ringColor : floatingColor) : nil
                return SlideView.Item(id: id, frame: local, icon: NSRunningApplication(processIdentifier: w.pid)?.icon, thumbnail: Thumbnails.cached(id),
                                      radius: manager.config.focusRingAutoRadius ? (WindowServerEvents.cornerRadius(of: id) ?? manager.config.focusRingRadius) : manager.config.focusRingRadius,
                                      ring: ring, ringWidth: manager.config.focusRingWidth)
            }
        }
        hasPrevious = current > 0
        hasNext = current + 1 < manager.desktopCount
        // The current desktop's windows are on screen: capture them now so the slide starts sharp.
        Thumbnails.captureNow((byDesktop[current] ?? []).compactMap(\.windowID))
        let backdrop = Overview.captureBackdrop(screenAX, topInset: manager.system.topInset(screen))
        panel.setFrame(screen.frame, display: false)
        view.configure(backdrop: backdrop, current: slide(current), previous: hasPrevious ? slide(current - 1) : nil, next: hasNext ? slide(current + 1) : nil,
                       scale: screen.backingScaleFactor)
        offset = 0
        view.offset = 0
        panel.orderFrontRegardless()
        manager.focusRing.suspended = true
        // Neighbours of hidden apps were captured before hiding; parked ones can be refreshed now.
        Thumbnails.refresh(((byDesktop[current - 1] ?? []) + (byDesktop[current + 1] ?? [])).compactMap(\.windowID)) { [weak self] id, img in self?.view.setThumbnail(img, for: id) }
    }

    /// `travel` is in desktops: -1 means the next desktop has fully arrived from the right.
    func changed(_ travel: CGFloat) {
        guard panel.isVisible else { return }
        var t = travel
        // Rubber band past the edges, where there is no desktop to show.
        if t < 0, !hasNext { t = t * 0.25 }
        if t > 0, !hasPrevious { t = t * 0.25 }
        set(offset: t * width)
    }

    func ended(velocity: CGFloat) {
        guard panel.isVisible else { return }
        let travel = offset / width
        var target = 0
        if (velocity < -1.2 || travel < -0.5), hasNext { target = 1 }
        if (velocity > 1.2 || travel > 0.5), hasPrevious { target = -1 }
        if target == 0, !hasNext, travel < -0.1 || velocity < -1.2 {
            // Past the last desktop: on to the neighbouring macOS Space (a fullscreen app), no slide to draw.
            animate(to: 0) { [weak self] in self?.manager.switchDesktopOrSpace(next: true) }
            return
        }
        if target == 0, !hasPrevious, travel > 0.1 || velocity > 1.2 {
            animate(to: 0) { [weak self] in self?.manager.switchDesktopOrSpace(next: false) }
            return
        }
        guard target != 0 else { animate(to: 0) {}; return }
        let destination = current + target
        // The real switch runs behind the finishing animation, so the windows are in place when the slide lands.
        manager.switchDesktop(destination)
        animate(to: CGFloat(-target) * width) { [weak self] in self?.dismiss() }
    }

    private func set(offset o: CGFloat) {
        offset = o
        view.offset = o
    }

    private func animate(to target: CGFloat, then: @escaping () -> Void) {
        animator?.invalidate()
        let from = offset
        let start = Date()
        let duration = max(0.12, 0.3 * Double(abs(target - from) / width))
        animator = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let x = min(1, Date().timeIntervalSince(start) / duration)
            let eased = 1 - pow(1 - x, 3)
            self.set(offset: from + (target - from) * CGFloat(eased))
            if x >= 1 {
                t.invalidate()
                self.animator = nil
                if target == 0 { self.dismiss() }
                then()
            }
        }
        RunLoop.main.add(animator!, forMode: .common)
    }

    private func dismiss() {
        panel.orderOut(nil)
        manager.focusRing.suspended = false
    }
}

private final class SlideView: NSView {
    struct Item {
        let id: WindowID
        let frame: CGRect
        let icon: NSImage?
        let thumbnail: NSImage?
        let radius: CGFloat
        let ring: NSColor?
        let ringWidth: CGFloat
    }
    private let backdrop = CALayer()
    private let slides = (previous: CALayer(), current: CALayer(), next: CALayer())
    private var tiles: [WindowID: CALayer] = [:]
    override var isFlipped: Bool { true }

    var offset: CGFloat = 0 {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let w = bounds.width
            slides.current.frame = CGRect(x: offset, y: 0, width: w, height: bounds.height)
            slides.previous.frame = CGRect(x: offset - w - 40, y: 0, width: w, height: bounds.height)
            slides.next.frame = CGRect(x: offset + w + 40, y: 0, width: w, height: bounds.height)
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.contentsGravity = .resize
        layer?.addSublayer(backdrop)
        for l in [slides.previous, slides.current, slides.next] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(backdrop image: CGImage?, current: [Item], previous: [Item]?, next: [Item]?, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image
        backdrop.frame = bounds
        tiles.removeAll()
        for (layer, items) in [(slides.previous, previous ?? []), (slides.current, current), (slides.next, next ?? [])] {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            for item in items.reversed() {
                let t = CALayer()
                t.contentsScale = scale
                t.contentsGravity = .resize
                t.frame = item.frame
                t.cornerRadius = item.radius
                t.masksToBounds = true
                t.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
                if let img = item.thumbnail { t.contents = img }
                else if let icon = item.icon {
                    let i = CALayer()
                    i.contents = icon
                    i.contentsGravity = .resizeAspect
                    i.contentsScale = scale
                    let side = min(96, item.frame.width * 0.3, item.frame.height * 0.3)
                    i.frame = CGRect(x: item.frame.width / 2 - side / 2, y: item.frame.height / 2 - side / 2, width: side, height: side)
                    t.addSublayer(i)
                }
                let shadow = CALayer()
                shadow.frame = item.frame
                shadow.cornerRadius = item.radius
                shadow.backgroundColor = NSColor.black.cgColor
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOpacity = 0.45
                shadow.shadowRadius = 20
                shadow.shadowOffset = CGSize(width: 0, height: 10)
                layer.addSublayer(shadow)
                if let color = item.ring {
                    let r = CALayer()
                    let pad = item.ringWidth / 2 + 1
                    r.frame = item.frame.insetBy(dx: -pad, dy: -pad)
                    r.cornerRadius = item.radius + pad
                    r.borderWidth = item.ringWidth
                    r.borderColor = color.cgColor
                    layer.addSublayer(r)
                }
                layer.addSublayer(t)
                tiles[item.id] = t
            }
        }
        CATransaction.commit()
        offset = 0
    }

    func setThumbnail(_ image: NSImage, for id: WindowID) {
        guard let t = tiles[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        t.contents = image
        t.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        offset = offset + 0
    }
}
