import Cocoa

/// Built-in hand-drawn frames: 16x11 pixels, facing right, mirrored for left.
enum BuiltinCatArt {
    // 16x11, facing right: ear and head on the right, tail curling up on the left.
    static let walk: [[String]] = [
        [
            "...........#..#.",
            "...........####.",
            "...........#.##.",
            "#.....##########",
            "#....###########",
            ".#.#############",
            "..##############",
            "....############",
            "....#..#...#..#.",
            "....#..#...#..#.",
            "...#..#.....#..#",
        ],
        [
            "...........#..#.",
            "...........####.",
            "...........#.##.",
            ".#....##########",
            "#....###########",
            "#..#############",
            ".###############",
            "....############",
            ".....#..#..#..#.",
            ".....#..#..#..#.",
            ".....#..#..#..#.",
        ],
        [
            "...........#..#.",
            "...........####.",
            "...........#.##.",
            "#.....##########",
            ".#...###########",
            ".#.#############",
            "..##############",
            "....############",
            "....#..#...#..#.",
            "....#..#...#..#.",
            ".....#..#..#..#.",
        ],
    ]
    static let sit: [[String]] = [
        [
            "...........#..#.",
            "...........####.",
            "...........#.##.",
            "..........######",
            "........########",
            "......##########",
            ".....###########",
            "....############",
            "...#.###########",
            "..#..###....###.",
            "...##.#.....#...",
        ],
        [
            "...........#..#.",
            "...........####.",
            "...........#.##.",
            "..........######",
            "........########",
            "......##########",
            ".....###########",
            "....############",
            "....############",
            "..#.####....###.",
            "...#..#.....#...",
        ],
    ]
    static let groom: [[String]] = [
        [
            "................",
            "................",
            "...........#..#.",
            "...........####.",
            "#.....######.###",
            "#....###########",
            ".#.#############",
            "..##############",
            "....##########.#",
            "....#..#...#.#..",
            "...#..#.....##..",
        ],
        [
            "................",
            "................",
            "...........#..#.",
            "...........####.",
            "#.....######.###",
            ".#...###########",
            ".#.#############",
            "..##############",
            "....###########.",
            "....#..#...#.##.",
            "...#..#.....#...",
        ],
    ]
    static let sleep: [[String]] = [
        [
            "................",
            "................",
            "................",
            "................",
            ".......####.....",
            "....#########...",
            "..###########.#.",
            ".##############.",
            ".###.#######.##.",
            "..###.####.###..",
            "....##....##....",
        ],
        [
            "............###.",
            ".............#..",
            "............###.",
            ".......####.....",
            "....##########..",
            "..############.#",
            ".##############.",
            ".###.#######.##.",
            ".###.#######.##.",
            "..###.####.###..",
            "....##....##....",
        ],
    ]
    static let stretch: [[String]] = [
        [
            "................",
            ".#..............",
            ".#...######.....",
            "..#..########...",
            "...###########..",
            "....###########.",
            "......##########",
            ".......######..#",
            ".........####...",
            ".........#..#...",
            "........#....#..",
        ],
    ]

}

/// One cat: sprite, position and current animation. Movement is driven by the herd.
final class Cat {
    enum Mode { case walk, run, sit, groom, sleep, stretch, lie }

    let sprite = NSImageView()
    /// Second copy of the sprite, shown only while the cat is half-way through a portal.
    let ghost = NSImageView()
    let sheet: CatSheet?
    private var walkFrames: [NSImage] = []
    private var idle: [Mode: [NSImage]] = [:]
    var mode: Mode = .walk
    var modeUntil = Date.distantFuture
    var direction: CGFloat = 1
    var x: CGFloat = 0

    var size: NSSize { sheet?.spriteSize ?? Cat.builtinSize }
    static var builtinScale: CGFloat = 2
    static var builtinSize: NSSize { NSSize(width: 16 * builtinScale, height: 11 * builtinScale) }

    init(sheet: CatSheet?, color: NSColor) {
        self.sheet = sheet
        for v in [sprite, ghost] {
            v.imageScaling = .scaleNone
            v.wantsLayer = true
            v.frame = NSRect(origin: .zero, size: size)
        }
        ghost.isHidden = true
        if sheet == nil { rebuildBuiltin(color: color) }
        sprite.image = frame("walk", tick: 0, every: 1)
    }

