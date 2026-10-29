import CoreGraphics
import Foundation

public struct Column: Equatable {
    public var windows: [WindowID]
    public var weight: CGFloat

    public init(_ windows: [WindowID], weight: CGFloat = 1) {
        self.windows = windows
        self.weight = weight
    }
}

/// The desired arrangement of one desktop: columns of windows, plus the per-window sizing hints
/// the geometry needs. A plain value; geometry and mutations are pure functions of it.
public struct Grid: Equatable {
    public var mode: LayoutMode = .columns
    public var columns: [Column] = []
    public var heightWeights: [WindowID: CGFloat] = [:]
    /// Sizes windows refused to shrink below; the layout distributes space around them.
    public var minSizes: [WindowID: CGSize] = [:]
    /// Last auto-tiled window and whether the next spiral step goes beside (true) or below it.
    public var spiralAnchor: WindowID?
    public var spiralBeside = true

    public init() {}

    public var windows: [WindowID] { columns.flatMap(\.windows) }
    public var isEmpty: Bool { columns.isEmpty }
    public func contains(_ w: WindowID) -> Bool { columns.contains { $0.windows.contains(w) } }

    public func position(of w: WindowID) -> (column: Int, index: Int)? {
        for (ci, c) in columns.enumerated() {
            if let wi = c.windows.firstIndex(of: w) { return (ci, wi) }
        }
        return nil
    }

    // MARK: Mutations

    public mutating func remove(_ w: WindowID) {
        if spiralAnchor == w { spiralAnchor = nil }
        minSizes[w] = nil
        heightWeights[w] = nil
        for i in columns.indices { columns[i].windows.removeAll { $0 == w } }
        columns.removeAll { $0.windows.isEmpty }
    }

    public mutating func clear() {
        let mode = self.mode
        self = Grid()
        self.mode = mode
    }

    /// Stacked mode keeps one window per column (the deck order); switching to it flattens any stacks.
    public mutating func setMode(_ m: LayoutMode) {
        mode = m
        if m == .stacked { columns = windows.map { Column([$0]) } }
    }

    public mutating func equalize() {
        for i in columns.indices { columns[i].weight = 1 }
        heightWeights.removeAll()
        minSizes.removeAll()
    }

    public mutating func apply(_ zone: DropZone, to w: WindowID) {
        // A cascade has no stacks: anything that would stack becomes a deck position just after the target.
        if mode == .stacked, case let .stack(ci, _) = zone { apply(.newColumn(index: ci + 1), to: w); return }
        let origin = position(of: w)?.column
        let originWasAlone = origin.map { columns[$0].windows.count == 1 } ?? false
        if let o = origin, originWasAlone, case .stack(o, _) = zone { return }
        remove(w)
        // Zone indices were computed with `w` still tiled; its column may have vanished.
        func adjusted(_ ci: Int) -> Int {
            if let o = origin, originWasAlone, o < ci { return ci - 1 }
            return min(ci, columns.count)
        }
        switch zone {
        case let .newColumn(i):
            columns.insert(Column([w]), at: adjusted(i))
        case let .stack(ci, i):
            let idx = adjusted(ci)
            if idx < columns.count {
                columns[idx].windows.insert(w, at: min(i, columns[idx].windows.count))
            } else {
                columns.append(Column([w]))
            }
        }
    }

    /// Replaces the whole grid with `preset`, filling columns left to right from `windows`.
    public mutating func apply(preset: LayoutPreset, windows: [WindowID]) {
        clear()
        var rest = windows[...]
        for c in preset.columns {
            let slice = Array(rest.prefix(c.count))
            rest = rest.dropFirst(c.count)
            guard !slice.isEmpty else { break }
            columns.append(Column(slice, weight: c.weight))
        }
        for w in rest { columns.append(Column([w])) }
    }

    /// Width fractions a column at the screen edge cycles through when moved into the edge again.
    public static let edgeFractions: [CGFloat] = [1.0 / 3, 1.0 / 4, 2.0 / 3, 1.0 / 2]

    /// Column `ci`'s share of the total width under the current weights.
    public func fraction(ofColumn ci: Int) -> CGFloat {
        guard ci >= 0, ci < columns.count else { return 0 }
        let total = columns.reduce(0) { $0 + $1.weight }
        return total > 0 ? columns[ci].weight / total : 0
    }

