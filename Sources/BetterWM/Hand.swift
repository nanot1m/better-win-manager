import BetterWMCore
import Cocoa

/// The hand: an arc of overlapping cards along the bottom of a screen, one per window held off the table, the
/// way a card game shows a hand. It peeks above the bottom edge and rises when the pointer reaches it. A card
/// dragged onto the table plays its window: with ⌥ held at the drop it is tiled into the zone under the pointer,
/// otherwise it floats where it was dropped. A window ⌥-dragged into the fan is held.
final class HandWindow {
    struct Item {
        let id: WindowID
        let pid: pid_t
        let app: String
        let title: String
        let icon: NSImage?
        /// Memory footprint of the app in GB, times ten: the card's cost (the gem top-left).
        let cost: Int
        /// CPU use of the app in percent of one core: attack.
        let attack: Int
        /// Windows the app has: health.
        let health: Int
    }

    private let panel: NSPanel
    private let view = HandView()
    private(set) var screen: NSScreen
    /// How much of the resting fan shows above the screen edge: enough for the cost gems and the art.
    static let peek: CGFloat = 96
    static var cardSize: CGSize { CardView.size }
    private var raised = false
    private var pinned = false

    /// A card dropped off the fan: the window, the drop point (AX), whether ⌥ was held, and the card in flight.
    var onPlay: ((WindowID, CGPoint, Bool, CardFlight) -> Void)? {
        get { view.onPlay }
        set { view.onPlay = newValue }
    }
    /// A card being carried: the drop point (AX) and whether ⌥ is held; x < 0 means it is back over the fan.
    var onDragMoved: ((WindowID, CGPoint, Bool) -> Void)? {
        get { view.onDragMoved }
        set { view.onDragMoved = newValue }
    }

    init(screen: NSScreen) {
        self.screen = screen
        panel = HandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the focus ring, which would otherwise draw across the resting fan.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = view
        view.onHoverChange = { [weak self] inside in
            guard let self, !self.pinned, !self.view.dragging else { return }
            self.raise(inside)
        }
        view.onDragEnd = { [weak self] in
            guard let self else { return }
            if !self.pinned, !self.view.mouseInside { self.raise(false) }
        }
    }

    var isVisible: Bool { panel.isVisible }
    /// The tray's frame in AX coordinates, as a drop target.
    var dropFrame: CGRect { frame(raised: raised).insetBy(dx: HandView.margin, dy: 0).toCocoa() }

    /// Where the fan sits (Cocoa coordinates) at rest and when raised.
    private func frame(raised: Bool) -> NSRect {
        let size = HandView.size(for: view.count, maxWidth: screen.frame.width * 0.6)
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = raised ? screen.frame.minY : screen.frame.minY - (HandView.restTop - Self.peek)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func show(items: [Item], on screen: NSScreen) {
        self.screen = screen
        view.configure(items: items)
        let f = frame(raised: raised)
        if panel.frame != f {
            // A card joining or leaving widens or narrows the fan: the others glide to their new places.
            if panel.isVisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(f, display: true)
                }
            } else {
                panel.setFrame(f, display: true)
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() { panel.orderOut(nil) }

    func raise(_ up: Bool) {
        guard raised != up else { return }
        raised = up
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame(raised: up), display: true)
        }
        view.setRaised(up)
    }

    /// Keeps the fan up until toggled again (the hotkey).
    func togglePinned() {
        pinned.toggle()
        raise(pinned || view.mouseInside)
    }

    /// Lights the fan up as a drop target for a window being carried over it.
    func setDropTarget(_ on: Bool) {
        view.setDropTarget(on)
        if on { raise(true) } else if !pinned, !view.mouseInside { raise(false) }
    }

    /// The card's resting frame in AX coordinates, for a card flying into the fan.
    func cardFrame(of id: WindowID) -> CGRect? {
        guard let f = view.cardFrame(of: id) else { return nil }
        return panel.convertToScreen(view.convert(f, to: nil)).toCocoa()
    }