    func rebuildBuiltin(color: NSColor) {
        guard sheet == nil else { return }
        func render(_ rows: [String]) -> NSImage {
            let s = Cat.builtinScale
            return NSImage(size: Cat.builtinSize, flipped: true) { _ in
                NSGraphicsContext.current?.imageInterpolation = .none
                for (y, row) in rows.enumerated() {
                    for (x, ch) in row.enumerated() where ch == "#" {
                        color.setFill()
                        NSRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s).fill()
                    }
                }
                return true
            }
        }
        walkFrames = BuiltinCatArt.walk.map(render)
        idle = [.sit: BuiltinCatArt.sit.map(render), .groom: BuiltinCatArt.groom.map(render),
                .sleep: BuiltinCatArt.sleep.map(render), .stretch: BuiltinCatArt.stretch.map(render)]
    }

    /// Current frame for an animation, advancing every `every` ticks; sheet frames are per direction.
    func frame(_ name: String, tick: Int, every: Int) -> NSImage? {
        let frames: [NSImage]
        if let sheet {
            frames = sheet.frames(name, right: direction > 0)
        } else {
            switch name {
            case "walk", "run": frames = walkFrames
            case "sit": frames = idle[.sit] ?? []
            case "groom": frames = idle[.groom] ?? []
            case "sleep": frames = idle[.sleep] ?? []
            case "stretch": frames = idle[.stretch] ?? []
            default: frames = idle[.sit] ?? []
            }
        }
        guard !frames.isEmpty else { return nil }
        return frames[(tick / max(1, every)) % frames.count]
    }

    func enter(_ m: Mode, for seconds: ClosedRange<Double>? = nil) {
        mode = m
        let range: ClosedRange<Double>
        switch m {
        case .walk: modeUntil = .distantFuture; return
        case .run: range = 1...2
        case .sit: range = 3...7
        case .groom: range = 2...4
        case .sleep: range = 8...20
        case .stretch: range = 1.2...1.2
        case .lie: range = 4...9
        }
        let r = seconds ?? range
        modeUntil = Date().addingTimeInterval(Double.random(in: r))
    }

    func render(tick: Int) {
        let name: String
        let every: Int
        switch mode {
        case .walk: (name, every) = ("walk", 1)
        case .run: (name, every) = ("run", 1)
        case .sit: (name, every) = ("sit", 4)
        case .groom: (name, every) = ("groom", 2)
        case .sleep: (name, every) = ("sleep", 8)
        case .lie: (name, every) = (sheet == nil ? "sit" : "lie", 6)
        case .stretch: (name, every) = (sheet == nil ? "stretch" : "lie", 6)
        }
        sprite.image = frame(name, tick: tick, every: every)
        ghost.image = sprite.image
        // Built-in art faces right and is mirrored when facing left (about its own width; the layer anchor stays at the origin).
        let mirror = sheet == nil && direction < 0
        let t = mirror ? CGAffineTransform(translationX: size.width, y: 0).scaledBy(x: -1, y: 1) : .identity
        sprite.layer?.setAffineTransform(t)
        ghost.layer?.setAffineTransform(t)
    }

    /// Shows only the part of `view` between `lo` and `hi` (in the cat's own left-to-right coordinates); nil shows all.
    func clip(_ view: NSImageView, to range: ClosedRange<CGFloat>?) {
        guard let range else { view.layer?.mask = nil; return }
        let mirror = sheet == nil && direction < 0
        let a = min(max(range.lowerBound, 0), size.width), b = min(max(range.upperBound, a), size.width)
        let lo = mirror ? size.width - b : a
        let hi = mirror ? size.width - a : b
        let mask = view.layer?.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: lo, y: 0, width: max(0, hi - lo), height: size.height)
        CATransaction.commit()
        view.layer?.mask = mask
    }
}

/// A Portal-style oval: a glowing ring in blue or orange, drawn at a notch edge while a cat passes through.
final class PortalView: NSView {
    let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let outer = NSBezierPath(ovalIn: r)
        color.withAlphaComponent(0.35).setFill()
        outer.fill()
        outer.lineWidth = 2
        color.setStroke()
        outer.stroke()
        let inner = NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.3, dy: r.height * 0.18))
        inner.lineWidth = 1
        color.blended(withFraction: 0.6, of: .white)?.setStroke()
        inner.stroke()
    }
}

