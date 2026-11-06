import BetterWMCore
import Cocoa

/// What the status item shows for the desktops: the compact chips, or one of the drawn styles below.
protocol MenuBarDesktops: NSView {
    func render(_ style: BarStyle)
    /// The desktop under a point in the view's coordinates.
    func chipDesktop(at point: NSPoint) -> Int?
    func setDropTarget(_ desktop: Int?)
}

extension DesktopChipsView: MenuBarDesktops {}

/// The drawn menu bar styles: numbers in small chips, dots, or one pill with slashes between the desktops where
/// only the active one shows (up to three) app icons. The active section's width animates on a switch.
final class MenuBarDesktopsView: NSView, MenuBarDesktops {
    enum Style { case numbers, dots, pill }
    let style: Style
    private let screen: NSScreen
    private let context: BarContext
    var onSizeChange: (() -> Void)?

    private struct Segment { var desktop: Int; var icons: [NSImage]; var active: Bool; var shown: Bool }
    private var segments: [Segment] = []
    private var frames: [CGRect] = []
    private var textColor = NSColor.labelColor
    private var activeColor = NSColor.controlAccentColor
    private var dropTarget: Int?
    /// Icon room per desktop, animated from the old active section to the new one.
    private var iconRoom: [Int: CGFloat] = [:]
    /// How active each section looks, 0 to 1; the fill and the icons fade with it while the room slides.
    private var activeness: [Int: CGFloat] = [:]
    private var animation: Timer?

