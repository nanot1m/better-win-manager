import CoreGraphics
import Foundation

/// What we want the desktops to look like, independent of what the system currently shows.
public struct DesiredState: Equatable {
    public var grids: [SpaceID: Grid] = [:]
    /// Windows already accounted for on each Space; a visible window not in here just arrived.
    public var seen: [SpaceID: Set<WindowID>] = [:]
    /// Spaces whose next reconcile tiles every window regardless of `tileExistingOnStart` (Retile action).
    public var retileRequested: Set<SpaceID> = []
    /// Carries plans out and keeps the verdict on every ask: pending, confirmed, refused.
    public var executor = Executor()
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

    /// Drops every per-window record of a window that no longer exists.
    public mutating func forget(_ w: WindowID) {
        for k in grids.keys { grids[k]?.remove(w) }
        for k in seen.keys { seen[k]?.remove(w) }
        floating.remove(w)
        executor.forget(w)
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

    public func geometry(_ grid: Grid, _ screen: ScreenInfo, front: WindowID? = nil) -> GridGeometry {
        GridGeometry(grid: grid, area: screen.area, config: config, front: front)
    }

    /// The frontmost window of `grid` in `snapshot`, whose windows are front to back.
    func front(of grid: Grid, in snapshot: Snapshot) -> WindowID? { snapshot.windows.first { grid.contains($0.id) }?.id }

    public func isIgnored(_ w: WindowInfo) -> Bool {
        if let id = w.bundleID, config.ignoreApps.contains(id) { return true }
        if config.floatSmallWindows, w.frame.width < config.smallWindowWidth, w.frame.height < config.smallWindowHeight { return true }
        return false
    }

    /// Brings `state` in line with `snapshot` for every active screen and emits the plan to carry out: the asks
    /// the executor accepts now, given what it has learned about each window. Pure: no system calls, so the same
    /// inputs always yield the same outputs.
    public func reconcile(_ state: DesiredState, _ snapshot: Snapshot) -> (DesiredState, Plan) {
        var state = state
        // Verdicts first: a window that kept a larger size than asked has a minimum size to lay out around.
        let actual = { (w: WindowID) -> CGRect? in snapshot.away.contains(w) ? nil : snapshot.window(w)?.frame }
        for learned in state.executor.observe(actual: actual, now: snapshot.now) {
            guard let space = state.space(containing: learned.window) else { continue }
            state.mutate(space) { grid in
                var m = grid.minSizes[learned.window] ?? .zero
                m.width = max(m.width, learned.minSize.width)
                m.height = max(m.height, learned.minSize.height)
                grid.minSizes[learned.window] = m
            }
        }
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

            state.grids[space] = grid
            state.seen[space] = hereIDs
            state.floating.subtract(grid.windows)
            state.retileRequested.remove(space)
        }
        let accepted = state.executor.submit(plan(for: state, snapshot), actual: actual, now: snapshot.now)
        return (state, accepted)
    }

    /// Every tiled window on an active screen with its slot, its real frame and why it goes there.
    func slots(_ state: DesiredState, _ snapshot: Snapshot) -> [(window: WindowID, target: CGRect, actual: CGRect, intent: Intent)] {
        snapshot.screens.flatMap { screen in
            let geo = geometry(state.grid(for: screen.space), screen, front: front(of: state.grid(for: screen.space), in: snapshot))
            return geo.windowFrames().compactMap { w, target -> (window: WindowID, target: CGRect, actual: CGRect, intent: Intent)? in
                guard !snapshot.away.contains(w), let actual = snapshot.window(w)?.frame else { return nil }
                // A hidden window of a tabbed stack that already waits by the corner is done: macOS keeps a sliver of
                // it on screen (it clamps the position), so the exact frame is never taken, and it is covered by the
                // front window anyway. It gets its real frame when it comes forward.
                if geo.waitsAside(target) {
                    if abs(actual.minX - target.minX) <= 100, abs(actual.minY - target.minY) <= 100 { return nil }
                    return (w, target, actual, .aside)
                }
                return (w, target, actual, .slot)
            }
        }
    }

    /// Everything the layout wants moved so every tiled window on an active screen sits in its slot, before the
    /// executor's verdicts. AX rounds to whole pixels; sub-pixel differences are not worth a round trip.
    public func plan(for state: DesiredState, _ snapshot: Snapshot) -> Plan {
        Plan(ops: slots(state, snapshot).filter { !$0.actual.approximatelyEquals($0.target, tolerance: 0.75) }
            .map { Op(window: $0.window, frame: $0.target, intent: $0.intent) })
    }

    /// Tiled windows whose real frame no longer matches their slot: the user moved or resized them by hand.
    /// A nudge under 10pt snaps back instead of floating the window.
    public func displaced(_ state: DesiredState, _ snapshot: Snapshot) -> [WindowID] {
        slots(state, snapshot).filter { !$0.actual.approximatelyEquals($0.target, tolerance: 10) }.map(\.window)
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