    /// Re-weights so column `ci` takes `fraction` of the width; the others keep their relative sizes.
    public mutating func setFraction(_ fraction: CGFloat, ofColumn ci: Int) {
        guard columns.count > 1, ci >= 0, ci < columns.count, fraction > 0, fraction < 1 else { return }
        let others = columns.indices.filter { $0 != ci }.reduce(CGFloat(0)) { $0 + columns[$1].weight }
        columns[ci].weight = fraction * others / (1 - fraction)
    }

    /// Next fraction after the current one, so repeated presses cycle 1/3 → 1/4 → 2/3 → 1/2 → 1/3.
    public mutating func cycleEdgeWidth(ofColumn ci: Int) {
        guard columns.count > 1, ci >= 0, ci < columns.count else { return }
        let current = fraction(ofColumn: ci)
        let next: CGFloat
        if let i = Grid.edgeFractions.firstIndex(where: { abs($0 - current) < 0.02 }) {
            next = Grid.edgeFractions[(i + 1) % Grid.edgeFractions.count]
        } else {
            next = Grid.edgeFractions[0]
        }
        setFraction(next, ofColumn: ci)
    }

    public func canMove(_ w: WindowID, _ dir: Move) -> Bool {
        guard let (ci, wi) = position(of: w) else { return false }
        // A stacked deck has no stacks to merge into; left/right reorder the deck.
        if mode == .stacked, dir == .mergeLeft || dir == .mergeRight { return false }
        let alone = columns[ci].windows.count == 1
        switch dir {
        case .left: return !alone || ci > 0 || columns.count > 1
        case .right: return !alone || ci + 1 < columns.count || columns.count > 1
        case .mergeLeft: return ci > 0
        case .mergeRight: return ci + 1 < columns.count
        case .up: return wi > 0
        case .down: return wi + 1 < columns[ci].windows.count
        }
    }

    /// Moves column `from` to position `to`, shifting the ones in between (a stacked deck's tabs, dragged).
    public mutating func moveColumn(from: Int, to: Int) {
        guard from != to, columns.indices.contains(from), columns.indices.contains(to) else { return }
        let c = columns.remove(at: from)
        columns.insert(c, at: to)
    }

    public mutating func move(_ w: WindowID, _ dir: Move) {
        guard let (ci, wi) = position(of: w) else { return }
        let alone = columns[ci].windows.count == 1
        switch dir {
        // At the edge already: cycle the column's width instead of moving.
        case .left where alone && ci == 0: cycleEdgeWidth(ofColumn: ci)
        case .right where alone && ci + 1 == columns.count: cycleEdgeWidth(ofColumn: ci)
        case .left where alone: columns.swapAt(ci, ci - 1)
        case .left: apply(.newColumn(index: ci), to: w)
        case .right where alone: columns.swapAt(ci, ci + 1)
        case .right: apply(.newColumn(index: ci + 1), to: w)
        case .mergeLeft: if ci > 0 { apply(.stack(column: ci - 1, index: columns[ci - 1].windows.count), to: w) }
        case .mergeRight: if ci + 1 < columns.count { apply(.stack(column: ci + 1, index: columns[ci + 1].windows.count), to: w) }
        case .up: if wi > 0 { columns[ci].windows.swapAt(wi, wi - 1) }
        case .down: if wi + 1 < columns[ci].windows.count { columns[ci].windows.swapAt(wi, wi + 1) }
        }
    }

    /// Whether window `w` is at the outer edge of the grid in direction `dir`.
    public func isAtEdge(_ w: WindowID, _ dir: Direction) -> Bool {
        guard let (ci, wi) = position(of: w) else { return false }
        switch dir {
        case .up: return wi == 0
        case .down: return wi + 1 == columns[ci].windows.count
        case .left: return ci == 0
        case .right: return ci + 1 == columns.count
        }
    }

