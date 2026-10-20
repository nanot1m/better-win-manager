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
}

/// Pure geometry for a grid inside a screen area with the given gaps.
public struct GridGeometry {
    public let grid: Grid
    public let area: CGRect
    public let config: Config

    public init(grid: Grid, area: CGRect, config: Config) {
        self.grid = grid
        self.area = area
        self.config = config
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

    public func windowFrames() -> [(WindowID, CGRect)] {
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

    /// Cascade: every window as large as the screen allows, shifted right by `stackOffset` per position.
    private func stackedFrames() -> [(WindowID, CGRect)] {
        let ws = grid.windows
        guard !ws.isEmpty else { return [] }
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
        guard !others.isEmpty else { return (.newColumn(index: 0), inner) }
        let n = CGFloat(others.count)
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