/// The cats living in the status bar: independent wandering plus occasional two-cat scenes.
final class BarCat: NSView {
    private var cats: [Cat] = []
    private var timer: Timer?
    private var tick = 0
    private var color: NSColor = .labelColor
    private var barHeight: CGFloat = 28

    private enum Scene {
        case free
        /// One cat approaches the other, then both hold a pose facing each other.
        case meeting(a: Int, b: Int, hold: Cat.Mode, approaching: Bool, until: Date)
        case chase(chaser: Int, runner: Int, until: Date)
    }
    private var scene: Scene = .free
    /// Pointer x in this view while it hovers the cats' strip; the cats run to catch it.
    private var pointerX: CGFloat?
    /// Cats being petted keep their pose until it ends, whatever the pointer does.
    private var pettedUntil: [ObjectIdentifier: Date] = [:]

    /// The notch, in this view's coordinates, with a little breathing room. Cats cross it through a pair of
    /// portals: whatever part of a cat has entered one edge comes out of the other.
    var gap: ClosedRange<CGFloat>? {
        didSet {
            guard let g = gap else { portalLeft.isHidden = true; portalRight.isHidden = true; return }
            portalLeft.isHidden = false; portalRight.isHidden = false
            let h = max(10, bounds.height - 6), w: CGFloat = 10
            portalLeft.frame = NSRect(x: g.lowerBound - w / 2, y: (bounds.height - h) / 2, width: w, height: h)
            portalRight.frame = NSRect(x: g.upperBound - w / 2, y: (bounds.height - h) / 2, width: w, height: h)
        }
    }
    private let portalLeft = PortalView(color: NSColor(srgbRed: 0.25, green: 0.6, blue: 1, alpha: 1))
    private let portalRight = PortalView(color: NSColor(srgbRed: 1, green: 0.6, blue: 0.15, alpha: 1))
    private var portalsLit = false

    /// Horizontal range the cats may roam, in this view's coordinates; set by the bar after layout.
    var roam: ClosedRange<CGFloat> = 0...0 {
        didSet {
            if oldValue.upperBound - oldValue.lowerBound < 1, roam.upperBound - roam.lowerBound > 1 { scatter() }
            clampAll()
        }
    }

