import Foundation

/// A screen arrangement as columns of (relative width, window count), e.g. [(2,1),(1,2)] is a wide main window
/// with two stacked beside it. Generated per window count so the popup can show what each would do.
public struct LayoutPreset: Equatable {
    public struct Col: Equatable {
        public let weight: CGFloat
        public let count: Int
        public init(weight: CGFloat, count: Int) { self.weight = weight; self.count = count }
    }
    public let name: String
    public let columns: [Col]

    public init(name: String, columns: [Col]) { self.name = name; self.columns = columns }

    public var windowCount: Int { columns.reduce(0) { $0 + $1.count } }

    public static func presets(for n: Int) -> [LayoutPreset] {
        guard n > 0 else { return [] }
        var out: [LayoutPreset] = []
        func add(_ name: String, _ cols: [(CGFloat, Int)]) {
            let p = LayoutPreset(name: name, columns: cols.filter { $0.1 > 0 }.map { Col(weight: $0.0, count: $0.1) })
            if !out.contains(where: { $0.columns == p.columns }) { out.append(p) }
        }
        if n == 1 { add("Full", [(1, 1)]); return out }
        add("Columns", Array(repeating: (1, 1), count: n))
        add("Main + stack", [(1, 1), (1, n - 1)])
        add("Wide main", [(2, 1), (1, n - 1)])
        add("Narrow main", [(1, 1), (2, n - 1)])
        if n >= 4 {
            let cols = (n + 1) / 2
            add("Grid", (0..<cols).map { i in (1, i < cols - 1 || n % 2 == 0 ? 2 : 1) })
        }
        if n >= 3 { add("Main + two stacks", [(2, 1), (1, (n - 1 + 1) / 2), (1, (n - 1) / 2)]) }
        if n <= 3 { add("Stack", [(1, n)]) }
        return Array(out.prefix(6))
    }
}