    /// A rendering of the card for `item`, for a window morphing into it.
    static func render(_ item: Item) -> NSImage {
        let c = CardView(frame: CGRect(origin: .zero, size: CardView.size))
        c.configure(item)
        c.layoutSubtreeIfNeeded()
        return c.snapshot()
    }

    /// A card kept invisible until its flight lands.
    func hideCard(_ id: WindowID) { view.setCardHidden(id, true) }
    func revealCard(_ id: WindowID) { view.setCardHidden(id, false) }
}

/// A panel allowed to hang below the screen's bottom edge.
private final class HandPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

// MARK: - The fan

private final class HandView: NSView {
    /// How far a hovered card rises; the panel keeps that much room above the resting cards.
    static let lift: CGFloat = 70
    static let baseY: CGFloat = 10
    /// Room around the tray inside the panel, so tilted, lifted cards and their shadows are never clipped.
    static let margin: CGFloat = 70
    /// Top of the resting cards (the middle one, the highest of the arc).
    static var restTop: CGFloat { baseY + CardView.size.height }
    private static let sidePad: CGFloat = 40

    var onHoverChange: ((Bool) -> Void)?
    var onPlay: ((WindowID, CGPoint, Bool, CardFlight) -> Void)?
    var onDragMoved: ((WindowID, CGPoint, Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var mouseInside = false
    private(set) var dragging = false
    private var items: [HandWindow.Item] = []
    private var cards: [WindowID: CardView] = [:]
    private var hovered: WindowID?
    private var raised = false
    private let tray: NSView
    private let hint = NSTextField(labelWithString: "Drop a window here to hold it")
    private var hiddenCards: Set<WindowID> = []
    /// Set when the hand's contents changed while on screen: the next layout animates the cards into place.
    private var animateNextLayout = false
    var count: Int { items.count }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        // Liquid glass where macOS has it; a blurred material elsewhere.
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 28
            g.tintColor = NSColor(white: 0.05, alpha: 0.3)
            tray = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 28
            v.layer?.masksToBounds = true
            tray = v
        }
        super.init(frame: frame)
        wantsLayer = true
        addSubview(tray)
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        hint.alignment = .center
        addSubview(hint)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Panel size for `n` cards: the tray wide enough for the arc, with the margin around it and room above for a
    /// lifted, enlarged card.
    static func size(for n: Int, maxWidth: CGFloat) -> CGSize {
        let w = CardView.size.width
        let span = n > 1 ? w + Self.step(for: n, maxWidth: maxWidth) * CGFloat(n - 1) : w
        let tray = max(420, span + sidePad * 2)
        return CGSize(width: (tray + margin * 2).rounded(), height: restTop + lift + 60)
    }

    /// Horizontal distance between neighbouring cards: just over half a card, less as the hand fills up.
    private static func step(for n: Int, maxWidth: CGFloat) -> CGFloat {
        guard n > 1 else { return 0 }
        let w = CardView.size.width
        return min(w * 0.6, (maxWidth - sidePad * 2 - w) / CGFloat(n - 1))
    }

    func configure(items: [HandWindow.Item]) {
        if items.map(\.id) != self.items.map(\.id), window?.isVisible == true { animateNextLayout = true }
        self.items = items
        let ids = Set(items.map(\.id))
        for (id, c) in cards where !ids.contains(id) { c.removeFromSuperview(); cards[id] = nil }
        for item in items {
            let c = cards[item.id] ?? {
                let c = CardView(frame: CGRect(origin: .zero, size: CardView.size))
                c.onPress = { [weak self, weak c] e in if let c { self?.press(c, with: e) } }
                addSubview(c)
                cards[item.id] = c
                return c
            }()
            c.configure(item)
            c.isHidden = hiddenCards.contains(item.id)
        }
        // Later cards draw over earlier ones, like a hand held in the right hand.
        for item in items { if let c = cards[item.id] { addSubview(c, positioned: .above, relativeTo: nil) } }
        hint.isHidden = !items.isEmpty
        needsLayout = true
    }

    func setRaised(_ up: Bool) { raised = up; relayout(animated: true) }
    func setDropTarget(_ on: Bool) {
        if let g = tray as? NSVisualEffectView { g.layer?.borderWidth = on ? 2 : 0; g.layer?.borderColor = NSColor.controlAccentColor.cgColor }
        if #available(macOS 26, *), let g = tray as? NSGlassEffectView {
            g.tintColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor(white: 0.05, alpha: 0.3)
        }
    }
    func setCardHidden(_ id: WindowID, _ h: Bool) {
        if h { hiddenCards.insert(id) } else { hiddenCards.remove(id) }
        cards[id]?.isHidden = h
    }
    func cardFrame(of id: WindowID) -> CGRect? { restingFrames()[id]?.frame }

