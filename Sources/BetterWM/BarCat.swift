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
        sprite.imageScaling = .scaleNone
        sprite.wantsLayer = true
        sprite.frame = NSRect(origin: .zero, size: size)
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
        // Built-in art faces right and is mirrored when facing left (about its own width; the layer anchor stays at the origin).
        let mirror = sheet == nil && direction < 0
        sprite.layer?.setAffineTransform(mirror ? CGAffineTransform(translationX: size.width, y: 0).scaledBy(x: -1, y: 1) : .identity)
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.step() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    /// `sheets`: one entry per cat, a PNG path or "builtin". Empty means a single built-in cat.
    func configure(sheets: [String], color: NSColor, barHeight: CGFloat) {
        self.color = color
        self.barHeight = barHeight
        cats.forEach { $0.sprite.removeFromSuperview() }
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
            addSubview(cat.sprite)
            cats.append(cat)
        }
        clampAll()
    }

    private func baseline(for cat: Cat) -> CGFloat {
        cat.sheet == nil ? (bounds.height - cat.size.height) / 2 - 2 : max(0, (bounds.height - cat.size.height) / 2 - 1)
    }

    private func clampAll() {
        for c in cats {
            c.x = min(max(c.x, roam.lowerBound), max(roam.lowerBound, roam.upperBound - c.size.width))
            c.sprite.frame.origin = NSPoint(x: c.x, y: baseline(for: c))
        }
    }

    override func layout() {
        super.layout()
        clampAll()
    }

    // MARK: Simulation

    private func step() {
        guard !isHidden, !cats.isEmpty, roam.upperBound - roam.lowerBound > (cats.map { $0.size.width }.max() ?? 0) + 8 else { return }
        tick += 1
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
            c.sprite.frame.origin = NSPoint(x: c.x, y: baseline(for: c))
            c.render(tick: tick)
        }
    }

    private func stepFree(_ c: Cat) {
        if c.mode != .walk, c.mode != .run, Date() >= c.modeUntil { c.enter(.walk) }
        switch c.mode {
        case .walk, .run:
            move(c, by: c.mode == .run ? 5 : 2)
            if c.mode == .walk, Int.random(in: 0..<90) == 0 {
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
