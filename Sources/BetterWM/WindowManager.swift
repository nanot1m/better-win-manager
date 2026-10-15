import BetterWMCore
import Cocoa

/// Thin shell: owns the desired state, feeds snapshots to the pure reconciler, executes the resulting commands,
/// and translates UI gestures into state mutations.
final class WindowManager {
    private(set) var state = DesiredState()
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
    var interacting = false
    var onFocusChange: (() -> Void)?

    var config: Config {
        didSet {
            reconciler.config = config
            focusRing.apply(config)
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
        axObserver = WindowObserver(onNewWindow: { [weak self] _ in self?.tick() },
                                    onFocusChange: { [weak self] in
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
            let snap = system.snapshot(tracked: tracked)
            let (next, commands) = reconciler.reconcile(state, snap)
            state = next
            guard !commands.isEmpty else { break }
            system.execute(commands)
        }
        refreshChrome()
    }

    /// Push the current desired state to the screen without re-reconciling; used during gestures and after edits.
    func apply() {
        let snap = system.lightSnapshot(tracked: tracked)
        let cmds = reconciler.commands(for: state, snap)
        for case let .setFrame(w, f) in cmds { state.requested[w] = f }
        system.execute(cmds)
        refreshChrome()
    }

    func relayout() { apply() }

    private func refreshChrome() {
        refreshHandles()
        focusRing.update()
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

    /// Cycles through tiled windows left to right, top to bottom, on the screen holding the focused window.
    func focusNext(reverse: Bool = false) {
        let focused = AXWindow.focused
        let fid = focused.flatMap(id)
        let space = fid.flatMap(state.space) ?? screen(at: focused?.frame.center ?? NSEvent.mouseLocation.toAX())?.space
        guard let space, let geo = geometry(for: space) else { return }
        let order = geo.windowFrames().map(\.0)
        guard !order.isEmpty else { return }
        let i = fid.flatMap(order.firstIndex) ?? (reverse ? 0 : order.count - 1)
        system.execute([.raise(order[(i + (reverse ? -1 : 1) + order.count) % order.count])])
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

    // MARK: Desktops

    func sendFocusedWindow(toNext: Bool) {
        guard let cur = Spaces.currentDesktopIndex() else { return }
        sendFocusedWindow(toDesktop: cur + (toNext ? 1 : -1))
    }

    func sendFocusedWindow(toDesktop index: Int) {
        guard let w = AXWindow.focused else { return }
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
            h.orderFrontRegardless()
        }
    }
}
