import Cocoa

final class Column {
    var windows: [AXWindow] = []
    var weight: CGFloat = 1
    init(_ w: AXWindow) { windows = [w] }
}

enum DropZone: Equatable {
    case newColumn(index: Int)
    case stack(column: Int, index: Int)
}

final class Layout {
    private(set) var columns: [Column] = []
    private var minSizes: [AXWindow: CGSize] = [:]
    private var heightWeights: [AXWindow: CGFloat] = [:]
    var config: Config
    /// Work area in top-left-origin global coordinates (AX space).
    var area: CGRect

    init(config: Config, area: CGRect) {
        self.config = config
        self.area = area
    }

    func contains(_ w: AXWindow) -> Bool { columns.contains { $0.windows.contains(w) } }

    func remove(_ w: AXWindow) {
        minSizes[w] = nil
        heightWeights[w] = nil
        for c in columns { c.windows.removeAll { $0 == w } }
        columns.removeAll { $0.windows.isEmpty }
    }

    func equalize() {
        for c in columns { c.weight = 1 }
        heightWeights.removeAll()
        minSizes.removeAll()
    }

    func clear() {
        columns.removeAll()
        minSizes.removeAll()
        heightWeights.removeAll()
    }

    func prune() {
        for c in columns { c.windows.removeAll { !$0.isValid } }
        columns.removeAll { $0.windows.isEmpty }
    }

    private var inner: CGRect { area.insetBy(dx: config.outerGap, dy: config.outerGap) }

