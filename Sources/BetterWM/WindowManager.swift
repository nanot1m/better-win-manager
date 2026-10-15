import BetterWMCore
import Cocoa

/// Thin shell: owns the desired state, feeds snapshots to the pure reconciler, executes the resulting commands,
/// and translates UI gestures into state mutations.
final class WindowManager {
    private(set) var state = DesiredState()
    /// Grids from the previous run, applied to each desktop the first time it is seen.
    private var saved = SavedLayout()
    private var lastSaved = SavedLayout()
    private var saveWork: DispatchWorkItem?
    private var virtualWS: VirtualWorkspaces?
    var isVirtual: Bool { virtualWS != nil }
    /// Visible window IDs front to back from the last full tick; avoids re-enumerating on every gesture frame.
    private var zOrder: [WindowID] = []
    private var reconciler: Reconciler
    let system = SystemObserver()
    let overlay: ZoneOverlay
    let focusRing: FocusRing
    private var handles: [HandleWindow] = []
    private var timer: Timer?
    private var axObserver: WindowObserver?
    /// Set while a Space switch is in flight; the window list mixes both desktops during the slide.
    private var switching = false
    /// Set while the user drags a window or a gap handle; reconciling mid-gesture would fight it.
    var interacting = false { didSet { focusRing.suspended = interacting } }
    var onFocusChange: (() -> Void)?
    var onDesktopChange: (() -> Void)?

    var config: Config {
        didSet {
            reconciler.config = config
            focusRing.apply(config)
            configureWorkspaces()
        }
    }

