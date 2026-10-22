import BetterWMCore
import Cocoa

/// Builds `Snapshot`s from the window list and Accessibility, and resolves window IDs back to AX handles.
final class SystemObserver {
    private var ax: [WindowID: AXWindow] = [:]
    /// Last good info per window: a hung app's windows keep their place in the model instead of being dropped.
    private var lastInfo: [WindowID: WindowInfo] = [:]
    private var keptFromCache: Set<WindowID> = []
    private var lastReadAt: [WindowID: Date] = [:]

    private func hasExcuse(_ w: WindowInfo) -> Bool {
        if let readAt = lastReadAt[w.id], Date().timeIntervalSince(readAt) < 2 { return true }
        if AXResponsiveness.isUnresponsive(w.pid) { return true }
        if NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { return true }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return false
    }
    /// Space to keep free at the top of each screen (the status bar), in points.
    var topInset: (NSScreen) -> CGFloat = { _ in 0 }
    /// Virtual workspaces: overrides the Space a screen shows and the Spaces a window belongs to.
    /// Model Space of a screen / of a window: the virtual workspace ids the manager assigns.
    var spaceOf: (NSScreen) -> SpaceID = { Spaces.current(for: $0) }
    var spacesOfWindow: (WindowID) -> [SpaceID] = { Spaces.spaces(of: $0) }

    /// Windows closed by the user that their app keeps alive off every Space; the manager forgets them as if gone.
    private(set) var closedByApp: Set<WindowID> = []
    func forgetClosed(_ ids: Set<WindowID>) { closedByApp.subtract(ids) }

    func pid(of id: WindowID) -> pid_t? { ax[id]?.pid ?? lastInfo[id]?.pid }
    /// Frame from the last snapshot, without touching Accessibility.
    func lastFrame(of id: WindowID) -> CGRect? { lastInfo[id]?.frame }
    /// Windows in the most recent full snapshot. A window the user closed can stay alive in WindowServer
    /// (apps keep them for reuse) yet is gone from here.
    private(set) var inLastSnapshot: Set<WindowID> = []

    func axWindow(_ id: WindowID) -> AXWindow? {
        if let w = ax[id], w.isValid { return w }
        ax[id] = nil
        return nil
    }

    func id(of w: AXWindow) -> WindowID? {
        guard let id = w.windowID else { return nil }
        ax[id] = w
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
            return ScreenInfo(space: spaceOf(s), area: area)
        }
    }

    /// Full picture: everything on the active Spaces, plus any `tracked` window still resolvable even if
    /// momentarily off the on-screen list (mid-transition or on another Space).
    func snapshot(tracked: [WindowID]) -> Snapshot {
        var infos: [WindowInfo] = []
        var seen = Set<WindowID>()
        for w in Spaces.visibleWindows() {
            guard let id = id(of: w) else { continue }
            seen.insert(id)
            closedByApp.remove(id)
            infos.append(info(id, w))
        }
        // Window IDs WindowServer still knows, hidden or off screen included; computed only if needed.
        var aliveCache: Set<WindowID>?
        func alive(_ id: WindowID) -> Bool {
            if aliveCache == nil {
                aliveCache = CGWindowInfo.aliveIDs()
            }
            return aliveCache!.contains(id)
        }
        for id in tracked where !seen.contains(id) {
            if let w = ax[id], AXResponsiveness.isUnresponsive(w.pid), let cached = lastInfo[id] {
                infos.append(cached)
                continue
            }
            if let w = axWindow(id), w.isStandard {
                infos.append(info(id, w))
                lastReadAt[id] = Date()
                keptFromCache.remove(id)
                continue
            }
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
                // Some apps (ChatGPT, Calendar) keep a window alive after the user closes it; it is on no Space.
                // A window on another macOS desktop can be unreadable too, but it still has its Space.
                if alive(id), Spaces.spaces(of: id).isEmpty {
                    if closedByApp.insert(id).inserted { Log.write("snapshot", "#\(id) \(lastInfo[id]?.bundleID ?? "?") was closed but its app keeps it alive; forgetting it") }
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
        inLastSnapshot = Set(infos.map(\.id))
        return Snapshot(screens: screens(), windows: infos, focused: AXWindow.focused.flatMap { self.id(of: $0) }, now: Date())
    }

    /// Cheap variant for live interactions: only the tracked windows, read straight from their AX handles.
    func lightSnapshot(tracked: [WindowID]) -> Snapshot {
        let infos = tracked.compactMap { id -> WindowInfo? in
            guard let w = axWindow(id) else { return nil }
            return info(id, w)
        }
        return Snapshot(screens: screens(), windows: infos, focused: AXWindow.focused.flatMap { self.id(of: $0) }, now: Date())
    }

    private func info(_ id: WindowID, _ w: AXWindow) -> WindowInfo {
        WindowInfo(id: id, pid: w.pid, bundleID: w.bundleID, frame: w.frame,
                   spaces: spacesOfWindow(id), title: w.title)
    }

    func execute(_ commands: [Command]) {
        for c in commands {
            switch c {
            case let .setFrame(id, f): axWindow(id)?.frame = f
            case let .raise(id): axWindow(id)?.raise()
            }
        }
    }
}
