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
    /// Virtual mode: one independent workspace set per macOS desktop (nil in native mode).
    private let wsEvents = WindowServerEvents()
    /// Last key press or click seen by the event tap; distinguishes user focus changes from app self-activation.
    var lastUserInput = Date.distantPast
    /// Last input that could have activated another app; consumed by one focus-follow so apps fighting over
    /// focus (Unity after a compile versus the app the user was in) cannot ping-pong the desktop.
    var lastFocusInput = Date.distantPast
    private var virtualSets: [SpaceID: VirtualWorkspaces]?
    var isVirtual: Bool { virtualSets != nil }

    /// The set for the desktop currently shown on the main screen; created on first use.
    private var virtualWS: VirtualWorkspaces? { virtualSet(for: NSScreen.screens.first ?? NSScreen.main!) }

    private func virtualSet(for screen: NSScreen) -> VirtualWorkspaces? {
        guard virtualSets != nil else { return nil }
        return virtualSet(realSpace: Spaces.current(for: screen))
    }

    private func virtualSet(realSpace: SpaceID) -> VirtualWorkspaces? {
        guard virtualSets != nil else { return nil }
        if let v = virtualSets?[realSpace] { return v }
        let v = VirtualWorkspaces(realSpace: realSpace, count: config.virtualWorkspaces)
        virtualSets?[realSpace] = v
        return v
    }

    /// The set a window belongs to: that of the macOS desktop it is on.
    private func virtualSet(ofWindow id: WindowID) -> VirtualWorkspaces? {
        guard virtualSets != nil else { return nil }
        guard let real = Spaces.spaces(of: id).first else { return virtualWS }
        return virtualSet(realSpace: real)
    }
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
    var interacting = false { didSet { interactionScreens = nil } }
    /// Screen geometry is stable for the length of a drag; asking SkyLight for it on every mouse move is not free.
    private var interactionScreens: [ScreenInfo]?
    private func screens() -> [ScreenInfo] {
        guard interacting else { return system.screens() }
        if interactionScreens == nil { interactionScreens = system.screens() }
        return interactionScreens!
    }
    var onFocusChange: (() -> Void)?
    var onWindowsChange: (() -> Void)?
    private var lastWindowIDs: Set<WindowID> = []
    var onDesktopChange: (() -> Void)?

    var config: Config {
        didSet {
            Log.enabled = config.debugLog
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
            guard let sets = virtualSets else { return }
            migrateToNative(from: Array(sets.values))
            virtualSets = nil
            system.spaceOverride = nil
            system.windowSpacesOverride = nil
        case .virtual:
            if let sets = virtualSets { sets.values.forEach { $0.setCount(config.virtualWorkspaces) }; return }
            virtualSets = [:]
            migrateToVirtual()
            system.spaceOverride = { [unowned self] screen in
                guard let v = self.virtualSet(for: screen) else { return Spaces.current(for: screen) }
                return v.spaceID(workspace: v.active, screenIndex: NSScreen.screens.firstIndex(of: screen) ?? 0)
            }
            system.windowSpacesOverride = { [unowned self] id in
                guard let v = self.virtualSet(ofWindow: id) else { return Spaces.spaces(of: id) }
                let screenIndex = self.system.axWindow(id).flatMap { w in NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(w.frame.center) } } ?? 0
                return [v.spaceID(workspace: v.workspace(of: id), screenIndex: screenIndex)]
            }
        }
        tick()
    }

    /// Native → virtual: each macOS desktop keeps its windows and gets its own workspace set; the existing grid
    /// becomes workspace 1 of that desktop.
    private func migrateToVirtual() {
        var newState = DesiredState()
        for (space, grid) in state.grids where !VirtualWorkspaces.isVirtual(space) {
            guard let v = virtualSet(realSpace: space), let first = grid.windows.first, let f = system.axWindow(first)?.frame else { continue }
            let screenIndex = NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(f.center) } ?? 0
            let target = v.spaceID(workspace: 0, screenIndex: screenIndex)
            for id in grid.windows { v.move(id, to: 0) }
            newState.grids[target] = grid
            newState.seen[target] = Set(grid.windows)
        }
        if !state.grids.isEmpty { virtualRestoreDeadline = .distantPast }
        state = newState
    }

    /// Quitting must leave every window reachable: unpark all of them and write the layout one last time.
    func prepareForQuit() {
        saveWork?.cancel()
        saveNow()
        guard let sets = virtualSets?.values else { return }
        for v in sets {
            // Parked tiled windows have no remembered frame; their grid slot is where they go.
            for id in v.parkedWindows where state.isTiled(id) {
                if let f = targetFrame(of: id) { system.execute([.setFrame(id, f)]) }
            }
            v.unparkAll(setFrame: { self.system.execute([.setFrame($0, $1)]) },
                        unhide: { NSRunningApplication(processIdentifier: $0)?.unhide() })
        }
    }

    /// Virtual → native: unpark everything; workspace 1 of each desktop becomes that desktop's grid, the rest float.
    private func migrateToNative(from sets: [VirtualWorkspaces]) {
        for v in sets { v.unparkAll(setFrame: { self.system.execute([.setFrame($0, $1)]) }, unhide: { NSRunningApplication(processIdentifier: $0)?.unhide() }) }
        var newState = DesiredState()
        for (space, grid) in state.grids {
            guard let d = VirtualWorkspaces.decode(space), d.workspace == 0 else { continue }
            newState.grids[d.real] = grid
            newState.seen[d.real] = Set(grid.windows)
        }
        state = newState
    }

    // MARK: Desktops facade (native Spaces or virtual workspaces)

    /// Every standard window with the desktop it lives on, front-to-back within each desktop, current desktop first.
    func windowsByDesktop() -> [(desktop: Int, windows: [AXWindow])] {
        var byDesktop: [Int: [AXWindow]] = [:]
        if let v = virtualWS {
            // Only this macOS desktop's set: windows on other desktops belong to their own sets.
            var listed = Set<WindowID>()
            for w in Spaces.visibleWindows() {
                guard let id = id(w), virtualSet(ofWindow: id) === v else { continue }
                listed.insert(id)
                byDesktop[v.workspace(of: id), default: []].append(w)
            }
            // Windows of hidden apps are not on screen but still belong to their workspace.
            for id in v.knownWindows where !listed.contains(id) && v.isParked(id) {
                guard let w = system.axWindow(id), w.isValid, w.isStandard else { continue }
                byDesktop[v.workspace(of: id), default: []].append(w)
            }
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

    /// Apps with a window on each desktop, front to back, one entry per app. Built from the window list alone:
    /// the bar asks for this often and an Accessibility pass over every window would stall the event tap.
    func appsByDesktop() -> [Int: [pid_t]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [Int: [pid_t]] = [:]
        let desktops = isVirtual ? [] : Spaces.desktops()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let desktop: Int
            if let v = virtualWS {
                guard virtualSet(ofWindow: id) === v, v.isKnown(id) else { continue }
                desktop = v.workspace(of: id)
            } else {
                guard let space = Spaces.spaces(of: id).first, let d = desktops.firstIndex(of: space) else { continue }
                desktop = d
            }
            if !(out[desktop]?.contains(pid) ?? false) { out[desktop, default: []].append(pid) }
        }
        if let v = virtualWS {
            for id in v.knownWindows where v.isParked(id) {
                guard let pid = system.pid(of: id) else { continue }
                let d = v.workspace(of: id)
                if !(out[d]?.contains(pid) ?? false) { out[d, default: []].append(pid) }
            }
        }
        return out
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
            Log.write("desktop", "switch to workspace \(index + 1) (real space \(v.realSpace))")
            v.switchTo(index)
            ignoreFocusSwitchUntil = Date().addingTimeInterval(0.8)
            lastFocusedID = AXWindow.focused.flatMap(id)
            tick()
            revealRingAndFocusTop()
            v.trimEmptyTrailing(minimum: config.virtualWorkspaces)
            onDesktopChange?()
        } else {
            Log.write("desktop", "switch to macOS desktop \(index + 1)")
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
    /// Windows just placed on a background workspace; their app tends to focus them right away (Unity does),
    /// and that focus change is the app's, not the user's, even if the user typed a moment ago.
    private var adoptedInBackground: [WindowID: Date] = [:]
    private func followFocusedWindowsWorkspace() {
        guard isVirtual, let f = AXWindow.focused, let id = id(f), let v = virtualSet(ofWindow: id) else { return }
        guard id != lastFocusedID else { return }
        lastFocusedID = id
        guard Date() >= ignoreFocusSwitchUntil else { return }
        let ws = v.workspace(of: id)
        guard ws != v.active else { return }
        // Only follow focus the user caused (⌘Tab, Dock, a click). An app activating itself after a build or
        // a long task must not yank the user to another workspace; its window is parked there, where it belongs.
        guard Date().timeIntervalSince(lastFocusInput) < 2 else {
            Log.write("desktop", "ignoring self-activation of \(describe(f)) (workspace \(ws + 1), no click or ⌘ input)")
            return
        }
        lastFocusInput = .distantPast
        if let t = adoptedInBackground[id], Date().timeIntervalSince(t) < 3 {
            Log.write("desktop", "ignoring self-activation of \(describe(f)) (workspace \(ws + 1), window just appeared there)")
            return
        }
        Log.write("desktop", "focus follows \(describe(f)) to workspace \(ws + 1)")
        focusRing.suspended = true
        v.switchTo(ws)
        tick()
        // The window that triggered this is the one to ring; it is already focused.
        if let frame = targetFrame(of: id) ?? system.axWindow(id)?.frame { focusRing.show(windowID: id, frame: frame) } else { focusRing.suspended = false }
        onDesktopChange?()
    }

    private func focusTopWindow() {
        guard let v = virtualWS else { return }
        if let id = zOrder.first(where: { virtualSet(ofWindow: $0) === v && v.workspace(of: $0) == v.active }) { system.execute([.raise(id)]) }
    }

    /// Where a tiled window sits (or will sit) in its grid, in AX coordinates. Works for inactive virtual
    /// workspaces too, by using the area of the screen the workspace belongs to.
    private func targetFrame(of id: WindowID) -> CGRect? {
        guard let space = state.space(containing: id) else { return nil }
        let screens = system.screens()
        let screen: ScreenInfo
        if let s = screens.first(where: { $0.space == space }) {
            screen = s
        } else if let d = VirtualWorkspaces.decode(space), d.screenIndex < screens.count {
            screen = ScreenInfo(space: space, area: screens[d.screenIndex].area)
        } else {
            return nil
        }
        return reconciler.geometry(state.grid(for: space), screen).frame(of: id)
    }

    /// After a workspace switch: show the ring on the window we are about to raise, in the same pass, then raise it.
    private func revealRingAndFocusTop() {
        guard let v = virtualWS,
              let id = zOrder.first(where: { virtualSet(ofWindow: $0) === v && v.workspace(of: $0) == v.active }) else {
            focusRing.suspended = false
            return
        }
        if state.isTiled(id) || config.focusRingFloating, let frame = targetFrame(of: id) ?? system.axWindow(id)?.frame {
            focusRing.show(windowID: id, frame: frame)
        } else {
            focusRing.suspended = false
        }
        system.execute([.raise(id)])
    }

    /// Parks windows of inactive workspaces and restores returning floating ones; tiled ones follow their grid.
    private func applyVirtualParking(_ snap: Snapshot) {
        guard let sets = virtualSets else { return }
        var bySet: [SpaceID: [WindowID]] = [:]
        for w in snap.windows { if let v = virtualSet(ofWindow: w.id) { bySet[v.realSpace, default: []].append(w.id) } }
        for (real, ids) in bySet {
            guard let v = sets[real] ?? virtualSets?[real] else { continue }
            v.apply(windows: ids,
                pid: { snap.window($0)?.pid },
                // Hiding is app-wide: only when every window the app has anywhere belongs to this set.
                hideable: { p in
                    guard let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular else { return false }
                    return snap.windows.filter { $0.pid == p }.allSatisfy { self.virtualSet(ofWindow: $0.id) === v }
                },
                isTiled: { self.state.isTiled($0) }, frame: { snap.window($0)?.frame },
                setFrame: { self.system.execute([.setFrame($0, $1)]) }, parkOrigin: { f in
                    // Bottom-right corner of the screen the window is on, leaving two points visible.
                    let screen = NSScreen.screens.first { $0.frame.toCocoa().contains(f.center) } ?? NSScreen.screens[0]
                    let r = screen.frame.toCocoa()
                    return CGPoint(x: r.maxX - 2, y: r.maxY - 2)
                },
                hide: { NSRunningApplication(processIdentifier: $0)?.hide() },
                unhide: { NSRunningApplication(processIdentifier: $0)?.unhide() })
        }
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
        focusRing.isTiledID = { [unowned self] id in self.state.isTiled(id) }
        focusRing.onReorder = { [unowned self] in self.stackHandles() }
        if config.restoreLayouts, let data = try? Data(contentsOf: Config.statePath),
           let layout = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            let current = Spaces.current(for: NSScreen.screens.first ?? NSScreen.main!)
            saved = layout.migrated(currentSpace: current)
            lastSaved = saved
            // A previous run that was killed left its hidden apps hidden; bring them back before parking decides anew.
            for pid in saved.hiddenPids {
                if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
                    app.unhide()
                    Log.write("park", "unhide app \(pid) left hidden by the previous run")
                }
            }
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
        // WindowServer reports a new front window before Accessibility does; stacked screens re-fan on it.
        wsEvents.onEvent = { [weak self] event, _ in
            switch event {
            case .frontChange, .windowReorder: self?.refanStackedScreens()
            case .windowCreate, .windowDestroy: self?.scheduleTick()
            default: break
            }
        }
        axObserver = WindowObserver(onNewWindow: { [weak self] _ in self?.tick() },
                                    onFocusChange: { [weak self] in
                                        self?.followFocusedWindowsWorkspace()
                                        self?.refanStackedScreens()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.followFocusedWindowsWorkspace() }
                                        self?.focusRing.update()
                                        self?.onFocusChange?()
                                    },
                                    onGeometryChange: { [weak self] in
                                        guard let self, !self.interacting else { return }
                                        self.focusRing.scheduleUpdate()
                                        self.scheduleTick()
                                    },
                                    onTitleChange: { [weak self] in self?.onFocusChange?() })
        tick()
        // Window creation, destruction, focus and Space changes all arrive as events; the timer is a safety net.
        // A full snapshot walks every window through Accessibility, so once a second was measurable idle CPU.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private var tickScheduled = false
    /// Events come in bursts (an app opening three windows, a Space switch); one tick per burst is enough.
    func scheduleTick() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.tickScheduled = false
            self?.tick()
        }
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
            virtualSets?.values.forEach { $0.rememberHomes(snap.windows) }
            restoreIfFirstVisit(snap)
            restoreSavedModes(snap)
            let before = state
            let (next, commands) = reconciler.reconcile(state, snap)
            state = next
            logReconcileChanges(from: before, to: next)
            let ids = Set(snap.windows.map(\.id))
            if ids != lastWindowIDs { lastWindowIDs = ids; onWindowsChange?() }
            scheduleSave(snap)
            applyVirtualParking(snap)
            guard !commands.isEmpty else { break }
            anticipateRing(commands, snap.focused)
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
        guard virtualSets != nil else { return false }
        var pool = snap.windows.filter { !(virtualSet(ofWindow: $0.id)?.isKnown($0.id) ?? true) }
        guard !pool.isEmpty else { return false }
        var placed = false
        if config.restoreLayouts, Date() < virtualRestoreDeadline {
            for savedSpace in saved.spaces {
                guard let d = VirtualWorkspaces.decode(savedSpace.id), let v = virtualSet(realSpace: d.real) else { continue }
                let candidates = pool.filter { !reconciler.isIgnored($0) && Spaces.spaces(of: $0.id).first == d.real }
                guard let grid = saved.restore(space: savedSpace.id, candidates: candidates) else { continue }
                let ws = d.workspace
                for id in grid.windows { v.move(id, to: ws) }
                pool.removeAll { grid.contains($0.id) }
                // Merge into whatever that workspace already has rather than replacing it.
                state.mutate(savedSpace.id) { existing in
                    existing.mode = grid.mode
                    for col in grid.columns { existing.columns.append(col) }
                    for (k, h) in grid.heightWeights { existing.heightWeights[k] = h }
                }
                state.seen[savedSpace.id, default: []].formUnion(grid.windows)
                placed = true
            }
        }
        if config.restoreLayouts, Date() < virtualRestoreDeadline {
            for savedSpace in saved.spaces where !savedSpace.floating.isEmpty {
                guard let d = VirtualWorkspaces.decode(savedSpace.id), let v = virtualSet(realSpace: d.real) else { continue }
                let candidates = pool.filter { Spaces.spaces(of: $0.id).first == d.real }
                for (id, frame) in saved.restoreFloating(space: savedSpace.id, candidates: candidates) {
                    v.move(id, to: d.workspace)
                    state.floating.insert(id)
                    system.execute([.setFrame(id, frame)])
                    pool.removeAll { $0.id == id }
                    Log.write("restore", "\(describe(id)) floats on workspace \(d.workspace + 1) at \(frame)")
                    placed = true
                }
            }
        }
        // A window left in a parking corner by a previous run (quit without unparking, a crash) and matched by
        // nothing above would be adopted here, unreachable; pull it back onto its screen.
        for w in pool {
            guard let screen = NSScreen.screens.first(where: { $0.frame.toCocoa().contains(w.frame.center) })
                ?? NSScreen.screens.first(where: { $0.frame.toCocoa().contains(w.frame.origin) }) else { continue }
            let r = screen.frame.toCocoa()
            guard w.frame.minX >= r.maxX - 3, w.frame.minY >= r.maxY - 3 else { continue }
            let area = screen.visibleFrame.toCocoa()
            let origin = CGPoint(x: max(area.minX, area.midX - w.frame.width / 2), y: max(area.minY, area.midY - w.frame.height / 2))
            system.execute([.setFrame(w.id, CGRect(origin: origin, size: w.frame.size))])
            Log.write("restore", "\(describe(w.id)) was stranded in the parking corner; moved on screen")
            placed = true
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentInput = Date().timeIntervalSince(lastUserInput) < 2
        for w in pool {
            guard let v = virtualSet(ofWindow: w.id) else { continue }
            // A window appearing while its app is in the background (Unity recreating its editor window, a
            // background app opening a document) stays with the app's other windows, or where its last window
            // was, instead of landing on the active workspace and dragging the user there later. Only a window
            // the user just asked the frontmost app for belongs on the active workspace.
            let siblings = snap.windows.filter { $0.pid == w.pid && $0.id != w.id && v.isKnown($0.id) }.map(\.id)
            let siblingSpaces = v.workspaces(of: siblings)
            let home = siblingSpaces.count == 1 ? siblingSpaces.first : (siblings.isEmpty ? v.homeByPid[w.pid] : nil)
            let deliberate = w.pid == frontPid && recentInput
            if let ws = home, ws != v.active, !deliberate {
                v.adopt(w.id, into: ws)
                adoptedInBackground[w.id] = Date()
                let why = siblings.isEmpty ? "where its last window was" : "with its app's windows"
                Log.write("adopt", "\(describe(w.id)) joins workspace \(ws + 1) \(why) (\(w.pid == frontPid ? "no recent input" : "app not frontmost"))")
            } else {
                v.adopt(w.id)
                Log.write("adopt", "\(describe(w.id)) joins active workspace \(v.active + 1)")
            }
        }
        return placed
    }

    /// A screen's layout mode (stacked/columns) comes back even if none of its saved windows are around anymore.
    private func restoreSavedModes(_ snap: Snapshot) {
        guard config.restoreLayouts else { return }
        for screen in snap.screens where state.grids[screen.space] == nil {
            if let mode = saved.mode(for: screen.space), mode != .columns {
                state.mutate(screen.space) { $0.mode = mode }
            }
        }
    }

    /// A desktop seen for the first time this run gets its saved grid back, with windows matched by app and title.
    private func restoreIfFirstVisit(_ snap: Snapshot) {
        guard config.restoreLayouts, virtualWS == nil else { return }
        for screen in snap.screens where state.seen[screen.space] == nil && state.grid(for: screen.space).isEmpty {
            let here = snap.windows.filter { screen.area.contains($0.frame.center) && $0.spaces.contains(screen.space) && !reconciler.isIgnored($0) }
            if let grid = saved.restore(space: screen.space, candidates: here) { state.grids[screen.space] = grid }
            let rest = here.filter { !state.isTiled($0.id) }
            for (id, frame) in saved.restoreFloating(space: screen.space, candidates: rest) {
                state.floating.insert(id)
                system.execute([.setFrame(id, frame)])
                Log.write("restore", "\(describe(id)) floats at \(frame)")
            }
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
        guard config.restoreLayouts, var snap = pendingSnapshot else { return }
        // Parked windows sit in the screen corner; save the slot they belong to instead of that position.
        if virtualSets != nil {
            snap.windows = snap.windows.map { w in
                guard let v = virtualSet(ofWindow: w.id), v.isParked(w.id) else { return w }
                var fixed = w
                if let slot = targetFrame(of: w.id) { fixed.frame = slot } else if let real = v.parkedFrame(of: w.id) { fixed.frame = real }
                return fixed
            }
        }
        var layout = SavedLayout.capture(state, snap, floatingSpace: { w in
            guard let v = self.virtualSet(ofWindow: w.id) else { return self.isVirtual ? nil : w.spaces.first }
            guard v.isKnown(w.id) else { return nil }
            let screenIndex = NSScreen.screens.firstIndex { $0.visibleFrame.toCocoa().contains(w.frame.center) } ?? 0
            return v.spaceID(workspace: v.workspace(of: w.id), screenIndex: screenIndex)
        })
        // Desktops not active right now keep what was saved for them before.
        let activeSpaces = Set(snap.screens.map(\.space))
        let captured = Set(layout.spaces.map(\.id))
        layout.spaces += lastSaved.spaces.filter { !activeSpaces.contains($0.id) && !captured.contains($0.id) }
        layout.spaces.sort { $0.id < $1.id }
        layout.hiddenPids = (virtualSets?.values.flatMap(\.hiddenPids) ?? []).sorted()
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
        anticipateRing(cmds, snap.focused)
        system.execute(cmds)
        if let full = pendingSnapshot { scheduleSave(full) }
        refreshChrome()
    }

    func relayout() { apply() }

    private func logReconcileChanges(from a: DesiredState, to b: DesiredState) {
        guard Log.enabled else { return }
        for space in Set(a.grids.keys).union(b.grids.keys) {
            let was = Set(a.grid(for: space).windows), now = Set(b.grid(for: space).windows)
            let added = now.subtracting(was), removed = was.subtracting(now)
            if !added.isEmpty { Log.write("reconcile", "space \(space): tiled \(added.map { describe($0) }) (first visit: \(a.seen[space] == nil), floating: \(a.floating.sorted()))") }
            if !removed.isEmpty { Log.write("reconcile", "space \(space): dropped \(removed.map { describe($0) })") }
        }
    }

    /// Puts the ring where the focused window is about to be, before the app has even applied the move.
    /// On stacked screens the front window by z-order is used: it is known before Accessibility reports focus.
    private func anticipateRing(_ commands: [Command], _ focused: WindowID?) {
        for screen in system.screens() where state.grid(for: screen.space).mode == .stacked {
            let grid = state.grid(for: screen.space)
            guard let top = zOrder.first(where: grid.contains),
                  let frame = reconciler.geometry(grid, screen).frame(of: top) else { continue }
            focusRing.show(windowID: top, frame: frame)
            return
        }
        guard let focused else { return }
        for case let .setFrame(w, f) in commands where w == focused { focusRing.anticipate(windowID: focused, frame: f) }
    }

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

    private func screen(at p: CGPoint) -> ScreenInfo? { let all = screens(); return all.first { $0.area.contains(p) } ?? all.first }

    private func geometry(for space: SpaceID) -> GridGeometry? {
        guard let screen = system.screens().first(where: { $0.space == space }) else { return nil }
        return reconciler.geometry(state.grid(for: space), screen)
    }

    private func activeGeometries() -> [(SpaceID, GridGeometry)] {
        system.screens().map { ($0.space, reconciler.geometry(state.grid(for: $0.space), $0)) }
    }

    func zone(at p: CGPoint, dragging w: AXWindow) -> (DropZone, CGRect)? { zone(at: p, draggingID: id(w)) }

    /// Resolving a window's ID is a round-trip; drags resolve it once and pass it here per mouse move.
    func zone(at p: CGPoint, draggingID id: WindowID?) -> (DropZone, CGRect)? {
        guard let screen = screen(at: p) else { return nil }
        return reconciler.geometry(state.grid(for: screen.space), screen).zone(at: p, dragging: id)
    }

    // MARK: Mutations

    /// Where each window floated before it was tiled by hand, so toggling tiling off puts it back.
    private var floatingFrames: [WindowID: CGRect] = [:]
    private func rememberFloatingFrame(_ w: AXWindow, _ id: WindowID, frame: CGRect? = nil) {
        guard !state.isTiled(id), !(virtualSet(ofWindow: id)?.isParked(id) ?? false) else { return }
        floatingFrames[id] = frame ?? w.frame
    }
    /// After a drag or resize by hand that left the window floating, that is where it now belongs.
    func rememberFloatingFrame(_ w: AXWindow) {
        guard let id = id(w) else { return }
        rememberFloatingFrame(w, id)
    }

    /// `from` is where the window sat before the drag began; that, not the drop point, is its floating spot.
    func drop(_ w: AXWindow, into zone: DropZone, at p: CGPoint, from original: CGRect) {
        guard let id = id(w), let screen = screen(at: p) else { return }
        Log.write("tile", "drop \(describe(w)) into \(zone) on space \(screen.space)")
        rememberFloatingFrame(w, id, frame: original)
        virtualSet(ofWindow: id)?.claimForActive(id)
        for space in state.grids.keys where space != screen.space { state.grids[space]?.remove(id) }
        state.mutate(screen.space) { $0.apply(zone, to: id) }
        state.seen[screen.space, default: []].insert(id)
        apply()
        w.raise()
    }

    func untile(_ w: AXWindow) {
        guard let id = id(w) else { return }
        Log.write("tile", "untile \(describe(w))")
        state.untile(id)
    }

    func tile(_ w: AXWindow) {
        guard let id = id(w), !state.isTiled(id) else { return }
        Log.write("tile", "tile \(describe(w))")
        rememberFloatingFrame(w, id)
        // A parked window sits in the screen corner; claim it first so it belongs here and can be placed.
        virtualSet(ofWindow: id)?.claimForActive(id)
        guard let screen = screen(at: w.frame.center) else { return }
        let geo = reconciler.geometry(state.grid(for: screen.space), screen)
        state.mutate(screen.space) { $0.apply(.newColumn(index: geo.columnIndex(forX: w.frame.midX)), to: id) }
        state.seen[screen.space, default: []].insert(id)
        apply()
    }

    func toggleFocused() {
        guard let w = AXWindow.focused else { return }
        if isTiled(w) {
            untile(w)
            apply()
            if let id = id(w), let frame = floatingFrames.removeValue(forKey: id),
               NSScreen.screens.contains(where: { $0.visibleFrame.toCocoa().contains(frame.center) }) {
                w.frame = frame
                Log.write("tile", "restore \(describe(w)) to its floating frame \(frame)")
            }
        } else {
            tile(w)
        }
    }

    /// Called on mouse-up: anything moved or resized by hand leaves the grid and floats.
    func releaseDisplacedWindows() {
        let snap = system.lightSnapshot(tracked: tracked)
        let displaced = reconciler.displaced(state, snap)
        guard !displaced.isEmpty else { return }
        Log.write("tile", "released by hand: \(displaced.map { describe($0) })")
        displaced.forEach { state.untile($0) }
        apply()
    }

    func retileCurrentScreen() {
        guard let screen = screen(at: NSEvent.mouseLocation.toAX()) else { return }
        // Start the grid afresh but keep the screen's layout mode.
        var fresh = Grid()
        fresh.mode = state.grid(for: screen.space).mode
        state.grids[screen.space] = fresh
        state.seen[screen.space] = nil
        // Retile is the "tile everything here" action: hand-floated windows on this screen are tiled too.
        let here = system.lightSnapshot(tracked: Array(state.floating)).windows
            .filter { screen.area.contains($0.frame.center) }.map(\.id)
        state.floating.subtract(here)
        state.retileRequested.insert(screen.space)
        Log.write("layout", "retile space \(screen.space), including \(here.count) floating window(s)")
        tick()
    }

    /// Stacked screens lay out by z-order, so a focus change must re-run the reconcile promptly.
    private func refanStackedScreens() {
        guard system.screens().contains(where: { state.grid(for: $0.space).mode == .stacked }) else { return }
        tick()
    }

    /// Flips the layout mode of the screen holding the focused window (or the cursor).
    func toggleStackedLayout() {
        let anchor = AXWindow.focused?.frame.center ?? NSEvent.mouseLocation.toAX()
        guard let screen = screen(at: anchor) else { return }
        state.mutate(screen.space) { $0.setMode($0.mode == .stacked ? .columns : .stacked) }
        Log.write("layout", "space \(screen.space) mode -> \(state.grid(for: screen.space).mode)")
        apply()
    }

    func layoutMode(forScreenAt p: CGPoint) -> LayoutMode {
        guard let screen = screen(at: p) else { return .columns }
        return state.grid(for: screen.space).mode
    }

    func equalize() {
        for k in state.grids.keys { state.grids[k]?.equalize() }
        apply()
    }

    func reloadConfig() {
        config = Config.load()
        apply()
    }

    /// A floating window can always be "moved": the move tiles it first, where it sits, then applies.
    func canMoveFocused(_ dir: Move) -> Bool {
        guard let w = AXWindow.focused, let id = id(w) else { return false }
        guard let space = state.space(containing: id) else { return true }
        return state.grid(for: space).canMove(id, dir)
    }

    func moveFocused(_ dir: Move) {
        guard let w = AXWindow.focused, let id = id(w) else { return }
        if !state.isTiled(id) {
            tile(w)
            guard let space = state.space(containing: id) else { return }
            if state.grid(for: space).canMove(id, dir) {
                Log.write("layout", "move \(describe(w)) \(dir) (tiled first)")
                state.mutate(space) { $0.move(id, dir) }
                apply()
            }
            return
        }
        guard let space = state.space(containing: id) else { return }
        Log.write("layout", "move \(describe(w)) \(dir)")
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
        Log.write("layout", "preset \(preset.name) on space \(space) for \(windows.count) windows")
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
        if isVirtual {
            guard let id = id(w), let v = virtualSet(ofWindow: id), index >= 0, index < 9, index != v.active else { return }
            if index >= v.count { v.setCount(index + 1) }
            let wasTiled = isTiled(w)
            Log.write("desktop", "send \(describe(w)) to workspace \(index + 1) (tiled: \(wasTiled))")
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
    /// Short, stable description of a window for the log: app, title, id.
    func describe(_ w: AXWindow) -> String {
        "\(w.bundleID?.split(separator: ".").last.map(String.init) ?? "?")/\"\(w.title.prefix(30))\"#\(w.windowID ?? 0)"
    }
    func describe(_ id: WindowID) -> String { system.axWindow(id).map(describe) ?? "#\(id)" }

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
