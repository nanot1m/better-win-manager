import BetterWMCore
import Cocoa

/// Builds `Snapshot`s from the window list and Accessibility, and resolves window IDs back to AX handles.
/// Accessibility work runs on `AX.queue`; results are published to the main thread, which reads only those.
final class SystemObserver {
    // MARK: Queue-side state (touched on AX.queue only)

    private var ax: [WindowID: AXWindow] = [:]
    /// Last good info per window: a hung app's windows keep their place in the model instead of being dropped.
    private var lastInfo: [WindowID: WindowInfo] = [:]
    private var keptFromCache: Set<WindowID> = []
    private var lastReadAt: [WindowID: Date] = [:]
    private var closedByAppQ: Set<WindowID> = []

    // MARK: Published state (main thread), refreshed after every snapshot

    private var axMain: [WindowID: AXWindow] = [:]
    private var lastInfoMain: [WindowID: WindowInfo] = [:]
    /// Windows in the most recent full snapshot. A window the user closed can stay alive in WindowServer
    /// (apps keep them for reuse) yet is gone from here.
    private(set) var inLastSnapshot: Set<WindowID> = []
    private(set) var lastSnapshotWindows: [WindowInfo] = []
    /// Windows closed by the user that their app keeps alive off every Space; the manager forgets them as if gone.
    private(set) var closedByApp: Set<WindowID> = []
    /// The frontmost app's focused standard window as of the last snapshot or `refreshFocused`.
    private(set) var focused: AXWindow?

    /// Space to keep free at the top of each screen (the status bar), in points.
    var topInset: (NSScreen) -> CGFloat = { _ in 0 }
    /// Space to keep free at the bottom (the resting hand), in points.
    var bottomInset: (NSScreen) -> CGFloat = { _ in 0 }
    /// Model Space of a screen / of a window: the virtual workspace ids the manager assigns.
    var spaceOf: (NSScreen) -> SpaceID = { Spaces.current(for: $0) }
    var spacesOfWindow: (WindowID) -> [SpaceID] = { Spaces.spaces(of: $0) }

    func forgetClosed(_ ids: Set<WindowID>) {
        closedByApp.subtract(ids)
        AX.queue.async { self.closedByAppQ.subtract(ids) }
    }

    func pid(of id: WindowID) -> pid_t? { axMain[id]?.pid ?? lastInfoMain[id]?.pid }
    /// Frame from the last snapshot, without touching Accessibility.
    func lastFrame(of id: WindowID) -> CGRect? { lastInfoMain[id]?.frame }

    /// The handle the last snapshot resolved for a window; answers from its cache off the queue.
    func axWindow(_ id: WindowID) -> AXWindow? { axMain[id] }

    func id(of w: AXWindow) -> WindowID? {
        guard let id = w.windowID else { return nil }
        axMain[id] = w
        return id
    }

    func screens() -> [ScreenInfo] {
        NSScreen.screens.map { s in
            var area = s.visibleFrame.toCocoa()
            // The status bar is anchored to the screen's top edge; keep tiled windows below its bottom edge.
            let barBottom = s.frame.toCocoa().minY + topInset(s)
            if topInset(s) > 0, area.minY < barBottom {
                area.size.height -= barBottom - area.minY
                area.origin.y = barBottom
            }
            let handTop = s.frame.toCocoa().maxY - bottomInset(s)
            if bottomInset(s) > 0, area.maxY > handTop { area.size.height -= area.maxY - handTop }
            return ScreenInfo(space: spaceOf(s), area: area)
        }
    }

    // MARK: Snapshots

    /// Full picture: everything on the active Spaces, plus any `tracked` window still resolvable even if
    /// momentarily off the on-screen list (mid-transition or on another Space). Taken on the AX queue;
    /// `completion` runs on the main thread with the result.
    func snapshot(tracked: [WindowID], completion: @escaping (Snapshot) -> Void) {
        let shownSpaces = Set(NSScreen.screens.map { Spaces.current(for: $0) })
        AX.queue.async {
            let (infos, focused, closed) = self.take(tracked: tracked, shownSpaces: shownSpaces)
            let handles = self.ax
            DispatchQueue.main.async {
                self.publish(infos, handles: handles, focused: focused, closed: closed)
                completion(self.assemble(infos))
            }
        }
    }

