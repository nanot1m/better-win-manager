import Cocoa

final class WindowManager {
    /// One grid per Space; only the grids of the currently visible Spaces are touched.
    private var layoutsBySpace: [Spaces.SpaceID: Layout] = [:]
    private var active: [(space: Spaces.SpaceID, layout: Layout)] = []
    /// Windows seen on each Space; a visible window not in here just arrived (opened or moved in).
    private var seen: [Spaces.SpaceID: Set<AXWindow>] = [:]
    var layouts: [Layout] { active.map(\.layout) }
    let overlay: ZoneOverlay
    var config: Config { didSet { focusRing.apply(config) } }
    let focusRing: FocusRing
    private var timer: Timer?
    private var observer: WindowObserver?
    var enabled = true
    /// Set while the user drags a window or a gap handle; reconciling mid-gesture would fight it.
    var interacting = false
    private var handles: [HandleWindow] = []

    init(config: Config) {
        self.config = config
        focusRing = FocusRing(config: config)
        overlay = ZoneOverlay(screen: NSScreen.screens[0])
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.activateCurrentSpaces() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.activateCurrentSpaces() }
        observer = WindowObserver(onNewWindow: { [weak self] _ in self?.reconcile() },
                                  onFocusChange: { [weak self] in self?.focusRing.update() })
        activateCurrentSpaces()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    private func activateCurrentSpaces() {
        active = NSScreen.screens.map { s in
            let area = s.visibleFrame.toCocoa()
            let id = Spaces.current(for: s)
            if let l = layoutsBySpace[id] { l.area = area; return (id, l) }
            let l = Layout(config: config, area: area)
            layoutsBySpace[id] = l
            return (id, l)
        }
        reconcile()
    }

    /// Syncs the active grids with what is really on screen: departed windows leave, arrivals get tiled.
    private func reconcile() {
        guard !interacting else { return }
        let visible = Spaces.visibleWindows()
        var changed = false
        for (space, l) in active {
            let here = visible.filter { l.area.contains($0.frame.center) }
            let hereSet = Set(here)
            for w in l.columns.flatMap(\.windows) where !hereSet.contains(w) {
                l.remove(w)
                changed = true
            }
            // First look at a desktop keeps the existing order; later arrivals open on the right.
            let firstVisit = seen[space] == nil
            let known = seen[space] ?? []
            if enabled, firstVisit || config.autoTile {
                for w in here.sorted(by: { $0.frame.midX < $1.frame.midX }) where !known.contains(w) && !l.contains(w) && !isIgnored(w) {
                    l.apply(firstVisit ? .newColumn(index: l.columnIndex(forX: w.frame.midX)) : autoTileZone(for: w, in: l), to: w)
                    l.spiralAnchor = w
                    changed = true
                }
            }
            seen[space] = hereSet
        }
        if changed { relayout() }
    }

    func retileCurrentScreen() {
        guard let i = active.firstIndex(where: { $0.layout.area.contains(NSEvent.mouseLocation.toAX()) }) ?? active.indices.first else { return }
        active[i].layout.clear()
        seen[active[i].space] = []
        reconcile()
    }

    func equalize() {
        layouts.forEach { $0.equalize() }
        relayout()
    }

    func reloadConfig() {
        config = Config.load()
        layoutsBySpace.values.forEach { $0.config = config }
        relayout()
    }

    /// Cycles through tiled windows left to right, top to bottom, on the screen holding the focused window.
    func focusNext(reverse: Bool = false) {
        let focused = AXWindow.focused
        let l = focused.flatMap { f in layouts.first { $0.contains(f) } }
            ?? layout(for: focused?.frame.center ?? NSEvent.mouseLocation.toAX())
        guard let l else { return }
        let order = l.windowFrames().map(\.0)
        guard !order.isEmpty else { return }
        let i = focused.flatMap(order.firstIndex) ?? (reverse ? 0 : order.count - 1)
        order[(i + (reverse ? -1 : 1) + order.count) % order.count].raise()
    }

    func sendFocusedWindow(toNext: Bool) {
        guard let cur = Spaces.currentDesktopIndex() else { return }
        sendFocusedWindow(toDesktop: cur + (toNext ? 1 : -1))
    }

    func sendFocusedWindow(toDesktop index: Int) {
        guard let w = AXWindow.focused else { return }
        untile(w)
        interacting = true
        Spaces.sendFocusedWindow(toDesktop: index) { [weak self] moved in
            guard let self else { return }
            self.interacting = false
            guard let moved else { return }
            self.tileWhenVisible(moved, attempts: 10)
        }
    }