    override func layout() {
        super.layout()
        // The tray runs on below the screen edge so its bottom corners never show.
        tray.frame = CGRect(x: Self.margin, y: -60, width: bounds.width - Self.margin * 2, height: Self.restTop + 24 + 60)
        hint.sizeToFit()
        hint.frame = CGRect(x: 0, y: Self.restTop / 2 - hint.frame.height / 2, width: bounds.width, height: hint.frame.height)
        relayout(animated: animateNextLayout)
        animateNextLayout = false
    }

    /// The arc: cards overlap along a curve, the middle one highest and upright, the outer ones lower and tilted
    /// outward, as a hand is held.
    private func restingFrames() -> [WindowID: (frame: CGRect, angle: CGFloat)] {
        var out: [WindowID: (CGRect, CGFloat)] = [:]
        let n = items.count
        guard n > 0 else { return out }
        let w = CardView.size.width
        let step = Self.step(for: n, maxWidth: bounds.width - Self.margin * 2)
        let span = w + step * CGFloat(n - 1)
        let x0 = ((bounds.width - span) / 2).rounded()
        let mid = CGFloat(n - 1) / 2
        let perCard: CGFloat = n > 7 ? 3.5 : 5
        for (i, item) in items.enumerated() {
            let off = CGFloat(i) - mid
            let angle = -off * perCard * .pi / 180
            let drop = off * off * (n > 7 ? 1.6 : 3)
            let frame = CGRect(x: x0 + (CGFloat(i) * step).rounded(), y: Self.baseY - drop, width: w, height: CardView.size.height)
            out[item.id] = (frame, angle)
        }
        return out
    }

    private func relayout(animated: Bool) {
        let rest = restingFrames()
        for (i, item) in items.enumerated() {
            guard let c = cards[item.id], let (f, angle) = rest[item.id], !c.isDragging else { continue }
            let hover = hovered == item.id
            var frame = f
            if hover {
                frame.origin.y = Self.baseY + Self.lift
            } else if !raised {
                frame.origin.y -= 8
            }
            c.layer?.zPosition = hover ? 100 : CGFloat(i)
            c.set(frame: frame, angle: hover ? 0 : angle, scale: hover ? 1.18 : 1, lifted: hover, animated: animated)
        }
    }

    /// Cards overlap, so the topmost drawn one under the pointer wins: the hovered card, else the latest in order.
    private func card(at p: CGPoint) -> CardView? {
        if let h = hovered, let c = cards[h], c.hitFrame.contains(p) { return c }
        return items.reversed().compactMap { cards[$0.id] }.first { !$0.isHidden && $0.hitFrame.contains(p) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return card(at: p) ?? super.hitTest(point)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        onHoverChange?(true)
    }
    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        if hovered != nil { hovered = nil; relayout(animated: true) }
        onHoverChange?(false)
    }
    override func mouseMoved(with event: NSEvent) {
        guard !dragging else { return }
        let under = card(at: convert(event.locationInWindow, from: nil))?.item?.id
        if under != hovered { hovered = under; relayout(animated: true) }
    }