    /// Target window when focusing in direction `dir` from `w`.
    /// When at an outer edge, wraps around within the grid (i3 default behavior).
    public func focusTarget(from w: WindowID, in dir: Direction) -> WindowID? {
        guard !isEmpty else { return nil }
        if mode == .stacked {
            let ws = windows
            guard let i = ws.firstIndex(of: w) else { return ws.first }
            switch dir {
            case .right, .down:
                return ws[(i + 1) % ws.count]
            case .left, .up:
                return ws[(i - 1 + ws.count) % ws.count]
            }
        }
        guard let (ci, wi) = position(of: w) else { return windows.first }
        switch dir {
        case .up:
            return wi > 0 ? columns[ci].windows[wi - 1] : columns[ci].windows.last
        case .down:
            return wi + 1 < columns[ci].windows.count ? columns[ci].windows[wi + 1] : columns[ci].windows.first
        case .left:
            let targetCol = ci > 0 ? ci - 1 : columns.count - 1
            return bestWindow(in: targetCol, matchingRow: wi, inColumn: ci)
        case .right:
            let targetCol = ci + 1 < columns.count ? ci + 1 : 0
            return bestWindow(in: targetCol, matchingRow: wi, inColumn: ci)
        }
    }

    /// Picks the window in `targetCol` that best corresponds to row `srcRow` in `srcCol` by vertical center fraction.
    private func bestWindow(in targetCol: Int, matchingRow srcRow: Int, inColumn srcCol: Int) -> WindowID? {
        guard targetCol >= 0, targetCol < columns.count else { return nil }
        let targetWindows = columns[targetCol].windows
        guard !targetWindows.isEmpty else { return nil }
        let srcCount = columns[srcCol].windows.count
        guard srcCount > 0 else { return targetWindows.first }
        let srcFrac = (CGFloat(srcRow) + 0.5) / CGFloat(srcCount)
        return targetWindows.enumerated().min(by: { a, b in
            let fracA = (CGFloat(a.offset) + 0.5) / CGFloat(targetWindows.count)
            let fracB = (CGFloat(b.offset) + 0.5) / CGFloat(targetWindows.count)
            return abs(srcFrac - fracA) < abs(srcFrac - fracB)
        })?.element
    }

    /// Window on the entry edge of this grid when focus enters from another screen in direction `dir`.
    public func entryWindow(from dir: Direction, relativeTo point: CGPoint, in area: CGRect) -> WindowID? {
        guard !isEmpty else { return nil }
        if mode == .stacked {
            return dir == .left || dir == .up ? windows.last : windows.first
        }
        switch dir {
        case .left:
            let col = columns.count - 1
            return closestWindow(in: col, toY: point.y, area: area)
        case .right:
            return closestWindow(in: 0, toY: point.y, area: area)
        case .up:
            let col = columnIndex(forX: point.x, in: area)
            return columns[col].windows.last
        case .down:
            let col = columnIndex(forX: point.x, in: area)
            return columns[col].windows.first
        }
    }

    private func columnIndex(forX x: CGFloat, in area: CGRect) -> Int {
        let fracX = (x - area.minX) / max(1, area.width)
        var edge: CGFloat = 0
        for ci in columns.indices {
            edge += fraction(ofColumn: ci)
            if fracX < edge { return ci }
        }
        return columns.count - 1
    }

    private func closestWindow(in col: Int, toY y: CGFloat, area: CGRect) -> WindowID? {
        guard col >= 0, col < columns.count else { return nil }
        let wins = columns[col].windows
        guard !wins.isEmpty else { return nil }
        let fracY = (y - area.minY) / max(1, area.height)
        let row = min(wins.count - 1, max(0, Int(fracY * CGFloat(wins.count))))
        return wins[row]
    }
}

/// Pure geometry for a grid inside a screen area with the given gaps.
public struct GridGeometry {
    public let grid: Grid
    public let area: CGRect
    public let config: Config
    /// The window in front of a tabbed stack; the others are kept off screen behind the corner. Nil places every
    /// window of the stack at its full frame (previews, drop zones).
    public let front: WindowID?

    public init(grid: Grid, area: CGRect, config: Config, front: WindowID? = nil) {
        self.grid = grid
        self.area = area
        self.config = config
        self.front = front
    }

    public var inner: CGRect { area.insetBy(dx: config.outerGap, dy: config.outerGap) }

    /// Split `total` by `weights`, but never below `mins`; constrained entries take their minimum and the rest share what remains.
    static func distribute(total: CGFloat, weights: [CGFloat], mins: [CGFloat]) -> [CGFloat] {
        var fixed = [Bool](repeating: false, count: weights.count)
        var out = [CGFloat](repeating: 0, count: weights.count)
        for _ in 0...weights.count {
            let free = total - zip(fixed, mins).filter(\.0).reduce(0) { $0 + $1.1 }
            let freeWeight = zip(fixed, weights).filter { !$0.0 }.reduce(0) { $0 + $1.1 }
            var changed = false
            for i in weights.indices {
                if fixed[i] { out[i] = mins[i]; continue }
                out[i] = freeWeight > 0 ? free * weights[i] / freeWeight : 0
                if out[i] < mins[i] { fixed[i] = true; changed = true }
            }
            if !changed { break }
        }
        return out
    }

