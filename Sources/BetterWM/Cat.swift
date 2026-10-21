import Cocoa

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
    /// Key under which this cat's state is remembered between launches (its sheet path, or builtin-N).
    var memoryKey = ""

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
    static let builtinScale: CGFloat = 2
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

    private var lastRenderedX: CGFloat = .nan
    func render(tick: Int) {
        var name: String
        let every: Int
        let stoodStill = lastRenderedX == x
        lastRenderedX = x
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
        // Feet only move when the cat does; a walker held in place stands and flicks its tail instead.
        if stoodStill, mode == .walk || mode == .run { name = sheet == nil ? "sit" : "alert" }
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
