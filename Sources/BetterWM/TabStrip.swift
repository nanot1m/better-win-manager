import BetterWMCore
import Cocoa

/// The row (or column) of folder-style tabs on a stacked screen whose look is tabs: one tab per window in deck
/// order, the focused window's tab raised in the accent colour. Clicking a tab brings its window to the front.
final class TabStripWindow {
    struct Item {
        let id: WindowID
        let app: String
        let title: String
    }
    enum Side { case top, left, right }

    private let panel: NSPanel
    private let view = TabStripView()
    var onSelect: ((WindowID) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }
    /// A tab dragged to a new place in the deck: the window and the deck position it was dropped at.
    var onReorder: ((WindowID, Int) -> Void)? {
        get { view.onReorder }
        set { view.onReorder = newValue }
    }
    var isVisible: Bool { panel.isVisible }

    init() {
        // Behind every app window: the strip lives in the area the layout keeps free, and a window carried over
        // it stays on top. Not an auxiliary of fullscreen Spaces, so a fullscreen app covers it.
        panel = .overlay(level: .normal, behavior: [.canJoinAllSpaces, .transient])
        panel.contentView = view
    }

    /// `frame` in AX coordinates.
    func show(frame: CGRect, items: [Item], focused: WindowID?, side: Side, config: Config) {
        panel.setFrame(frame.toCocoa(), display: false)
        view.configure(items: items, focused: focused, side: side, config: config)
        if !panel.isVisible { panel.orderBack(nil) }
    }