    /// Random starting spots, so the cats don't all file in from the left on every launch.
    private func scatter() {
        for c in cats {
            c.x = CGFloat.random(in: roam.lowerBound...max(roam.lowerBound, roam.upperBound - c.size.width))
            c.direction = Bool.random() ? 1 : -1
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for p in [portalLeft, portalRight] { p.isHidden = true; addSubview(p) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.step() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    /// `sheets`: one entry per cat, a PNG path or "builtin". Empty means a single built-in cat.
    func configure(sheets: [String], color: NSColor, barHeight: CGFloat) {
        self.color = color
        self.barHeight = barHeight
        cats.forEach { $0.sprite.removeFromSuperview(); $0.ghost.removeFromSuperview() }
        cats = []
        scene = .free
        let entries = sheets.isEmpty ? ["builtin"] : sheets
        let scale = max(0.5, floor((barHeight - 4) / CatSheet.crop.height * 2) / 2)
        for entry in entries {
            var sheet: CatSheet?
            if entry.lowercased() != "builtin" {
                sheet = CatSheet(path: (entry as NSString).expandingTildeInPath, scale: scale)
                if sheet == nil { print("Cat: could not load sprite sheet at \(entry); using the built-in cat.") }
            }
            let cat = Cat(sheet: sheet, color: color)
            cat.x = CGFloat.random(in: roam.lowerBound...max(roam.lowerBound, roam.upperBound - cat.size.width))
            cat.direction = Bool.random() ? 1 : -1
            // Cats pass in front of the portals, so the oval frames the clipped edge rather than covering it.
            addSubview(cat.sprite, positioned: .above, relativeTo: portalRight)
            addSubview(cat.ghost, positioned: .above, relativeTo: portalRight)
            cats.append(cat)
        }
        clampAll()
    }

    /// A cat whose left edge has passed the left portal (or right edge the right one) is entirely inside the
    /// notch, so it pops out on the other side.
    private func crossGap(_ c: Cat) {
        guard let g = gap else { return }
        let width = g.upperBound - g.lowerBound
        if c.direction > 0, c.x >= g.lowerBound, c.x < g.upperBound { c.x += width }
        else if c.direction < 0, c.x + c.size.width <= g.upperBound, c.x + c.size.width > g.lowerBound { c.x -= width }
    }

    /// Resting spots must not straddle the notch; nudge to the nearer side.
    private func settleOutsideGap(_ c: Cat) {
        guard let g = gap, c.x < g.upperBound, c.x + c.size.width > g.lowerBound else { return }
        let mid = (g.lowerBound + g.upperBound) / 2
        c.x = c.x + c.size.width / 2 < mid ? g.lowerBound - c.size.width : g.upperBound
    }

    /// Positions sprites, splitting a cat that is part-way through the portals across both edges.
    private func place(_ c: Cat) {
        let y = baseline(for: c), w = c.size.width
        // Entirely inside the notch (a slot or a layout change put it there): it has effectively crossed.
        if let g = gap, c.x >= g.lowerBound, c.x + w <= g.upperBound { settleOutsideGap(c) }
        c.sprite.frame.origin = NSPoint(x: c.x, y: y)
        guard let g = gap, c.x < g.upperBound, c.x + w > g.lowerBound else {
            c.clip(c.sprite, to: nil)
            c.ghost.isHidden = true
            return
        }
        let width = g.upperBound - g.lowerBound
        c.ghost.isHidden = false
        if c.x < g.lowerBound {
            // Entering from the left: the head is already coming out of the right portal.
            let inside = g.lowerBound - c.x
            c.clip(c.sprite, to: 0...inside)
            c.ghost.frame.origin = NSPoint(x: c.x + width, y: y)
            c.clip(c.ghost, to: inside...w)
        } else {
            // Entering from the right: the part past the right portal shows left of the left one.
            let inside = g.upperBound - c.x
            c.clip(c.sprite, to: inside...w)
            c.ghost.frame.origin = NSPoint(x: c.x - width, y: y)
            c.clip(c.ghost, to: 0...inside)
        }
    }

    private func updatePortals() {
        guard gap != nil else { return }
        let lit = cats.contains { !$0.ghost.isHidden }
        guard lit != portalsLit else { return }
        portalsLit = lit
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = lit ? 0.15 : 0.5
            portalLeft.animator().alphaValue = lit ? 1 : 0
            portalRight.animator().alphaValue = lit ? 1 : 0
        }
    }

    private func baseline(for cat: Cat) -> CGFloat {
        cat.sheet == nil ? (bounds.height - cat.size.height) / 2 - 2 : max(0, (bounds.height - cat.size.height) / 2 - 1)
    }

    private func clampAll() {
        for c in cats {
            c.x = min(max(c.x, roam.lowerBound), max(roam.lowerBound, roam.upperBound - c.size.width))
            place(c)
        }
    }

    override func layout() {
        super.layout()
        clampAll()
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// Only the cats themselves take clicks; the rest of the strip stays click-through for the bar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let p = convert(point, from: superview)
        return cats.contains { $0.sprite.frame.insetBy(dx: -4, dy: -4).contains(p) } ? self : nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointerX = roam.contains(p.x) && !cats.isEmpty ? p.x : nil
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { pointerX = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let cat = cats.first(where: { $0.sprite.frame.insetBy(dx: -4, dy: -4).contains(p) }) else { return }
        pet(cat)
        // Let the panel do its "stay behind the windows" bit.
        window?.mouseDown(with: event)
    }

    private func pet(_ cat: Cat) {
        cat.enter(cat.sheet == nil ? .groom : .lie, for: 3...5)
        pettedUntil[ObjectIdentifier(cat)] = cat.modeUntil
        showHeart(above: cat)
    }

    private func showHeart(above cat: Cat) {
        let heart = NSTextField(labelWithString: "♥")
        heart.font = .systemFont(ofSize: max(9, cat.size.height * 0.45), weight: .bold)
        heart.textColor = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.5, alpha: 1)
        heart.sizeToFit()
        heart.frame.origin = NSPoint(x: cat.x + cat.size.width / 2 - heart.frame.width / 2 + CGFloat.random(in: -4...4),
                                     y: baseline(for: cat) + cat.size.height * 0.5)
        heart.alphaValue = 0.95
        addSubview(heart)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.9
            heart.animator().frame.origin.y += cat.size.height * 0.6
            heart.animator().alphaValue = 0
        }, completionHandler: { heart.removeFromSuperview() })
    }

