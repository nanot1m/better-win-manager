import BetterWMCore
import Cocoa
import QuartzCore

/// Horizontal swipe between desktops, drawn like Spaces: the current desktop slides out as one image while the
/// neighbour's windows slide in as previews, following the fingers. Real windows cannot be moved that smoothly,
/// so the panel covers the screen below the bar for the duration and the real switch happens behind it on release.
/// Everything the first frame needs comes from one screen capture and the manager's own state: no per-window
/// captures and no Accessibility, which is what kept the start from being instant.
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
    /// Screen image taken when the fingers touched the pad, so a swipe that follows starts without a capture.
    private var prewarmed: (at: Date, area: CGRect, image: CGImage)?
    private let captureQueue = DispatchQueue(label: "betterwm.slide", qos: .userInteractive)
    private var pending = 0

    init(manager: WindowManager) {
        self.manager = manager
        panel = .overlay(level: .screenSaver, ignoresMouse: true)
        panel.contentView = view
    }

    private func area(of screen: NSScreen) -> CGRect {
        // Below the bar only: the bar stays put and live, like the menu bar in Spaces.
        let inset = manager.system.topInset(screen)
        let screenAX = screen.frame.toCocoa()
        return CGRect(x: screenAX.minX, y: screenAX.minY + inset, width: screenAX.width, height: screenAX.height - inset)
    }

    /// Fingers are down; capture the screen now, off the main thread, in case a swipe follows.
    func prewarm() {
        guard !panel.isVisible, !manager.interacting, let screen = NSScreen.screens.first else { return }
        let areaAX = area(of: screen)
        pending += 1
        captureQueue.async { [weak self] in
            let image = CGWindowListCreateImage(areaAX, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
            _ = Overview.captureBackdrop(areaAX, topInset: 0)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending -= 1
                if let image { self.prewarmed = (Date(), areaAX, image) }
            }
        }
    }

    func began() {
        animator?.invalidate()
        guard !panel.isVisible, let screen = NSScreen.screens.first, let current = manager.currentDesktop else { return }
        let t0 = Date()
        defer { Log.write("gesture", "slide ready in \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
        self.current = current
        let areaAX = area(of: screen)
        let inset = manager.system.topInset(screen)
        width = areaAX.width
        hasPrevious = current > 0
        hasNext = current + 1 < manager.desktopCount
        func slide(_ d: Int) -> [SlideView.Item] {
            let items = manager.previewItems(desktop: d)
            let top = manager.lastFocusedWindow(onDesktop: d) ?? items.first?.id
            return items.map { w in
                let local = CGRect(x: w.frame.minX - areaAX.minX, y: w.frame.minY - areaAX.minY, width: w.frame.width, height: w.frame.height)
                let ring: NSColor? = manager.config.focusRing && w.id == top && (manager.config.focusRingFloating || w.tiled) ? manager.config.ringColor(floating: !w.tiled) : nil
                return SlideView.Item(id: w.id, frame: local, icon: NSRunningApplication(processIdentifier: w.pid)?.icon, thumbnail: Thumbnails.cached(w.id),
                                      radius: manager.config.ringRadius(for: w.id),
                                      ring: ring, ringWidth: manager.config.focusRingWidth)
            }
        }
        let fresh = prewarmed.flatMap { $0.area == areaAX && Date().timeIntervalSince($0.at) < 2 ? $0.image : nil }
        let outgoing = fresh ?? CGWindowListCreateImage(areaAX, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])
        prewarmed = nil
        let backdrop = Overview.captureBackdrop(areaAX, topInset: 0)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: screen.frame.height - inset)
        panel.setFrame(frame, display: false)
        view.configure(backdrop: backdrop, outgoing: outgoing, previous: hasPrevious ? slide(current - 1) : nil, next: hasNext ? slide(current + 1) : nil,
                       scale: screen.backingScaleFactor)
        offset = 0
        view.offset = 0
        panel.orderFrontRegardless()
        // No layout passes while the slide is up: a snapshot mid-scrub stalls the main thread for tens of ms.
        manager.interacting = true
        // Parked neighbours are on screen and can be refreshed; hidden ones keep the capture taken before hiding.
        let neighbours = (hasPrevious ? manager.previewItems(desktop: current - 1) : []) + (hasNext ? manager.previewItems(desktop: current + 1) : [])
        Thumbnails.refresh(neighbours.filter { !(NSRunningApplication(processIdentifier: $0.pid)?.isHidden ?? false) }.map(\.id)) { [weak self] id, img in
            self?.view.setThumbnail(img, for: id)
        }
    }

    /// `travel` is in desktops: -1 means the next desktop has fully arrived from the right.
    func changed(_ travel: CGFloat) {
        guard panel.isVisible else { return }
        var t = travel
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
        // The finishing slide is a Core Animation transaction, animated by the render server, so the real switch
        // (some 40 ms of Accessibility moves on the main thread) can run right away without stalling a frame.
        animator?.invalidate()
        let to = CGFloat(-target) * width
        let duration = max(0.15, 0.3 * Double(abs(to - offset) / width))
        view.animateOffset(to: to, duration: duration) { [weak self] in self?.dismiss() }
        offset = to
        manager.interacting = false
        let t0 = Date()
        manager.switchDesktop(destination)
        Log.write("gesture", "real switch took \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    }

    private func set(offset o: CGFloat) {
        offset = o
        view.offset = o
    }

    @discardableResult
    private func animate(to target: CGFloat, then: @escaping () -> Void) -> TimeInterval {
        animator?.invalidate()
        let from = offset
        let duration = max(0.12, 0.3 * Double(abs(target - from) / width))
        animator = Tween.run(duration: duration, step: { [weak self] e in
            self?.set(offset: from + (target - from) * e)
        }, done: { [weak self] in
            self?.animator = nil
            if target == 0 { self?.dismiss() }
            then()
        })
        return duration
    }

    private func dismiss() {
        panel.orderOut(nil)
        if manager.interacting { manager.interacting = false; manager.tick() }
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

    private var animating = false
    var offset: CGFloat = 0 {
        didSet {
            guard !animating else { return }
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
        slides.current.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(backdrop image: CGImage?, outgoing: CGImage?, previous: [Item]?, next: [Item]?, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image
        backdrop.frame = bounds
        tiles.removeAll()
        slides.current.sublayers?.forEach { $0.removeFromSuperlayer() }
        slides.current.contents = outgoing
        for (layer, items) in [(slides.previous, previous ?? []), (slides.next, next ?? [])] {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            for item in items.reversed() {
                let shadow = CALayer()
                shadow.frame = item.frame
                shadow.backgroundColor = NSColor.black.cgColor
                shadow.cornerRadius = item.radius
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOpacity = 0.45
                shadow.shadowRadius = 20
                shadow.shadowOffset = CGSize(width: 0, height: 10)
                shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: item.frame.size), cornerWidth: item.radius, cornerHeight: item.radius, transform: nil)
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
                layer.addSublayer(t)
                tiles[item.id] = t
            }
        }
        CATransaction.commit()
        offset = 0
    }

    /// Animated in the render server: the main thread may block meanwhile without dropping a frame.
    func animateOffset(to target: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(completion)
        let w = bounds.width
        slides.current.frame = CGRect(x: target, y: 0, width: w, height: bounds.height)
        slides.previous.frame = CGRect(x: target - w - 40, y: 0, width: w, height: bounds.height)
        slides.next.frame = CGRect(x: target + w + 40, y: 0, width: w, height: bounds.height)
        CATransaction.commit()
        animating = true
        offset = target
        animating = false
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
