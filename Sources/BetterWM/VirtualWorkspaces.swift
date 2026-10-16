import BetterWMCore
import Cocoa

/// Emulates several desktops on one macOS Space: each window belongs to a workspace, and windows of inactive
/// workspaces are parked just off the bottom-right corner of their screen (macOS won't let a window leave entirely).
final class VirtualWorkspaces {
    private(set) var active = 0
    private(set) var count: Int
    private var membership: [WindowID: Int] = [:]
    /// Real frames of floating windows while parked, restored when their workspace returns.
    private var parkedFrames: [WindowID: CGRect] = [:]
    private var parked: Set<WindowID> = []
    /// Last workspace each app had a window in, kept after the window is gone: an app that recreates its only
    /// window (Unity on scene reload or Play mode) has no siblings to follow, but it still has a home.
    private(set) var homeByPid: [pid_t: Int] = [:]

    func setCount(_ n: Int) {
        count = max(1, n)
        if active >= count { active = count - 1 }
        for (w, ws) in membership where ws >= count { membership[w] = count - 1 }
    }

    /// The macOS Space this set belongs to; every real desktop has its own independent set.
    let realSpace: SpaceID

    init(realSpace: SpaceID, count: Int) {
        self.realSpace = realSpace
        self.count = max(1, count)
    }

    /// Model Space ID for workspace `ws` on `screenIndex` within this set; stable across launches so saved layouts match.
    func spaceID(workspace ws: Int, screenIndex: Int) -> SpaceID { VirtualWorkspaces.spaceID(real: realSpace, workspace: ws, screenIndex: screenIndex) }

    static let base: SpaceID = 1_000_000_000
    static func spaceID(real: SpaceID, workspace ws: Int, screenIndex: Int) -> SpaceID {
        base + real * 10_000 + SpaceID(ws) * 100 + SpaceID(screenIndex)
    }
    static func isVirtual(_ id: SpaceID) -> Bool { id >= base }
    static func decode(_ id: SpaceID) -> (real: SpaceID, workspace: Int, screenIndex: Int)? {
        guard id >= base else { return nil }
        let rest = id - base
        return (rest / 10_000, Int((rest % 10_000) / 100), Int(rest % 100))
    }

    func workspace(of w: WindowID) -> Int { membership[w] ?? active }
    func isKnown(_ w: WindowID) -> Bool { membership[w] != nil }
    func isParked(_ w: WindowID) -> Bool { parked.contains(w) }
    var parkedWindows: Set<WindowID> { parked }
    /// The real frame of a parked floating window, if remembered.
    func parkedFrame(of w: WindowID) -> CGRect? { parkedFrames[w] }

    /// Unknown windows join the active workspace unless told otherwise.
    func adopt(_ w: WindowID, into ws: Int? = nil) { if membership[w] == nil { membership[w] = ws ?? active } }

    /// Workspaces holding windows of `ids` (an app's other windows), to keep a recreated window with its siblings.
    func workspaces(of ids: [WindowID]) -> Set<Int> { Set(ids.compactMap { membership[$0] }) }
    func rememberHomes(_ windows: [WindowInfo]) {
        for w in windows { if let ws = membership[w.id] { homeByPid[w.pid] = ws } }
    }
    func forget(_ w: WindowID) { membership[w] = nil; parkedFrames[w] = nil; parked.remove(w) }
    func move(_ w: WindowID, to ws: Int) { membership[w] = max(0, min(count - 1, ws)) }

    /// Claims a window for the active workspace and drops any parking state so the layout can place it.
    func claimForActive(_ w: WindowID) {
        membership[w] = active
        parked.remove(w)
        parkedFrames[w] = nil
    }
    func switchTo(_ ws: Int) { active = max(0, min(count - 1, ws)) }

    /// Drops trailing workspaces above the configured minimum once they hold no windows and aren't active.
    func trimEmptyTrailing(minimum: Int) {
        while count > max(1, minimum), count - 1 != active, !membership.values.contains(count - 1) {
            count -= 1
        }
    }

    /// Restores every parked floating window's real frame and forgets the parking state.
    func unparkAll(setFrame: (WindowID, CGRect) -> Void) {
        for (w, f) in parkedFrames { setFrame(w, f) }
        parkedFrames.removeAll()
        parked.removeAll()
    }

    /// Park/unpark according to membership. `frame(of:)` reads the current frame; `setFrame` writes one.
    /// Tiled windows are not restored here: their grid is laid out by the reconciler once the workspace is active.
    func apply(windows: [WindowID], isTiled: (WindowID) -> Bool, frame: (WindowID) -> CGRect?,
               setFrame: (WindowID, CGRect) -> Void, parkOrigin: (CGRect) -> CGPoint) {
        for w in windows {
            adopt(w)
            let shouldPark = workspace(of: w) != active
            if shouldPark, !parked.contains(w), let f = frame(w) {
                if !isTiled(w) { parkedFrames[w] = f }
                setFrame(w, CGRect(origin: parkOrigin(f), size: f.size))
                parked.insert(w)
                Log.write("park", "park #\(w) (workspace \(workspace(of: w) + 1), active \(active + 1))")
            } else if !shouldPark, parked.contains(w) {
                parked.remove(w)
                Log.write("park", "unpark #\(w)")
                if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, f) }
            }
        }
    }
}