    private func isPetted(_ cat: Cat) -> Bool {
        guard let until = pettedUntil[ObjectIdentifier(cat)] else { return false }
        if Date() >= until { pettedUntil[ObjectIdentifier(cat)] = nil; return false }
        return true
    }

    /// Every free cat runs at the pointer; one that reaches it sits and watches, running again if it moves.
    private func stepHunt(_ px: CGFloat) {
        // Each cat gets its own spot around the pointer so they sit side by side instead of on top of each other.
        let n = CGFloat(cats.count)
        for (i, c) in cats.enumerated() where !isPetted(c) {
            var slot = px + (CGFloat(i) - (n - 1) / 2) * (c.size.width + 4)
            // Slots never sit in the notch: push them to the pointer's side of it.
            if let g = gap, slot + c.size.width / 2 > g.lowerBound, slot - c.size.width / 2 < g.upperBound {
                slot = px < (g.lowerBound + g.upperBound) / 2 ? g.lowerBound - c.size.width / 2 - 2 : g.upperBound + c.size.width / 2 + 2
            }
            let target = slot - c.size.width / 2
            let centre = c.x + c.size.width / 2
            if abs(centre - slot) <= 6 {
                if c.mode != .sit { c.enter(.sit, for: 60...60) }
                c.direction = px >= centre ? 1 : -1
            } else {
                if c.mode != .run { c.enter(.run, for: 60...60) }
                if approach(c, to: target, speed: 6) { c.enter(.sit, for: 60...60) }
            }
        }
    }

    // MARK: Simulation

    private func step() {
        guard !isHidden, !cats.isEmpty, roam.upperBound - roam.lowerBound > (cats.map { $0.size.width }.max() ?? 0) + 8 else { return }
        tick += 1
        if let px = pointerX {
            if case .free = scene {} else { scene = .free }
            stepHunt(px)
            for c in cats { c.render(tick: tick); place(c) }
            updatePortals()
            return
        }
        switch scene {
        case .free:
            for c in cats { stepFree(c) }
            if cats.count >= 2, Int.random(in: 0..<250) == 0 { startScene() }
        case let .meeting(a, b, hold, approaching, until):
            stepMeeting(a: a, b: b, hold: hold, approaching: approaching, until: until)
            for (i, c) in cats.enumerated() where i != a && i != b { stepFree(c) }
        case let .chase(chaser, runner, until):
            stepChase(chaser: chaser, runner: runner, until: until)
            for (i, c) in cats.enumerated() where i != chaser && i != runner { stepFree(c) }
        }
        for c in cats {
            if c.mode != .walk, c.mode != .run { settleOutsideGap(c) }
            c.render(tick: tick)
            place(c)
        }
        updatePortals()
    }

    private func stepFree(_ c: Cat) {
        // A hunt leaves cats parked in long sit/run poses; once the pointer is gone they wander again.
        if pointerX == nil, !isPetted(c), c.modeUntil.timeIntervalSinceNow > 30 { c.enter(.walk) }
        if c.mode != .walk, c.mode != .run, Date() >= c.modeUntil { c.enter(.walk) }
        switch c.mode {
        case .walk, .run:
            move(c, by: c.mode == .run ? 5 : 2)
            let inGap = gap.map { c.x < $0.upperBound && c.x + c.size.width > $0.lowerBound } ?? false
            if c.mode == .walk, !inGap, Int.random(in: 0..<90) == 0 {
                var options: [Cat.Mode] = [.sit, .sit, .groom, .sleep, .run]
                options.append(c.sheet == nil ? .stretch : .lie)
                c.enter(options.randomElement()!)
            } else if c.mode == .run, Date() >= c.modeUntil {
                c.enter(.walk)
            }
        default: break
        }
    }

