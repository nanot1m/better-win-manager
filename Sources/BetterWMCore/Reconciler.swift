import CoreGraphics
import Foundation

/// What we want the desktops to look like, independent of what the system currently shows.
public struct DesiredState: Equatable {
    public var grids: [SpaceID: Grid] = [:]
    /// Windows already accounted for on each Space; a visible window not in here just arrived.
    public var seen: [SpaceID: Set<WindowID>] = [:]
    /// Spaces whose next reconcile tiles every window regardless of `tileExistingOnStart` (Retile action).
    public var retileRequested: Set<SpaceID> = []
    /// Frames last requested per window; a window still larger than a frame we asked for has a minimum size.
    public var requested: [WindowID: CGRect] = [:]
    /// Windows floating on purpose (untiled by hand or restored as floating); never arrivals, even on a first visit.
    public var floating: Set<WindowID> = []

    public init() {}

    public func grid(for space: SpaceID) -> Grid { grids[space] ?? Grid() }
    public func space(containing w: WindowID) -> SpaceID? { grids.first { $0.value.contains(w) }?.key }
    public func isTiled(_ w: WindowID) -> Bool { space(containing: w) != nil }

    /// Untiling by hand makes the window floating until it is tiled again: leaving and returning to its
    /// workspace (which parks it out of sight) must not present it as a new arrival.
    public mutating func untile(_ w: WindowID) {
        for k in grids.keys { grids[k]?.remove(w) }
        floating.insert(w)
    }

    public mutating func mutate(_ space: SpaceID, _ body: (inout Grid) -> Void) {
        var g = grid(for: space)
        body(&g)
        grids[space] = g
    }
}

public struct Reconciler {
    public var config: Config
    public var enabled: Bool

    public init(config: Config, enabled: Bool = true) {
        self.config = config
        self.enabled = enabled
    }

    public func geometry(_ grid: Grid, _ screen: ScreenInfo) -> GridGeometry {
        GridGeometry(grid: grid, area: screen.area, config: config)
    }

    public func isIgnored(_ w: WindowInfo) -> Bool {
        if let id = w.bundleID, config.ignoreApps.contains(id) { return true }
        if config.floatSmallWindows, w.frame.width < config.smallWindowWidth, w.frame.height < config.smallWindowHeight { return true }
        return false
    }

    /// Brings `state` in line with `snapshot` for every active screen and emits the frame changes needed.
    /// Pure: no system calls, so the same inputs always yield the same outputs.
    public func reconcile(_ state: DesiredState, _ snapshot: Snapshot) -> (DesiredState, [Command]) {
        var state = state
        for screen in snapshot.screens {
            let space = screen.space
            var grid = state.grid(for: space)
            if state.grids[space] == nil, config.stackScreensNarrowerThan > 0, screen.area.width < config.stackScreensNarrowerThan {
                grid.mode = .stacked
            }
            let here = snapshot.windows.filter { screen.area.contains($0.frame.center) && $0.spaces.contains(space) }
            let hereIDs = Set(here.map(\.id))

            for w in grid.windows where !hereIDs.contains(w) {
                let stillHere = snapshot.window(w)?.spaces.contains(space) ?? false
                if !stillHere { grid.remove(w) }
            }

            // Arrivals: first look at a desktop keeps the on-screen order; later arrivals follow the strategy.
            let firstVisit = state.seen[space] == nil
            let known = state.seen[space] ?? []
            let shouldTile = firstVisit ? (config.tileExistingOnStart || state.retileRequested.contains(space)) : config.autoTile
            if enabled, shouldTile {
                let arrivals = here.filter { !known.contains($0.id) && !grid.contains($0.id) && !state.floating.contains($0.id) && !isIgnored($0) }
                    .sorted { a, b in
                        (a.frame.midX, a.frame.minY, a.id) < (b.frame.midX, b.frame.minY, b.id)
                    }
                for w in arrivals {
                    let geo = geometry(grid, screen)
                    // Arrivals are already in screen order, so a first visit simply appends.
                    let zone = firstVisit ? DropZone.newColumn(index: grid.columns.count)
                                          : autoTileZone(for: w, grid: &grid, geo: geo, snapshot: snapshot)
                    grid.apply(zone, to: w.id)
                    grid.spiralAnchor = w.id
                }
            }

            // Minimum sizes: a window still larger than the frame we asked for refused to shrink; distribute space around it.
            let geo = geometry(grid, screen)
            for (w, target) in geo.windowFrames() {
                guard let actual = snapshot.window(w)?.frame, state.requested[w] == target else { continue }
                let wide = actual.width > target.width + 1, tall = actual.height > target.height + 1
                guard wide || tall else { continue }
                var m = grid.minSizes[w] ?? .zero
                if wide { m.width = max(m.width, actual.width) }
                if tall { m.height = max(m.height, actual.height) }
                grid.minSizes[w] = m
            }

            state.grids[space] = grid
            state.seen[space] = hereIDs
            state.floating.subtract(grid.windows)
            state.retileRequested.remove(space)
        }
        let cmds = commands(for: state, snapshot)
        for case let .setFrame(w, f) in cmds { state.requested[w] = f }
        return (state, cmds)
    }