    func minSize(of c: Column) -> CGSize {
        c.windows.reduce(.zero) { acc, w in
            let m = grid.minSizes[w] ?? .zero
            return CGSize(width: max(acc.width, m.width), height: acc.height + m.height)
        }
    }

    public func columnFrames() -> [CGRect] {
        guard !grid.columns.isEmpty else { return [] }
        let usable = inner.width - config.gap * CGFloat(grid.columns.count - 1)
        let widths = Self.distribute(total: usable, weights: grid.columns.map(\.weight), mins: grid.columns.map { minSize(of: $0).width })
        var x = inner.minX
        return widths.map { w in
            defer { x += w + config.gap }
            return CGRect(x: x, y: inner.minY, width: w, height: inner.height)
        }
    }

    /// Slots shrunk by the ring gap, except the ones waiting aside: those are placed by position only.
    public func windowFrames() -> [(WindowID, CGRect)] {
        let inset = config.tileInset
        guard inset > 0 else { return slotFrames() }
        return slotFrames().map { w, f in (w, waitsAside(f) ? f : f.insetBy(dx: inset, dy: inset)) }
    }

    private func slotFrames() -> [(WindowID, CGRect)] {
        if grid.mode == .stacked { return stackedFrames() }
        var out: [(WindowID, CGRect)] = []
        for (c, cf) in zip(grid.columns, columnFrames()) {
            let usable = cf.height - config.gap * CGFloat(c.windows.count - 1)
            let heights = Self.distribute(total: usable, weights: c.windows.map { grid.heightWeights[$0] ?? 1 },
                                          mins: c.windows.map { grid.minSizes[$0]?.height ?? 0 })
            var y = cf.minY
            for (w, h) in zip(c.windows, heights) {
                out.append((w, CGRect(x: cf.minX, y: y, width: cf.width, height: h)))
                y += h + config.gap
            }
        }
        return out
    }

