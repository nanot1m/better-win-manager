import Cocoa

final class WindowManager {
    /// One grid per Space; only the grids of the currently visible Spaces are touched.
    private var layoutsBySpace: [Spaces.SpaceID: Layout] = [:]
    private(set) var layouts: [Layout] = []
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
        observer = WindowObserver { [weak self] w in
            guard let self, self.enabled else { return }
            self.tile(w)
        }
        activateCurrentSpaces()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.layouts.map { $0.columns.flatMap(\.windows).count }
            self.layouts.forEach { $0.prune() }
            if before != self.layouts.map({ $0.columns.flatMap(\.windows).count }) { self.relayout() }
        }
    }

    private func activateCurrentSpaces() {
        var fresh: [Layout] = []
        layouts = NSScreen.screens.map { s in
            let area = s.visibleFrame.toCocoa()
            let id = Spaces.current(for: s)
            if let l = layoutsBySpace[id] { l.area = area; return l }
            let l = Layout(config: config, area: area)
            layoutsBySpace[id] = l
            fresh.append(l)
            return l
        }
        if !fresh.isEmpty { tileVisible(into: fresh) }
        relayout()
    }

    func retileCurrentScreen() {
        guard let l = layout(for: NSEvent.mouseLocation.toAX()) else { return }
        l.clear()
        tileVisible(into: [l])
        relayout()
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

    private func tileVisible(into targets: [Layout]) {
        let windows = Spaces.visibleWindows()
            .map { ($0, $0.frame) }
            .sorted { $0.1.midX < $1.1.midX }
        for (w, f) in windows where !isTiled(w) {
            guard let l = layout(for: f.center), targets.contains(where: { $0 === l }) else { continue }
            l.apply(.newColumn(index: l.columns.count), to: w)
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
