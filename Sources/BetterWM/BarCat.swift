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
    enum Mode { case walk, run, sit, groom, sleep, stretch, lie, alert, swipe, scratch, eat, hiss, jump, meow, yawn, hind }

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

    /// Stable per-cat multipliers (0.6…1.4), seeded from the sheet so the same cat behaves the same every launch.
    struct Personality { var lazy: Double; var playful: Double; var clingy: Double }
    var personality = Personality(lazy: 1, playful: 1, clingy: 1)
    /// Slow-moving drives in 0…1 that pick the next pose instead of a flat dice roll.
    var energy = 1.0
    var boredom = 0.0
    var affection = 0.0
    /// Whether this cat cares about the pointer this time, and for how long.
    var huntInterestUntil: Date?
    var recentPets: [Date] = []
    /// Which of the pack's sleeping poses this nap uses; chosen when the cat lies down.
    var napStyle = "sleep3"
    /// Which grooming animation this session uses.
    var groomStyle = "groom"
    /// Movement mode to return to after leaping through a portal.
    var modeBeforeJump: Mode?

    static func personality(seed: String) -> Personality {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        func pick() -> Double { h = h &* 6364136223846793005 &+ 1442695040888963407; return 0.6 + Double(h >> 40) / Double(1 << 24) * 0.8 }
        return Personality(lazy: pick(), playful: pick(), clingy: pick())
    }

    /// One simulation tick (about 8 a second) of the drives, according to what the cat is doing.
    func updateDrives(inScene: Bool) {
        switch mode {
        case .run, .jump: energy -= 0.004; boredom -= 0.004
        case .walk: energy -= 0.0007; boredom += 0.0006 * personality.playful
        case .sleep: energy += 0.0035 * personality.lazy; boredom += 0.0008 * personality.playful
        case .sit, .lie, .stretch, .alert, .yawn, .hind: energy += 0.0012; boredom += 0.0012 * personality.playful
        case .groom, .scratch, .eat, .meow: energy += 0.0008; boredom += 0.0006
        case .swipe, .hiss: boredom -= 0.003
        }
        if inScene { boredom -= 0.003 }
        affection -= 0.0004
        energy = min(1, max(0, energy)); boredom = min(1, max(0, boredom)); affection = min(1, max(0, affection))
    }

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
        case .alert: range = 1.5...3
        case .swipe: range = 1.0...1.6
        case .scratch: range = 2...3.5
        case .eat: range = 4...7
        case .hiss: range = 0.8...1.2
        case .jump: range = 0.7...0.7
        case .meow: range = 0.9...1.2
        case .yawn: range = 1.2...1.6
        case .hind: range = 1.0...2.0
        }
        let r = seconds ?? range
        modeUntil = Date().addingTimeInterval(Double.random(in: r))
        if m == .sleep, let sheet {
            // Lazy cats sprawl; the others curl up. Each nap picks anew.
            let sprawled = ["sleep4", "sleep5"], curled = ["sleep1", "sleep2", "sleep3"]
            let pool = (Double.random(in: 0..<1) < (personality.lazy - 0.6) ? sprawled : curled).filter(sheet.has)
            napStyle = pool.randomElement() ?? "sleep3"
        }
        if m == .groom, let sheet {
            groomStyle = ["groom", "groom2", "lick", "lick"].filter(sheet.has).randomElement() ?? "groom"
        }
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
        case .alert: (name, every) = (sheet == nil ? "sit" : "alert", 3)
        case .swipe: (name, every) = (sheet == nil ? "groom" : "swipe", 1)
        case .scratch: (name, every) = (sheet == nil ? "groom" : "scratch", 2)
        case .eat: (name, every) = (sheet == nil ? "sit" : "eat", 2)
        case .hiss: (name, every) = (sheet == nil ? "sit" : "hiss", 3)
        case .jump: (name, every) = (sheet == nil ? "walk" : "jump", 1)
        case .meow: (name, every) = (sheet == nil ? "sit" : "meow", 3)
        case .yawn: (name, every) = (sheet == nil ? "stretch" : "yawn", 2)
        case .hind: (name, every) = (sheet == nil ? "sit" : "hind", 3)
        }
        // Extras a sheet lacks fall back to the nearest core animation.
        var resolved = name
        if let sheet, !sheet.has(name) {
            resolved = ["alert": "sit", "swipe": "groom", "scratch": "groom", "eat": "sit", "hiss": "sit", "jump": "run", "meow": "sit", "yawn": "lie", "hind": "sit", "lick": "groom", "lickLie": "lie", "groom2": "groom"][name] ?? "sit"
        }
        if mode == .sleep, let sheet, sheet.has(napStyle) { resolved = napStyle }
        if mode == .groom, let sheet, sheet.has(groomStyle) { resolved = groomStyle }
        sprite.image = frame(resolved, tick: tick, every: every)
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
        /// Everyone goes to `x` and holds `hold` there (a huddle by the battery, a glance at a new desktop).
        case gather(x: CGFloat, hold: Cat.Mode, until: Date)
        /// The others trail behind the leader, who just walks.
        case follow(leader: Int, until: Date)
    }
    private var scene: Scene = .free

    /// Things in the bar the cats notice.
    enum Reaction {
        /// The active desktop changed; `towardX` is the new chip's centre in this view.
        case desktopSwitched(towardX: CGFloat)
        /// The battery is running low; `x` is the battery icon's centre. Cats huddle up next to it.
        case batteryLow(x: CGFloat)
        /// The machine is working hard; cats stop and stare at the gauges on the right.
        case load
        /// The charger went in after the battery ran low; `x` is the battery icon's centre.
        case charging(x: CGFloat)
    }

    func react(_ r: Reaction) {
        guard !cats.isEmpty, pointerX == nil else { return }
        switch r {
        case .desktopSwitched(let x):
            // A glance, not a migration: only the cats that are awake and not busy turn toward it, and a
            // playful one trots a little way over before losing interest.
            for c in cats where c.mode != .sleep && !isPetted(c) {
                c.direction = x >= c.x + c.size.width / 2 ? 1 : -1
                if c.mode == .walk || c.mode == .run {
                    if Double.random(in: 0..<1) < c.personality.playful * 0.35 {
                        c.enter(.run, for: 0.6...1.0)
                    } else {
                        c.enter(.alert, for: 0.8...1.5)
                    }
                }
            }
        case .batteryLow(let x):
            if case .gather = scene { return }
            scene = .gather(x: x - 40, hold: cats.first?.sheet == nil ? .sit : .lie, until: Date().addingTimeInterval(25))
            for c in cats { c.enter(.walk) }
        case .load:
            if case .gather = scene { return }
            scene = .gather(x: roam.upperBound - 20, hold: .alert, until: Date().addingTimeInterval(8))
            for c in cats { c.enter(.walk) }
        case .charging(let x):
            // Plugged in after running low: dinner is served by the battery icon.
            if case .gather = scene { return }
            scene = .gather(x: x - 40, hold: .eat, until: Date().addingTimeInterval(12))
            for c in cats { c.enter(.walk) }
        }
    }
    /// Pointer x in this view while it hovers the cats' strip; the cats run to catch it.
    private var pointerX: CGFloat? {
        didSet {
            if pointerX != nil, oldValue == nil { pointerArrived() }
            if pointerX == nil, let last = oldValue { lastPointerX = last; pointerLostAt = Date() }
        }
    }
    /// Where the pointer was last seen; interested cats go and look there for a few seconds after it leaves.
    private var lastPointerX: CGFloat?
    private var pointerLostAt = Date.distantPast
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
            cat.personality = Cat.personality(seed: entry.lowercased() == "builtin" ? "builtin-\(cats.count)" : entry)
            cat.energy = Double.random(in: 0.5...1)
            cat.boredom = Double.random(in: 0...0.4)
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
        // Crossing a portal is a leap; the cat keeps moving underneath and lands back in its stride.
        let inGap = gap.map { c.x < $0.upperBound && c.x + w > $0.lowerBound } ?? false
        if inGap, c.sheet != nil, c.mode == .walk || c.mode == .run {
            c.modeBeforeJump = c.mode
            c.mode = .jump
        } else if c.mode == .jump, !inGap {
            c.mode = c.modeBeforeJump ?? .walk
            c.modeBeforeJump = nil
        }
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
        let now = Date()
        cat.recentPets = cat.recentPets.filter { now.timeIntervalSince($0) < 8 } + [now]
        let count = cat.recentPets.count
        if cat.mode == .sleep {
            // Woken up: a sit and a look around, no purring yet.
            cat.enter(.sit, for: 2...3)
            cat.direction = -cat.direction
            cat.energy = min(1, cat.energy + 0.1)
        } else if Double(count) > 5 * cat.personality.clingy {
            // Enough. A hiss, then it walks off, slightly offended.
            cat.affection = max(0, cat.affection - 0.15)
            cat.enter(.hiss)
            cat.direction = Bool.random() ? 1 : -1
            pettedUntil[ObjectIdentifier(cat)] = cat.modeUntil
            return
        } else if count >= 3 {
            // Delighted: a little jump, then it flops down purring.
            cat.enter(.jump)
            showHeart(above: cat)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak cat] in
                guard let self, let cat, cat.mode == .jump else { return }
                cat.enter(cat.sheet != nil ? .lie : .sit, for: 4...7)
                self.pettedUntil[ObjectIdentifier(cat)] = cat.modeUntil
            }
        } else if count == 1 {
            cat.enter(.meow)
        } else {
            cat.enter(cat.sheet == nil ? .groom : .lie, for: 3...5)
        }
        cat.affection = min(1, cat.affection + 0.25 * cat.personality.clingy)
        cat.boredom = max(0, cat.boredom - 0.2)
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
        for (i, c) in cats.enumerated() where !isPetted(c) && isHunting(c) {
            var slot = px + (CGFloat(i) - (n - 1) / 2) * (c.size.width + 4)
            // Slots never sit in the notch: push them to the pointer's side of it.
            if let g = gap, slot + c.size.width / 2 > g.lowerBound, slot - c.size.width / 2 < g.upperBound {
                slot = px < (g.lowerBound + g.upperBound) / 2 ? g.lowerBound - c.size.width / 2 - 2 : g.upperBound + c.size.width / 2 + 2
            }
            let target = slot - c.size.width / 2
            let centre = c.x + c.size.width / 2
            if abs(centre - slot) <= 6 {
                let overMe = abs(px - centre) < c.size.width / 2
                if overMe, c.mode != .hind { c.enter(.hind, for: 60...60) }
                else if !overMe, c.mode == .hind || c.mode == .run { c.enter(.swipe, for: 1.2...1.8) }
                else if c.mode != .sit, c.mode != .swipe, c.mode != .hind { c.enter(.sit, for: 60...60) }
                else if c.mode == .swipe, Date() >= c.modeUntil { c.enter(.sit, for: 60...60) }
                c.direction = px >= centre ? 1 : -1
            } else {
                if c.mode != .run { c.enter(.run, for: 60...60) }
                if approach(c, to: target, speed: 6) { c.enter(.swipe, for: 1.2...1.8) }
            }
        }
    }

    // MARK: Simulation

    private func step() {
        guard !isHidden, !cats.isEmpty, roam.upperBound - roam.lowerBound > (cats.map { $0.size.width }.max() ?? 0) + 8 else { return }
        tick += 1
        let inScene: Set<Int>
        switch scene {
        case .free: inScene = []
        case let .meeting(a, b, _, _, _): inScene = [a, b]
        case let .chase(a, b, _): inScene = [a, b]
        case .gather: inScene = Set(cats.indices)
        case let .follow(leader, _): inScene = Set(cats.indices).subtracting([leader])
        }
        for (i, c) in cats.enumerated() { c.updateDrives(inScene: inScene.contains(i)) }
        if let px = pointerX {
            if case .free = scene {} else { scene = .free }
            stepHunt(px)
            for c in cats where !isHunting(c) && !isPetted(c) { stepFree(c) }
            for c in cats { c.render(tick: tick); place(c) }
            updatePortals()
            return
        }
        switch scene {
        case .free:
            for c in cats { stepFree(c) }
        case let .meeting(a, b, hold, approaching, until):
            stepMeeting(a: a, b: b, hold: hold, approaching: approaching, until: until)
            for (i, c) in cats.enumerated() where i != a && i != b { stepFree(c) }
        case let .chase(chaser, runner, until):
            stepChase(chaser: chaser, runner: runner, until: until)
            for (i, c) in cats.enumerated() where i != chaser && i != runner { stepFree(c) }
        case let .gather(x, hold, until):
            stepGather(x: x, hold: hold, until: until)
        case let .follow(leader, until):
            stepFollow(leader: leader, until: until)
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
        // Looking for a pointer that just left: interested cats stroll to where it was and have a look.
        if pointerX == nil, let last = lastPointerX, Date().timeIntervalSince(pointerLostAt) < 4, isHunting(c), c.mode == .walk {
            if approach(c, to: last - c.size.width / 2, speed: 2) { c.enter(.sit, for: 2...3); c.huntInterestUntil = nil }
            return
        }
        if c.mode != .walk, c.mode != .run, c.mode != .jump, Date() >= c.modeUntil {
            // Waking up takes a yawn first.
            if c.mode == .sleep, c.sheet != nil { c.enter(.yawn); return }
            c.enter(.walk)
        }
        if stepPoke(c) { return }
        switch c.mode {
        case .walk, .run, .jump:
            move(c, by: (c.mode == .run || c.modeBeforeJump == .run) ? 5 : 2)
            let inGap = gap.map { c.x < $0.upperBound && c.x + c.size.width > $0.lowerBound } ?? false
            if c.mode == .walk, !inGap, tick % 8 == 0 { decide(c) }
            else if c.mode == .run, Date() >= c.modeUntil { c.enter(.walk) }
        default: break
        }
    }

    /// Portal poking: (turns left, resting x). The cat darts a little way into the portal and back out.
    private var pokes: [ObjectIdentifier: (turns: Int, home: CGFloat)] = [:]
    private func stepPoke(_ c: Cat) -> Bool {
        guard let g = gap, var poke = pokes[ObjectIdentifier(c)] else { return false }
        let depth: CGFloat = 14
        let intoLeft = c.direction > 0 && c.x + c.size.width <= g.lowerBound + depth && c.x + c.size.width > g.lowerBound - 2
        let intoRight = c.direction < 0 && c.x >= g.upperBound - depth && c.x < g.upperBound + 2
        if c.mode != .run, c.mode != .swipe { c.enter(.swipe, for: 0.9...0.9); return true }
        if c.mode == .swipe { if Date() >= c.modeUntil { c.enter(.run, for: 60...60) } else { return true } }
        if intoLeft || intoRight {
            // Head is in: turn around and come back out.
            c.direction = -c.direction
            poke.turns -= 1
        }
        let backHome = (c.direction > 0 && c.x > poke.home + 1) || (c.direction < 0 && c.x < poke.home - 1)
        if poke.turns <= 0 && backHome {
            pokes[ObjectIdentifier(c)] = nil
            c.enter(.sit, for: 1...2)
            c.direction = -c.direction
            c.boredom = max(0, c.boredom - 0.3)
            return true
        }
        if backHome { c.direction = -c.direction }
        c.x += c.direction * 4
        pokes[ObjectIdentifier(c)] = poke
        return true
    }

    private func startFollow(leader: Cat) {
        guard let i = cats.firstIndex(where: { $0 === leader }) else { return }
        scene = .follow(leader: i, until: Date().addingTimeInterval(Double.random(in: 6...10)))
        leader.enter(.walk)
        for c in cats where c !== leader { c.enter(.walk) }
    }

    private func stepFollow(leader: Int, until: Date) {
        let l = cats[leader]
        if l.mode != .walk { l.enter(.walk) }
        move(l, by: 2)
        var slot = l.x
        for (i, c) in cats.enumerated() where i != leader {
            slot -= (c.size.width + 6) * l.direction
            if approach(c, to: slot, speed: 3) { c.direction = l.direction }
        }
        if Date() >= until { scene = .free }
    }

    private func stepGather(x: CGFloat, hold: Cat.Mode, until: Date) {
        if Date() >= until {
            scene = .free
            for c in cats { c.enter(.walk) }
            return
        }
        let n = CGFloat(cats.count)
        for (i, c) in cats.enumerated() where !isPetted(c) {
            let target = x + (CGFloat(i) - (n - 1) / 2) * (c.size.width + 2) - c.size.width / 2
            if c.mode == hold { c.modeUntil = until; continue }
            if c.mode != .walk { c.enter(.walk) }
            if approach(c, to: target, speed: 3) {
                c.enter(hold, for: 60...60)
                c.direction = x >= c.x + c.size.width / 2 ? 1 : -1
            }
        }
    }

    /// Picks what a walking cat does next from its drives: tired cats nap, bored playful cats run or start a
    /// scene, cats that were petted groom. Evaluated about once a second.
    private func decide(_ c: Cat) {
        let p = c.personality
        // Cats keep a daily rhythm: sleepy after lunch, lively in the morning.
        let hour = Calendar.current.component(.hour, from: Date())
        let sleepy: Double = (13...16).contains(hour) ? 1.6 : (8...11).contains(hour) ? 0.6 : 1
        var options: [(weight: Double, act: () -> Void)] = [
            (0.75, {}),  // keep walking
            (pow(1 - c.energy, 2) * 1.2 * p.lazy * sleepy, { c.enter(.sleep, for: (8 * p.lazy)...(20 * p.lazy)) }),
            ((1 - c.energy) * 0.35 + 0.08, { c.enter(.sit) }),
            (0.06 + c.affection * 0.3, { c.enter(.groom) }),
            (0.04 + c.boredom * 0.15, { c.enter(.scratch) }),
            (0.05 + (1 - c.energy) * 0.1, { c.enter(c.sheet == nil ? .stretch : .lie) }),
            (c.boredom * p.playful * 0.5 * c.energy, { c.enter(.run) }),
        ]
        if cats.count >= 2, case .free = scene {
            options.append((c.boredom * p.playful * 0.45 + c.affection * p.clingy * 0.25, { self.startScene(from: c) }))
        }
        if cats.count >= 3, case .free = scene {
            options.append((c.affection * p.clingy * 0.2 + 0.03, { self.startFollow(leader: c) }))
        }
        if let g = gap, p.playful > 1.05, c.boredom > 0.3 {
            // A playful cat near a portal pokes its head in and out a few times before going through.
            let nearLeft = abs(c.x + c.size.width - g.lowerBound) < 30 && c.direction > 0
            let nearRight = abs(c.x - g.upperBound) < 30 && c.direction < 0
            if nearLeft || nearRight { options.append((0.9 * p.playful, { self.pokes[ObjectIdentifier(c)] = (3, c.x) })) }
        }
        let total = options.reduce(0) { $0 + $1.weight }
        var r = Double.random(in: 0..<total)
        for o in options { r -= o.weight; if r < 0 { o.act(); return } }
    }

    private func isHunting(_ c: Cat) -> Bool {
        guard let until = c.huntInterestUntil else { return false }
        if Date() >= until { c.huntInterestUntil = nil; return false }
        return true
    }

    /// The pointer just showed up: each cat decides whether it cares, by playfulness and affection, and for how long.
    private func pointerArrived() {
        for c in cats where !isPetted(c) {
            let interest = c.personality.playful * 0.45 + c.affection * 0.5 + (c.mode == .sleep ? -0.4 : 0)
            if Double.random(in: 0..<1) < interest {
                c.huntInterestUntil = Date().addingTimeInterval(5 * c.personality.playful + 10 * c.affection + 2)
            } else {
                c.huntInterestUntil = nil
            }
        }
        // Nobody cares? One cat always humours the user.
        if !cats.contains(where: isHunting), let c = cats.max(by: { $0.personality.playful < $1.personality.playful }) {
            c.huntInterestUntil = Date().addingTimeInterval(4)
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

    private func startScene(from initiator: Cat) {
        guard let a = cats.firstIndex(where: { $0 === initiator }),
              let b = cats.indices.filter({ $0 != a }).min(by: { abs(cats[$0].x - initiator.x) < abs(cats[$1].x - initiator.x) }) else { return }
        let partner = cats[b]
        // Tired cats cuddle, affectionate cats groom a friend, bored energetic cats chase; otherwise just visit.
        if initiator.energy < 0.4 || partner.energy < 0.35 {
            scene = .meeting(a: a, b: b, hold: .sleep, approaching: true, until: .distantFuture)
            cats[a].enter(.walk); cats[b].enter(.walk)
        } else if initiator.affection > 0.4 || initiator.personality.clingy > 1.15 {
            scene = .meeting(a: a, b: b, hold: .groom, approaching: true, until: .distantFuture)
            look(initiator, at: partner); cats[b].enter(.sit, for: 60...60)
        } else if initiator.boredom > 0.5 && partner.energy > 0.4 {
            scene = .chase(chaser: a, runner: b, until: Date().addingTimeInterval(Double.random(in: 3...5)))
            cats[a].enter(.run, for: 60...60); cats[b].enter(.run, for: 60...60)
        } else {
            scene = .meeting(a: a, b: b, hold: .sit, approaching: true, until: .distantFuture)
            look(initiator, at: partner); cats[b].enter(.sit, for: 60...60)
        }
    }

    /// Before heading over, a cat stops and looks at the one it means to visit.
    private func look(_ c: Cat, at other: Cat) {
        c.direction = other.x >= c.x ? 1 : -1
        c.enter(.sit, for: 0.7...1.1)
    }

    private func stepMeeting(a: Int, b: Int, hold: Cat.Mode, approaching: Bool, until: Date) {
        let ca = cats[a], cb = cats[b]
        if approaching {
            // Still looking? Wait, then set off.
            if ca.mode == .sit, hold != .sleep {
                guard Date() >= ca.modeUntil else { return }
                ca.enter(.run, for: 60...60)
            }
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
            r.enter(cornered ? .hiss : .sit, for: 2...4)
            c.enter(cornered ? .swipe : .sit, for: 2...4)
            scene = .meeting(a: chaser, b: runner, hold: .sit, approaching: false, until: Date().addingTimeInterval(2))
        }
    }
}
