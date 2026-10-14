import BetterWMCore
import Cocoa

/// Builds `Snapshot`s from the window list and Accessibility, and resolves window IDs back to AX handles.
final class SystemObserver {
    private var ax: [WindowID: AXWindow] = [:]

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
        NSScreen.screens.map { ScreenInfo(space: Spaces.current(for: $0), area: $0.visibleFrame.toCocoa()) }
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
            guard let w = axWindow(id), w.isStandard else { continue }
            infos.append(info(id, w))
        }
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
        WindowInfo(id: id, pid: w.pid, bundleID: w.bundleID, frame: w.frame, spaces: Spaces.spaces(of: id))
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
