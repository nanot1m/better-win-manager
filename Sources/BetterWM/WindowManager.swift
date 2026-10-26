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
    private let wsEvents = WindowServerEvents()
    /// Last key press or click seen by the event tap; distinguishes user focus changes from app self-activation.
    var lastUserInput = Date.distantPast
    /// Last input that could have activated another app; consumed by one focus-follow so apps fighting over
    /// focus (Unity after a compile versus the app the user was in) cannot ping-pong the desktop.
    var lastFocusInput = Date.distantPast
    /// Numbered desktops across all displays, each living on one.
    private let desktops = VirtualWorkspaces(count: 1) { Log.write("park", $0) }

    static func displayID(_ screen: NSScreen) -> DisplayID {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private func screen(of display: DisplayID) -> NSScreen? { NSScreen.screens.first { Self.displayID($0) == display } }
    private func screen(containing p: CGPoint) -> NSScreen? { NSScreen.screens.first { $0.frame.toCocoa().contains(p) } }
    /// The desktop shown on the display at `p`, the active one if no display is there.
    private func desktopShown(at p: CGPoint) -> Int {
        screen(containing: p).flatMap { desktops.shownDesktop(on: Self.displayID($0)) } ?? desktops.active
    }
    /// The screen of a desktop's display, the main one if it has none.
    private func screen(ofDesktop ws: Int) -> NSScreen? { desktops.display(of: ws).flatMap(screen(of:)) ?? NSScreen.screens.first }

    /// Keeps the model's displays in step with the connected ones; System Settings decides which is main.
    /// A display that vanishes gets a grace period before its desktops move: sleep, the lid and a loose cable
    /// all take displays away for a few seconds, and macOS puts the windows back itself when one returns.
    private var displayGrace: DispatchWorkItem?
    private func syncDisplays() {
        let ids = NSScreen.screens.map(Self.displayID)
        guard ids != desktops.displays else { displayGrace?.cancel(); displayGrace = nil; return }
        let lost = Set(desktops.displays).subtracting(ids)
        if lost.isEmpty || desktops.displays.isEmpty {
            displayGrace?.cancel()
            displayGrace = nil
            connectDisplays(ids)
            return
        }
        guard displayGrace == nil else { return }
        Log.write("screen", "display(s) \(lost.map { $0.prefix(8) }) gone; their desktops stay put for 10 s in case it is sleep")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.displayGrace = nil
            let now = NSScreen.screens.map(Self.displayID)
            if now != self.desktops.displays { self.connectDisplays(now); self.tick(); self.onDesktopChange?() }
        }
        displayGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func connectDisplays(_ ids: [DisplayID]) {
        desktops.connect(ids)
        Log.write("screen", "displays \(ids.map { $0.prefix(8) }); desktops \(ids.map { d in desktops.desktops(on: d).map { $0 + 1 } })")
    }

    /// Displays the model still counts on that are not connected right now (within the grace period).
    private var missingDisplays: Set<DisplayID> { Set(desktops.displays).subtracting(NSScreen.screens.map(Self.displayID)) }

    /// Visible window IDs front to back from the last full tick; avoids re-enumerating on every gesture frame.
    private var zOrder: [WindowID] = []
    /// Front-to-back order of visible windows as of the last full tick.
    var frontToBack: [WindowID] { zOrder }
    private var reconciler: Reconciler
    let system = SystemObserver()
    let overlay: ZoneOverlay
    let focusRing: FocusRing
    private var handles: [HandleWindow] = []
    private var timer: Timer?
    private var axObserver: WindowObserver?
    /// Set while a Space switch is in flight; the window list mixes both desktops during the slide.
    private var switching = false
    /// Bumped per Space switch so only the latest one's settle clears `switching`.
    private var spaceSwitchGeneration = 0
    /// Set while the user drags a window or a gap handle; reconciling mid-gesture would fight it.
    var interacting = false {
        didSet {
            interactionScreens = nil
            if oldValue, !interacting { onInteractionEnd?() }
        }
    }
    var onInteractionEnd: (() -> Void)?
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

    /// Fullscreen, split view, or a fullscreen Space being torn down: macOS owns its frame until it is back.
    private func isAway(_ id: WindowID) -> Bool { Spaces.spaces(of: id).first.map { !Spaces.isDesktop($0) } ?? false }
    private func markAway(_ snap: inout Snapshot) {
        let missing = missingDisplays
        snap.away = Set(snap.windows.map(\.id).filter { id in
            isAway(id) || (desktops.display(of: desktops.workspace(of: id)).map(missing.contains) ?? false)
        })
    }

    private func configureWorkspaces() {
        tick()
    }

    /// The observer reports model Spaces: the virtual workspace a screen shows and the one a window belongs to.
    private func installSpaceModel() {
        system.spaceOf = { [unowned self] screen in
            VirtualWorkspaces.spaceID(self.desktops.shownDesktop(on: Self.displayID(screen)) ?? self.desktops.active)
        }
        system.spacesOfWindow = { [unowned self] id in [VirtualWorkspaces.spaceID(self.desktops.workspace(of: id))] }
    }

    /// Quitting must leave every window reachable: unpark all of them and write the layout one last time.
    func prepareForQuit() {
        saveWork?.cancel()
        saveNow()
        // Parked tiled windows have no remembered frame; their grid slot is where they go.
        for id in desktops.parkedWindows where state.isTiled(id) {
            if let f = targetFrame(of: id) { system.execute([.setFrame(id, f)]) }
        }
        desktops.unparkAll(setFrame: { self.system.execute([.setFrame($0, $1)]) },
                           unhide: { NSRunningApplication(processIdentifier: $0)?.unhide() },
                           fit: { self.fit($1, toDesktopOf: $0) })
        system.waitForCommands()
    }

    // MARK: Desktops

    /// Every window with the desktop it lives on, in the order the bar's chips show them (grid order, then
    /// floating windows in their chip order), current desktop first. The switcher and the overview read this,
    /// so what they list is exactly what the bar lists.
    func windowsByDesktop() -> [(desktop: Int, windows: [AXWindow])] {
        let apps = appsByDesktop()
        let current = currentDesktop ?? 0
        return apps.keys.sorted { a, b in a == current ? true : b == current ? false : a < b }.map { d in
            (d, (apps[d] ?? []).flatMap(\.windows).compactMap { system.axWindow($0) })
        }
    }

    /// Floating windows keep their chip slot while they are around; newcomers go to the end. Tiled windows
    /// follow the grid instead, so their icons never need remembering.
    private var chipOrder: [Int: [WindowID]] = [:]

    /// Windows per desktop in display order: the grid's columns left to right, top to bottom, then floating
    /// windows. One entry per window, for the status bar chips.
    func appsByDesktop() -> [Int: [(pid: pid_t, windows: [WindowID])]] {
        var out: [Int: [(pid: pid_t, windows: [WindowID])]] = [:]
        for (desktop, apps) in currentAppsByDesktop() {
            let all = apps.flatMap { app in app.windows.map { (pid: app.pid, id: $0) } }
            let gridOrder = state.grid(for: VirtualWorkspaces.spaceID(desktop)).windows
            var ordered = gridOrder.compactMap { id in all.first { $0.id == id } }
            let floating = all.filter { !gridOrder.contains($0.id) }
            var order = chipOrder[desktop]?.filter { fid in floating.contains { $0.id == fid } } ?? []
            order += floating.map(\.id).filter { !order.contains($0) }
            chipOrder[desktop] = order
            ordered += order.compactMap { id in floating.first { $0.id == id } }
            out[desktop] = ordered.map { ($0.pid, [$0.id]) }
        }
        for desktop in chipOrder.keys where out[desktop] == nil { chipOrder[desktop] = nil }
        return out
    }

    private func currentAppsByDesktop() -> [Int: [(pid: pid_t, windows: [WindowID])]] {
        var out: [Int: [(pid: pid_t, windows: [WindowID])]] = [:]
        var counted = Set<WindowID>()
        func add(_ pid: pid_t, _ id: WindowID, to desktop: Int) {
            guard counted.insert(id).inserted else { return }
            if let i = out[desktop]?.firstIndex(where: { $0.pid == pid }) { out[desktop]![i].windows.append(id) }
            else { out[desktop, default: []].append((pid, [id])) }
        }
        for info in CGWindowInfo.list([.optionOnScreenOnly, .excludeDesktopElements]) where info.isOrdinaryOtherApp {
            guard desktops.isKnown(info.id) else { continue }
            add(info.pid, info.id, to: desktops.workspace(of: info.id))
        }
        for id in desktops.knownWindows where desktops.isParked(id) && system.inLastSnapshot.contains(id) {
            guard let pid = system.pid(of: id) else { continue }
            add(pid, id, to: desktops.workspace(of: id))
        }
        return out
    }

    /// Where a window sits on its own desktop: its grid slot if tiled, its remembered frame if parked, else as is.
    func layoutFrame(of w: AXWindow) -> CGRect? {
        guard let id = id(w) else { return nil }
        if state.isTiled(id) { return targetFrame(of: id) }
        return desktops.parkedFrame(of: id)
    }

    /// Brings `w` to front, switching to its desktop first when needed.
    func activate(_ w: AXWindow, onDesktop desktop: Int) {
        if desktop != currentDesktop {
            switchDesktop(desktop)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { w.raise() }
        } else {
            w.raise()
        }
    }

    var desktopCount: Int { desktops.count }
    func desktop(of id: WindowID) -> Int { desktops.workspace(of: id) }
    var currentDesktop: Int? { desktops.active }
    /// Desktops living on `screen`, and the one it shows; for the bar on that screen.
    func desktopList(on screen: NSScreen) -> [Int] { desktops.desktops(on: Self.displayID(screen)) }
    func shownDesktop(on screen: NSScreen) -> Int? { desktops.shownDesktop(on: Self.displayID(screen)) }

    func switchDesktop(_ index: Int) {
        let v = desktops
        guard index >= 0 else { return }
        // Asking for the desktop you are already on cycles focus through its windows instead.
        if index == v.active {
            Log.write("desktop", "workspace \(index + 1) already active; focusing next window")
            focusNext()
            return
        }
        // Workspaces are created on demand: asking for 6 with 4 configured makes 5 and 6.
        if index >= v.count { v.setCount(index + 1) }
        // Hide the ring during the switch so it doesn't linger on the parked window.
        focusRing.suspended = true
        Log.write("desktop", "switch to workspace \(index + 1) on display \(v.display(of: index)?.prefix(8) ?? "?")")
        rememberFocus()
        v.switchTo(index)
        ignoreOwnFocusChanges()
        lastFocusedID = system.focused.flatMap(id)
        onDesktopChange?()
        let t0 = Date()
        tick(settle: false) { [weak self] in
            guard let self else { return }
            let t1 = Date()
            self.revealRingAndFocusTop()
            v.trimEmptyTrailing(minimum: 1)
            self.onDesktopChange?()
            let t2 = Date()
            if t2.timeIntervalSince(t0) > 0.05 { Log.write("desktop", "switch cost: tick \(Int(t1.timeIntervalSince(t0) * 1000)) ms, reveal \(Int(t2.timeIntervalSince(t1) * 1000)) ms") }
        }
    }

    /// Reorders workspaces: everything keyed by workspace follows.
    func moveDesktop(from: Int, to: Int) {
        let map = desktops.moveWorkspace(from: from, to: to)
        guard !map.isEmpty else { return }
        func remap(_ id: SpaceID) -> SpaceID {
            guard let ws = VirtualWorkspaces.workspace(of: id), let to = map[ws] else { return id }
            return VirtualWorkspaces.spaceID(to)
        }
        state.grids = Dictionary(uniqueKeysWithValues: state.grids.map { (remap($0.key), $0.value) })
        state.seen = Dictionary(uniqueKeysWithValues: state.seen.map { (remap($0.key), $0.value) })
        state.retileRequested = Set(state.retileRequested.map(remap))
        lastFocusedByWorkspace = Dictionary(uniqueKeysWithValues: lastFocusedByWorkspace.map { (remap($0.key), $0.value) })
        for i in lastSaved.spaces.indices { lastSaved.spaces[i].id = remap(lastSaved.spaces[i].id) }
        chipOrder = Dictionary(uniqueKeysWithValues: chipOrder.compactMap { k, order in map[k].map { ($0, order) } })
        Log.write("desktop", "move workspace \(from + 1) to position \(to + 1)")
        tick()
        onDesktopChange?()
    }

    func moveCurrentDesktop(left: Bool) {
        moveDesktop(from: desktops.active, to: desktops.active + (left ? -1 : 1))
    }

    /// The screen showing the active desktop.
    var activeScreen: NSScreen? { screen(ofDesktop: desktops.active) }

    /// The desktop next to `ws` (the active one by default) on its display, if any.
    func neighbourDesktop(of ws: Int? = nil, next: Bool) -> Int? {
        let ws = ws ?? desktops.active
        guard let d = desktops.display(of: ws) else { return nil }
        let here = desktops.desktops(on: d)
        guard let i = here.firstIndex(of: ws) else { return nil }
        let j = i + (next ? 1 : -1)
        return here.indices.contains(j) ? here[j] : nil
    }

    /// Next or previous desktop on the active desktop's display; past the last one, a new one there.
    func switchDesktop(next: Bool) {
        if let n = neighbourDesktop(next: next) { switchDesktop(n); return }
        guard next, desktops.display(of: desktops.active) == desktops.main else { return }
        // Only the main display grows on demand; a new desktop lands there anyway.
        switchDesktop(desktops.count)
    }

    /// Moves a desktop (the active one by default), windows and all, to the next display; it becomes active there.
    func sendDesktopToNextScreen(_ which: Int? = nil) {
        let ds = desktops.displays
        let ws = which ?? desktops.active
        guard ds.count > 1, let from = desktops.display(of: ws), let i = ds.firstIndex(of: from) else { return }
        let to = ds[(i + 1) % ds.count]
        rememberFocus()
        let floatingHere = desktops.knownWindows.filter { desktops.workspace(of: $0) == ws && !state.isTiled($0) && !desktops.isParked($0) }
        desktops.send(desktop: ws, to: to)
        Log.write("desktop", "send desktop \(ws + 1) to display \(to.prefix(8))")
        // Tiled windows follow their grid to the new display; floating ones keep their place relative to it.
        for id in floatingHere { if let f = system.lastFrame(of: id) { system.execute([.setFrame(id, fit(f, toDesktopOf: id))]) } }
        ignoreOwnFocusChanges()
        onDesktopChange?()
        tick { [weak self] in
            self?.revealRingAndFocusTop()
            self?.onDesktopChange?()
        }
    }

    /// `f` moved to the display of `id`'s desktop if it lies on another one, keeping its relative position, and
    /// fitted to that display's visible area.
    private func fit(_ f: CGRect, toDesktopOf id: WindowID) -> CGRect {
        guard let target = screen(ofDesktop: desktops.workspace(of: id)) else { return fitToScreen(f) }
        let to = target.visibleFrame.toCocoa()
        guard let source = NSScreen.screens.first(where: { $0.frame.toCocoa().contains(f.center) }), source != target else {
            return fitToScreen(f, area: to)
        }
        let from = source.visibleFrame.toCocoa()
        let moved = CGRect(x: to.minX + (f.minX - from.minX) / from.width * to.width,
                           y: to.minY + (f.minY - from.minY) / from.height * to.height,
                           width: f.width, height: f.height)
        return fitToScreen(moved, area: to)
    }

    private var fullscreenCache: (at: Date, value: [(space: SpaceID, pids: [pid_t])])?
    /// Fullscreen Spaces on the main display with the apps in them, for the bar; enumerating windows per Space
    /// is not free, so the answer is kept for a few seconds.
    func fullscreenSpaces() -> [(space: SpaceID, pids: [pid_t])] {
        if let c = fullscreenCache, Date().timeIntervalSince(c.at) < 3 { return c.value }
        guard let screen = NSScreen.screens.first else { return [] }
        let value = Spaces.fullscreenSpaces(alongside: Spaces.current(for: screen)).map { ($0, Spaces.owners(on: $0)) }.filter { !$0.1.isEmpty }
        fullscreenCache = (Date(), value)
        return value
    }

    /// Goes to another macOS Space by activating an app with a window on it, as a Dock click would; there is no
    /// public call to switch Spaces, and Accessibility does not even list windows on other Spaces. `prefer`
    /// names windows whose apps to try first.
    @discardableResult
    func activateSpace(_ space: SpaceID, prefer: [WindowID] = []) -> Bool {
        let all = Spaces.windows(on: space)
        let ordered = prefer.compactMap { id in all.first { $0.id == id } } + all.filter { !prefer.contains($0.id) }
        var tried: Set<pid_t> = []
        for w in ordered where tried.insert(w.pid).inserted {
            guard let app = NSRunningApplication(processIdentifier: w.pid), app.activate(options: [.activateIgnoringOtherApps]) else { continue }
            Log.write("desktop", "activating \(app.localizedName ?? "pid \(w.pid)") to reach Space \(space)")
            return true
        }
        Log.write("desktop", "no app on Space \(space) to switch through")
        return false
    }

    /// Swipe semantics: through the virtual desktops, and past the last (or first) one on to the neighbouring
    /// macOS Space, which is how fullscreen apps are reached; from a fullscreen Space, back the same way.
    /// There is no public call to switch Spaces, but activating an app whose windows live on the target Space
    /// makes macOS go there.
    func switchDesktopOrSpace(next: Bool) {
        guard let screen = screen(ofDesktop: desktops.active), let d = desktops.display(of: desktops.active) else { return }
        let real = Spaces.current(for: screen)
        let here = desktops.desktops(on: d)
        let atEdge = next ? desktops.active == here.last : desktops.active == here.first
        if !Spaces.isFullscreen(real), !atEdge {
            switchDesktop(next: next)
            return
        }
        let n = Spaces.neighbours(of: real)
        guard let target = next ? n.next : n.previous else { return }
        // On a desktop, prefer a window visible on its active workspace so the switch lands on the right windows.
        let prefer = desktops.knownWindows.filter { desktops.isShown(desktops.workspace(of: $0)) && !desktops.isParked($0) }
        activateSpace(target, prefer: prefer)
    }

    /// Activating a parked window (⌘Tab, Dock, a notification) switches to its workspace. Only a *change* of
    /// focus counts: after switching to an empty workspace the old window stays focused and must not pull us back.
    private var ignoreFocusSwitchUntil = Date.distantPast
    private var lastFocusedID: WindowID?
    /// The window focused when each workspace was last left, keyed by model Space ID; coming back focuses it
    /// rather than whatever ended up on top after parking and unhiding.
    private var lastFocusedByWorkspace: [SpaceID: WindowID] = [:]
    /// Windows just placed on a background workspace; their app tends to focus them right away (Unity does),
    /// and that focus change is the app's, not the user's, even if the user typed a moment ago.
    private var adoptedInBackground: [WindowID: Date] = [:]
    private func followFocusedWindowsWorkspace() {
        guard let f = system.focused, let id = id(f) else { return }
        let v = desktops
        guard id != lastFocusedID else { return }
        lastFocusedID = id
        guard Date() >= ignoreFocusSwitchUntil else { return }
        let ws = v.workspace(of: id)
        guard ws != v.active else { return }
        // Focus moved to a desktop already on screen (another display): nothing moves, it just becomes active.
        if v.isShown(ws) {
            v.switchTo(ws)
            onDesktopChange?()
            return
        }
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
        rememberFocus()
        v.switchTo(ws)
        onDesktopChange?()
        tick { [weak self] in
            guard let self else { return }
            // The window that triggered this is the one to ring; it is already focused.
            if let frame = self.targetFrame(of: id) ?? self.system.axWindow(id)?.frame { self.focusRing.show(windowID: id, frame: frame) } else { self.focusRing.suspended = false }
            self.onDesktopChange?()
        }
    }

    private var focusFollowScheduled = false
    /// AX focus events can arrive before the frontmost app updates, and activation notifications after; one
    /// look once both have landed.
    private func scheduleFocusFollow() {
        guard !focusFollowScheduled else { return }
        focusFollowScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusFollowScheduled = false
            self?.followFocusedWindowsWorkspace()
        }
    }

    /// Parking, hiding and raising after our own switch move focus around for a moment; none of that is the user.
    private func ignoreOwnFocusChanges() { ignoreFocusSwitchUntil = Date().addingTimeInterval(0.8) }

    private func activateTopApp() {
        let top = zOrder.first { desktops.workspace(of: $0) == desktops.active && !desktops.isParked($0) }
        if let id = top, let pid = system.pid(of: id), let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func focusTopWindow() {
        if let id = zOrder.first(where: { desktops.workspace(of: $0) == desktops.active }) { system.execute([.raise(id)]) }
    }

    /// Where a tiled window sits (or will sit) in its grid, in AX coordinates. Works for desktops not shown
    /// too, by using the area of the display the desktop lives on.
    private func targetFrame(of id: WindowID) -> CGRect? {
        guard let space = state.space(containing: id), let ws = VirtualWorkspaces.workspace(of: space),
              let target = screen(ofDesktop: ws), let i = NSScreen.screens.firstIndex(of: target) else { return nil }
        let screens = system.screens()
        guard i < screens.count else { return nil }
        return reconciler.geometry(state.grid(for: space), ScreenInfo(space: space, area: screens[i].area)).frame(of: id)
    }

    /// After a workspace switch: show the ring on the window we are about to raise, in the same pass, then raise it.
    /// Windows of `desktop` with the frames they will have when it shows, from the manager's own state and the
    /// last snapshot: no Accessibility round trips, so it is cheap enough for the first frame of a gesture.
    /// The window that was focused there comes first, then the grid's order, then floating windows.
    func previewItems(desktop d: Int) -> [(id: WindowID, pid: pid_t, frame: CGRect, tiled: Bool)] {
        let v = desktops
        let top = lastFocusedWindow(onDesktop: d)
        let gridOrder = state.grid(for: VirtualWorkspaces.spaceID(d)).windows
        let known = v.knownWindows.filter { v.workspace(of: $0) == d }
        let ordered = ([top].compactMap { $0 } + gridOrder + known).reduce(into: [WindowID]()) { if !$0.contains($1), known.contains($1) { $0.append($1) } }
        return ordered.compactMap { id in
            guard let pid = system.pid(of: id) else { return nil }
            let tiled = state.isTiled(id)
            guard let frame = (tiled ? targetFrame(of: id) : nil) ?? v.parkedFrame(of: id) ?? system.lastFrame(of: id) else { return nil }
            return (id, pid, frame, tiled)
        }
    }

    /// The window that had focus when `desktop` was last left, if it is still around.
    func lastFocusedWindow(onDesktop desktop: Int) -> WindowID? {
        guard let id = lastFocusedByWorkspace[VirtualWorkspaces.spaceID(desktop)],
              desktops.workspace(of: id) == desktop, system.axWindow(id)?.isValid == true else { return nil }
        return id
    }

    private func rememberFocus() {
        guard let f = system.focused, let id = id(f), desktops.workspace(of: id) == desktops.active else { return }
        lastFocusedByWorkspace[VirtualWorkspaces.spaceID(desktops.active)] = id
    }

    private func revealRingAndFocusTop() {
        let v = desktops
        let onActive: (WindowID) -> Bool = { v.workspace(of: $0) == v.active }
        let remembered = lastFocusedByWorkspace[VirtualWorkspaces.spaceID(v.active)].flatMap { r in system.axWindow(r)?.isValid == true && onActive(r) ? r : nil }
        guard let id = remembered ?? zOrder.first(where: onActive) else {
            focusRing.suspended = false
            return
        }
        if state.isTiled(id) || config.focusRingFloating, let frame = targetFrame(of: id) ?? system.axWindow(id)?.frame {
            focusRing.show(windowID: id, frame: frame)
        } else {
            focusRing.suspended = false
        }
        system.execute([.raise(id)])
        // The raise and the unhides that follow a switch change depths asynchronously; settle the ring after them.
        for delay in [0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.focusRing.reorder() }
        }
    }

    /// Moves and shrinks a frame so it lies within the visible area of the screen nearest to it; frames
    /// remembered on a monitor that has since been unplugged would otherwise come back off screen or oversized.
    func fitToScreen(_ f: CGRect, area: CGRect? = nil) -> CGRect {
        let screens = system.screens()
        guard let a = area ?? (screens.first(where: { $0.area.contains(f.center) })
            ?? screens.min(by: { hypot($0.area.midX - f.midX, $0.area.midY - f.midY) < hypot($1.area.midX - f.midX, $1.area.midY - f.midY) }))?.area else { return f }
        var r = f
        r.size.width = min(r.width, a.width)
        r.size.height = min(r.height, a.height)
        r.origin.x = min(max(r.minX, a.minX), a.maxX - r.width)
        r.origin.y = min(max(r.minY, a.minY), a.maxY - r.height)
        return r
    }

    /// Parks windows of inactive workspaces and restores returning floating ones; tiled ones follow their grid.
    private func applyVirtualParking(_ snap: Snapshot) {
        let v = desktops
        let screenFrames = NSScreen.screens.map { $0.frame.toCocoa() }
        func corner(_ id: WindowID, _ f: CGRect) -> CGPoint {
            Parking.origin(for: f, home: screen(ofDesktop: v.workspace(of: id))?.frame.toCocoa(), screens: screenFrames)
        }
        v.apply(windows: snap.windows.map(\.id).filter { !snap.away.contains($0) },
                pid: { snap.window($0)?.pid },
                hideable: { p in
                    guard self.config.hideApps, let app = NSRunningApplication(processIdentifier: p) else { return false }
                    return app.activationPolicy == .regular
                },
                isTiled: { self.state.isTiled($0) }, frame: { snap.window($0)?.frame },
                setFrame: { self.system.execute([.setFrame($0, $1)]) },
                parkOrigin: corner,
                // At the corner that would be chosen now: a display connected beside the old one makes it re-park.
                isInCorner: { id, f in
                    let o = corner(id, f)
                    return abs(o.x - f.minX) <= 100 && abs(o.y - f.minY) <= 100
                },
                fit: { self.fit($1, toDesktopOf: $0) },
                hide: { pid in
                    // A hidden window cannot be captured; the overview shows what it looked like just before.
                    // Only when the overview is in use: captures count as screen recording to macOS.
                    if self.config.overview { Thumbnails.captureNow(snap.windows.filter { $0.pid == pid }.map(\.id)) }
                    // Hiding the frontmost app lets macOS pick the next one (usually Finder, with no window);
                    // hand focus to the destination workspace's top app first, or to ourselves if it is empty.
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { self.activateTopApp() }
                    NSRunningApplication(processIdentifier: pid)?.hide()
                },
                unhide: { [weak self] pid in
                    NSRunningApplication(processIdentifier: pid)?.unhide()
                    // Frames set while an app is still unhiding can be lost; look again shortly after.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.scheduleTick(); self?.focusRing.reorder() }
                },
                // Moves ignored while macOS is waking or rearranging displays say nothing about the window.
                countRefusals: snap.now >= claimsSuspendedUntil, now: snap.now)
    }

    var enabled: Bool {
        get { reconciler.enabled }
        set { reconciler.enabled = newValue }
    }

    init(config: Config) {
        self.config = config
        reconciler = Reconciler(config: config)
        focusRing = FocusRing(config: config)
        let primaryScreen = NSScreen.screens.first ?? NSScreen.main ?? NSScreen()
        overlay = ZoneOverlay(screen: primaryScreen)
        focusRing.isTiled = { [unowned self] w in self.isTiled(w) }
        focusRing.isTiledID = { [unowned self] id in self.state.isTiled(id) }
        focusRing.focusedWindow = { [unowned self] in self.system.focused }
        focusRing.onReorder = { [unowned self] in self.stackHandles() }
        if config.restoreLayouts, let data = try? Data(contentsOf: Config.statePath),
           let layout = try? JSONDecoder().decode(SavedLayout.self, from: data) {
            let spaceScreen = NSScreen.screens.first ?? NSScreen.main
            let current = spaceScreen.map { Spaces.current(for: $0) } ?? 0
            saved = layout.migrated(currentSpace: current)
            lastSaved = saved
            desktops.restore(homes: Dictionary(uniqueKeysWithValues: saved.desktopHomes.compactMap { k, v in Int(k).map { ($0, v) } }),
                             shownOn: saved.shownOnDisplays, active: saved.activeDesktop)
            // A previous run that was killed left its hidden apps hidden; bring them back before parking decides anew.
            for pid in saved.hiddenPids {
                if let app = NSRunningApplication(processIdentifier: pid), app.isHidden {
                    app.unhide()
                    Log.write("park", "unhide app \(pid) left hidden by the previous run")
                }
            }
        }
        syncDisplays()
        installSpaceModel()
        configureWorkspaces()
        // Sleep, display sleep, the lock screen and fast user switching all leave macOS ignoring window moves for
        // a while; no window may be judged as refusing to leave until a minute after the Mac is back.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspendClaims(until: .distantFuture) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.suspendClaims(until: Date().addingTimeInterval(60)) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.suspendClaims(until: .distantFuture) }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.suspendClaims(until: Date().addingTimeInterval(60)) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("screen", "display configuration changed: \(NSScreen.screens.count) screen(s)")
            self.suspendClaims(until: max(Date().addingTimeInterval(60), self.claimsSuspendedUntil))
            self.syncDisplays()
            self.tick()
            self.onDesktopChange?()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            // The window list is still in flux while the slide animation runs, and macOS reports no end to it.
            guard let self else { return }
            self.switching = true
            self.spaceSwitchGeneration += 1
            let generation = self.spaceSwitchGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, generation == self.spaceSwitchGeneration else { return }
                self.switching = false
                self.tick()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }
        // App activation (⌘Tab, Dock) is the common way to reach a parked window; AX focus events fire before
        // the frontmost app updates, so re-check shortly after activation as well.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.system.refreshFocused { self?.scheduleFocusFollow() }
        }
        // WindowServer reports a new front window before Accessibility does; stacked screens re-fan on it.
        wsEvents.onEvent = { [weak self] event, _ in
            switch event {
            case .frontChange, .windowReorder: self?.refanStackedScreens()
            case .windowCreate, .windowDestroy: self?.scheduleTick()
            default: break
            }
        }
        AXResponsiveness.onBackoffEnd = { [weak self] in self?.scheduleTick() }
        axObserver = WindowObserver(onNewWindow: { [weak self] _ in self?.tick() },
                                    onFocusChange: { [weak self] in
                                        self?.system.refreshFocused {
                                            self?.followFocusedWindowsWorkspace()
                                            self?.refanStackedScreens()
                                            self?.scheduleFocusFollow()
                                            self?.focusRing.update()
                                            self?.onFocusChange?()
                                        }
                                    },
                                    onGeometryChange: { [weak self] in
                                        guard let self, !self.interacting else { return }
                                        self.focusRing.scheduleUpdate()
                                        self.scheduleTick()
                                    },
                                    onTitleChange: { [weak self] in self?.system.refreshFocused { self?.onFocusChange?() } })
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

    /// Windows the snapshot must include even when they are not on screen: tiled ones (parked or on other
    /// desktops) and every window a workspace knows, since floating windows of a hidden app are invisible
    /// yet still need saving and restoring per workspace.
    private var tracked: [WindowID] {
        var ids = Set(state.grids.values.flatMap(\.windows))
        ids.formUnion(state.floating)
        ids.formUnion(desktops.knownWindows)
        return Array(ids)
    }

    private var tickInFlight = false
    private var tickPending = false
    private var tickCompletions: [() -> Void] = []

    /// Full reconcile: observe, reconcile, execute, and settle (windows that refuse a size need a second pass).
    /// The snapshot is taken on the AX queue, so this returns at once; `completion` runs on the main thread once
    /// the pass and its settle passes are done. `settle` re-reads the screen after moving windows, for ones that
    /// refuse a size; a desktop switch skips it, since the window-server events the moves cause bring a tick right after.
    func tick(settle: Bool = true, completion: (() -> Void)? = nil) {
        if let completion { tickCompletions.append(completion) }
        if tickInFlight { tickPending = true; return }
        guard !interacting, !switching else { drainTickCompletions(); return }
        tickInFlight = true
        pruneDeadWindows()
        runPass(0, settle: settle, assignRetries: 3, timing: [])
    }

    private func runPass(_ pass: Int, settle: Bool, assignRetries: Int, timing: [String]) {
        let t0 = Date()
        system.snapshot(tracked: tracked) { [weak self] snap in
            guard let self else { return }
            var timing = timing
            timing.append("snap\(pass) \(Int(Date().timeIntervalSince(t0) * 1000))")
            // A drag or Space switch that began meanwhile must not be fought with frames from before it.
            guard !self.interacting, !self.switching else { self.finishTick(timing); return }
            // Accessibility answering for nobody (the lock screen, the first seconds after waking) is not a desktop
            // with no windows; acting on it would untile everything.
            if snap.windows.isEmpty, CGWindowInfo.list([.optionOnScreenOnly, .excludeDesktopElements]).contains(where: \.isOrdinaryOtherApp) {
                Log.write("snapshot", "no window readable through Accessibility; leaving the layout alone")
                self.finishTick(timing)
                return
            }
            if !self.sawWindows, !snap.windows.isEmpty {
                self.sawWindows = true
                self.virtualRestoreDeadline = Date().addingTimeInterval(20)
            }
            var snap = snap
            self.markAway(&snap)
            Spaces.withSpaceTypesCached {
                self.zOrder = snap.windows.map(\.id)
                // Placing windows changes what the next snapshot shows, and apps unhiding during launch add windows
                // between snapshots; every window must pass through assignment before parking can adopt it.
                if self.assignNewVirtualWindows(snap), assignRetries > 0 {
                    return self.runPass(pass, settle: settle, assignRetries: assignRetries - 1, timing: timing)
                }
                self.desktops.rememberHomes(snap.windows)
                self.restoreSavedModes(snap)
                let before = self.state
                let (next, commands) = self.reconciler.reconcile(self.state, snap)
                self.state = next
                self.logReconcileChanges(from: before, to: next)
                let ids = Set(snap.windows.map(\.id))
                if ids != self.lastWindowIDs { self.lastWindowIDs = ids; self.onWindowsChange?() }
                self.scheduleSave(snap)
                let t1 = Date()
                self.applyVirtualParking(snap)
                timing.append("park \(Int(Date().timeIntervalSince(t1) * 1000))")
                if !commands.isEmpty {
                    self.anticipateRing(commands, snap.focused)
                    self.system.execute(commands)
                    timing.append("exec \(commands.count)")
                    if settle, pass + 1 < 3 { return self.runPass(pass + 1, settle: settle, assignRetries: 3, timing: timing) }
                }
                self.finishTick(timing)
            }
        }
    }

    private func finishTick(_ timing: [String]) {
        var timing = timing
        let t3 = Date()
        refreshChrome()
        timing.append("chrome \(Int(Date().timeIntervalSince(t3) * 1000))")
        if Log.enabled, timing.count > 3 || timing.contains(where: { (Int($0.split(separator: " ").last ?? "") ?? 0) > 15 }) { Log.write("tick", timing.joined(separator: ", ")) }
        tickInFlight = false
        drainTickCompletions()
        if tickPending { tickPending = false; tick() }
    }

    private func drainTickCompletions() {
        let done = tickCompletions
        tickCompletions = []
        done.forEach { $0() }
    }

    /// Workspace membership outlives windows unless told otherwise; a closed window must not keep showing its
    /// app on a desktop chip or count as a sibling, even when its app keeps it alive.
    private func pruneDeadWindows() {
        guard case let alive = CGWindowInfo.aliveIDs(), !alive.isEmpty else { return }
        let closed = system.closedByApp
        system.forgetClosed(closed)
        do {
            let v = desktops
            for id in v.knownWindows where !alive.contains(id) || closed.contains(id) {
                v.forget(id)
                state.forget(id)
                floatingFrames[id] = nil
                adoptedInBackground[id] = nil
                Thumbnails.forget(id)
                lastFocusedByWorkspace = lastFocusedByWorkspace.filter { $0.value != id }
            }
        }
    }

    /// Windows keep arriving for a while after launch (moves from other desktops land asynchronously), so saved
    /// slots are matched against newly seen windows until this deadline instead of once.
    private var virtualRestoreDeadline = Date.distantFuture
    /// The deadline counts from the first snapshot with windows in it, not from launch: a launch while the screen
    /// is locked sees nothing for a while.
    private var sawWindows = false

    /// Gives every not-yet-assigned window a workspace: its saved slot if one matches, otherwise the active one.
    /// Returns true if any window was placed from the saved layout, so the snapshot should be rebuilt.
    private func assignNewVirtualWindows(_ snap: Snapshot) -> Bool {
        var pool = snap.windows.filter { !snap.away.contains($0.id) && !desktops.isKnown($0.id) }
        guard !pool.isEmpty else { return false }
        if Date() < virtualRestoreDeadline { Log.write("restore", "unassigned: \(pool.map { describe($0.id) })") }
        var placed = false
        // At launch everything is matched against the saved layout. Later, only windows of an app that just
        // (re)started are, and only by exact title, against the latest save and never into the active
        // workspace: an updated browser reopening its windows gets them back where they were.
        let atLaunch = Date() < virtualRestoreDeadline
        let layout = atLaunch ? saved : lastSaved
        let launchCutoff = Date().addingTimeInterval(-15)
        func eligible(_ w: WindowInfo) -> Bool {
            atLaunch || (NSRunningApplication(processIdentifier: w.pid)?.launchDate.map { $0 > launchCutoff } ?? false)
        }
        if config.restoreLayouts {
            for savedSpace in layout.spaces {
                guard let ws = VirtualWorkspaces.workspace(of: savedSpace.id) else { continue }
                if !atLaunch, desktops.isShown(ws) { continue }
                let candidates = pool.filter { !reconciler.isIgnored($0) && eligible($0) }
                guard !candidates.isEmpty, let grid = layout.restore(space: savedSpace.id, candidates: candidates, exactTitle: !atLaunch) else { continue }
                Log.write("restore", "\(grid.windows.map { describe($0) }) back on workspace \(ws + 1)\(atLaunch ? "" : " (app relaunched)")")
                for id in grid.windows { desktops.move(id, to: ws) }
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
        if config.restoreLayouts {
            for savedSpace in layout.spaces where !savedSpace.floating.isEmpty {
                guard let ws = VirtualWorkspaces.workspace(of: savedSpace.id) else { continue }
                if !atLaunch, desktops.isShown(ws) { continue }
                let candidates = pool.filter { eligible($0) }
                for (id, frame) in layout.restoreFloating(space: savedSpace.id, candidates: candidates, exactTitle: !atLaunch) {
                    desktops.move(id, to: ws)
                    state.floating.insert(id)
                    system.execute([.setFrame(id, fit(frame, toDesktopOf: id))])
                    pool.removeAll { $0.id == id }
                    Log.write("restore", "\(describe(id)) floats on workspace \(ws + 1) at \(frame)")
                    placed = true
                }
            }
        }
        // A window left in a parking corner by a previous run (quit without unparking, a crash) and matched by
        // nothing above would be adopted here, unreachable; pull it back onto its screen.
        let screenFrames = NSScreen.screens.map { $0.frame.toCocoa() }
        for w in pool {
            guard let corner = Parking.screen(parking: w.frame, screens: screenFrames, tolerance: 3),
                  let screen = NSScreen.screens.first(where: { $0.frame.toCocoa() == corner }) else { continue }
            let area = screen.visibleFrame.toCocoa()
            let origin = CGPoint(x: max(area.minX, area.midX - w.frame.width / 2), y: max(area.minY, area.midY - w.frame.height / 2))
            system.execute([.setFrame(w.id, CGRect(origin: origin, size: w.frame.size))])
            Log.write("restore", "\(describe(w.id)) was stranded in the parking corner; moved on screen")
            placed = true
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentInput = Date().timeIntervalSince(lastUserInput) < 2
        for w in pool {
            let v = desktops
            // A window appearing while its app is in the background (Unity recreating its editor window, a
            // background app opening a document) stays with the app's other windows, or where its last window
            // was, instead of landing on the active workspace and dragging the user there later. Only a window
            // the user just asked the frontmost app for belongs on the active workspace.
            let siblings = snap.windows.filter { $0.pid == w.pid && $0.id != w.id && v.isKnown($0.id) }.map(\.id)
            let siblingSpaces = v.workspaces(of: siblings)
            let home = siblingSpaces.count == 1 ? siblingSpaces.first : (siblings.isEmpty ? v.homeByPid[w.pid] : nil)
            let deliberate = w.pid == frontPid && recentInput
            // Where it appeared: the desktop that display shows.
            let local = desktopShown(at: w.frame.center)
            if let ws = home, ws != local, !deliberate {
                v.adopt(w.id, into: ws)
                adoptedInBackground[w.id] = Date()
                let why = siblings.isEmpty ? "where its last window was" : "with its app's windows"
                Log.write("adopt", "\(describe(w.id)) joins workspace \(ws + 1) \(why) (\(w.pid == frontPid ? "no recent input" : "app not frontmost"))")
            } else {
                v.adopt(w.id, into: local)
                Log.write("adopt", "\(describe(w.id)) joins workspace \(local + 1), shown where it appeared")
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

    // MARK: Persistence

    private var pendingSnapshot: Snapshot?

    private var claimsSuspendedUntil = Date.distantPast
    /// Pauses the "window will not leave the screen" rule; `.distantFuture` until a matching resume. Refusals
    /// counted so far, by parking and by the layout, are dropped: they were likely macOS, not the window.
    private func suspendClaims(until date: Date) {
        claimsSuspendedUntil = date
        state.attempts.removeAll()
        desktops.forgetReparkAttempts()
        Log.write("park", claimsSuspendedUntil == .distantFuture ? "pausing the refusal rule (sleep or lock)" : "refusal rule resumes in \(Int(claimsSuspendedUntil.timeIntervalSinceNow)) s")
    }

    /// Set by a layout reset: the state file was deleted on purpose and must not be written again on the way out.
    private var suppressSaves = false

    /// Unparks everything and deletes the saved layout for good: no later save, including the one on quit, rewrites it.
    func resetLayout() {
        suppressSaves = true
        prepareForQuit()
        try? FileManager.default.removeItem(at: Config.statePath)
    }

    /// Throttled, not debounced: the reconcile ticks every second, so a debounce would never fire.
    private func scheduleSave(_ snap: Snapshot) {
        guard config.restoreLayouts, !suppressSaves else { return }
        pendingSnapshot = snap
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func saveNow() {
        saveWork = nil
        guard config.restoreLayouts, !suppressSaves, var snap = pendingSnapshot else { return }
        // Parked windows sit in the screen corner; save the slot they belong to instead of that position.
        snap.windows = snap.windows.map { w in
            let v = desktops
            guard v.isParked(w.id) else { return w }
            var fixed = w
            if let slot = targetFrame(of: w.id) { fixed.frame = slot } else if let real = v.parkedFrame(of: w.id) { fixed.frame = real }
            return fixed
        }
        var layout = SavedLayout.capture(state, snap, floatingSpace: { w in
            self.desktops.isKnown(w.id) ? VirtualWorkspaces.spaceID(self.desktops.workspace(of: w.id)) : nil
        })
        // Desktops not active right now keep what was saved for them before.
        let activeSpaces = Set(snap.screens.map(\.space))
        let captured = Set(layout.spaces.map(\.id))
        layout.spaces += lastSaved.spaces.filter { !activeSpaces.contains($0.id) && !captured.contains($0.id) }
        layout.spaces.sort { $0.id < $1.id }
        layout.hiddenPids = desktops.hiddenPids.sorted()
        layout.desktopHomes = Dictionary(uniqueKeysWithValues: desktops.homes.map { (String($0.key), $0.value) })
        layout.shownOnDisplays = desktops.shownOn
        layout.activeDesktop = desktops.active
        guard layout != lastSaved else { return }
        lastSaved = layout
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Config.statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(layout).write(to: Config.statePath, options: .atomic)
    }

    /// Push the current desired state to the screen without re-reconciling; used during gestures and after edits.
    func apply() {
        var snap = system.lightSnapshot(tracked: tracked)
        markAway(&snap)
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
        for (w, now) in b.attempts where now.count >= DesiredState.maxAttempts && (a.attempts[w]?.count ?? 0) < DesiredState.maxAttempts {
            Log.write("layout", "\(describe(w)) refuses frame \(now.target); leaving it be until the layout changes")
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
        guard !state.isTiled(id), !desktops.isParked(id) else { return }
        floatingFrames[id] = frame ?? w.frame
    }
    /// After a drag or resize by hand that left the window floating, that is where it now belongs.
    func rememberFloatingFrame(_ w: AXWindow, frame: CGRect? = nil) {
        guard let id = id(w) else { return }
        rememberFloatingFrame(w, id, frame: frame)
    }

    /// `from` is where the window sat before the drag began; that, not the drop point, is its floating spot.
    func drop(_ w: AXWindow, into zone: DropZone, at p: CGPoint, from original: CGRect) {
        guard let id = id(w), let screen = screen(at: p) else { return }
        Log.write("tile", "drop \(describe(w)) into \(zone) on space \(screen.space)")
        rememberFloatingFrame(w, id, frame: original)
        desktops.claim(id, for: desktopShown(at: w.frame.center))
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
        desktops.claim(id, for: desktopShown(at: w.frame.center))
        guard let screen = screen(at: w.frame.center) else { return }
        let geo = reconciler.geometry(state.grid(for: screen.space), screen)
        state.mutate(screen.space) { $0.apply(.newColumn(index: geo.columnIndex(forX: w.frame.midX)), to: id) }
        state.seen[screen.space, default: []].insert(id)
        apply()
    }

    func toggleFocused() {
        guard let w = system.focused else { return }
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

    /// Called on mouse-up: the window moved or resized by hand leaves the grid and floats. Only that window;
    /// others may be off their slots merely because a desktop switch is still settling them.
    func releaseDisplacedWindow(_ id: WindowID) {
        guard state.isTiled(id) else { return }
        let snap = system.lightSnapshot(tracked: tracked)
        if reconciler.displaced(state, snap).contains(id) {
            Log.write("tile", "released by hand: \(describe(id))")
            state.untile(id)
        }
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
        let anchor = system.focused?.frame.center ?? NSEvent.mouseLocation.toAX()
        guard let screen = screen(at: anchor) else { return }
        state.mutate(screen.space) { $0.setMode($0.mode == .stacked ? .columns : .stacked) }
        Log.write("layout", "space \(screen.space) mode -> \(state.grid(for: screen.space).mode)")
        apply()
    }

    func layoutMode(forScreenAt p: CGPoint) -> LayoutMode {
        guard let screen = screen(at: p) else { return .columns }
        return state.grid(for: screen.space).mode
    }

    /// Grows or shrinks the focused window by `config.resizeStep`: a tiled one against its neighbours, a floating
    /// one around its centre, within its screen.
    func resizeFocused(grow: Bool) {
        guard let w = system.focused, let id = id(w) else { return }
        let delta = grow ? config.resizeStep : -config.resizeStep
        if let space = state.space(containing: id), let geo = geometry(for: space) {
            state.grids[space] = geo.resizing(window: id, by: delta)
            Log.write("layout", "\(grow ? "grow" : "shrink") \(describe(w)) by \(Int(config.resizeStep))")
            apply()
            return
        }
        let f = w.frame
        let target = fitToScreen(f.insetBy(dx: -delta, dy: -delta))
        guard target.width >= 100, target.height >= 80 else { return }
        w.frame = target
        rememberFloatingFrame(w, id, frame: target)
        Log.write("layout", "\(grow ? "grow" : "shrink") floating \(describe(w)) to \(Int(target.width))x\(Int(target.height))")
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
        guard let w = system.focused, let id = id(w) else { return false }
        guard let space = state.space(containing: id) else { return true }
        return state.grid(for: space).canMove(id, dir)
    }

    func moveFocused(_ dir: Move) {
        guard let w = system.focused, let id = id(w) else { return }
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
        guard let current = currentDesktop else { return }
        let others = windowsByDesktop().first(where: { $0.desktop == current })?.windows ?? []
        // Our own titled windows (Settings, Welcome) are not in the list: Accessibility calls into our own
        // process would stall the main thread. They join the cycle through AppKit instead.
        let own = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
        let count = others.count + own.count
        guard count > 0 else { return }
        var i: Int
        if NSApp.isActive, let key = NSApp.keyWindow, let k = own.firstIndex(of: key) {
            i = others.count + k
        } else if let f = system.focused, let k = others.firstIndex(of: f) {
            i = k
        } else {
            i = reverse ? 0 : count - 1
        }
        i = (i + (reverse ? -1 : 1) + count) % count
        if i < others.count {
            others[i].raise()
        } else {
            own[i - others.count].makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Focuses the window adjacent to the currently focused window in `dir` (i3-style directional focus).
    /// If tiled, navigates the grid's columns and rows, crossing to a neighbouring display at the outer edge,
    /// or wrapping within the grid. If floating, searches geometrically among visible windows.
    func focusWindow(in dir: Direction) {
        guard let current = currentDesktop else { return }
        let focused = system.focused
        let focusedID = focused.flatMap(id)

        if let curID = focusedID, let space = state.space(containing: curID) {
            let grid = state.grid(for: space)
            let screens = system.screens()
            let curScreen = screens.first { $0.space == space }

            if let curScreen, grid.isAtEdge(curID, dir) {
                let curFrame = targetFrame(of: curID) ?? focused?.frame ?? curScreen.area
                if let neighbor = adjacentScreen(to: curScreen, in: dir, allScreens: screens) {
                    let neighborGrid = state.grid(for: neighbor.space)
                    if !neighborGrid.isEmpty {
                        if let targetID = neighborGrid.entryWindow(from: dir, relativeTo: curFrame.center, in: neighbor.area) {
                            focusWindow(id: targetID)
                            Log.write("focus", "focus \(dir) -> \(targetID) on adjacent space \(neighbor.space)")
                            return
                        }
                    } else if let neighborDesktop = VirtualWorkspaces.workspace(of: neighbor.space) {
                        // No grid over there: the first window of the desktop that screen shows, in chip order.
                        let neighborWindows = windowsByDesktop().first(where: { $0.desktop == neighborDesktop })?.windows ?? []
                        if let first = neighborWindows.first {
                            first.raise()
                            if let fid = id(first) { focusRing.show(windowID: fid, frame: first.frame) }
                            Log.write("focus", "focus \(dir) -> \(describe(first)) on adjacent screen")
                            return
                        }
                    }
                }
            }

            if let targetID = grid.focusTarget(from: curID, in: dir) {
                focusWindow(id: targetID)
                Log.write("focus", "focus \(dir) -> \(targetID) in grid")
                return
            }
        }

        // Floating or untiled: the nearest window in that direction, by geometry.
        let desktopWindows = windowsByDesktop().first(where: { $0.desktop == current })?.windows ?? []
        guard !desktopWindows.isEmpty else { return }

        guard let curWin = focused, let curID = focusedID, desktopWindows.contains(curWin) else {
            if let lastID = lastFocusedWindow(onDesktop: current), let w = system.axWindow(lastID), w.isValid {
                focusWindow(id: lastID)
            } else if let first = desktopWindows.first {
                first.raise()
                if let fid = id(first) { focusRing.show(windowID: fid, frame: first.frame) }
            }
            return
        }

        let curFrame = targetFrame(of: curID) ?? curWin.frame
        let others = desktopWindows.filter { id($0) != curID }
        guard !others.isEmpty else { return }

        if let target = geometricTarget(from: curFrame, among: others, in: dir) {
            target.raise()
            if let tid = id(target) {
                let frame = targetFrame(of: tid) ?? target.frame
                focusRing.show(windowID: tid, frame: frame)
            }
            Log.write("focus", "focus \(dir) -> \(describe(target)) geometrically")
        }
    }

    private func focusWindow(id: WindowID) {
        guard let w = system.axWindow(id), w.isValid else { return }
        let frame = targetFrame(of: id) ?? w.frame
        focusRing.show(windowID: id, frame: frame)
        w.raise()
    }

    private func adjacentScreen(to current: ScreenInfo, in dir: Direction, allScreens: [ScreenInfo]) -> ScreenInfo? {
        let candidates = allScreens.filter { $0.space != current.space }
        switch dir {
        case .left:
            return candidates
                .filter { $0.area.maxX <= current.area.minX + 10 && $0.area.maxY > current.area.minY && $0.area.minY < current.area.maxY }
                .max(by: { $0.area.maxX < $1.area.maxX })
        case .right:
            return candidates
                .filter { $0.area.minX >= current.area.maxX - 10 && $0.area.maxY > current.area.minY && $0.area.minY < current.area.maxY }
                .min(by: { $0.area.minX < $1.area.minX })
        case .up:
            return candidates
                .filter { $0.area.maxY <= current.area.minY + 10 && $0.area.maxX > current.area.minX && $0.area.minX < current.area.maxX }
                .max(by: { $0.area.maxY < $1.area.maxY })
        case .down:
            return candidates
                .filter { $0.area.minY >= current.area.maxY - 10 && $0.area.maxX > current.area.minX && $0.area.minX < current.area.maxX }
                .min(by: { $0.area.minY < $1.area.minY })
        }
    }

    private func geometricTarget(from cur: CGRect, among candidates: [AXWindow], in dir: Direction) -> AXWindow? {
        func inDirection(_ f: CGRect) -> Bool {
            switch dir {
            case .left: return f.midX < cur.midX - 5
            case .right: return f.midX > cur.midX + 5
            case .up: return f.midY < cur.midY - 5
            case .down: return f.midY > cur.midY + 5
            }
        }
        func distanceScore(_ f: CGRect) -> CGFloat {
            let dx = abs(f.midX - cur.midX)
            let dy = abs(f.midY - cur.midY)
            switch dir {
            case .left, .right:
                return dx + dy * 2.5
            case .up, .down:
                return dy + dx * 2.5
            }
        }

        let inDir = candidates.filter { inDirection($0.frame) }
        if let best = inDir.min(by: { distanceScore($0.frame) < distanceScore($1.frame) }) {
            return best
        }
        switch dir {
        case .left: return candidates.max(by: { $0.frame.midX < $1.frame.midX })
        case .right: return candidates.min(by: { $0.frame.midX < $1.frame.midX })
        case .up: return candidates.max(by: { $0.frame.midY < $1.frame.midY })
        case .down: return candidates.min(by: { $0.frame.midY < $1.frame.midY })
        }
    }

    // MARK: Presets

    /// Windows the presets would arrange on the screen holding the focused window, in reading order.
    func presetCandidates() -> (SpaceID, [WindowID])? {
        let anchor = system.focused?.frame.center ?? NSEvent.mouseLocation.toAX()
        guard let screen = screen(at: anchor) else { return nil }
        let windows = system.lastSnapshotWindows
            .filter { screen.area.contains($0.frame.center) && system.spacesOfWindow($0.id).contains(screen.space) && !reconciler.isIgnored($0) }
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
        guard let w = system.focused else { return }
        send(w, toDesktop: index)
    }

    func send(_ w: AXWindow, toDesktop index: Int) {
        guard let id = id(w) else { return }
        let v = desktops
        guard index >= 0, index < 9, index != v.workspace(of: id) else { return }
        if index >= v.count { v.setCount(index + 1) }
        let wasTiled = isTiled(w)
        Log.write("desktop", "send \(describe(w)) to workspace \(index + 1) (tiled: \(wasTiled))")
        untile(w)
        v.move(id, to: index)
        // The sent window is still focused for a moment; don't let that pull us into its workspace.
        ignoreOwnFocusChanges()
        if wasTiled {
            // Pre-place it in the target workspace's grid so it is tiled when that workspace shows.
            let space = VirtualWorkspaces.spaceID(index)
            state.mutate(space) { $0.apply(.newColumn(index: $0.columns.count), to: id) }
            state.seen[space, default: []].insert(id)
        }
        tick { [weak self] in self?.focusTopWindow() }
    }

    /// Short, stable description of a window for the log: app, title, id.
    func describe(_ w: AXWindow) -> String {
        let app = w.bundleID?.split(separator: ".").last.map(String.init) ?? "?"
        return Log.includeTitles ? "\(app)/\"\(w.title.prefix(30))\"#\(w.windowID ?? 0)" : "\(app)#\(w.windowID ?? 0)"
    }
    func describe(_ id: WindowID) -> String { system.axWindow(id).map(describe) ?? "#\(id)" }

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