    private func take(tracked: [WindowID], shownSpaces: Set<SpaceID>) -> ([WindowInfo], AXWindow?, Set<WindowID>) {
        var infos: [WindowInfo] = []
        var seen = Set<WindowID>()
        for w in Spaces.visibleWindows() {
            guard let id = w.windowID else { continue }
            ax[id] = w
            seen.insert(id)
            closedByAppQ.remove(id)
            infos.append(info(id, w))
        }
        // Window IDs WindowServer still knows, hidden or off screen included; computed only if needed.
        var aliveCache: Set<WindowID>?
        func alive(_ id: WindowID) -> Bool {
            if aliveCache == nil { aliveCache = CGWindowInfo.aliveIDs() }
            return aliveCache!.contains(id)
        }
        for id in tracked where !seen.contains(id) {
            if let w = ax[id], AXResponsiveness.isUnresponsive(w.pid), let cached = lastInfo[id] {
                infos.append(cached)
                continue
            }
            if let w = ax[id], w.isValid, w.isStandard {
                infos.append(info(id, w))
                lastReadAt[id] = Date()
                keptFromCache.remove(id)
                continue
            }
            ax[id] = nil
            // Accessibility can fail for a window that still exists: the app is hidden or just unhiding, hung, or
            // the screen is locked. Dropping it would untile it, so keep the last known picture while one of those
            // holds. A window merely kept off screen by its app after the user closed it has no such excuse.
            if let cached = lastInfo[id], alive(id), hasExcuse(cached) {
                infos.append(cached)
                // The excuse keeps the grace window open, so an app that was hidden for an hour still gets the
                // two seconds it needs to become readable after unhiding.
                lastReadAt[id] = Date()
                if keptFromCache.insert(id).inserted { Log.write("snapshot", "#\(id) unreadable via Accessibility but alive; keeping last known state") }
            } else {
                keptFromCache.remove(id)
                // Some apps keep a window alive after the user closes it: on no Space (ChatGPT, Calendar), or on a
                // Space being shown yet not on screen (Codex). A window on another macOS desktop can be unreadable
                // too, but its Space is not one being shown. Parked windows stay two points on screen.
                if alive(id), closedByItsApp(id, shownSpaces: shownSpaces) {
                    if closedByAppQ.insert(id).inserted { Log.write("snapshot", "#\(id) \(lastInfo[id]?.bundleID ?? "?") was closed but its app keeps it alive; forgetting it") }
                    continue
                }
                if let cached = lastInfo[id] {
                    let app = NSRunningApplication(processIdentifier: cached.pid)
                    let age = lastReadAt[id].map { Int(Date().timeIntervalSince($0)) } ?? -1
                    Log.write("snapshot", "#\(id) \(cached.bundleID ?? "?") left the snapshot: alive=\(alive(id)) hidden=\(app?.isHidden ?? false) unresponsive=\(AXResponsiveness.isUnresponsive(cached.pid)) lastRead=\(age)s ago")
                }
            }
        }
        for i in infos { lastInfo[i.id] = i }
        let focused = AXWindow.focused()
        if let focused, let id = focused.windowID { ax[id] = focused }
        return (infos, focused, closedByAppQ)
    }

    private func hasExcuse(_ w: WindowInfo) -> Bool {
        if let readAt = lastReadAt[w.id], Date().timeIntervalSince(readAt) < 2 { return true }
        if AXResponsiveness.isUnresponsive(w.pid) { return true }
        if NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { return true }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return false
    }

    /// A closed window is gone from Accessibility (`ax[id]` was just dropped); a minimized one is still there.
    private func closedByItsApp(_ id: WindowID, shownSpaces: Set<SpaceID>) -> Bool {
        let spaces = Spaces.spaces(of: id)
        if spaces.isEmpty { return true }
        return spaces.allSatisfy(shownSpaces.contains) && !CGWindowInfo.isOnScreen(id)
    }