    private static let height: CGFloat = 22, iconSize: CGFloat = 12, overlap: CGFloat = 4, limit = 3
    /// The outlined tile, the size of the BetterWM menu bar icon, centred in the item's height.
    private static let tile = NSRect(x: 0.6, y: (height - 16) / 2 + 0.6, width: 0, height: 16 - 1.2)
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)

    init(screen: NSScreen, context: BarContext, style: Style) {
        self.screen = screen
        self.context = context
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { intrinsicContentSize }

    func render(_ style: BarStyle) {
        textColor = style.textColor
        activeColor = style.activeColor
        let desktops = context.desktopsOn(screen)
        let current = context.shownOn(screen), active = context.activeDesktop()
        let apps = context.desktopApps()
        segments = desktops.map { d in
            let pids = (apps[d] ?? []).flatMap { app in app.windows.isEmpty ? [app.pid] : app.windows.map { _ in app.pid } }
            return Segment(desktop: d, icons: pids.prefix(Self.limit).compactMap(ChipView.icon(for:)), active: d == current && d == active, shown: d == current)
        }
        retarget()
    }

    /// Icon room: the active segment's icons' width, everyone else none; a change animates over 0.22 s.
    private func retarget() {
        var targets: [Int: CGFloat] = [:]
        // The icon room is the same for any count up to the limit, so the pill keeps its width across switches;
        // only a desktop with no windows shows none.
        let fullRoom = Self.iconSize + (Self.iconSize - Self.overlap) * CGFloat(Self.limit - 1) + 4
        for s in segments where self.style == .pill {
            targets[s.desktop] = s.active && !s.icons.isEmpty ? fullRoom : 0
        }
        var activeTargets: [Int: CGFloat] = [:]
        for s in segments { activeTargets[s.desktop] = s.active ? 1 : 0 }
        for d in segments.map(\.desktop) {
            if iconRoom[d] == nil { iconRoom[d] = targets[d] ?? 0 }
            if activeness[d] == nil { activeness[d] = activeTargets[d] ?? 0 }
        }
        let moving = targets.contains { abs($0.value - (iconRoom[$0.key] ?? 0)) > 0.5 }
            || activeTargets.contains { abs($0.value - (activeness[$0.key] ?? 0)) > 0.01 }
        animation?.invalidate()
        guard moving, Fade.enabled else { iconRoom = targets; activeness = activeTargets; relayout(); return }
        let startRoom = iconRoom, startActive = activeness, t0 = Date(), duration = 0.28
        animation = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(t0) / duration)
            // Ease in and out: the section glides rather than snapping off the mark.
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            for (d, target) in targets { self.iconRoom[d] = (startRoom[d] ?? 0) + (target - (startRoom[d] ?? 0)) * eased }
            for (d, target) in activeTargets { self.activeness[d] = (startActive[d] ?? 0) + (target - (startActive[d] ?? 0)) * eased }
            self.relayout()
            if t >= 1 { timer.invalidate(); self.animation = nil }
        }
        RunLoop.main.add(animation!, forMode: .common)
    }

    private func relayout() {
        var x: CGFloat = 0
        frames = []
        switch style {
        case .numbers:
            for s in segments {
                let w = max(22, Self.numberWidth(s.desktop) + 10)
                frames.append(CGRect(x: x, y: 0, width: w, height: Self.height)); x += w + 6
            }
        case .dots:
            for _ in segments { frames.append(CGRect(x: x, y: 0, width: 14, height: Self.height)); x += 14 }
        case .pill:
            // Sections meet at the slashes; each is padded 8 on both sides, so a section's frame runs from slash
            // to slash and the active one's fill covers that whole span.
            for (i, s) in segments.enumerated() {
                // The pill's own ends need less than the room around a slash.
                let lead: CGFloat = i == 0 ? 6 : 8, trail: CGFloat = i == segments.count - 1 ? 6 : 8
                let w = lead + Self.numberWidth(s.desktop) + (iconRoom[s.desktop] ?? 0) + trail
                frames.append(CGRect(x: x, y: 0, width: w, height: Self.height)); x += w
            }
            pillWidth = segments.isEmpty ? 0 : x
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onSizeChange?()
    }
    private var pillWidth: CGFloat = 0
    override var intrinsicContentSize: NSSize {
        NSSize(width: style == .pill ? pillWidth : (frames.last?.maxX ?? 0), height: Self.height)
    }

    private static func numberWidth(_ d: Int) -> CGFloat {
        ceil(NSAttributedString(string: "\(d + 1)", attributes: [.font: font]).size().width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = textColor.dimmed(0.5)
        switch style {
        case .numbers:
            for (s, f) in zip(segments, frames) {
                let chip = NSBezierPath(roundedRect: f.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6)
                (s.active ? activeColor : textColor.dimmed(s.shown ? 0.3 : 0.1)).setFill(); chip.fill()
                if dropTarget == s.desktop { activeColor.setStroke(); chip.lineWidth = 2; chip.stroke() }
                Self.drawNumber(s.desktop, in: f, color: s.active ? activeColor.contrastingText : textColor.dimmed(s.shown ? 1 : 0.7))
            }
        case .dots:
            for (s, f) in zip(segments, frames) {
                let r: CGFloat = s.active ? 4 : 3
                let dot = NSBezierPath(ovalIn: NSRect(x: f.midX - r, y: f.midY - r, width: r * 2, height: r * 2))
                (s.active ? activeColor : dropTarget == s.desktop ? activeColor.dimmed(0.6) : dim).setFill(); dot.fill()
            }
        case .pill:
            // Drawn like the BetterWM menu bar icon: an outlined rounded tile, no fill of its own.
            let pillRect = NSRect(x: Self.tile.minX, y: Self.tile.minY, width: pillWidth - 1.2, height: Self.tile.height)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 3.5, yRadius: 3.5)
            NSGraphicsContext.saveGraphicsState()
            pill.addClip()
            // A section's fill is a parallelogram leaning with the slashes, so the slash is its edge; the first and
            // last sections run square to the pill's ends.
            func fill(_ f: CGRect, first: Bool, last: Bool) -> NSBezierPath {
                let lean: CGFloat = 2.5
                let p = NSBezierPath()
                p.move(to: NSPoint(x: f.minX - (first ? 0 : lean), y: 0))
                p.line(to: NSPoint(x: f.maxX - (last ? 0 : lean), y: 0))
                p.line(to: NSPoint(x: f.maxX + (last ? 0 : lean), y: Self.height))
                p.line(to: NSPoint(x: f.minX + (first ? 0 : lean), y: Self.height))
                p.close()
                return p
            }
            for (i, (s, f)) in zip(segments, frames).enumerated() {
                let a = activeness[s.desktop] ?? 0
                if a > 0.01 { activeColor.withAlphaComponent(a).setFill(); fill(f, first: i == 0, last: i == frames.count - 1).fill() }
                else if dropTarget == s.desktop { activeColor.dimmed(0.35).setFill(); fill(f, first: i == 0, last: i == frames.count - 1).fill() }
            }
            // Full-height slashes where sections meet, leaning like the glyph; the ones bordering the active
            // section fade out with it, so its fill reads as one shape.
            for (i, f) in frames.enumerated().dropFirst() {
                let beside = max(activeness[segments[i].desktop] ?? 0, activeness[segments[i - 1].desktop] ?? 0)
                guard beside < 0.99 else { continue }
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: f.minX - 2.5, y: 0)); slash.line(to: NSPoint(x: f.minX + 2.5, y: Self.height))
                slash.lineWidth = 1.2; textColor.withAlphaComponent(1 - beside).setStroke(); slash.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            pill.lineWidth = 1.2
            textColor.setStroke()
            pill.stroke()
            for (s, f) in zip(segments, frames) {
                // Number and icons as one group, centred in the section.
                let a = activeness[s.desktop] ?? 0
                let room = iconRoom[s.desktop] ?? 0
                let numberWidth = Self.numberWidth(s.desktop)
                let step = Self.iconSize - Self.overlap
                // The slot is three icons wide whatever the count; the group centred is the number and the icons
                // actually shown, scaled with the room as it opens.
                let iconsWidth = s.icons.isEmpty ? 0 : Self.iconSize + step * CGFloat(s.icons.count - 1)
                let fullRoom = Self.iconSize + step * CGFloat(Self.limit - 1) + 4
                let shownIcons = room > 1 ? (4 + iconsWidth) * min(1, room / fullRoom) : 0
                let group = numberWidth + shownIcons
                let startX = f.midX - group / 2
                let numberFrame = CGRect(x: startX, y: 0, width: numberWidth, height: Self.height)
                let numberColor = textColor.dimmed(s.shown ? 1 : 0.7).blended(withFraction: a, of: activeColor.contrastingText) ?? textColor
                Self.drawNumber(s.desktop, in: numberFrame, color: numberColor)
                guard room > 1, !s.icons.isEmpty else { continue }
                // Icons fan out from the number as the room opens, clipped to it so they appear from the left.
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: numberFrame.maxX + 4, y: 0, width: max(0, shownIcons - 4), height: Self.height)).addClip()
                for (k, icon) in s.icons.enumerated().reversed() {
                    let x = numberFrame.maxX + 4 + step * CGFloat(k)
                    icon.draw(in: NSRect(x: x, y: (Self.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize), from: .zero, operation: .sourceOver, fraction: max(0.2, a))
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    private static func drawNumber(_ d: Int, in frame: CGRect, color: NSColor) {
        let text = NSAttributedString(string: "\(d + 1)", attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: frame.midX - size.width / 2, y: (height - size.height) / 2))
    }

    func chipDesktop(at point: NSPoint) -> Int? {
        for (s, f) in zip(segments, frames) where f.insetBy(dx: -4, dy: -4).contains(point) { return s.desktop }
        return nil
    }

    func setDropTarget(_ desktop: Int?) {
        guard dropTarget != desktop else { return }
        dropTarget = desktop
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let d = chipDesktop(at: convert(event.locationInWindow, from: nil)) { context.onSelectDesktop?(d) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if let d = chipDesktop(at: convert(event.locationInWindow, from: nil)) { context.onDesktopMenu?(d, self) }
    }
}
