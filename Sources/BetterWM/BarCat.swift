import Cocoa

/// A pixel cat that wanders the free stretch of the status bar. Pure decoration.
final class BarCat: NSView {
    // 16x11, facing right: ear and head on the right, tail curling up on the left.
    private static let walk: [[String]] = [
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
    private static let sit: [[String]] = [
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
    private static let groom: [[String]] = [
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
    private static let sleep: [[String]] = [
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
    private static let stretch: [[String]] = [
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

    private enum Mode { case walk, run, sit, groom, sleep, stretch, lie }

    private let sprite = NSImageView()
    private var walkFrames: [NSImage] = []
    private var idle: [Mode: [NSImage]] = [:]
    /// External sheet with direction-specific frames; when set, the built-in art and mirroring are not used.
    private var sheet: CatSheet?
    private var spriteSize: NSSize { sheet?.spriteSize ?? BarCat.size }
    private var mode: Mode = .walk
    private var modeUntil = Date.distantFuture
    private var tick = 0
    private var direction: CGFloat = 1
    private var timer: Timer?
    /// Horizontal range the cat may roam, in this view's coordinates; set by the bar after layout.
    var roam: ClosedRange<CGFloat> = 0...0 { didSet { clamp() } }
    var color: NSColor = .labelColor { didSet { rebuildFrames() } }

    static var scale: CGFloat = 2
    static var size: NSSize { NSSize(width: 16 * scale, height: 11 * scale) }

    /// Loads (or clears) an external sheet, scaled to fit `barHeight` in half steps so pixels stay even.
    func useSheet(path: String, barHeight: CGFloat) {
        guard !path.isEmpty else { sheet = nil; applySpriteSize(); return }
        let scale = max(0.5, floor((barHeight - 4) / CatSheet.crop.height * 2) / 2)
        sheet = CatSheet(path: (path as NSString).expandingTildeInPath, scale: scale)
        if sheet == nil { print("Cat: could not load sprite sheet at \(path); using the built-in cat.") }
        applySpriteSize()
    }

    private func applySpriteSize() {
        sprite.frame.size = spriteSize
        sprite.layer?.setAffineTransform(.identity)
        clamp()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sprite.imageScaling = .scaleNone
        sprite.frame = NSRect(origin: .zero, size: BarCat.size)
        sprite.wantsLayer = true
        addSubview(sprite)
        rebuildFrames()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.step() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    /// Dev aid: every frame, walk cycle first.
    func previewImages() -> [NSImage] { walkFrames + [Mode.sit, .groom, .sleep, .stretch].flatMap { idle[$0] ?? [] } }

    private func rebuildFrames() {
        walkFrames = BarCat.walk.map { render($0) }
        idle = [.sit: BarCat.sit.map { render($0) }, .groom: BarCat.groom.map { render($0) },
                .sleep: BarCat.sleep.map { render($0) }, .stretch: BarCat.stretch.map { render($0) }]
        sprite.image = walkFrames.first
    }

    private func render(_ rows: [String]) -> NSImage {
        let s = BarCat.scale
        let img = NSImage(size: BarCat.size, flipped: true) { _ in
            NSGraphicsContext.current?.imageInterpolation = .none
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    self.color.setFill()
                    NSRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s).fill()
                }
            }
            return true
        }
        return img
    }

    private func step() {
        guard roam.upperBound - roam.lowerBound > spriteSize.width + 8, !isHidden else { return }
        tick += 1
        if mode != .walk, mode != .run, Date() >= modeUntil { enter(.walk) }
        switch mode {
        case .walk, .run:
            move(by: mode == .run ? 5 : 2)
            sprite.image = frame(mode == .run ? "run" : "walk", every: 1)
            if mode == .walk, Int.random(in: 0..<90) == 0 {
                var options: [Mode] = [.sit, .sit, .groom, .sleep, .run]
                options.append(sheet == nil ? .stretch : .lie)
                enter(options.randomElement()!)
            } else if mode == .run, Date() >= modeUntil {
                enter(.walk)
            }
        case .sit: sprite.image = frame("sit", every: 4)
        case .groom: sprite.image = frame("groom", every: 2)
        case .sleep: sprite.image = frame("sleep", every: 8)
        case .lie: sprite.image = frame("lie", every: 6)
        case .stretch: sprite.image = idle[.stretch]?.first
        }
    }

    /// Current frame for an animation, advancing every `every` ticks; sheet frames are per direction.
    private func frame(_ name: String, every: Int) -> NSImage? {
        let frames: [NSImage]
        if let sheet {
            frames = sheet.frames(name, right: direction > 0)
        } else {
            switch name {
            case "walk", "run": frames = walkFrames
            case "sit": frames = idle[.sit] ?? []
            case "groom": frames = idle[.groom] ?? []
            case "sleep": frames = idle[.sleep] ?? []
            default: frames = idle[.sit] ?? []
            }
        }
        guard !frames.isEmpty else { return nil }
        return frames[(tick / max(1, every)) % frames.count]
    }

    private func enter(_ m: Mode) {
        mode = m
        switch m {
        case .walk: modeUntil = .distantFuture
        case .run: modeUntil = Date().addingTimeInterval(Double.random(in: 1...2))
        case .sit: modeUntil = Date().addingTimeInterval(Double.random(in: 3...7))
        case .groom: modeUntil = Date().addingTimeInterval(Double.random(in: 2...4))
        case .sleep: modeUntil = Date().addingTimeInterval(Double.random(in: 8...20))
        case .stretch: modeUntil = Date().addingTimeInterval(1.2)
        case .lie: modeUntil = Date().addingTimeInterval(Double.random(in: 4...9))
        }
    }

    private func move(by dx: CGFloat) {
        var origin = sprite.frame.origin
        origin.x += direction * dx
        if origin.x <= roam.lowerBound { origin.x = roam.lowerBound; direction = 1 }
        if origin.x + spriteSize.width >= roam.upperBound { origin.x = roam.upperBound - spriteSize.width; direction = -1 }
        sprite.frame.origin = origin
        // Built-in art faces right and is mirrored when walking left (about its own width; the layer anchor stays at the origin).
        let mirror = sheet == nil && direction < 0
        sprite.layer?.setAffineTransform(mirror ? CGAffineTransform(translationX: spriteSize.width, y: 0).scaledBy(x: -1, y: 1) : .identity)
    }

    private func clamp() {
        var o = sprite.frame.origin
        o.x = min(max(o.x, roam.lowerBound), max(roam.lowerBound, roam.upperBound - spriteSize.width))
        o.y = sheet == nil ? (bounds.height - spriteSize.height) / 2 - 2 : max(0, (bounds.height - spriteSize.height) / 2 - 1)
        sprite.frame.origin = o
    }

    override func layout() {
        super.layout()
        clamp()
    }
}
