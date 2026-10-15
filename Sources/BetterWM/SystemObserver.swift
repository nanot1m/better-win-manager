import BetterWMCore
import Cocoa

/// Builds `Snapshot`s from the window list and Accessibility, and resolves window IDs back to AX handles.
final class SystemObserver {
    private var ax: [WindowID: AXWindow] = [:]
    /// Last good info per window: a hung app's windows keep their place in the model instead of being dropped.
    private var lastInfo: [WindowID: WindowInfo] = [:]
    /// Space to keep free at the top of each screen (the status bar), in points.
    var topInset: (NSScreen) -> CGFloat = { _ in 0 }
    /// Virtual workspaces: overrides the Space a screen shows and the Spaces a window belongs to.
    var spaceOverride: ((NSScreen) -> SpaceID)?
    var windowSpacesOverride: ((WindowID) -> [SpaceID])?

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
        // A fullscreen app's Space is not a desktop; never tile there.
        NSScreen.screens.filter { spaceOverride != nil || !Spaces.isFullscreen(Spaces.current(for: $0)) }.map { s in
            var area = s.visibleFrame.toCocoa()
            // The status bar is anchored to the screen's top edge; keep tiled windows below its bottom edge.
            let barBottom = s.frame.toCocoa().minY + topInset(s)
            if topInset(s) > 0, area.minY < barBottom {
                area.size.height -= barBottom - area.minY
                area.origin.y = barBottom
            }
            return ScreenInfo(space: spaceOverride?(s) ?? Spaces.current(for: s), area: area)
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
            infos.append(info(id, w))
        }
        for id in tracked where !seen.contains(id) {
            if let w = ax[id], AXResponsiveness.isUnresponsive(w.pid), let cached = lastInfo[id] {
                infos.append(cached)
                continue
            }
            guard let w = axWindow(id), w.isStandard else { continue }
            infos.append(info(id, w))
        }
        for i in infos { lastInfo[i.id] = i }
        return Snapshot(screens: screens(), windows: infos, focused: AXWindow.focused.flatMap { self.id(of: $0) })
    }

    /// Cheap variant for live interactions: only the tracked windows, read straight from their AX handles.
    func lightSnapshot(tracked: [WindowID]) -> Snapshot {
        let infos = tracked.compactMap { id -> WindowInfo? in
            guard let w = axWindow(id) else { return nil }
            return info(id, w)
        }
        return Snapshot(screens: screens(), windows: infos, focused: AXWindow.focused.flatMap { self.id(of: $0) })
    }

    private func info(_ id: WindowID, _ w: AXWindow) -> WindowInfo {
        WindowInfo(id: id, pid: w.pid, bundleID: w.bundleID, frame: w.frame,
                   spaces: windowSpacesOverride?(id) ?? Spaces.spaces(of: id), title: w.title)
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