    func hide() { panel.orderOut(nil) }

    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private final class TabStripView: NSView {
    var onSelect: ((WindowID) -> Void)?
    var onReorder: ((WindowID, Int) -> Void)?
    private var drag: ReorderDrag?
    private var settling: ReorderDrag?
    private var tabs: [TabView] = []
    private var items: [TabStripWindow.Item] = []
    private var side = TabStripWindow.Side.top
    private var activeIndex: Int?
    private var maxLength: CGFloat = 240

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(items: [TabStripWindow.Item], focused: WindowID?, side: TabStripWindow.Side, config: Config) {
        self.items = items
        self.side = side
        maxLength = config.tabWidth
        while tabs.count < items.count {
            let t = TabView()
            // Tabs change places in `tabs` after a drag, so each looks its index up when asked.
            let indexOf: (TabView) -> Int? = { [weak self] t in self?.tabs.firstIndex { $0 === t } }
            t.onClick = { [weak self, weak t] in
                guard let self, let t, let i = indexOf(t), i < self.items.count else { return }
                self.onSelect?(self.items[i].id)
            }
            t.onDragBegan = { [weak self, weak t] in if let t, let i = indexOf(t) { self?.beginDrag(i) } }
            t.onDragMoved = { [weak self] d in self?.drag?.update(delta: d) }
            t.onDragEnded = { [weak self] in self?.endDrag() }
            addSubview(t)
            tabs.append(t)
        }
        let accent = config.ringTiledColor
        activeIndex = items.firstIndex { $0.id == focused }
        for (i, t) in tabs.enumerated() {
            t.isHidden = i >= items.count
            guard i < items.count else { continue }
            let item = items[i]
            let active = item.id == focused
            // Re-adding a view that is already frontmost drops a frame; only move it when something is above it.
            if active, subviews.last !== t { addSubview(t, positioned: .above, relativeTo: nil) }
            t.configure(title: BarView.formatTitle(config.tabTitleFormat, app: item.app, title: item.title,
                                                   color: active ? accent.contrastingText : .white),
                        active: active, accent: accent, side: side)
        }
        needsLayout = true
        layoutTabs()
    }

    override func layout() {
        super.layout()
        layoutTabs()
        settling?.settle()
        settling = nil
    }

    /// Tabs in the order they appear along the strip (left tabs run bottom to top, so the deck is reversed there).
    private var visualOrder: [Int] { side == .left ? Array((0..<items.count).reversed()) : Array(0..<items.count) }

    private func beginDrag(_ index: Int) {
        let order = visualOrder
        guard let v = order.firstIndex(of: index) else { return }
        drag = ReorderDrag(items: order.map { tabs[$0] }, index: v, horizontal: side == .top)
    }

    private func endDrag() {
        guard let d = drag else { return }
        drag = nil
        let order = visualOrder
        d.end { [weak self] target in
            guard let self, let from = order.firstIndex(where: { self.tabs[$0] === d.grabbed }), target != from, target < order.count else {
                d.settle()
                return
            }
            // The tab view takes its new deck position first, keeping its label; the strip's refresh then finds
            // every view already showing the right window, so nothing is relabelled and no old-order frame shows.
            let fromDeck = order[from], toDeck = order[target]
            let t = self.tabs.remove(at: fromDeck)
            self.tabs.insert(t, at: toDeck)
            self.settling = d
            self.needsLayout = true
            self.onReorder?(self.items[fromDeck].id, toDeck)
        }
    }

    /// Tabs share the strip, with a cap so a lone tab does not span the screen. Every tab gets the full height; an
    /// inactive one sits a little lower, which is the tab's own business so it can animate the change.
    private func layoutTabs() {
        let n = CGFloat(max(1, items.count)), pad: CGFloat = 16, gap: CGFloat = 4
        if side != .top {
            // Sideways tabs: as long along the strip as a top tab is wide, as thick as the strip. On the left they
            // read bottom to top, so the deck runs that way too; on the right, top to bottom.
            let h = min(maxLength, (bounds.height - pad * 2 - gap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                let slot = side == .left ? CGFloat(items.count - 1 - i) : CGFloat(i)
                let y = pad + slot * (h + gap)
                t.frame = side == .left ? CGRect(x: 1, y: y, width: bounds.width - 1, height: h)
                                        : CGRect(x: 0, y: y, width: bounds.width - 1, height: h)
            }
        } else {
            let w = min(maxLength, (bounds.width - pad * 2 - gap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                t.frame = CGRect(x: pad + CGFloat(i) * (w + gap), y: 1, width: w, height: bounds.height - 1)
            }
        }
    }
}

/// One folder tab: rounded on the side away from the window, square where it meets it. The painted part is a
/// `body` view inside an invisible full-size frame: an inactive tab's body sits a few points closer to the window
/// (its far edge clipped by the strip), a hovered one halfway up, and the move between those is animated. The outer
/// view's layer is left to the reorder drag.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var horizontal = true
    private let body = NSView()
    private let label = NSTextField(labelWithString: "")
    private var active = false
    private var accent = NSColor.controlAccentColor
    private var hovering = false
    private var side = TabStripWindow.Side.top
    private let shape = CAShapeLayer()
    private var lift: CGFloat?
    private static let duration = 0.16

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        body.wantsLayer = true
        body.layer?.mask = shape
        addSubview(body)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        body.addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: NSAttributedString, active: Bool, accent: NSColor, side: TabStripWindow.Side) {
        let wasActive = self.active
        self.active = active
        self.accent = accent
        self.side = side
        horizontal = side == .top
        label.attributedStringValue = title
        layoutBody(animated: wasActive != active)
        updateShape()
        layoutLabel()
        paint(animated: wasActive != active)
    }

    override func layout() {
        super.layout()
        layoutBody(animated: false)
        updateShape()
        layoutLabel()
    }

    /// Toward the window by 4 points when inactive, 2 when hovered; a fresh tab takes its place without animating.
    private func layoutBody(animated: Bool) {
        let target: CGFloat = active ? 0 : hovering ? 2 : 4
        var f = bounds
        switch side {
        case .top: f.origin.y += target
        case .left: f.origin.x += target
        case .right: f.origin.x -= target
        }
        let animate = animated && lift != nil && lift != target && !isHidden
        lift = target
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                body.animator().frame = f
            }
        } else {
            body.frame = f
        }
    }

    private func layoutLabel() {
        let inset: CGFloat = 8, h = label.intrinsicContentSize.height, b = body.bounds
        if side != .top {
            // The frame is set unrotated (long side along y) and then turned about its centre: a left spine reads
            // bottom to top, a right one top to bottom.
            label.frameCenterRotation = 0
            label.frame = CGRect(x: b.midX - (b.height - inset * 2) / 2, y: b.midY - h / 2, width: b.height - inset * 2, height: h)
            label.frameCenterRotation = side == .left ? 90 : -90
        } else {
            // A tab view outlives a style change; undo a sideways turn from before.
            label.frameCenterRotation = 0
            label.frame = CGRect(x: inset, y: b.midY - h / 2, width: b.width - inset * 2, height: h)
        }
    }

    /// Rounded away from the window, square where it meets it.
    private func updateShape() {
        let r: CGFloat = 8, b = body.bounds
        let path = CGMutablePath()
        switch side {
        case .right:
            path.move(to: CGPoint(x: b.minX, y: b.minY))
            path.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
            path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.minY), tangent2End: CGPoint(x: b.maxX, y: b.minY + r), radius: r)
            path.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
            path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.maxX - r, y: b.maxY), radius: r)
            path.addLine(to: CGPoint(x: b.minX, y: b.maxY))
        case .left:
            path.move(to: CGPoint(x: b.maxX, y: b.minY))
            path.addLine(to: CGPoint(x: b.minX + r, y: b.minY))
            path.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX, y: b.minY + r), radius: r)
            path.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
            path.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX + r, y: b.maxY), radius: r)
            path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        case .top:
            // The mask layer is not geometry-flipped with the view: maxY is the top edge.
            path.move(to: CGPoint(x: b.minX, y: b.minY))
            path.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
            path.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX + r, y: b.maxY), radius: r)
            path.addLine(to: CGPoint(x: b.maxX - r, y: b.maxY))
            path.addArc(tangent1End: CGPoint(x: b.maxX, y: b.maxY), tangent2End: CGPoint(x: b.maxX, y: b.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: b.maxX, y: b.minY))
        }
        path.closeSubpath()
        shape.frame = b
        shape.path = path
    }

    private func paint(animated: Bool) {
        guard let layer = body.layer else { return }
        let base = active ? accent : NSColor(white: 0.22, alpha: 0.92)
        let color = (hovering && !active ? base.blended(withFraction: 0.15, of: .white) ?? base : base).cgColor
        if animated, let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = from
            anim.toValue = color
            anim.duration = Self.duration
            layer.add(anim, forKey: "paint")
        }
        layer.backgroundColor = color
        layer.borderWidth = active ? 0 : 1
        layer.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; layoutBody(animated: true); paint(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; layoutBody(animated: true); paint(animated: true) }

    /// A click brings the window forward; a drag past a few points moves the tab along the strip.
    override func mouseDown(with event: NSEvent) {
        guard let window else { onClick?(); return }
        let start = event.locationInWindow
        var dragging = false
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            // The strip view is flipped while window coordinates are not: a downward drag is a positive shift.
            let d = horizontal ? e.locationInWindow.x - start.x : start.y - e.locationInWindow.y
            if e.type == .leftMouseDragged {
                if !dragging, abs(d) > 4 { dragging = true; onDragBegan?() }
                if dragging { onDragMoved?(d) }
            } else {
                break
            }
        }
        if dragging { onDragEnded?() } else { onClick?() }
    }
}
