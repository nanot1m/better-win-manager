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

    init(count: Int) { self.count = max(1, count) }

    func setCount(_ n: Int) {
        count = max(1, n)
        if active >= count { active = count - 1 }
        for (w, ws) in membership where ws >= count { membership[w] = count - 1 }
    }

    /// Space ID used in the model for workspace `ws` on `screen`; stable across launches so saved layouts match.
    func spaceID(workspace ws: Int, screenIndex: Int) -> SpaceID { 1_000_000 + SpaceID(ws) * 100 + SpaceID(screenIndex) }

    func workspace(of w: WindowID) -> Int { membership[w] ?? active }
    func isKnown(_ w: WindowID) -> Bool { membership[w] != nil }
    func isParked(_ w: WindowID) -> Bool { parked.contains(w) }
    /// The real frame of a parked floating window, if remembered.
    func parkedFrame(of w: WindowID) -> CGRect? { parkedFrames[w] }

    /// Unknown windows join the active workspace.
    func adopt(_ w: WindowID) { if membership[w] == nil { membership[w] = active } }
    func forget(_ w: WindowID) { membership[w] = nil; parkedFrames[w] = nil; parked.remove(w) }
    func move(_ w: WindowID, to ws: Int) { membership[w] = max(0, min(count - 1, ws)) }
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
            } else if !shouldPark, parked.contains(w) {
                parked.remove(w)
                if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, f) }
            }
        }
    }
}
