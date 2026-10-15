import CoreGraphics
import Foundation

/// A grid as saved to disk. Window IDs don't survive app relaunches, so each slot stores a fingerprint instead.
public struct SavedLayout: Codable, Equatable {
    public struct Window: Codable, Equatable {
        public var bundleID: String?
        public var title: String
        public var frame: CGRect
        public var heightWeight: CGFloat
        public init(bundleID: String?, title: String, frame: CGRect, heightWeight: CGFloat) {
            self.bundleID = bundleID; self.title = title; self.frame = frame; self.heightWeight = heightWeight
        }
    }
    public struct Column: Codable, Equatable {
        public var weight: CGFloat
        public var windows: [Window]
        public init(weight: CGFloat, windows: [Window]) { self.weight = weight; self.windows = windows }
    }
    public struct Space: Codable, Equatable {
        public var id: SpaceID
        public var columns: [Column]
        public init(id: SpaceID, columns: [Column]) { self.id = id; self.columns = columns }
    }
    public var spaces: [Space] = []

    public init(spaces: [Space] = []) { self.spaces = spaces }

    /// Captures every non-empty grid in `state`, describing windows with what `snapshot` knows about them.
    public static func capture(_ state: DesiredState, _ snapshot: Snapshot) -> SavedLayout {
        var out = SavedLayout()
        for (space, grid) in state.grids.sorted(by: { $0.key < $1.key }) where !grid.isEmpty {
            let columns = grid.columns.compactMap { col -> Column? in
                let windows = col.windows.compactMap { id -> Window? in
                    guard let w = snapshot.window(id) else { return nil }
                    return Window(bundleID: w.bundleID, title: w.title, frame: w.frame, heightWeight: grid.heightWeights[id] ?? 1)
                }
                return windows.isEmpty ? nil : Column(weight: col.weight, windows: windows)
            }
            if !columns.isEmpty { out.spaces.append(Space(id: space, columns: columns)) }
        }
        return out
    }

    /// Rebuilds a grid for `space` from the saved slots, using the windows in `candidates`.
    /// Matching prefers same app and title, then same app and nearest frame, then any window of the app.
    /// Unmatched slots are dropped; a column with no survivors disappears.
    public func restore(space: SpaceID, candidates: [WindowInfo]) -> Grid? {
        guard let saved = spaces.first(where: { $0.id == space }) else { return nil }
        var pool = candidates
        func take(_ slot: Window) -> WindowInfo? {
            let sameApp = pool.indices.filter { pool[$0].bundleID == slot.bundleID }
            guard !sameApp.isEmpty else { return nil }
            let pick = sameApp.first { pool[$0].title == slot.title }
                ?? sameApp.min { distance(pool[$0].frame, slot.frame) < distance(pool[$1].frame, slot.frame) }!
            return pool.remove(at: pick)
        }
        var grid = Grid()
        for col in saved.columns {
            var ids: [WindowID] = []
            for slot in col.windows {
                guard let w = take(slot) else { continue }
                ids.append(w.id)
                grid.heightWeights[w.id] = slot.heightWeight
            }
            if !ids.isEmpty { grid.columns.append(BetterWMCore.Column(ids, weight: col.weight)) }
        }
        return grid.isEmpty ? nil : grid
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}