    /// The Space switch and the drop land asynchronously; wait until the window shows up on the active desktop.
    private func tileWhenVisible(_ w: AXWindow, attempts: Int) {
        activateCurrentSpaces()
        if Spaces.visibleWindows().contains(w) {
            if !isTiled(w) { tile(w) }
            w.raise()
            return
        }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.tileWhenVisible(w, attempts: attempts - 1) }
    }

    func canMoveFocused(_ dir: Layout.Move) -> Bool {
        guard let w = AXWindow.focused, let l = layouts.first(where: { $0.contains(w) }) else { return false }
        return l.canMove(w, dir)
    }

    func moveFocused(_ dir: Layout.Move) {
        guard let w = AXWindow.focused, let l = layouts.first(where: { $0.contains(w) }) else { return }
        l.move(w, dir)
        relayout()
    }

    func toggleFocused() {
        guard let w = AXWindow.focused else { return }
        if isTiled(w) {
            untile(w)
            relayout()
        } else {
            tile(w)
        }
    }

    func isIgnored(_ w: AXWindow) -> Bool {
        if let id = w.bundleID, config.ignoreApps.contains(id) { return true }
        if config.floatSmallWindows {
            let f = w.frame.size
            if f.width < config.smallWindowWidth && f.height < config.smallWindowHeight { return true }
        }
        return false
    }

    private func autoTileZone(for w: AXWindow, in l: Layout) -> DropZone {
        let focused = AXWindow.focused.flatMap { f -> (Int, Int, CGRect)? in
            guard let ci = l.columns.firstIndex(where: { $0.windows.contains(f) }),
                  let wi = l.columns[ci].windows.firstIndex(of: f), let fr = l.frame(of: f) else { return nil }
            return (ci, wi, fr)
        }
        switch config.autoTileStrategy {
        case .rightmost: return .newColumn(index: l.columns.count)
        case .leftmost: return .newColumn(index: 0)
        case .position: return .newColumn(index: l.columnIndex(forX: w.frame.midX))
        case .nextToFocused:
            guard let (ci, _, _) = focused else { return .newColumn(index: l.columns.count) }
            return .newColumn(index: ci + 1)
        case .stackFocused:
            guard let (ci, wi, _) = focused else { return .newColumn(index: l.columns.count) }
            return .stack(column: ci, index: wi + 1)
        case .autoSplit:
            guard let (ci, wi, fr) = focused else { return .newColumn(index: l.columns.count) }
            return fr.width > fr.height ? .newColumn(index: ci + 1) : .stack(column: ci, index: wi + 1)
        case .spiral:
            guard let a = l.spiralAnchor, let ci = l.columns.firstIndex(where: { $0.windows.contains(a) }),
                  let wi = l.columns[ci].windows.firstIndex(of: a) else {
                l.spiralBeside = false
                return .newColumn(index: l.columns.count)
            }
            defer { l.spiralBeside.toggle() }
            return l.spiralBeside ? .newColumn(index: ci + 1) : .stack(column: ci, index: wi + 1)
        }
    }

    func tile(_ w: AXWindow) {
        guard !isTiled(w), let l = layout(for: w.frame.center) else { return }
        l.apply(.newColumn(index: l.columnIndex(forX: w.frame.midX)), to: w)
        relayout()
    }

    func layout(for p: CGPoint) -> Layout? {
        layouts.first { $0.area.contains(p) } ?? layouts.first
    }

    func isTiled(_ w: AXWindow) -> Bool { layouts.contains { $0.contains(w) } }

    func untile(_ w: AXWindow, except keep: Layout? = nil) {
        layouts.forEach { if $0 !== keep { $0.remove(w) } }
    }

    /// Called on mouse-up: anything moved or resized by hand leaves the grid and floats.
    func releaseDisplacedWindows() {
        let displaced = layouts.flatMap { $0.displacedWindows() }
        guard !displaced.isEmpty else { return }
        displaced.forEach { untile($0) }
        relayout()
    }

    func relayout() {
        layouts.forEach { $0.applyFrames() }
        refreshHandles()
        focusRing.update()
    }

    private func refreshHandles() {
        var needed: [(Layout, Layout.Handle, CGRect)] = []
        for l in layouts { for (h, f) in l.handleFrames() { needed.append((l, h, f)) } }
        while handles.count < needed.count { handles.append(HandleWindow()) }
        for (idx, h) in handles.enumerated() {
            guard idx < needed.count else { h.orderOut(nil); continue }
            let (l, handle, f) = needed[idx]
            h.setFrame(f.toCocoa(), display: true)
            h.isVertical = handle.isVertical
            h.onDrag = { [weak self, weak l] p in
                self?.interacting = true
                switch handle {
                case let .column(i): l?.resize(boundary: i, toX: p.x)
                case let .row(ci, i): l?.resize(column: ci, boundary: i, toY: p.y)
                }
                self?.relayout()
            }
            h.onDragEnd = { [weak self] in
                self?.interacting = false
                self?.relayout()
            }
            h.orderFrontRegardless()
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