    /// A click plays the card into a new column; a drag carries it, and the drop point and ⌥ decide where it lands.
    private func press(_ card: CardView, with event: NSEvent) {
        guard let window, let id = card.item?.id else { return }
        let start = NSEvent.mouseLocation
        var flight: CardFlight?
        var alt = event.modifierFlags.contains(.option)
        let origin = window.convertToScreen(convert(card.frame, to: nil))
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged]) {
            let p = NSEvent.mouseLocation
            alt = e.modifierFlags.contains(.option)
            if e.type == .leftMouseUp { break }
            if flight == nil, hypot(p.x - start.x, p.y - start.y) > 6 {
                dragging = true
                card.isDragging = true
                flight = CardFlight(card: card.snapshot(), frame: origin)
                flight?.pickUp()
                card.isHidden = true
            }
            if let flight {
                flight.carry(center: p)
                onDragMoved?(id, window.frame.contains(p) ? CGPoint(x: -1, y: -1) : p.toAX(), alt)
            }
        }
        dragging = false
        card.isDragging = false
        let p = NSEvent.mouseLocation
        if let flight {
            if window.frame.contains(p) {
                // Dropped back on the fan: the card settles home.
                flight.setDown()
                flight.fly(to: origin, duration: 0.24) { [weak card] in card?.isHidden = false; flight.dismiss() }
                onDragMoved?(id, CGPoint(x: -1, y: -1), alt)
            } else {
                onPlay?(id, p.toAX(), alt, flight)
            }
        } else {
            onPlay?(id, CGPoint(x: -1, y: -1), alt, CardFlight(card: card.snapshot(), frame: origin))
        }
        onDragEnd?()
    }
}

// MARK: - One card