    /// The strip the tabs occupy on a stacked screen, or nil for a cascade (and for other layouts).
    public func tabStripFrame() -> CGRect? {
        guard grid.mode == .stacked else { return nil }
        switch config.stackStyle {
        case .cascade: return nil
        case .tabsTop: return CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: config.tabHeight)
        case .tabsLeft: return CGRect(x: inner.minX, y: inner.minY, width: config.tabHeight, height: inner.height)
        case .tabsRight: return CGRect(x: inner.maxX - config.tabHeight, y: inner.minY, width: config.tabHeight, height: inner.height)
        }
    }

    /// Where a tabbed stack's hidden windows wait; a window there is done moving whatever its size.
    public func waitsAside(_ frame: CGRect) -> Bool {
        grid.mode == .stacked && config.stackStyle != .cascade && frame.minX == area.maxX - 2 && frame.minY == area.maxY - 2
    }

    /// Tabs: every window fills what the strip leaves, plus room for the focus ring between the two.
    private var tabbedArea: CGRect {
        let t = config.tabHeight + config.focusRingOutset
        switch config.stackStyle {
        case .cascade: return inner
        case .tabsTop: return CGRect(x: inner.minX, y: inner.minY + t, width: inner.width, height: inner.height - t)
        case .tabsLeft: return CGRect(x: inner.minX + t, y: inner.minY, width: inner.width - t, height: inner.height)
        case .tabsRight: return CGRect(x: inner.minX, y: inner.minY, width: inner.width - t, height: inner.height)
        }
    }

    /// Cascade: every window as large as the screen allows, shifted right by `stackOffset` per position.
    private func stackedFrames() -> [(WindowID, CGRect)] {
        let ws = grid.windows
        guard !ws.isEmpty else { return [] }
        if config.stackStyle != .cascade {
            // Only the front window shows; the rest wait past the corner with two points on screen, like parked
            // windows, so a tab click brings one in at full size with no resize.
            guard let front, ws.contains(front) else { return ws.map { ($0, tabbedArea) } }
            let hidden = CGRect(x: area.maxX - 2, y: area.maxY - 2, width: tabbedArea.width, height: tabbedArea.height)
            return ws.map { ($0, $0 == front ? tabbedArea : hidden) }
        }
        let n = CGFloat(ws.count)
        let offset = min(config.stackOffset, inner.width / max(1, n) / 2)
        let width = inner.width - offset * (n - 1)
        return ws.enumerated().map { i, w in
            (w, CGRect(x: inner.minX + offset * CGFloat(i), y: inner.minY, width: width, height: inner.height))
        }
    }

    public func frame(of w: WindowID) -> CGRect? { windowFrames().first { $0.0 == w }?.1 }

    /// Column slot a window centered at x would occupy, by comparing against existing column centers.
    public func columnIndex(forX x: CGFloat) -> Int {
        columnFrames().firstIndex { x < $0.midX } ?? grid.columns.count
    }

    public func handleFrames() -> [(Handle, CGRect)] {
        guard grid.mode == .columns else { return [] }
        var out: [(Handle, CGRect)] = []
        let cf = columnFrames()
        for i in cf.indices.dropLast() {
            let midX = (cf[i].maxX + cf[i + 1].minX) / 2
            out.append((.column(i), CGRect(x: midX - config.handleWidth / 2, y: inner.minY, width: config.handleWidth, height: inner.height)))
        }
        let wf = windowFrames()
        var k = 0
        for (ci, c) in grid.columns.enumerated() {
            for i in 0..<max(0, c.windows.count - 1) {
                let midY = (wf[k + i].1.maxY + wf[k + i + 1].1.minY) / 2
                out.append((.row(column: ci, index: i), CGRect(x: cf[ci].minX, y: midY - config.handleWidth / 2, width: cf[ci].width, height: config.handleWidth)))
            }
            k += c.windows.count
        }
        return out
    }

    /// Each window is split by its diagonals: the nearest edge decides. Left/right create a column, top/bottom stack.
    public func zone(at p: CGPoint, dragging dragged: WindowID?) -> (DropZone, CGRect)? {
        guard inner.contains(p) else { return nil }
        if grid.mode == .stacked { return stackedZone(at: p, dragging: dragged) }
        let cf = columnFrames()
        if cf.isEmpty { return (.newColumn(index: 0), inner) }
        let origin = dragged.flatMap { grid.position(of: $0)?.column }
        let alone = origin.map { grid.columns[$0].windows.count == 1 } ?? false
        func newColumnIsNoop(_ idx: Int) -> Bool { alone && (idx == origin! || idx == origin! + 1) }
        for (ci, f) in cf.enumerated() {
            guard f.minX - config.gap <= p.x, p.x < f.maxX + config.gap else { continue }
            let others = grid.columns[ci].windows.filter { $0 != dragged }
            if others.isEmpty { return (.stack(column: ci, index: 0), f) }
            let n = CGFloat(others.count)
            let h = (f.height - config.gap * (n - 1)) / n
            let slot = Int(min(n - 1, max(0, (p.y - f.minY) / (h + config.gap))))
            let slotRect = CGRect(x: f.minX, y: f.minY + CGFloat(slot) * (h + config.gap), width: f.width, height: h)
            let rx = (p.x - slotRect.minX) / slotRect.width, ry = (p.y - slotRect.minY) / slotRect.height
            let toSide = min(rx, 1 - rx), toTopBottom = min(ry, 1 - ry)
            let (lw, lh) = (slotRect.width / 2, slotRect.height / 2)
            if toSide < toTopBottom {
                if rx < 0.5, !newColumnIsNoop(ci) {
                    return (.newColumn(index: ci), CGRect(x: slotRect.minX, y: slotRect.minY, width: lw, height: slotRect.height))
                }
                if rx >= 0.5, !newColumnIsNoop(ci + 1) {
                    return (.newColumn(index: ci + 1), CGRect(x: slotRect.midX, y: slotRect.minY, width: lw, height: slotRect.height))
                }
            }
            if ry < 0.5 {
                return (.stack(column: ci, index: slot), CGRect(x: slotRect.minX, y: slotRect.minY, width: slotRect.width, height: lh))
            }
            return (.stack(column: ci, index: slot + 1), CGRect(x: slotRect.minX, y: slotRect.midY, width: slotRect.width, height: lh))
        }
        return nil
    }

    /// Stacked: the deck position under the cursor, by the visible left strips; dropping past them appends.
    private func stackedZone(at p: CGPoint, dragging dragged: WindowID?) -> (DropZone, CGRect)? {
        let others = grid.windows.filter { $0 != dragged }
        guard !others.isEmpty else { return (.newColumn(index: 0), tabbedArea) }
        let n = CGFloat(others.count)
        if config.stackStyle != .cascade {
            // The deck position follows where along the strip the window is dropped; left tabs run bottom to top.
            var along = config.stackStyle == .tabsTop ? (p.x - inner.minX) / max(1, inner.width) : (p.y - inner.minY) / max(1, inner.height)
            if config.stackStyle == .tabsLeft { along = 1 - along }
            return (.newColumn(index: min(others.count, max(0, Int(along * (n + 1))))), tabbedArea)
        }
        let offset = min(config.stackOffset, inner.width / max(1, n + 1) / 2)
        let index = min(others.count, Int((p.x - inner.minX) / max(1, offset)))
        let width = inner.width - offset * n
        let highlight = CGRect(x: inner.minX + offset * CGFloat(index), y: inner.minY, width: width, height: inner.height)
        return (.newColumn(index: index), highlight)
    }

    /// Grid with the boundary between column i and i+1 moved to global x, keeping the pair's total width.
    public func resizing(boundary i: Int, toX x: CGFloat) -> Grid {
        var g = grid
        let cf = columnFrames()
        guard i >= 0, i + 1 < cf.count, i + 1 < g.columns.count else { return g }
        // Weights drift from real widths once a column is pinned to a minimum; re-anchor them first.
        for (ci, f) in cf.enumerated() { g.columns[ci].weight = f.width }
        let minA = max(120, minSize(of: grid.columns[i]).width), minB = max(120, minSize(of: grid.columns[i + 1]).width)
        let pairWidth = cf[i].width + cf[i + 1].width
        guard pairWidth >= minA + minB else { return g }
        let left = min(max(x - config.gap / 2 - cf[i].minX, minA), pairWidth - minB)
        g.columns[i].weight = left
        g.columns[i + 1].weight = pairWidth - left
        return g
    }

    /// Grid with window `w` grown (or shrunk, for a negative delta) by `delta` points in every direction it has a
    /// neighbour: the boundary to the right (else left) moves, and so does the one below (else above) within its column.
    public func resizing(window w: WindowID, by delta: CGFloat) -> Grid {
        guard let (ci, wi) = grid.position(of: w) else { return grid }
        var g = grid
        let cf = columnFrames()
        if ci + 1 < cf.count {
            g = resizing(boundary: ci, toX: cf[ci].maxX + config.gap / 2 + delta)
        } else if ci > 0 {
            g = resizing(boundary: ci - 1, toX: cf[ci].minX - config.gap / 2 - delta)
        }
        let geo = GridGeometry(grid: g, area: area, config: config)
        let frames = geo.windowFrames().filter { g.columns[ci].windows.contains($0.0) }.map(\.1)
        if wi + 1 < frames.count {
            g = geo.resizing(column: ci, boundary: wi, toY: frames[wi].maxY + config.gap / 2 + delta)
        } else if wi > 0 {
            g = geo.resizing(column: ci, boundary: wi - 1, toY: frames[wi].minY - config.gap / 2 - delta)
        }
        return g
    }

    /// Grid with the boundary between window i and i+1 in a column moved to global y, keeping the pair's total height.
    public func resizing(column ci: Int, boundary i: Int, toY y: CGFloat) -> Grid {
        var g = grid
        guard ci >= 0, ci < grid.columns.count else { return g }
        let c = grid.columns[ci]
        guard i >= 0, i + 1 < c.windows.count else { return g }
        let frames = windowFrames().filter { c.windows.contains($0.0) }.map(\.1)
        guard i + 1 < frames.count else { return g }
        for (w, f) in zip(c.windows, frames) { g.heightWeights[w] = f.height }
        let a = c.windows[i], b = c.windows[i + 1]
        let minA = max(80, grid.minSizes[a]?.height ?? 0), minB = max(80, grid.minSizes[b]?.height ?? 0)
        let pairHeight = frames[i].height + frames[i + 1].height
        guard pairHeight >= minA + minB else { return g }
        let top = min(max(y - config.gap / 2 - frames[i].minY, minA), pairHeight - minB)
        g.heightWeights[a] = top
        g.heightWeights[b] = pairHeight - top
        return g
    }
}