    /// Spaces are the manager's business and main-thread state; the queue leaves them empty.
    private func info(_ id: WindowID, _ w: AXWindow) -> WindowInfo {
        WindowInfo(id: id, pid: w.pid, bundleID: w.bundleID, frame: w.frame, spaces: [], title: w.title)
    }

    private func publish(_ infos: [WindowInfo], handles: [WindowID: AXWindow], focused: AXWindow?, closed: Set<WindowID>) {
        for i in infos { lastInfoMain[i.id] = i }
        inLastSnapshot = Set(infos.map(\.id))
        lastSnapshotWindows = infos
        closedByApp = closed
        self.focused = focused
        axMain = handles
    }

    private func assemble(_ infos: [WindowInfo]) -> Snapshot {
        let windows = infos.map { i in
            var w = i
            w.spaces = spacesOfWindow(i.id)
            return w
        }
        return Snapshot(screens: screens(), windows: windows, focused: focused.flatMap { $0.windowID }, now: Date())
    }

    /// Cheap variant for live interactions, no Accessibility at all: frames straight from WindowServer for the
    /// tracked windows the last snapshot knew.
    func lightSnapshot(tracked: [WindowID]) -> Snapshot {
        // Front to back like a full snapshot, in the order the last one saw: a tabbed stack reads its front from it.
        let depth = Dictionary(uniqueKeysWithValues: lastSnapshotWindows.enumerated().map { ($1.id, $0) })
        let infos = tracked.sorted { (depth[$0] ?? .max, $0) < (depth[$1] ?? .max, $1) }.compactMap { id -> WindowInfo? in
            guard var i = lastInfoMain[id], axMain[id] != nil else { return nil }
            if let f = WindowServerEvents.bounds(of: id) { i.frame = f }
            i.spaces = spacesOfWindow(id)
            return i
        }
        return Snapshot(screens: screens(), windows: infos, focused: focused.flatMap { $0.windowID }, now: Date())
    }

    /// Re-reads the focused window (after a focus or title change) and calls back on the main thread.
    func refreshFocused(_ completion: @escaping () -> Void) {
        AX.queue.async {
            let f = AXWindow.focused()
            if let f, let id = f.windowID { self.ax[id] = f }
            DispatchQueue.main.async {
                self.focused = f
                if let f, let id = f.windowID { self.axMain[id] = f }
                completion()
            }
        }
    }

    /// The window under `point`, resolved on the queue; `completion` runs on the main thread.
    func hitTest(_ point: CGPoint, _ completion: @escaping (AXWindow?) -> Void) {
        AX.queue.async {
            let w = AXWindow.at(point: point)
            if let w, let id = w.windowID { self.ax[id] = w }
            DispatchQueue.main.async {
                if let w, let id = w.windowID { self.axMain[id] = w }
                completion(w)
            }
        }
    }

    // MARK: Commands

    func execute(_ commands: [Command]) {
        AX.queue.async { self.run(commands) }
    }

    private func run(_ commands: [Command]) {
        for c in commands {
            switch c {
            case let .setFrame(id, f): self.ax[id]?.frame = f
            case let .raise(id): self.ax[id]?.raise()
            }
        }
    }

    private let liveLock = NSLock()
    private var liveGeneration = 0

    /// For a live gesture (a handle drag): only the newest batch is worth carrying out. Some apps take a hundred
    /// milliseconds per frame change, so queuing every mouse move would leave the windows trailing the pointer
    /// long after it stopped.
    func executeLatest(_ commands: [Command]) {
        liveLock.lock()
        liveGeneration += 1
        let generation = liveGeneration
        liveLock.unlock()
        AX.queue.async {
            self.liveLock.lock()
            let stale = generation != self.liveGeneration
            self.liveLock.unlock()
            if !stale { self.run(commands) }
        }
    }

    /// Blocks until every command sent so far has been carried out; for quitting.
    func waitForCommands() { AX.queue.sync {} }
}
