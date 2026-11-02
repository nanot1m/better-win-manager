import BetterWMCore
import Cocoa

/// The row (or column) of folder-style tabs on a stacked screen whose look is tabs: one tab per window in deck
/// order, the focused window's tab raised in the accent colour. Clicking a tab brings its window to the front.
final class TabStripWindow {
    struct Item {
        let id: WindowID
        let app: String
        let title: String
        /// A name the user gave the tab; shown instead of the formatted title.
        var label: String? = nil
    }
    enum Side { case top, left, right }

    private let panel: NSPanel
    private let view = TabStripView()
    /// The user named a tab (nil or empty: back to the window's title).
    var onRename: ((WindowID, String?) -> Void)? {
        get { view.onRename }
        set { view.onRename = newValue }
    }
    /// Renaming ended: the strip gives key status up, and focus should go back to the front window.
    var onEditingEnd: (() -> Void)? {
        get { view.onEditingEnd }
        set { view.onEditingEnd = newValue }
    }
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
        panel = EditablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .normal
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = view
    }

    /// `frame` in AX coordinates.
    /// `inactive`: the front window has no focus; its tab is greyed like the ring. `clearance`: how far the
    /// first tab stays from the strip's start, at least the ring's corner radius so it does not hang over the curve.
    func show(frame: CGRect, items: [Item], focused: WindowID?, inactive: Bool, clearance: CGFloat, side: Side, config: Config) {
        let target = frame.toCocoa()
        // A short move at the same size is the strip settling onto or lifting off its window; it slides. Anything
        // larger is a new place, taken at once.
        let hop = panel.frame.size == target.size && hypot(panel.frame.minX - target.minX, panel.frame.minY - target.minY) <= 12
        if hop { Fade.move(panel, to: target) } else { panel.setFrame(target, display: false) }
        view.configure(items: items, focused: focused, inactive: inactive, clearance: clearance, side: side, config: config)
        Fade.show(panel) { if !panel.isVisible { panel.orderBack(nil) } }
    }

    func hide() { Fade.hide(panel) }

    func snapshot(to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Key status for the rename field, without activating the app.
private final class EditablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class TabStripView: NSView, NSTextFieldDelegate {
    var onRename: ((WindowID, String?) -> Void)?
    var onEditingEnd: (() -> Void)?
    private var editor: NSTextField?
    private var editing: WindowID?
    private var editStarted = Date.distantPast
    var onSelect: ((WindowID) -> Void)?
    var onReorder: ((WindowID, Int) -> Void)?
    private var drag: ReorderDrag?
    private var settling: ReorderDrag?
    private var tabs: [TabView] = []
    private var items: [TabStripWindow.Item] = []
    private var pad: CGFloat = 16
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

    func configure(items: [TabStripWindow.Item], focused: WindowID?, inactive: Bool, clearance: CGFloat, side: TabStripWindow.Side, config: Config) {
        let before = self.items.map(\.id)
        self.items = items
        // Tabs that were not there grow in from nothing where they land; the others slide over to make room.
        let arrived = Set(items.map(\.id)).subtracting(before)
        animateNextLayout = Fade.enabled && !before.isEmpty && before != items.map(\.id) && drag == nil && settling == nil
        self.side = side
        pad = max(16, clearance)
        maxLength = config.tabWidth
        while tabs.count < items.count {
            let t = TabView()
            // Tabs change places in `tabs` after a drag, so each looks its index up when asked.
            let indexOf: (TabView) -> Int? = { [weak self] t in self?.tabs.firstIndex { $0 === t } }
            t.onClick = { [weak self, weak t] in
                guard let self, let t, let i = indexOf(t), i < self.items.count else { return }
                self.onSelect?(self.items[i].id)
            }
            t.onRename = { [weak self, weak t] in if let t, let i = indexOf(t) { self?.beginRename(i) } }
            t.onContextMenu = { [weak self, weak t] e in if let t, let i = indexOf(t) { self?.showMenu(for: i, with: e) } }
            t.onDragBegan = { [weak self, weak t] in if let t, let i = indexOf(t) { self?.beginDrag(i) } }
            t.onDragMoved = { [weak self] d in self?.drag?.update(delta: d) }
            t.onDragEnded = { [weak self] in self?.endDrag() }
            addSubview(t)
            tabs.append(t)
        }
        let accent = inactive ? FocusRing.inactiveColor : config.ringTiledColor
        activeIndex = items.firstIndex { $0.id == focused }
        for (i, t) in tabs.enumerated() {
            t.isHidden = i >= items.count
            guard i < items.count else { continue }
            let item = items[i]
            let active = item.id == focused
            // Re-adding a view that is already frontmost drops a frame; only move it when something is above it.
            if active, subviews.last !== t { addSubview(t, positioned: .above, relativeTo: nil) }
            let color: NSColor = active ? accent.contrastingText : .white
            let title = item.label.map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color]) }
                ?? BarView.formatTitle(config.tabTitleFormat, app: item.app, title: item.title, color: color)
            t.configure(title: title, active: active, accent: accent, side: side)
            t.isNew = arrived.contains(item.id)
        }
        needsLayout = true
        layoutTabs()
        animateNextLayout = false
        // A refresh re-adds the active tab on top; the rename field, if any, stays above all of them.
        if let editor { addSubview(editor, positioned: .above, relativeTo: nil) }
    }

    override func layout() {
        super.layout()
        layoutTabs()
        settling?.settle()
        settling = nil
        if let editor, let id = editing, let i = items.firstIndex(where: { $0.id == id }), let tab = tabs[safe: i] {
            editor.frame = editorFrame(over: tab.frame)
        }
    }

    private func editorFrame(over f: CGRect) -> CGRect {
        side == .top ? CGRect(x: f.minX + 6, y: f.minY + 4, width: f.width - 12, height: f.height - 8)
                     : CGRect(x: f.midX - 100, y: f.midY - 11, width: 200, height: 22)
    }

    // MARK: Renaming

    private func showMenu(for index: Int, with event: NSEvent) {
        guard index < items.count, let tab = tabs[safe: index] else { return }
        let menu = NSMenu()
        let rename = menu.addItem(withTitle: "Rename Tab…", action: #selector(menuRename(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = index
        if items[index].label != nil {
            let reset = menu.addItem(withTitle: "Use Window Title", action: #selector(menuReset(_:)), keyEquivalent: "")
            reset.target = self
            reset.representedObject = index
        }
        NSMenu.popUpContextMenu(menu, with: event, for: tab)
    }
    @objc private func menuRename(_ item: NSMenuItem) { if let i = item.representedObject as? Int { beginRename(i) } }
    @objc private func menuReset(_ item: NSMenuItem) {
        if let i = item.representedObject as? Int, i < items.count { onRename?(items[i].id, nil) }
    }

    /// An inline field over the tab; Return keeps the name, Escape or clicking away drops the edit.
    private func beginRename(_ index: Int) {
        guard index < items.count, let tab = tabs[safe: index], let window else { return }
        endRename(commit: false)
        let item = items[index]
        let field = NSTextField(string: item.label ?? item.title)
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = NSColor(white: 1, alpha: 0.95)
        field.textColor = .black
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.frame = editorFrame(over: tab.frame)
        addSubview(field)
        editor = field
        editing = item.id
        editStarted = Date()
        takeFocus()
    }

    /// The panel is non-activating: as the key window it gets the typing while the app stays in the background.
    /// The first click of the double click raised a window, which can take key status away a moment later; the
    /// late re-take covers that.
    private func takeFocus() {
        guard let window, let field = editor else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let field = editor, let id = editing else { return }
        let text = field.stringValue
        editor = nil
        editing = nil
        window?.makeFirstResponder(nil)
        field.removeFromSuperview()
        window?.orderBack(nil)
        if commit { onRename?(id, text) }
        onEditingEnd?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Return commits; focus leaving any other way (a click elsewhere) cancels. Except right after the edit
        // began: the first click of the double click raised the window, and its app taking focus back is not the
        // user leaving. The field takes the focus again.
        let byReturn = (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue
        if !byReturn, Date().timeIntervalSince(editStarted) < 0.8, editor != nil {
            DispatchQueue.main.async { [weak self] in self?.takeFocus() }
            return
        }
        endRename(commit: byReturn)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename(commit: false)
        return true
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
    private var animateNextLayout = false
    private func layoutTabs() {
        let n = CGFloat(max(1, items.count)), gap: CGFloat = 4
        var frames: [CGRect] = []
        if side != .top {
            // Sideways tabs: as long along the strip as a top tab is wide, as thick as the strip. On the left they
            // read bottom to top, so the deck runs that way too; on the right, top to bottom.
            let h = min(maxLength, (bounds.height - pad * 2 - gap * (n - 1)) / n)
            for i in 0..<items.count {
                let slot = side == .left ? CGFloat(items.count - 1 - i) : CGFloat(i)
                let y = pad + slot * (h + gap)
                frames.append(side == .left ? CGRect(x: 1, y: y, width: bounds.width - 1, height: h)
                                            : CGRect(x: 0, y: y, width: bounds.width - 1, height: h))
            }
        } else {
            let w = min(maxLength, (bounds.width - pad * 2 - gap * (n - 1)) / n)
            for i in 0..<items.count { frames.append(CGRect(x: pad + CGFloat(i) * (w + gap), y: 1, width: w, height: bounds.height - 1)) }
        }
        guard animateNextLayout else {
            for (t, f) in zip(tabs, frames) { t.frame = f; t.isNew = false }
            return
        }
        for (t, f) in zip(tabs, frames) {
            if t.isNew {
                // From a sliver at its own place to full size, so it reads as growing out of the strip.
                t.frame = side == .top ? CGRect(x: f.midX, y: f.minY, width: 0, height: f.height) : CGRect(x: f.minX, y: f.midY, width: f.width, height: 0)
                t.isNew = false
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Fade.duration
            ctx.timingFunction = Fade.curve
            for (t, f) in zip(tabs, frames) where t.frame != f { t.animator().frame = f }
        }
    }
}

/// One folder tab: rounded on the side away from the window, square where it meets it. The painted part is a
/// `body` view inside an invisible full-size frame: an inactive tab's body sits a few points closer to the window
/// (its far edge clipped by the strip), a hovered one halfway up, and the move between those is animated. The outer
/// view's layer is left to the reorder drag.
private final class TabView: NSView {
    var onClick: (() -> Void)?
    var onRename: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var horizontal = true
    /// Just added to the strip; the next animated layout grows it in.
    var isNew = false
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
        // This view is not flipped: for a top strip the window is below, at minY.
        switch side {
        case .top: f.origin.y -= target
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

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    /// A click brings the window forward; a double click renames the tab; a drag past a few points moves the tab
    /// along the strip.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onRename?(); return }
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

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