    /// Moves `c` along its direction, bouncing at the roam edges.
    private func move(_ c: Cat, by dx: CGFloat) {
        c.x += c.direction * dx
        crossGap(c)
        if c.x <= roam.lowerBound { c.x = roam.lowerBound; c.direction = 1 }
        if c.x + c.size.width >= roam.upperBound { c.x = roam.upperBound - c.size.width; c.direction = -1 }
    }

    /// Moves `c` toward `target` (its left edge, clamped to the roam range), returning true when there.
    private func approach(_ c: Cat, to rawTarget: CGFloat, speed: CGFloat) -> Bool {
        let target = min(max(rawTarget, roam.lowerBound), max(roam.lowerBound, roam.upperBound - c.size.width))
        let delta = target - c.x
        if abs(delta) <= speed { c.x = target; return true }
        c.direction = delta > 0 ? 1 : -1
        c.x += c.direction * speed
        crossGap(c)
        return false
    }

    private func startScene() {
        let idx = Array(cats.indices).shuffled()
        let a = idx[0], b = idx[1]
        switch Int.random(in: 0..<4) {
        case 0: scene = .chase(chaser: a, runner: b, until: Date().addingTimeInterval(Double.random(in: 3...5)))
                cats[a].enter(.run, for: 60...60); cats[b].enter(.run, for: 60...60)
        case 1: scene = .meeting(a: a, b: b, hold: .sleep, approaching: true, until: .distantFuture)
                cats[a].enter(.walk); cats[b].enter(.walk)
        case 2: scene = .meeting(a: a, b: b, hold: .groom, approaching: true, until: .distantFuture)
                cats[a].enter(.run, for: 60...60); cats[b].enter(.sit, for: 60...60)
        default: scene = .meeting(a: a, b: b, hold: .sit, approaching: true, until: .distantFuture)
                cats[a].enter(.run, for: 60...60); cats[b].enter(.sit, for: 60...60)
        }
    }

    private func stepMeeting(a: Int, b: Int, hold: Cat.Mode, approaching: Bool, until: Date) {
        let ca = cats[a], cb = cats[b]
        if approaching {
            // Meet where b is: a comes to sit right beside b, both facing each other.
            let gap: CGFloat = 4
            let target = cb.x > ca.x ? cb.x - ca.size.width - gap : cb.x + cb.size.width + gap
            let speed: CGFloat = ca.mode == .run ? 5 : 2
            if hold == .sleep {
                // For a cuddle both stroll toward the middle of the roam range.
                let mid = (roam.lowerBound + roam.upperBound) / 2
                let doneA = approach(ca, to: mid - ca.size.width - gap / 2, speed: 2)
                let doneB = approach(cb, to: mid + gap / 2, speed: 2)
                if doneA && doneB { arrive() }
            } else if approach(ca, to: target, speed: speed) {
                arrive()
            }
            func arrive() {
                ca.direction = cb.x > ca.x ? 1 : -1
                cb.direction = -ca.direction
                let seconds: ClosedRange<Double> = hold == .sleep ? 10...25 : 4...8
                ca.enter(hold, for: seconds)
                cb.enter(hold == .groom ? .sit : hold, for: seconds)
                scene = .meeting(a: a, b: b, hold: hold, approaching: false, until: Date().addingTimeInterval(seconds.lowerBound))
            }
        } else if Date() >= until, Date() >= ca.modeUntil {
            ca.enter(.walk); cb.enter(.walk)
            ca.direction = -1 * ca.direction
            scene = .free
        }
    }

    private func stepChase(chaser: Int, runner: Int, until: Date) {
        let c = cats[chaser], r = cats[runner]
        // The runner flees away from the chaser; the chaser follows.
        r.direction = r.x >= c.x ? 1 : -1
        let before = r.x
        move(r, by: 5)
        let cornered = abs(r.x - before) < 1
        c.direction = r.x >= c.x ? 1 : -1
        if abs(r.x - c.x) > c.size.width + 2 { move(c, by: 5) }
        // Cornered at the end of the bar, or time's up: both catch their breath facing each other.
        if cornered || Date() >= until {
            r.direction = -r.direction
            c.direction = -r.direction
            r.enter(.sit, for: 2...4)
            c.enter(.sit, for: 2...4)
            scene = .meeting(a: chaser, b: runner, hold: .sit, approaching: false, until: Date().addingTimeInterval(2))
        }
    }
}