    /// Frame changes needed so every tiled window on an active screen sits in its slot.
    public func commands(for state: DesiredState, _ snapshot: Snapshot) -> [Command] {
        var out: [Command] = []
        for screen in snapshot.screens {
            let geo = geometry(state.grid(for: screen.space), screen)
            for (w, target) in geo.windowFrames() {
                guard let actual = snapshot.window(w)?.frame else { continue }
                // AX rounds to whole pixels; sub-pixel differences are not worth a round trip.
                if !actual.approximatelyEquals(target, tolerance: 0.75) { out.append(.setFrame(w, target)) }
            }
        }
        return out
    }

    /// Tiled windows whose real frame no longer matches their slot: the user moved or resized them by hand.
    public func displaced(_ state: DesiredState, _ snapshot: Snapshot) -> [WindowID] {
        var out: [WindowID] = []
        for screen in snapshot.screens {
            let geo = geometry(state.grid(for: screen.space), screen)
            for (w, target) in geo.windowFrames() {
                guard let actual = snapshot.window(w)?.frame else { continue }
                if !actual.approximatelyEquals(target) { out.append(w) }
            }
        }
        return out
    }

    func autoTileZone(for w: WindowInfo, grid: inout Grid, geo: GridGeometry, snapshot: Snapshot) -> DropZone {
        let focused: (Int, Int, CGRect)? = snapshot.focused.flatMap { f in
            guard let (ci, wi) = grid.position(of: f), let fr = geo.frame(of: f) else { return nil }
            return (ci, wi, fr)
        }
        let rightmost = DropZone.newColumn(index: grid.columns.count)
        switch config.autoTileStrategy {
        case .rightmost: return rightmost
        case .leftmost: return .newColumn(index: 0)
        case .position: return .newColumn(index: geo.columnIndex(forX: w.frame.midX))
        case .nextToFocused:
            guard let (ci, _, _) = focused else { return rightmost }
            return .newColumn(index: ci + 1)
        case .stackFocused:
            guard let (ci, wi, _) = focused else { return rightmost }
            return .stack(column: ci, index: wi + 1)
        case .autoSplit:
            guard let (ci, wi, fr) = focused else { return rightmost }
            return fr.width > fr.height ? .newColumn(index: ci + 1) : .stack(column: ci, index: wi + 1)
        case .spiral:
            guard let a = grid.spiralAnchor, let (ci, wi) = grid.position(of: a) else {
                grid.spiralBeside = false
                return rightmost
            }
            defer { grid.spiralBeside.toggle() }
            return grid.spiralBeside ? .newColumn(index: ci + 1) : .stack(column: ci, index: wi + 1)
        }
    }
}