/// A collectible-card look: a gold-edged dark frame, the app's icon in an oval portrait, a cost gem top-left,
/// the app's name on a ribbon, the window's title in a parchment box, attack and health gems at the bottom.
private final class CardView: NSView {
    static let size = CGSize(width: 148, height: 212)
    private(set) var item: HandWindow.Item?
    var onPress: ((NSEvent) -> Void)?
    var isDragging = false
    private let frameLayer = CAGradientLayer()
    private let inner = CAGradientLayer()
    private let portrait = CAGradientLayer()
    private let portraitRing = CAShapeLayer()
    private let icon = CALayer()
    private let nameRibbon = CALayer()
    private let name = CATextLayer()
    private let box = CALayer()
    private let text = CATextLayer()
    private let costGem = Gem(colors: [NSColor(calibratedRed: 0.62, green: 0.82, blue: 1, alpha: 1), NSColor(calibratedRed: 0.1, green: 0.3, blue: 0.85, alpha: 1)])
    private let attackGem = Gem(colors: [NSColor(calibratedRed: 1, green: 0.92, blue: 0.55, alpha: 1), NSColor(calibratedRed: 0.85, green: 0.58, blue: 0.08, alpha: 1)])
    private let healthGem = Gem(colors: [NSColor(calibratedRed: 1, green: 0.55, blue: 0.5, alpha: 1), NSColor(calibratedRed: 0.68, green: 0.08, blue: 0.1, alpha: 1)])
    static let gold = NSColor(calibratedRed: 0.84, green: 0.7, blue: 0.36, alpha: 1)
    private static let goldDark = NSColor(calibratedRed: 0.48, green: 0.36, blue: 0.14, alpha: 1)
    private static let parchment = NSColor(calibratedRed: 0.88, green: 0.81, blue: 0.66, alpha: 1).cgColor
    private static let ink = NSColor(calibratedRed: 0.16, green: 0.11, blue: 0.06, alpha: 1).cgColor
    private static func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
    }

    /// Where the card is on screen for hit testing, scale included; the view's frame ignores its layer transform.
    var hitFrame: CGRect {
        guard let layer else { return frame }
        let s = layer.transform.m11
        return frame.insetBy(dx: -(s - 1) * frame.width / 2, dy: -(s - 1) * frame.height / 2)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        layer.masksToBounds = false
        layer.actions = ["transform": NSNull(), "position": NSNull(), "bounds": NSNull(), "shadowRadius": NSNull(), "shadowOffset": NSNull(), "shadowOpacity": NSNull()]
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.5
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -3)
        frameLayer.colors = [Self.gold.cgColor, Self.goldDark.cgColor, Self.gold.cgColor, Self.goldDark.cgColor]
        frameLayer.locations = [0, 0.35, 0.7, 1]
        frameLayer.startPoint = CGPoint(x: 0, y: 1)
        frameLayer.endPoint = CGPoint(x: 1, y: 0)
        frameLayer.cornerRadius = 14
        inner.colors = [NSColor(calibratedRed: 0.2, green: 0.21, blue: 0.28, alpha: 1).cgColor, NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.14, alpha: 1).cgColor]
        inner.startPoint = CGPoint(x: 0.5, y: 1)
        inner.endPoint = CGPoint(x: 0.5, y: 0)
        inner.cornerRadius = 11
        inner.masksToBounds = true
        portrait.type = .radial
        portrait.colors = [NSColor(calibratedRed: 0.36, green: 0.4, blue: 0.55, alpha: 1).cgColor, NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.2, alpha: 1).cgColor]
        portrait.startPoint = CGPoint(x: 0.5, y: 0.6)
        portrait.endPoint = CGPoint(x: 1, y: 0)
        portraitRing.fillColor = nil
        portraitRing.strokeColor = Self.gold.cgColor
        portraitRing.lineWidth = 2.5
        icon.contentsGravity = .resizeAspect
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.5
        icon.shadowRadius = 6
        icon.shadowOffset = CGSize(width: 0, height: -3)
        nameRibbon.backgroundColor = Self.parchment
        nameRibbon.cornerRadius = 5
        nameRibbon.borderWidth = 1
        nameRibbon.borderColor = Self.goldDark.cgColor
        name.font = Self.serif(11.5, .bold)
        name.fontSize = 11.5
        name.foregroundColor = Self.ink
        name.alignmentMode = .center
        name.truncationMode = .end
        box.backgroundColor = Self.parchment
        box.cornerRadius = 6
        box.borderWidth = 1
        box.borderColor = Self.goldDark.cgColor
        text.font = Self.serif(9.5, .medium)
        text.fontSize = 9.5
        text.foregroundColor = Self.ink
        text.alignmentMode = .center
        text.isWrapped = true
        text.truncationMode = .end
        for l in [frameLayer, inner, portrait, portraitRing, icon, nameRibbon, name, box, text] as [CALayer] {
            l.contentsScale = 2
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "path": NSNull()]
        }
        layer.addSublayer(frameLayer)
        layer.addSublayer(inner)
        layer.addSublayer(portrait)
        layer.addSublayer(portraitRing)
        layer.addSublayer(icon)
        layer.addSublayer(box)
        box.addSublayer(text)
        layer.addSublayer(nameRibbon)
        nameRibbon.addSublayer(name)
        for g in [costGem, attackGem, healthGem] { layer.addSublayer(g) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(_ item: HandWindow.Item) {
        self.item = item
        icon.contents = item.icon
        name.string = item.app
        text.string = item.title
        costGem.value = "\(item.cost)"
        attackGem.value = "\(item.attack)"
        healthGem.value = "\(item.health)"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        frameLayer.frame = b
        inner.frame = b.insetBy(dx: 3, dy: 3)
        // The portrait sits in the upper half, its ring breaking the inner edge the way a minion's art does.
        let oval = CGRect(x: 24, y: b.height - 122, width: b.width - 48, height: 108)
        portrait.frame = oval
        let mask = CAShapeLayer()
        mask.path = CGPath(ellipseIn: portrait.bounds, transform: nil)
        portrait.mask = mask
        portraitRing.path = CGPath(ellipseIn: oval, transform: nil)
        icon.frame = CGRect(x: oval.midX - 30, y: oval.midY - 30, width: 60, height: 60)
        nameRibbon.frame = CGRect(x: 12, y: oval.minY - 14, width: b.width - 24, height: 24)
        name.frame = CGRect(x: 6, y: 5, width: nameRibbon.bounds.width - 12, height: 15)
        let boxTop = nameRibbon.frame.minY - 8
        box.frame = CGRect(x: 16, y: 22, width: b.width - 32, height: boxTop - 22)
        text.frame = CGRect(x: 6, y: box.bounds.midY - 13, width: box.bounds.width - 12, height: 26)
        let gem: CGFloat = 36
        costGem.frame = CGRect(x: -6, y: b.height - gem + 4, width: gem, height: gem)
        attackGem.frame = CGRect(x: -4, y: -4, width: gem, height: gem)
        healthGem.frame = CGRect(x: b.width - gem + 4, y: -4, width: gem, height: gem)
        for g in [costGem, attackGem, healthGem] { g.relayout() }
    }

    /// Frame, tilt, scale and shadow together, animated as one so the card glides rather than jumps; a lifted
    /// card casts a longer, softer shadow.
    func set(frame f: CGRect, angle: CGFloat, scale: CGFloat, lifted: Bool, animated: Bool) {
        guard let layer else { return }
        let t = CATransform3DScale(CATransform3DMakeRotation(angle, 0, 0, 1), scale, scale, 1)
        let from = layer.presentation()?.transform ?? layer.transform
        let fromPos = layer.presentation()?.position ?? layer.position
        let fromRadius = layer.presentation()?.shadowRadius ?? layer.shadowRadius
        let fromOffset = layer.presentation()?.shadowOffset ?? layer.shadowOffset
        self.frame = f
        layer.transform = t
        layer.shadowRadius = lifted ? 18 : 6
        layer.shadowOffset = CGSize(width: 0, height: lifted ? -12 : -3)
        guard animated, window != nil else { return }
        let anims: [(String, Any, Any)] = [("position", fromPos, layer.position), ("transform", from, t),
                                           ("shadowRadius", fromRadius, layer.shadowRadius), ("shadowOffset", fromOffset, layer.shadowOffset)]
        for (key, a, b) in anims {
            let anim = CABasicAnimation(keyPath: key)
            anim.fromValue = a
            anim.toValue = b
            anim.duration = 0.26
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(anim, forKey: key)
        }
    }

    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return img }
        cacheDisplay(in: bounds, to: rep)
        img.addRepresentation(rep)
        return img
    }

    override func mouseDown(with event: NSEvent) { onPress?(event) }
}

