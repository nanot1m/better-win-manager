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
    var isVisible: Bool { panel.isVisible }

    init() {
        // Behind every app window: the strip lives in the area the layout keeps free, and a window carried over
        // it stays on top.
        panel = .overlay(level: .normal)
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
            let i = tabs.count
            t.onClick = { [weak self] in
                guard let self, i < self.items.count else { return }
                self.onSelect?(self.items[i].id)
            }
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
            if active { addSubview(t, positioned: .above, relativeTo: nil) }
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
    }

    /// Tabs share the strip, with a cap so a lone tab does not span the screen; the active one stands a little taller.
    private func layoutTabs() {
        let n = CGFloat(max(1, items.count)), pad: CGFloat = 16, gap: CGFloat = 4
        if side != .top {
            // Sideways tabs: as long along the strip as a top tab is wide, as thick as the strip. On the left they
            // read bottom to top, so the deck runs that way too; on the right, top to bottom.
            let h = min(maxLength, (bounds.height - pad * 2 - gap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                let active = i == activeIndex
                let slot = side == .left ? CGFloat(items.count - 1 - i) : CGFloat(i)
                let lift: CGFloat = active ? 1 : 5
                let y = pad + slot * (h + gap)
                t.frame = side == .left ? CGRect(x: lift, y: y, width: bounds.width - lift, height: h)
                                        : CGRect(x: 0, y: y, width: bounds.width - lift, height: h)
            }
        } else {
            let w = min(maxLength, (bounds.width - pad * 2 - gap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                let active = i == activeIndex
                t.frame = CGRect(x: pad + CGFloat(i) * (w + gap), y: active ? 1 : 5, width: w, height: bounds.height - (active ? 1 : 5))
            }
        }
    }
}

/// One folder tab: rounded on the side away from the window, square where it meets it.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var active = false
    private var accent = NSColor.controlAccentColor
    private var hovering = false
    private var side = TabStripWindow.Side.top
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = shape
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        addSubview(label)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: NSAttributedString, active: Bool, accent: NSColor, side: TabStripWindow.Side) {
        self.active = active
        self.accent = accent
        self.side = side
        label.attributedStringValue = title
        updateShape()
        layoutLabel()
        paint()
    }

    override func layout() {
        super.layout()
        updateShape()
        layoutLabel()
    }

    private func layoutLabel() {
        let inset: CGFloat = 8, h = label.intrinsicContentSize.height
        if side != .top {
            // The frame is set unrotated (long side along y) and then turned about its centre: a left spine reads
            // bottom to top, a right one top to bottom.
            label.frameCenterRotation = 0
            label.frame = CGRect(x: bounds.midX - (bounds.height - inset * 2) / 2, y: bounds.midY - h / 2, width: bounds.height - inset * 2, height: h)
            label.frameCenterRotation = side == .left ? 90 : -90
        } else {
            label.frame = CGRect(x: inset, y: bounds.midY - h / 2, width: bounds.width - inset * 2, height: h)
        }
    }

    /// Rounded away from the window, square where it meets it.
    private func updateShape() {
        let r: CGFloat = 8, b = bounds
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

    private func paint() {
        let base = active ? accent : NSColor(white: 0.22, alpha: 0.92)
        layer?.backgroundColor = (hovering && !active ? base.blended(withFraction: 0.15, of: .white) ?? base : base).cgColor
        layer?.borderWidth = active ? 0 : 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; paint() }
    override func mouseExited(with event: NSEvent) { hovering = false; paint() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
