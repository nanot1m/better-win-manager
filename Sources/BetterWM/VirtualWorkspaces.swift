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
    /// Apps hidden with the native Hide because every window they have lives on an inactive workspace; hidden
    /// windows keep their real frames, so nothing peeks out of a screen corner.
    private var hiddenByPid: [pid_t: Set<WindowID>] = [:]
    private var reparkAttempts: [WindowID: Int] = [:]
    var knownWindows: [WindowID] { Array(membership.keys) }
    var hiddenPids: [pid_t] { Array(hiddenByPid.keys) }
    /// Last workspace each app had a window in, kept after the window is gone: an app that recreates its only
    /// window (Unity on scene reload or Play mode) has no siblings to follow, but it still has a home.
    private(set) var homeByPid: [pid_t: Int] = [:]

    /// `n` is a floor: workspaces created on demand (and the active one) are never folded away by a config
    /// reload; only `trimEmptyTrailing` removes them, once they are empty.
    func setCount(_ n: Int) {
        let highestUsed = (membership.values.max() ?? -1) + 1
        count = max(1, n, highestUsed, active + 1)
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
    /// A saved layout may name a workspace beyond the configured count (created on demand last time); it comes back.
    func move(_ w: WindowID, to ws: Int) {
        if ws >= count { setCount(ws + 1) }
        membership[w] = max(0, ws)
    }

    /// Moves workspace `from` to position `to`, shifting the ones in between. Returns old → new index for
    /// every workspace so callers can remap anything keyed by workspace.
    @discardableResult
    func moveWorkspace(from: Int, to: Int) -> [Int: Int] {
        guard from != to, (0..<count).contains(from), (0..<count).contains(to) else { return [:] }
        var order = Array(0..<count)
        order.remove(at: from)
        order.insert(from, at: to)
        var map: [Int: Int] = [:]
        for (newIndex, oldIndex) in order.enumerated() { map[oldIndex] = newIndex }
        membership = membership.mapValues { map[$0] ?? $0 }
        homeByPid = homeByPid.mapValues { map[$0] ?? $0 }
        active = map[active] ?? active
        return map
    }

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

    /// Restores every parked floating window's real frame, unhides hidden apps, and forgets the parking state.
    func unparkAll(setFrame: (WindowID, CGRect) -> Void, unhide: (pid_t) -> Void, fit: (CGRect) -> CGRect = { $0 }) {
        for (w, f) in parkedFrames { setFrame(w, fit(f)) }
        for pid in hiddenByPid.keys { unhide(pid) }
        hiddenByPid.removeAll()
        parkedFrames.removeAll()
        parked.removeAll()
    }

    /// Park/unpark according to membership. An app whose windows are all on inactive workspaces (and nowhere
    /// else, per `hideable`) is hidden natively; otherwise its inactive windows go to the corner. `frame(of:)`
    /// reads the current frame; `setFrame` writes one. Tiled windows are not restored here: their grid is laid
    /// out by the reconciler once the workspace is active.
    func apply(windows: [WindowID], pid: (WindowID) -> pid_t?, hideable: (pid_t) -> Bool,
               isTiled: (WindowID) -> Bool, frame: (WindowID) -> CGRect?,
               setFrame: (WindowID, CGRect) -> Void, parkOrigin: (CGRect) -> CGPoint, isInCorner: (CGRect) -> Bool,
               fit: (CGRect) -> CGRect, hide: (pid_t) -> Void, unhide: (pid_t) -> Void) {
        for w in windows { adopt(w) }
        // Hidden apps come back as soon as one of their windows is on the active workspace, whether or not
        // that window is in this snapshot (floating windows of a hidden app are not on screen).
        for (p, ws) in hiddenByPid where ws.contains(where: { workspace(of: $0) == active }) {
            unhide(p)
            hiddenByPid[p] = nil
            ws.forEach { parked.remove($0) }
            Log.write("park", "unhide app \(p)")
        }
        var byPid: [pid_t: [WindowID]] = [:]
        for w in windows { if let p = pid(w) { byPid[p, default: []].append(w) } }
        for (p, group) in byPid {
            let allInactive = group.allSatisfy { workspace(of: $0) != active }
            if allInactive, hideable(p) {
                if hiddenByPid[p] == nil {
                    // Anything already in the corner goes back to its real frame first; hidden is invisible anyway.
                    for w in group { if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, fit(f)) } }
                    hide(p)
                    Log.write("park", "hide app \(p) (\(group.count) window(s), all on inactive workspaces)")
                }
                hiddenByPid[p] = Set(group)
                parked.formUnion(group)
                continue
            }
            if let ws = hiddenByPid.removeValue(forKey: p) {
                unhide(p)
                ws.forEach { parked.remove($0) }
                Log.write("park", "unhide app \(p)")
            }
            for w in group {
                let shouldPark = workspace(of: w) != active
                if shouldPark, !parked.contains(w), let f = frame(w) {
                    if !isTiled(w) { parkedFrames[w] = f }
                    setFrame(w, CGRect(origin: parkOrigin(f), size: f.size))
                    parked.insert(w)
                    reparkAttempts[w] = nil
                    Log.write("park", "park #\(w) (workspace \(workspace(of: w) + 1), active \(active + 1))")
                } else if !shouldPark, parked.contains(w) {
                    parked.remove(w)
                    Log.write("park", "unpark #\(w)")
                    reparkAttempts[w] = nil
                    // Frames remembered on a screen that is gone (an unplugged monitor) are fitted to this one.
                    if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, fit(f)) }
                } else if shouldPark, parked.contains(w), let f = frame(w), !isInCorner(f) {
                    // Already parked but not in the corner: the move was lost (the app was mid-unhide, or it
                    // repositioned itself). Park again, but not forever: a window macOS refuses to move stays.
                    let attempts = reparkAttempts[w, default: 0]
                    if attempts < 3 {
                        reparkAttempts[w] = attempts + 1
                        let target = parkOrigin(f)
                        setFrame(w, CGRect(origin: target, size: f.size))
                        Log.write("park", "re-park #\(w) (was at \(Int(f.minX)),\(Int(f.minY)); corner \(Int(target.x)),\(Int(target.y)))")
                    }
                }
            }
        }
    }
}
