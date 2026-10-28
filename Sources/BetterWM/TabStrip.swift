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
    func show(frame: CGRect, items: [Item], focused: WindowID?, vertical: Bool, config: Config) {
        panel.setFrame(frame.toCocoa(), display: false)
        view.configure(items: items, focused: focused, vertical: vertical, config: config)
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
    private var vertical = false
    private var activeIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(items: [TabStripWindow.Item], focused: WindowID?, vertical: Bool, config: Config) {
        self.items = items
        self.vertical = vertical
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
            // Tabs overlap like folder tabs; the active one is brought to the front and stands a little taller.
            if active { addSubview(t, positioned: .above, relativeTo: nil) }
            t.configure(title: BarView.formatTitle(config.tabTitleFormat, app: item.app, title: item.title,
                                                   color: active ? accent.contrastingText : .white),
                        active: active, accent: accent, vertical: vertical)
        }
        needsLayout = true
        layoutTabs()
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    /// Tabs share the strip, with a cap so a lone tab does not span the screen. Along the strip they overlap a
    /// little, folder style, and the active one stands a little taller.
    private func layoutTabs() {
        let n = CGFloat(max(1, items.count)), pad: CGFloat = 16
        if vertical {
            let gap: CGFloat = 4
            let h = min(30, (bounds.height - pad * 2 - gap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                let active = i == activeIndex
                t.frame = CGRect(x: active ? pad - 4 : pad, y: pad + CGFloat(i) * (h + gap), width: bounds.width - (active ? pad - 4 : pad), height: h)
            }
        } else {
            let overlap: CGFloat = 8
            let w = min(240, (bounds.width - pad * 2 + overlap * (n - 1)) / n)
            for (i, t) in tabs.enumerated() where i < items.count {
                let active = i == activeIndex
                t.frame = CGRect(x: pad + CGFloat(i) * (w - overlap), y: active ? 1 : 5, width: w, height: bounds.height - (active ? 1 : 5))
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
    private var vertical = false
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = shape
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: NSAttributedString, active: Bool, accent: NSColor, vertical: Bool) {
        self.active = active
        self.accent = accent
        self.vertical = vertical
        label.attributedStringValue = title
        label.alignment = vertical ? .left : .center
        updateShape()
        paint()
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    /// Rounded away from the window (top for a strip on top, left for one on the left), square where it meets it.
    private func updateShape() {
        let r: CGFloat = 8, b = bounds
        let path = CGMutablePath()
        if vertical {
            path.move(to: CGPoint(x: b.maxX, y: b.minY))
            path.addLine(to: CGPoint(x: b.minX + r, y: b.minY))
            path.addArc(tangent1End: CGPoint(x: b.minX, y: b.minY), tangent2End: CGPoint(x: b.minX, y: b.minY + r), radius: r)
            path.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
            path.addArc(tangent1End: CGPoint(x: b.minX, y: b.maxY), tangent2End: CGPoint(x: b.minX + r, y: b.maxY), radius: r)
            path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        } else {
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