/// A round gem with a number on it: a radial gradient inside a gold rim.
private final class Gem: CALayer {
    private let fill = CAGradientLayer()
    private let label = CATextLayer()
    var value: String = "" { didSet { label.string = value } }

    init(colors: [NSColor]) {
        super.init()
        contentsScale = 2
        backgroundColor = CardView.gold.cgColor
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.45
        shadowRadius = 3
        shadowOffset = CGSize(width: 0, height: -1)
        fill.type = .radial
        fill.colors = colors.map(\.cgColor)
        fill.startPoint = CGPoint(x: 0.35, y: 0.65)
        fill.endPoint = CGPoint(x: 1, y: 0)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .heavy)
        label.fontSize = 15
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.shadowColor = NSColor.black.cgColor
        label.shadowOpacity = 0.8
        label.shadowRadius = 1
        label.shadowOffset = CGSize(width: 0, height: -1)
        for l in [fill, label] as [CALayer] { l.contentsScale = 2; l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()] }
        actions = ["bounds": NSNull(), "position": NSNull()]
        addSublayer(fill)
        addSublayer(label)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func relayout() {
        cornerRadius = bounds.width / 2
        fill.frame = bounds.insetBy(dx: 2.5, dy: 2.5)
        fill.cornerRadius = fill.bounds.width / 2
        label.frame = CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
    }
}

// MARK: - A card in flight

/// A card travelling between the table and the fan, in a panel of its own with room around it for a shadow.
/// A window picked up starts as its own snapshot and is sucked into the card, genie style; a card picked up
/// lifts off the fan (bigger, longer shadow) and settles when dropped. Cocoa coordinates throughout.
final class CardFlight {
    private let panel: NSPanel
    private let content = NSView()
    private let picture = CALayer()
    private let card = CALayer()
    private var rows: [CALayer] = []
    private var genieTimer: Timer?
    private static let margin: CGFloat = 60
    private var lifted = false
    /// The card's frame on screen, without the margin.
    private(set) var frame: NSRect

