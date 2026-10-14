import Cocoa

final class WindowManager {
    /// One grid per Space; only the grids of the currently visible Spaces are touched.
    private var layoutsBySpace: [Spaces.SpaceID: Layout] = [:]
    private var active: [(space: Spaces.SpaceID, layout: Layout)] = []
    /// Windows seen on each Space; a visible window not in here just arrived (opened or moved in).
    private var seen: [Spaces.SpaceID: Set<AXWindow>] = [:]
    var layouts: [Layout] { active.map(\.layout) }
    let overlay: ZoneOverlay
    private var config: Config
    private var timer: Timer?
    private var observer: WindowObserver?
    var enabled = true
    private var handles: [HandleWindow] = []

    init(config: Config) {
        self.config = config
        overlay = ZoneOverlay(screen: NSScreen.screens[0])
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.activateCurrentSpaces() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.activateCurrentSpaces() }
        observer = WindowObserver { [weak self] _ in self?.reconcile() }
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
        let visible = Spaces.visibleWindows()
        var changed = false
        for (space, l) in active {
            let here = visible.filter { l.area.contains($0.frame.center) }
            let hereSet = Set(here)
            for w in l.columns.flatMap(\.windows) where !hereSet.contains(w) {
                l.remove(w)
                changed = true
            }
            let known = seen[space] ?? []
            if enabled {
                for w in here.sorted(by: { $0.frame.midX < $1.frame.midX }) where !known.contains(w) && !l.contains(w) {
                    l.apply(.newColumn(index: l.columnIndex(forX: w.frame.midX)), to: w)
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

    func toggleFocused() {
        guard let w = AXWindow.focused else { return }
        if isTiled(w) {
            untile(w)
            relayout()
        } else {
            tile(w)
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
                switch handle {
                case let .column(i): l?.resize(boundary: i, toX: p.x)
                case let .row(ci, i): l?.resize(column: ci, boundary: i, toY: p.y)
                }
                self?.relayout()
            }
            h.onDragEnd = { [weak self] in self?.relayout() }
            h.orderFrontRegardless()
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
