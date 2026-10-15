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

    private enum Mode { case walk, run, sit, groom, sleep, stretch }

    private let sprite = NSImageView()
    private var walkFrames: [NSImage] = []
    private var idle: [Mode: [NSImage]] = [:]
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
        guard roam.upperBound - roam.lowerBound > BarCat.size.width + 8, !isHidden else { return }
        tick += 1
        if mode != .walk, mode != .run, Date() >= modeUntil { enter(.walk) }
        switch mode {
        case .walk, .run:
            move(by: mode == .run ? 5 : 2)
            sprite.image = walkFrames[tick % walkFrames.count]
            // Every so often, do something else for a while.
            if mode == .walk, Int.random(in: 0..<90) == 0 {
                enter([.sit, .sit, .groom, .sleep, .stretch, .run].randomElement()!)
            } else if mode == .run, Date() >= modeUntil {
                enter(.walk)
            }
        case .sit:
            sprite.image = idle[.sit]?[(tick / 4) % 2]
        case .groom:
            sprite.image = idle[.groom]?[(tick / 3) % 2]
        case .sleep:
            sprite.image = idle[.sleep]?[(tick / 8) % 2]
        case .stretch:
            sprite.image = idle[.stretch]?.first
        }
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
        }
    }

    private func move(by dx: CGFloat) {
        var origin = sprite.frame.origin
        origin.x += direction * dx
        if origin.x <= roam.lowerBound { origin.x = roam.lowerBound; direction = 1 }
        if origin.x + BarCat.size.width >= roam.upperBound { origin.x = roam.upperBound - BarCat.size.width; direction = -1 }
        sprite.frame.origin = origin
        // Art faces right; mirror about the sprite's own width when walking left (the layer anchor stays at the origin).
        sprite.layer?.setAffineTransform(direction < 0 ? CGAffineTransform(translationX: BarCat.size.width, y: 0).scaledBy(x: -1, y: 1) : .identity)
    }

    private func clamp() {
        var o = sprite.frame.origin
        o.x = min(max(o.x, roam.lowerBound), max(roam.lowerBound, roam.upperBound - BarCat.size.width))
        o.y = (bounds.height - BarCat.size.height) / 2 - 2
        sprite.frame.origin = o
    }

    override func layout() {
        super.layout()
        clamp()
    }
}