    /// A card as it looks in the fan, at `frame`.
    convenience init(card image: NSImage, frame: NSRect) {
        self.init(frame: frame, picture: nil, card: image)
    }

    /// A window's snapshot at the window's frame, with the card it is to become.
    convenience init(window image: NSImage?, frame: NSRect, card: NSImage) {
        self.init(frame: frame, picture: image, card: card)
    }

    private init(frame: NSRect, picture image: NSImage?, card cardImage: NSImage) {
        self.frame = frame
        let outer = frame.insetBy(dx: -Self.margin, dy: -Self.margin)
        panel = NSPanel(contentRect: outer, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        content.frame = NSRect(origin: .zero, size: outer.size)
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        for l in [picture, card] {
            l.contentsScale = 2
            l.cornerRadius = 14
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull()]
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        }
        picture.masksToBounds = true
        picture.contents = image
        picture.opacity = image == nil ? 0 : 1
        card.contents = cardImage
        card.opacity = image == nil ? 1 : 0
        card.shadowColor = NSColor.black.cgColor
        card.shadowOpacity = 0.5
        card.shadowRadius = 8
        card.shadowOffset = CGSize(width: 0, height: -4)
        picture.frame = content.bounds.insetBy(dx: Self.margin, dy: Self.margin)
        card.frame = picture.frame
        content.layer?.addSublayer(picture)
        content.layer?.addSublayer(card)
        panel.contentView = content
        panel.orderFrontRegardless()
    }