    /// Split `total` by `weights`, but never below `mins`; constrained entries take their minimum and the rest share what remains.
    private func distribute(total: CGFloat, weights: [CGFloat], mins: [CGFloat]) -> [CGFloat] {
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

    private func minSize(of c: Column) -> CGSize {
        c.windows.reduce(.zero) { acc, w in
            let m = minSizes[w] ?? .zero
            return CGSize(width: max(acc.width, m.width), height: acc.height + m.height)
        }
    }

    func columnFrames() -> [CGRect] {
        guard !columns.isEmpty else { return [] }
        let usable = inner.width - config.gap * CGFloat(columns.count - 1)
        let widths = distribute(total: usable, weights: columns.map(\.weight), mins: columns.map { minSize(of: $0).width })
        var x = inner.minX
        return zip(columns, widths).map { _, w in
            defer { x += w + config.gap }
            return CGRect(x: x, y: inner.minY, width: w, height: inner.height)
        }
    }

    func windowFrames() -> [(AXWindow, CGRect)] {
        var out: [(AXWindow, CGRect)] = []
        for (c, cf) in zip(columns, columnFrames()) {
            let usable = cf.height - config.gap * CGFloat(c.windows.count - 1)
            let heights = distribute(total: usable, weights: c.windows.map { heightWeights[$0] ?? 1 },
                                     mins: c.windows.map { minSizes[$0]?.height ?? 0 })
            var y = cf.minY
            for (w, h) in zip(c.windows, heights) {
                out.append((w, CGRect(x: cf.minX, y: y, width: cf.width, height: h)))
                y += h + config.gap
            }
        }
        return out
    }

    /// Column slot a window centered at x would occupy, by comparing against existing column centers.
    func columnIndex(forX x: CGFloat) -> Int {
        columnFrames().firstIndex { x < $0.midX } ?? columns.count
    }

    func frame(of w: AXWindow) -> CGRect? { windowFrames().first { $0.0 == w }?.1 }

    enum Handle {
        case column(Int)
        case row(column: Int, index: Int)
        var isVertical: Bool { if case .column = self { return true } else { return false } }
    }

    func handleFrames() -> [(Handle, CGRect)] {
        var out: [(Handle, CGRect)] = []
        let cf = columnFrames()
        for i in cf.indices.dropLast() {
            let midX = (cf[i].maxX + cf[i + 1].minX) / 2
            out.append((.column(i), CGRect(x: midX - config.handleWidth / 2, y: inner.minY, width: config.handleWidth, height: inner.height)))
        }
        let wf = windowFrames()
        var k = 0
        for (ci, c) in columns.enumerated() {
            for i in 0..<max(0, c.windows.count - 1) {
                let midY = (wf[k + i].1.maxY + wf[k + i + 1].1.minY) / 2
                out.append((.row(column: ci, index: i), CGRect(x: cf[ci].minX, y: midY - config.handleWidth / 2, width: cf[ci].width, height: config.handleWidth)))
            }
            k += c.windows.count
        }
        return out
    }

    /// Move the boundary between window i and i+1 in a column to global y, keeping the pair's total height.
    func resize(column ci: Int, boundary i: Int, toY y: CGFloat) {
        let c = columns[ci]
        guard i + 1 < c.windows.count else { return }
        let frames = windowFrames().filter { f in c.windows.contains(f.0) }.map(\.1)
        for (w, f) in zip(c.windows, frames) { heightWeights[w] = f.height }
        let a = c.windows[i], b = c.windows[i + 1]
        let minA = max(80, minSizes[a]?.height ?? 0), minB = max(80, minSizes[b]?.height ?? 0)
        let pairHeight = frames[i].height + frames[i + 1].height
        guard pairHeight >= minA + minB else { return }
        let top = min(max(y - config.gap / 2 - frames[i].minY, minA), pairHeight - minB)
        heightWeights[a] = top
        heightWeights[b] = pairHeight - top
    }

    /// Move the boundary between column i and i+1 to global x, keeping the pair's total width.
    func resize(boundary i: Int, toX x: CGFloat) {
        let cf = columnFrames()
        guard i + 1 < cf.count else { return }
        // Weights drift from real widths once a column is pinned to a minimum; re-anchor them first.
        for (c, f) in zip(columns, cf) { c.weight = f.width }
        let minA = max(120, minSize(of: columns[i]).width), minB = max(120, minSize(of: columns[i + 1]).width)
        let pairWidth = cf[i].width + cf[i + 1].width
        guard pairWidth >= minA + minB else { return }
        let left = min(max(x - config.gap / 2 - cf[i].minX, minA), pairWidth - minB)
        columns[i].weight = left
        columns[i + 1].weight = pairWidth - left
    }

    /// Each window is split by its diagonals: the nearest edge decides. Left/right create a column, top/bottom stack.
    func zone(at p: CGPoint, dragging dragged: AXWindow) -> (DropZone, CGRect)? {
        guard inner.contains(p) else { return nil }
        let cf = columnFrames()
        if cf.isEmpty { return (.newColumn(index: 0), inner) }
        let origin = columns.firstIndex { $0.windows.contains(dragged) }
        let alone = origin.map { columns[$0].windows.count == 1 } ?? false
        func newColumnIsNoop(_ idx: Int) -> Bool { alone && (idx == origin! || idx == origin! + 1) }
        for (ci, f) in cf.enumerated() {
            guard f.minX - config.gap <= p.x, p.x < f.maxX + config.gap else { continue }
            let others = columns[ci].windows.filter { $0 != dragged }
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

    func apply(_ zone: DropZone, to w: AXWindow) {
        let origin = columns.firstIndex { $0.windows.contains(w) }
        let originWasAlone = origin.map { columns[$0].windows.count == 1 } ?? false
        if let o = origin, originWasAlone {
            switch zone {
            case .stack(o, _): return
            default: break
            }
        }
        remove(w)
        // Zone indices were computed with `w` still tiled; its column may have vanished.
        func adjusted(_ ci: Int) -> Int {
            if let o = origin, originWasAlone, o < ci { return ci - 1 }
            return min(ci, columns.count)
        }
        switch zone {
        case let .newColumn(i):
            columns.insert(Column(w), at: adjusted(i))
        case let .stack(ci, i):
            let idx = adjusted(ci)
            if idx < columns.count {
                columns[idx].windows.insert(w, at: min(i, columns[idx].windows.count))
            } else {
                columns.append(Column(w))
            }
        }
    }

    /// Windows the user moved or resized by hand no longer match their slot.
    func displacedWindows() -> [AXWindow] {
        windowFrames().filter { w, f in w.isValid && !w.frame.approximatelyEquals(f) }.map(\.0)
    }

    func applyFrames() {
        for (w, f) in windowFrames() where w.frame != f { w.frame = f }
        var learned = false
        for (w, f) in windowFrames() {
            let actual = w.frame.size
            let wideOverflow = actual.width > f.width + 1, tallOverflow = actual.height > f.height + 1
            guard wideOverflow || tallOverflow else { continue }
            var m = minSizes[w] ?? .zero
            if wideOverflow { m.width = max(m.width, actual.width) }
            if tallOverflow { m.height = max(m.height, actual.height) }
            minSizes[w] = m
            learned = true
        }
        if learned {
            for (w, f) in windowFrames() where w.frame != f { w.frame = f }
        }
    }
}

extension CGRect {
    /// AX reports whole-pixel frames while the layout computes fractional ones.
    func approximatelyEquals(_ o: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}