    /// Switches between native Spaces and virtual workspaces, moving windows and grids across so desktop N
    /// becomes workspace N and back.
    private func configureWorkspaces() {
        switch config.workspaces {
        case .native:
            guard let v = virtualWS else { return }
            migrateToNative(from: v)
            virtualWS = nil
            system.spaceOverride = nil
            system.windowSpacesOverride = nil
        case .virtual:
            if let v = virtualWS { v.setCount(config.virtualWorkspaces); return }
            let v = VirtualWorkspaces(count: config.virtualWorkspaces)
            virtualWS = v
            migrateToVirtual(v)
            system.spaceOverride = { [unowned v] screen in
                v.spaceID(workspace: v.active, screenIndex: NSScreen.screens.firstIndex(of: screen) ?? 0)
            }
            system.windowSpacesOverride = { [unowned v, unowned self] id in
                let screenIndex = self.system.axWindow(id).flatMap { w in NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(w.frame.center) } } ?? 0
                return [v.spaceID(workspace: v.workspace(of: id), screenIndex: screenIndex)]
            }
        }
        tick()
        // Window moves between Spaces land asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.tick() }
    }

    /// Native → virtual: every window on another macOS desktop comes to this one and joins the matching workspace.
    private func migrateToVirtual(_ v: VirtualWorkspaces) {
        let desktops = Spaces.desktops()
        guard let currentIndex = Spaces.currentDesktopIndex() else { state = DesiredState(); return }
        v.switchTo(min(currentIndex, v.count - 1))
        let currentSpace = desktops[currentIndex]
        var newState = DesiredState()
        func screenIndex(_ f: CGRect) -> Int { NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(f.center) } ?? 0 }
        // Switching modes at runtime: desktop N becomes workspace N. At launch (no grids yet) the saved
        // layout assigns workspaces as windows appear, so only gather the windows here.
        let atLaunch = state.grids.isEmpty
        for w in Spaces.allWindows() {
            guard let id = id(w), let space = Spaces.spaces(of: id).first, let index = desktops.firstIndex(of: space) else { continue }
            if !atLaunch { v.move(id, to: min(index, v.count - 1)) }
            if space != currentSpace { Spaces.moveWindow(id, toSpace: currentSpace) { _ in } }
        }
        for (space, grid) in state.grids {
            guard let index = desktops.firstIndex(of: space), let first = grid.windows.first,
                  let f = system.axWindow(first)?.frame else { continue }
            let target = v.spaceID(workspace: min(index, v.count - 1), screenIndex: screenIndex(f))
            newState.grids[target] = grid
            newState.seen[target] = Set(grid.windows)
        }
        // At launch there are no native grids yet; saved-layout matching then decides workspaces as windows appear.
        if !state.grids.isEmpty { virtualRestoreDeadline = .distantPast }
        state = newState
    }

    /// Virtual → native: unpark everything and send each window to the macOS desktop matching its workspace.
    private func migrateToNative(from v: VirtualWorkspaces) {
        let desktops = Spaces.desktops()
        let current = Spaces.current(for: NSScreen.screens[0])
        var newState = DesiredState()
        let snap = system.snapshot(tracked: tracked)
        v.unparkAll { self.system.execute([.setFrame($0, $1)]) }
        for w in snap.windows {
            let ws = v.workspace(of: w.id)
            guard ws < desktops.count, desktops[ws] != current else { continue }
            Spaces.moveWindow(w.id, toSpace: desktops[ws]) { _ in }
        }
        for (space, grid) in state.grids where space >= 1_000_000 {
            let ws = Int((space - 1_000_000) / 100)
            guard ws < desktops.count else { continue }
            newState.grids[desktops[ws]] = grid
            newState.seen[desktops[ws]] = Set(grid.windows)
        }
        state = newState
    }

    // MARK: Desktops facade (native Spaces or virtual workspaces)

    /// Every standard window with the desktop it lives on, front-to-back within each desktop, current desktop first.
    func windowsByDesktop() -> [(desktop: Int, windows: [AXWindow])] {
        var byDesktop: [Int: [AXWindow]] = [:]
        if let v = virtualWS {
            for w in Spaces.visibleWindows() { if let id = id(w) { byDesktop[v.workspace(of: id), default: []].append(w) } }
        } else {
            let desktops = Spaces.desktops()
            for w in Spaces.allWindows() {
                guard let id = id(w), let space = Spaces.spaces(of: id).first, let d = desktops.firstIndex(of: space) else { continue }
                byDesktop[d, default: []].append(w)
            }
        }
        let current = currentDesktop ?? 0
        // Reading order: left to right by column, top to bottom within it.
        func sortKey(_ w: AXWindow) -> (CGFloat, CGFloat) {
            let f = layoutFrame(of: w) ?? w.frame
            return ((f.minX / 40).rounded(), f.minY)
        }
        return byDesktop.keys.sorted { a, b in a == current ? true : b == current ? false : a < b }.map { d in
            (d, byDesktop[d]!.sorted { sortKey($0) < sortKey($1) })
        }
    }

    /// Where a window sits on its own desktop: its grid slot if tiled, its remembered frame if parked, else as is.
    private func layoutFrame(of w: AXWindow) -> CGRect? {
        guard let id = id(w) else { return nil }
        if let space = state.space(containing: id), let screen = system.screens().first {
            return reconciler.geometry(state.grid(for: space), screen).frame(of: id)
        }
        return virtualWS?.parkedFrame(of: id)
    }

    /// Brings `w` to front, switching to its desktop first when needed.
    func activate(_ w: AXWindow, onDesktop desktop: Int) {
        if desktop != currentDesktop {
            switchDesktop(desktop)
            // Native Space switches animate; raise once the new desktop is showing.
            DispatchQueue.main.asyncAfter(deadline: .now() + (isVirtual ? 0.05 : 0.5)) { w.raise() }
        } else {
            w.raise()
        }
    }

    var desktopCount: Int { virtualWS?.count ?? Spaces.desktops().count }
    var currentDesktop: Int? { virtualWS?.active ?? Spaces.currentDesktopIndex() }

    func switchDesktop(_ index: Int) {
        if let v = virtualWS {
            guard index != v.active, index >= 0 else { return }
            // Workspaces are created on demand: asking for 6 with 4 configured makes 5 and 6.
            if index >= v.count { v.setCount(index + 1) }
            // Hide the ring during the switch so it doesn't linger on the parked window.
            focusRing.suspended = true
            v.switchTo(index)
            ignoreFocusSwitchUntil = Date().addingTimeInterval(0.8)
            lastFocusedID = AXWindow.focused.flatMap(id)
            tick()
            focusTopWindow()
            v.trimEmptyTrailing(minimum: config.virtualWorkspaces)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !self.interacting else { return }
                self.focusRing.suspended = false
            }
            onDesktopChange?()
        } else {
            Spaces.switchToDesktop(index)
        }
    }

    func switchDesktop(next: Bool) {
        if let v = virtualWS {
            switchDesktop(v.active + (next ? 1 : -1))
        } else {
            Spaces.swipe(toNext: next)
        }
    }

    /// Activating a parked window (⌘Tab, Dock, a notification) switches to its workspace. Only a *change* of
    /// focus counts: after switching to an empty workspace the old window stays focused and must not pull us back.
    private var ignoreFocusSwitchUntil = Date.distantPast
    private var lastFocusedID: WindowID?
    private func followFocusedWindowsWorkspace() {
        guard let v = virtualWS, let f = AXWindow.focused, let id = id(f) else { return }
        guard id != lastFocusedID else { return }
        lastFocusedID = id
        guard Date() >= ignoreFocusSwitchUntil else { return }
        let ws = v.workspace(of: id)
        guard ws != v.active else { return }
        print("Virtual: focused window belongs to workspace \(ws + 1); switching")
        focusRing.suspended = true
        v.switchTo(ws)
        tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.interacting else { return }
            self.focusRing.suspended = false
        }
        onDesktopChange?()
    }

    private func focusTopWindow() {
        guard let v = virtualWS else { return }
        if let id = zOrder.first(where: { v.workspace(of: $0) == v.active }) { system.execute([.raise(id)]) }
    }

    /// Parks windows of inactive workspaces and restores returning floating ones; tiled ones follow their grid.
    private func applyVirtualParking(_ snap: Snapshot) {
        guard let v = virtualWS else { return }
        let ids = snap.windows.map(\.id)
        v.apply(windows: ids, isTiled: { self.state.isTiled($0) }, frame: { snap.window($0)?.frame },
                setFrame: { self.system.execute([.setFrame($0, $1)]) }, parkOrigin: { f in
                    // Bottom-right corner of the screen the window is on, leaving two points visible.
                    let screen = NSScreen.screens.first { $0.frame.toCocoa().contains(f.center) } ?? NSScreen.screens[0]
                    let r = screen.frame.toCocoa()
                    return CGPoint(x: r.maxX - 2, y: r.maxY - 2)
                })
    }

    var enabled: Bool {
        get { reconciler.enabled }
        set { reconciler.enabled = newValue }
    }

    init(config: Config) {
        self.config = config
        reconciler = Reconciler(config: config)
        focusRing = FocusRing(config: config)
        overlay = ZoneOverlay(screen: NSScreen.screens[0])
        focusRing.isTiled = { [unowned self] w in self.isTiled(w) }
        focusRing.onReorder = { [unowned self] in self.stackHandles() }
        if config.restoreLayouts, let data = try? Data(contentsOf: Config.statePath),
           let layout = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            saved = layout
            lastSaved = layout
        }
        configureWorkspaces()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            // The window list is still in flux while the slide animation runs; settle first.
            self?.switching = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.switching = false
                self?.tick()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }
        // App activation (⌘Tab, Dock) is the common way to reach a parked window; AX focus events fire before
        // the frontmost app updates, so re-check shortly after activation as well.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.followFocusedWindowsWorkspace() }
        }
        axObserver = WindowObserver(onNewWindow: { [weak self] _ in self?.tick() },
                                    onFocusChange: { [weak self] in
                                        self?.followFocusedWindowsWorkspace()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.followFocusedWindowsWorkspace() }
                                        self?.focusRing.update()
                                        self?.onFocusChange?()
                                    })
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Reconcile loop

    private var tracked: [WindowID] { state.grids.values.flatMap(\.windows) }

    /// Full reconcile: observe, reconcile, execute, and settle (windows that refuse a size need a second pass).
    func tick() {
        guard !interacting, !switching else { return }
        for _ in 0..<3 {
            var snap = system.snapshot(tracked: tracked)
            zOrder = snap.windows.map(\.id)
            if assignNewVirtualWindows(snap) { snap = system.snapshot(tracked: tracked) }
            restoreIfFirstVisit(snap)
            let (next, commands) = reconciler.reconcile(state, snap)
            state = next
            scheduleSave(snap)
            applyVirtualParking(snap)
            guard !commands.isEmpty else { break }
            system.execute(commands)
        }
        refreshChrome()
    }

    /// Windows keep arriving for a while after launch (moves from other desktops land asynchronously), so saved
    /// slots are matched against newly seen windows until this deadline instead of once.
    private var virtualRestoreDeadline = Date().addingTimeInterval(20)

    /// Gives every not-yet-assigned window a workspace: its saved slot if one matches, otherwise the active one.
    /// Returns true if any window was placed from the saved layout, so the snapshot should be rebuilt.
    private func assignNewVirtualWindows(_ snap: Snapshot) -> Bool {
        guard let v = virtualWS else { return false }
        var pool = snap.windows.filter { !v.isKnown($0.id) }
        guard !pool.isEmpty else { return false }
        var placed = false
        if config.restoreLayouts, Date() < virtualRestoreDeadline {
            for savedSpace in saved.spaces where savedSpace.id >= 1_000_000 {
                let candidates = pool.filter { !reconciler.isIgnored($0) }
                guard let grid = saved.restore(space: savedSpace.id, candidates: candidates) else { continue }
                let ws = Int((savedSpace.id - 1_000_000) / 100)
                for id in grid.windows { v.move(id, to: ws) }
                pool.removeAll { grid.contains($0.id) }
                // Merge into whatever that workspace already has rather than replacing it.
                state.mutate(savedSpace.id) { existing in
                    for col in grid.columns { existing.columns.append(col) }
                    for (k, h) in grid.heightWeights { existing.heightWeights[k] = h }
                }
                state.seen[savedSpace.id, default: []].formUnion(grid.windows)
                placed = true
            }
        }
        for w in pool { v.adopt(w.id) }
        return placed
    }

    /// A desktop seen for the first time this run gets its saved grid back, with windows matched by app and title.
    private func restoreIfFirstVisit(_ snap: Snapshot) {
        guard config.restoreLayouts, virtualWS == nil else { return }
        for screen in snap.screens where state.seen[screen.space] == nil && state.grid(for: screen.space).isEmpty {
            let here = snap.windows.filter { screen.area.contains($0.frame.center) && $0.spaces.contains(screen.space) && !reconciler.isIgnored($0) }
            if let grid = saved.restore(space: screen.space, candidates: here) { state.grids[screen.space] = grid }
        }
    }

    // MARK: Persistence

    private var pendingSnapshot: Snapshot?

    /// Throttled, not debounced: the reconcile ticks every second, so a debounce would never fire.
    private func scheduleSave(_ snap: Snapshot) {
        guard config.restoreLayouts else { return }
        pendingSnapshot = snap
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard config.restoreLayouts, let snap = pendingSnapshot else { return }
        var layout = SavedLayout.capture(state, snap)
        // Desktops not active right now keep what was saved for them before.
        let activeSpaces = Set(snap.screens.map(\.space))
        let captured = Set(layout.spaces.map(\.id))
        layout.spaces += lastSaved.spaces.filter { !activeSpaces.contains($0.id) && !captured.contains($0.id) }
        layout.spaces.sort { $0.id < $1.id }
        guard layout != lastSaved else { return }
        lastSaved = layout
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(layout).write(to: Config.statePath, options: .atomic)
    }

    /// Push the current desired state to the screen without re-reconciling; used during gestures and after edits.
    func apply() {
        let snap = system.lightSnapshot(tracked: tracked)
        let cmds = reconciler.commands(for: state, snap)
        for case let .setFrame(w, f) in cmds { state.requested[w] = f }
        system.execute(cmds)
        if let full = pendingSnapshot { scheduleSave(full) }
        refreshChrome()
    }

    func relayout() { apply() }

    private func refreshChrome() {
        refreshHandles()
        focusRing.update()
        stackHandles()
    }

    /// Handles go right above the focus ring (or the frontmost tiled window), so the ring never covers the grip
    /// while floating windows in front of the tiles still do.
    private func stackHandles() {
        let tiledIDs = Set(tracked)
        let anchor = focusRing.windowNumber ?? zOrder.first { tiledIDs.contains($0) }.map(Int.init)
        for h in handles where h.isVisible {
            if let anchor { h.order(.above, relativeTo: anchor) } else { h.orderFrontRegardless() }
        }
    }

    // MARK: Queries used by the UI

    func id(_ w: AXWindow) -> WindowID? { system.id(of: w) }
    func isTiled(_ w: AXWindow) -> Bool { id(w).map(state.isTiled) ?? false }

    private func screen(at p: CGPoint) -> ScreenInfo? { system.screens().first { $0.area.contains(p) } ?? system.screens().first }

    private func geometry(for space: SpaceID) -> GridGeometry? {
        guard let screen = system.screens().first(where: { $0.space == space }) else { return nil }
        return reconciler.geometry(state.grid(for: space), screen)
    }

    private func activeGeometries() -> [(SpaceID, GridGeometry)] {
        system.screens().map { ($0.space, reconciler.geometry(state.grid(for: $0.space), $0)) }
    }

    func zone(at p: CGPoint, dragging w: AXWindow) -> (DropZone, CGRect)? {
        guard let screen = screen(at: p) else { return nil }
        return reconciler.geometry(state.grid(for: screen.space), screen).zone(at: p, dragging: id(w))
    }

    // MARK: Mutations

    func drop(_ w: AXWindow, into zone: DropZone, at p: CGPoint) {
        guard let id = id(w), let screen = screen(at: p) else { return }
        for space in state.grids.keys where space != screen.space { state.grids[space]?.remove(id) }
        state.mutate(screen.space) { $0.apply(zone, to: id) }
        state.seen[screen.space, default: []].insert(id)
        apply()
        w.raise()
    }

    func untile(_ w: AXWindow) {
        guard let id = id(w) else { return }
        state.untile(id)
    }

    func tile(_ w: AXWindow) {
        guard let id = id(w), !state.isTiled(id), let screen = screen(at: w.frame.center) else { return }
        let geo = reconciler.geometry(state.grid(for: screen.space), screen)
        state.mutate(screen.space) { $0.apply(.newColumn(index: geo.columnIndex(forX: w.frame.midX)), to: id) }
        state.seen[screen.space, default: []].insert(id)
        apply()
    }

    func toggleFocused() {
        guard let w = AXWindow.focused else { return }
        if isTiled(w) { untile(w); apply() } else { tile(w) }
    }

    /// Called on mouse-up: anything moved or resized by hand leaves the grid and floats.
    func releaseDisplacedWindows() {
        let snap = system.lightSnapshot(tracked: tracked)
        let displaced = reconciler.displaced(state, snap)
        guard !displaced.isEmpty else { return }
        displaced.forEach { state.untile($0) }
        apply()
    }

    func retileCurrentScreen() {
        guard let screen = screen(at: NSEvent.mouseLocation.toAX()) else { return }
        state.grids[screen.space] = Grid()
        state.seen[screen.space] = nil
        state.retileRequested.insert(screen.space)
        tick()
    }

    func equalize() {
        for k in state.grids.keys { state.grids[k]?.equalize() }
        apply()
    }

    func reloadConfig() {
        config = Config.load()
        apply()
    }

    func canMoveFocused(_ dir: Move) -> Bool {
        guard let w = AXWindow.focused, let id = id(w), let space = state.space(containing: id) else { return false }
        return state.grid(for: space).canMove(id, dir)
    }

    func moveFocused(_ dir: Move) {
        guard let w = AXWindow.focused, let id = id(w), let space = state.space(containing: id) else { return }
        state.mutate(space) { $0.move(id, dir) }
        apply()
    }

    /// Cycles through every window on the current desktop, tiled or floating, in reading order
    /// (left to right, top to bottom), starting from the focused one.
    func focusNext(reverse: Bool = false) {
        guard let current = currentDesktop,
              let group = windowsByDesktop().first(where: { $0.desktop == current }), !group.windows.isEmpty else { return }
        let order = group.windows
        let focused = AXWindow.focused
        let i = focused.flatMap { f in order.firstIndex { $0 == f } } ?? (reverse ? 0 : order.count - 1)
        order[(i + (reverse ? -1 : 1) + order.count) % order.count].raise()
    }

    // MARK: Presets

    /// Windows the presets would arrange on the screen holding the focused window, in reading order.
    func presetCandidates() -> (SpaceID, [WindowID])? {
        let anchor = AXWindow.focused?.frame.center ?? NSEvent.mouseLocation.toAX()
        guard let screen = screen(at: anchor) else { return nil }
        let snap = system.snapshot(tracked: [])
        let windows = snap.windows
            .filter { screen.area.contains($0.frame.center) && $0.spaces.contains(screen.space) && !reconciler.isIgnored($0) }
            .sorted { a, b in
                abs(a.frame.minX - b.frame.minX) > 40 ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
            }
        return (screen.space, windows.map(\.id))
    }

    func applyPreset(_ preset: LayoutPreset) {
        guard let (space, windows) = presetCandidates() else { return }
        state.mutate(space) { $0.apply(preset: preset, windows: windows) }
        state.seen[space] = Set(windows)
        apply()
    }


    func sendFocusedWindow(toNext: Bool) {
        guard let cur = currentDesktop else { return }
        sendFocusedWindow(toDesktop: cur + (toNext ? 1 : -1))
    }

    func sendFocusedWindow(toDesktop index: Int) {
        guard let w = AXWindow.focused else { return }
        if let v = virtualWS {
            guard let id = id(w), index >= 0, index < 9, index != v.active else { return }
            if index >= v.count { v.setCount(index + 1) }
            let wasTiled = isTiled(w)
            untile(w)
            v.move(id, to: index)
            // The sent window is still focused for a moment; don't let that pull us into its workspace.
            ignoreFocusSwitchUntil = Date().addingTimeInterval(0.8)
            if wasTiled {
                // Pre-place it in the target workspace's grid so it is tiled when that workspace shows.
                let screenIndex = NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(w.frame.center) } ?? 0
                let space = v.spaceID(workspace: index, screenIndex: screenIndex)
                state.mutate(space) { $0.apply(.newColumn(index: $0.columns.count), to: id) }
                state.seen[space, default: []].insert(id)
            }
            tick()
            focusTopWindow()
            return
        }
        let wasTiled = isTiled(w)
        if wasTiled {
            untile(w)
            apply()
        }
        interacting = true
        Spaces.sendFocusedWindow(toDesktop: index) { [weak self] moved in
            guard let self else { return }
            self.interacting = false
            guard let moved else { return }
            if wasTiled { self.tileWhenVisible(moved, attempts: 10) } else { self.tick() }
        }
    }

    /// The Space switch and the drop land asynchronously; wait until the window shows up on the active desktop.
    private func tileWhenVisible(_ w: AXWindow, attempts: Int) {
        tick()
        if Spaces.visibleWindows().contains(w) {
            if !isTiled(w) { tile(w) }
            w.raise()
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.tileWhenVisible(w, attempts: attempts - 1) }
    }

    // MARK: Gap handles

    private func refreshHandles() {
        var needed: [(SpaceID, Handle, CGRect)] = []
        for (space, geo) in activeGeometries() { for (h, f) in geo.handleFrames() { needed.append((space, h, f)) } }
        while handles.count < needed.count { handles.append(HandleWindow()) }
        for (idx, h) in handles.enumerated() {
            guard idx < needed.count else { h.orderOut(nil); continue }
            let (space, handle, f) = needed[idx]
            h.setFrame(f.toCocoa(), display: true)
            h.isVertical = handle.isVertical
            h.onDrag = { [weak self] p in
                guard let self, let geo = self.geometry(for: space) else { return }
                self.interacting = true
                switch handle {
                case let .column(i): self.state.grids[space] = geo.resizing(boundary: i, toX: p.x)
                case let .row(ci, i): self.state.grids[space] = geo.resizing(column: ci, boundary: i, toY: p.y)
                }
                self.apply()
            }
            h.onDragEnd = { [weak self] in
                self?.interacting = false
                self?.apply()
            }
            if !h.isVisible { h.orderFrontRegardless() }
        }
    }
}