    /// A window becomes a card, genie style: the snapshot is cut into rows that bend toward the card's edges and
    /// funnel into it, the rows nearest the card first, and the card appears as the last of them arrive.
    func morph(toCardAt center: NSPoint, duration: TimeInterval = 0.5, then: (() -> Void)? = nil) {
        guard let image = picture.contents as? NSImage else { return fly(to: Self.cardRect(at: center), duration: duration, then: then) }
        let src = frame
        let dst = Self.cardRect(at: center)
        // The panel covers both ends for the duration; the layers inside do the work.
        let union = src.union(dst).insetBy(dx: -Self.margin, dy: -Self.margin)
        panel.setFrame(union, display: false)
        content.frame = NSRect(origin: .zero, size: union.size)
        let toLocal = { (r: NSRect) in NSRect(x: r.minX - union.minX, y: r.minY - union.minY, width: r.width, height: r.height) }
        let s = toLocal(src), d = toLocal(dst)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.isHidden = true
        card.frame = d
        card.opacity = 0
        let n = 48
        let rowH = s.height / CGFloat(n)
        rows = (0..<n).map { i in
            let r = CALayer()
            r.contents = image
            r.contentsScale = 2
            r.contentsGravity = .resize
            r.contentsRect = CGRect(x: 0, y: CGFloat(i) / CGFloat(n), width: 1, height: 1 / CGFloat(n))
            r.frame = CGRect(x: s.minX, y: s.minY + CGFloat(i) * rowH, width: s.width, height: rowH + 0.5)
            r.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            content.layer?.insertSublayer(r, below: card)
            return r
        }
        CATransaction.commit()
        let start = Date()
        // Rows nearer the card start bending sooner; the whole stack slides into the card's height as it goes.
        let towardTop = d.midY > s.midY
        func smooth(_ x: CGFloat) -> CGFloat { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        genieTimer?.invalidate()
        genieTimer = Timer(timeInterval: 1 / 60, repeats: true) { [self] timer in
            let t = CGFloat(min(1, Date().timeIntervalSince(start) / duration))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, r) in rows.enumerated() {
                let pos = CGFloat(i) / CGFloat(n - 1)
                let nearness = towardTop ? pos : 1 - pos
                let bend = smooth((t * 1.5 - (1 - nearness) * 0.5) / 0.6)
                let x0 = s.minX + (d.minX - s.minX) * bend, x1 = s.maxX + (d.maxX - s.maxX) * bend
                let slide = smooth(t * 1.15 - 0.15)
                let srcY = s.minY + CGFloat(i) * rowH, dstY = d.minY + pos * (d.height - d.height / CGFloat(n))
                let h = rowH + (d.height / CGFloat(n) - rowH) * slide
                r.frame = CGRect(x: x0, y: srcY + (dstY - srcY) * slide, width: max(1, x1 - x0), height: h + 0.5)
                r.opacity = Float(1 - smooth((t - 0.8) / 0.2))
            }
            card.opacity = Float(smooth((t - 0.7) / 0.3))
            CATransaction.commit()
            if t >= 1 {
                timer.invalidate()
                genieTimer = nil
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                rows.forEach { $0.removeFromSuperlayer() }
                rows = []
                panel.setFrame(dst.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
                content.frame = NSRect(origin: .zero, size: panel.frame.size)
                card.frame = content.bounds.insetBy(dx: Self.margin, dy: Self.margin)
                CATransaction.commit()
                frame = dst
                pickUp()
                then?()
            }
        }
        RunLoop.main.add(genieTimer!, forMode: .common)
    }

    private static func cardRect(at center: NSPoint) -> NSRect {
        let size = CardView.size
        return NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Off the table: a touch bigger, with a long soft shadow, as if lifted toward the viewer.
    func pickUp() {
        guard !lifted else { return }
        lifted = true
        animate(scale: 1.08, shadowRadius: 26, shadowY: -18)
    }

    /// Back down: normal size, short shadow.
    func setDown() {
        guard lifted else { return }
        lifted = false
        animate(scale: 1, shadowRadius: 8, shadowY: -4)
    }

    private func animate(scale: CGFloat, shadowRadius: CGFloat, shadowY: CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        card.transform = CATransform3DMakeScale(scale, scale, 1)
        card.shadowRadius = shadowRadius
        card.shadowOffset = CGSize(width: 0, height: shadowY)
        CATransaction.commit()
    }

    /// Under a moving pointer, centred on it.
    func carry(center: NSPoint) {
        guard genieTimer == nil else { return }
        frame = NSRect(x: center.x - frame.width / 2, y: center.y - frame.height / 2, width: frame.width, height: frame.height)
        panel.setFrameOrigin(NSPoint(x: frame.minX - Self.margin, y: frame.minY - Self.margin))
    }

    /// Glides and resizes to `target`, then calls back.
    func fly(to target: NSRect, duration: TimeInterval, then: (() -> Void)? = nil) {
        frame = target
        NSAnimationContext.runAnimationGroup({ [panel] ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        }, completionHandler: then)
    }

    /// The card lands on the table: sets down, grows into `target` and gives way to the window appearing there.
    func drop(onto target: NSRect, then: @escaping () -> Void) {
        setDown()
        fly(to: target, duration: 0.3) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            self.card.opacity = 0
            CATransaction.commit()
            then()
        }
    }

    func fade(duration: TimeInterval = 0.18) {
        genieTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ [panel] ctx in
            ctx.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }

    func dismiss() {
        genieTimer?.invalidate()
        panel.orderOut(nil)
    }
}

// MARK: - Card stats

enum ProcessStats {
    private static var cpuSamples: [pid_t: (time: UInt64, at: Date)] = [:]

    private static func rusage(_ pid: pid_t) -> rusage_info_current? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return ok == 0 ? info : nil
    }

    /// Physical footprint in GB, as Activity Monitor's Memory column shows it.
    static func gigabytes(_ pid: pid_t) -> Double {
        rusage(pid).map { Double($0.ri_phys_footprint) / 1_073_741_824 } ?? 0
    }

    /// CPU use since the last sample, percent of one core; the first sample answers 0.
    static func cpuPercent(_ pid: pid_t) -> Double {
        guard let info = rusage(pid) else { return 0 }
        let total = info.ri_user_time + info.ri_system_time
        let now = Date()
        defer { cpuSamples[pid] = (total, now) }
        guard let last = cpuSamples[pid], now.timeIntervalSince(last.at) > 0.2 else { return 0 }
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        let ns = Double(total - last.time) * Double(tb.numer) / Double(tb.denom)
        return min(999, ns / 1e9 / now.timeIntervalSince(last.at) * 100)
    }
}
