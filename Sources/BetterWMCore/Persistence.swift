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
        public var mode: LayoutMode
        /// Untiled windows living on this space, with their real frames (not the parking spot).
        public var floating: [Window]
        public init(id: SpaceID, columns: [Column], mode: LayoutMode = .columns, floating: [Window] = []) {
            self.id = id; self.columns = columns; self.mode = mode; self.floating = floating
        }

        enum CodingKeys: String, CodingKey { case id, columns, mode, floating }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(SpaceID.self, forKey: .id)
            columns = try c.decode([Column].self, forKey: .columns)
            mode = try c.decodeIfPresent(LayoutMode.self, forKey: .mode) ?? .columns
            floating = try c.decodeIfPresent([Window].self, forKey: .floating) ?? []
        }
    }
    /// Bumped when the meaning of stored ids changes; `migrated(currentSpace:)` upgrades older files.
    public static let schemaVersion = 2
    public var version: Int = SavedLayout.schemaVersion
    public var spaces: [Space] = []
    /// Apps hidden by the window manager at the time of the save; unhidden at launch if a run ended without cleanup.
    public var hiddenPids: [Int32] = []
    /// Active workspace index per macOS desktop (keyed by the real Space id as a string), restored at launch.
    public var activeWorkspaces: [String: Int] = [:]

    public init(spaces: [Space] = []) { self.spaces = spaces }

    enum CodingKeys: String, CodingKey { case version, spaces, hiddenPids, activeWorkspaces }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        spaces = try c.decodeIfPresent([Space].self, forKey: .spaces) ?? []
        hiddenPids = try c.decodeIfPresent([Int32].self, forKey: .hiddenPids) ?? []
        activeWorkspaces = try c.decodeIfPresent([String: Int].self, forKey: .activeWorkspaces) ?? [:]
    }

    /// v1 virtual ids (1_000_000 + ws*100 + screen) belonged to one global workspace set. v2 ids are
    /// per macOS desktop; the old grids are attached to `currentSpace`, the desktop they were last used on.
    public func migrated(currentSpace: SpaceID) -> SavedLayout {
        guard version < 2 else { return self }
        var out = self
        out.version = SavedLayout.schemaVersion
        out.spaces = spaces.map { sp in
            guard sp.id >= 1_000_000, sp.id < 1_000_000_000 else { return sp }
            let rest = sp.id - 1_000_000
            return Space(id: 1_000_000_000 + currentSpace * 10_000 + rest, columns: sp.columns)
        }
        return out
    }

    /// Captures every non-empty grid in `state`, describing windows with what `snapshot` knows about them.
    /// `floatingSpace` names the space an untiled window belongs to; nil leaves it out.
    public static func capture(_ state: DesiredState, _ snapshot: Snapshot, floatingSpace: (WindowInfo) -> SpaceID? = { _ in nil }) -> SavedLayout {
        var out = SavedLayout()
        // Empty grids are still worth saving when their mode isn't the default.
        for (space, grid) in state.grids.sorted(by: { $0.key < $1.key }) where !grid.isEmpty || grid.mode != .columns {
            let columns = grid.columns.compactMap { col -> Column? in
                let windows = col.windows.compactMap { id -> Window? in
                    guard let w = snapshot.window(id) else { return nil }
                    return Window(bundleID: w.bundleID, title: w.title, frame: w.frame, heightWeight: grid.heightWeights[id] ?? 1)
                }
                return windows.isEmpty ? nil : Column(weight: col.weight, windows: windows)
            }
            if !columns.isEmpty || grid.mode != .columns { out.spaces.append(Space(id: space, columns: columns, mode: grid.mode)) }
        }
        for w in snapshot.windows where !state.isTiled(w.id) {
            guard let space = floatingSpace(w) else { continue }
            let slot = Window(bundleID: w.bundleID, title: w.title, frame: w.frame, heightWeight: 1)
            if let i = out.spaces.firstIndex(where: { $0.id == space }) { out.spaces[i].floating.append(slot) }
            else { out.spaces.append(Space(id: space, columns: [], floating: [slot])) }
        }
        out.spaces.sort { $0.id < $1.id }
        return out
    }

    /// Pairs saved floating windows of `space` with `candidates` (same app and title, else nearest frame) and
    /// returns each match with the frame to put it back at.
    /// With `exactTitle`, only a window with the slot's exact title qualifies (no nearest-frame fallback).
    public func restoreFloating(space: SpaceID, candidates: [WindowInfo], exactTitle: Bool = false) -> [(id: WindowID, frame: CGRect)] {
        guard let saved = spaces.first(where: { $0.id == space }), !saved.floating.isEmpty else { return [] }
        var pool = candidates
        var out: [(WindowID, CGRect)] = []
        for slot in saved.floating {
            let sameApp = pool.indices.filter { pool[$0].bundleID == slot.bundleID }
            guard !sameApp.isEmpty else { continue }
            let exact = sameApp.first { pool[$0].title == slot.title }
            guard let pick = exact ?? (exactTitle ? nil : sameApp.min { distance(pool[$0].frame, slot.frame) < distance(pool[$1].frame, slot.frame) }) else { continue }
            out.append((pool.remove(at: pick).id, slot.frame))
        }
        return out
    }

    public func mode(for space: SpaceID) -> LayoutMode? { spaces.first { $0.id == space }?.mode }

    /// Rebuilds a grid for `space` from the saved slots, using the windows in `candidates`.
    /// Matching prefers same app and title, then same app and nearest frame, then any window of the app.
    /// Unmatched slots are dropped; a column with no survivors disappears.
    public func restore(space: SpaceID, candidates: [WindowInfo], exactTitle: Bool = false) -> Grid? {
        guard let saved = spaces.first(where: { $0.id == space }) else { return nil }
        var pool = candidates
        func take(_ slot: Window) -> WindowInfo? {
            let sameApp = pool.indices.filter { pool[$0].bundleID == slot.bundleID }
            guard !sameApp.isEmpty else { return nil }
            let exact = sameApp.first { pool[$0].title == slot.title }
            guard let pick = exact ?? (exactTitle ? nil : sameApp.min { distance(pool[$0].frame, slot.frame) < distance(pool[$1].frame, slot.frame) }) else { return nil }
            return pool.remove(at: pick)
        }
        var grid = Grid()
        grid.mode = saved.mode
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
