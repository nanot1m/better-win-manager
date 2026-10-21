import Cocoa

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
    deinit { timer?.invalidate(); saveMemory() }

    // MARK: Memory

    /// What a cat keeps between launches. Affection fades a little per day away; energy and boredom resume.
    private struct Memory: Codable { var affection: Double; var energy: Double; var boredom: Double; var lastSeen: Date }
    private static let memoryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/betterwm/cats.json")
    private var lastMemorySave = Date()

    private func loadMemory() -> [String: Memory] {
        guard let data = try? Data(contentsOf: BarCat.memoryPath) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Memory].self, from: data)) ?? [:]
    }

    private func saveMemory() {
        guard !cats.isEmpty else { return }
        var all = loadMemory()
        for c in cats where !c.memoryKey.isEmpty {
            all[c.memoryKey] = Memory(affection: c.affection, energy: c.energy, boredom: c.boredom, lastSeen: Date())
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: BarCat.memoryPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(all).write(to: BarCat.memoryPath, options: .atomic)
        lastMemorySave = Date()
    }

    /// `sheets`: one entry per cat, a PNG path or "builtin". Empty means a single built-in cat.
    func configure(sheets: [String], color: NSColor, barHeight: CGFloat) {
        self.color = color
        self.barHeight = barHeight
        cats.forEach { $0.sprite.removeFromSuperview(); $0.ghost.removeFromSuperview() }
        cats = []
        scene = .free
        let entries = sheets.isEmpty ? ["builtin"] : sheets
        let scale = max(0.5, floor((barHeight - 4) / CatSheet.crop.height * 2) / 2)
        let remembered = loadMemory()
        for entry in entries {
            var sheet: CatSheet?
            if entry.lowercased() != "builtin" {
                sheet = CatSheet(path: (entry as NSString).expandingTildeInPath, scale: scale)
                if sheet == nil { print("Cat: could not load sprite sheet at \(entry); using the built-in cat.") }
            }
            let cat = Cat(sheet: sheet, color: color)
            let key = entry.lowercased() == "builtin" ? "builtin-\(cats.count)" : entry
            cat.personality = Cat.personality(seed: key)
            cat.memoryKey = key
            if let m = remembered[key] {
                let daysAway = Date().timeIntervalSince(m.lastSeen) / 86_400
                cat.affection = max(0, m.affection - 0.1 * daysAway)
                cat.energy = min(1, m.energy + 0.3 * daysAway)
                cat.boredom = min(1, m.boredom + 0.2 * daysAway)
                // Back after a while: a cat that likes you says hello.
                if daysAway > 0.5, m.affection > 0.3 { cat.enter(.meow, for: 1.5...1.5) }
            } else {
                cat.energy = Double.random(in: 0.5...1)
                cat.boredom = Double.random(in: 0...0.4)
            }
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
        if inGap, c.sheet != nil, pokes[ObjectIdentifier(c)] == nil, c.mode == .walk || c.mode == .run {
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

    private var strokeCat: ObjectIdentifier?
    private var strokeLastX: CGFloat = 0
    private var strokeDirection: CGFloat = 0
    private var strokeReversals = 0
    private var lastStrokePet = Date.distantPast

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pointerX = roam.contains(p.x) && !cats.isEmpty ? p.x : nil
        // Rubbing the pointer back and forth over a cat strokes it: two reversals make one pet.
        guard let cat = cats.first(where: { $0.sprite.frame.insetBy(dx: -4, dy: -4).contains(p) }) else { strokeCat = nil; return }
        if strokeCat != ObjectIdentifier(cat) {
            strokeCat = ObjectIdentifier(cat); strokeLastX = p.x; strokeDirection = 0; strokeReversals = 0
            return
        }
        let dx = p.x - strokeLastX
        guard abs(dx) > 2 else { return }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if strokeDirection != 0, dir != strokeDirection {
            strokeReversals += 1
            if strokeReversals >= 2, Date().timeIntervalSince(lastStrokePet) > 1.2 {
                strokeReversals = 0
                lastStrokePet = Date()
                pet(cat)
            }
        }
        strokeDirection = dir
        strokeLastX = p.x
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
        if Date().timeIntervalSince(lastMemorySave) > 30 { saveMemory() }
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
            // A leap is movement through the notch; only resting cats are nudged out of it.
            if c.mode != .walk, c.mode != .run, c.mode != .jump { settleOutsideGap(c) }
            unstickIfFrozen(c)
            c.render(tick: tick)
            place(c)
        }
        updatePortals()
    }

    /// Safety net: a cat animating a run, walk or leap without actually moving for five seconds has been pinned
    /// by some conflicting target. Sit it down facing the other way; the drives take over from there.
    private var lastMoved: [ObjectIdentifier: (x: CGFloat, at: Date)] = [:]
    private func unstickIfFrozen(_ c: Cat) {
        let key = ObjectIdentifier(c)
        guard c.mode == .walk || c.mode == .run || c.mode == .jump else { lastMoved[key] = (c.x, Date()); return }
        if let last = lastMoved[key], abs(last.x - c.x) < 12 {
            // Not just frozen: jittering within a cat's width for five seconds counts as stuck too.
            if Date().timeIntervalSince(last.at) > 5 {
                Log.write("cat", "unsticking a cat frozen at x=\(Int(c.x)) in \(c.mode)")
                pokes[key] = nil
                c.huntInterestUntil = nil
                scene = .free
                settleOutsideGap(c)
                c.direction = -c.direction
                c.enter(.sit, for: 1.5...2.5)
                lastMoved[key] = (c.x, Date())
            }
        } else {
            lastMoved[key] = (c.x, Date())
        }
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
    private var pokes: [ObjectIdentifier: (turns: Int, home: CGFloat, since: Date)] = [:]
    private func stepPoke(_ c: Cat) -> Bool {
        guard let g = gap, var poke = pokes[ObjectIdentifier(c)] else { return false }
        // A poke that drags on (a cat pinned by something else) is abandoned rather than looped forever.
        if Date().timeIntervalSince(poke.since) > 6 {
            pokes[ObjectIdentifier(c)] = nil
            c.enter(.walk)
            c.direction = -c.direction
            return true
        }
        let depth: CGFloat = 14
        let intoLeft = c.direction > 0 && c.x + c.size.width <= g.lowerBound + depth && c.x + c.size.width > g.lowerBound - 2
        let intoRight = c.direction < 0 && c.x >= g.upperBound - depth && c.x < g.upperBound + 2
        if c.mode != .run, c.mode != .swipe, c.mode != .jump { c.enter(.swipe, for: 0.9...0.9); return true }
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
            if c.mode != .walk, c.mode != .run, c.mode != .jump { c.enter(.walk) }
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
            if nearLeft || nearRight { options.append((0.9 * p.playful, { self.pokes[ObjectIdentifier(c)] = (3, c.x, Date()) })) }
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
        var target = min(max(rawTarget, roam.lowerBound), max(roam.lowerBound, roam.upperBound - c.size.width))
        // Nowhere to stand inside the notch: a target there becomes the nearer edge, otherwise the cat would
        // cross, get pulled back, and oscillate at the portal mouth forever.
        if let g = gap, target + c.size.width > g.lowerBound, target < g.upperBound {
            target = target + c.size.width / 2 < (g.lowerBound + g.upperBound) / 2 ? g.lowerBound - c.size.width : g.upperBound
        }
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
