import CoreGraphics
import Foundation

/// Emulates several desktops on one macOS Space: each window belongs to a workspace, and windows of inactive
/// workspaces are parked just off the bottom-right corner of their screen (macOS won't let a window leave entirely).
public final class VirtualWorkspaces {
    public private(set) var active = 0
    public private(set) var count: Int
    private var membership: [WindowID: Int] = [:]
    /// Real frames of floating windows while parked, restored when their workspace returns.
    private var parkedFrames: [WindowID: CGRect] = [:]
    private var parked: Set<WindowID> = []
    /// Apps hidden with the native Hide because every window they have lives on an inactive workspace. Windows
    /// already parked stay in the corner while hidden: moving them back would race the unhide later.
    private var hiddenByPid: [pid_t: Set<WindowID>] = [:]
    /// Consecutive re-parks a window ignored outright, with the frame seen before the last one and its time.
    private var reparkAttempts: [WindowID: (refused: Int, at: Date, seen: CGPoint)] = [:]
    /// While a display is being connected or removed macOS ignores moves for a while; that is not a window
    /// refusing to leave, so no window is claimed for the active workspace until this passes.
    public var claimsSuspendedUntil = Date.distantPast
    public func forgetReparkAttempts() { reparkAttempts.removeAll() }
    public var knownWindows: [WindowID] { Array(membership.keys) }
    public var hiddenPids: [pid_t] { Array(hiddenByPid.keys) }
    /// Last workspace each app had a window in, kept after the window is gone: an app that recreates its only
    /// window (Unity on scene reload or Play mode) has no siblings to follow, but it still has a home.
    public private(set) var homeByPid: [pid_t: Int] = [:]

    /// `n` is a floor: workspaces created on demand (and the active one) are never folded away by a config
    /// reload; only `trimEmptyTrailing` removes them, once they are empty.
    public func setCount(_ n: Int) {
        let highestUsed = (membership.values.max() ?? -1) + 1
        count = max(1, n, highestUsed, active + 1)
    }

    /// The macOS Space this set belongs to; every real desktop has its own independent set.
    public let realSpace: SpaceID

    private let log: (String) -> Void

    public init(realSpace: SpaceID, count: Int, log: @escaping (String) -> Void) {
        self.realSpace = realSpace
        self.log = log
        self.count = max(1, count)
    }

    /// Model Space ID for workspace `ws` on `screenIndex` within this set; stable across launches so saved layouts match.
    public func spaceID(workspace ws: Int, screenIndex: Int) -> SpaceID { VirtualWorkspaces.spaceID(real: realSpace, workspace: ws, screenIndex: screenIndex) }

    public static let base: SpaceID = 1_000_000_000
    public static func spaceID(real: SpaceID, workspace ws: Int, screenIndex: Int) -> SpaceID {
        base + real * 10_000 + SpaceID(ws) * 100 + SpaceID(screenIndex)
    }
    public static func isVirtual(_ id: SpaceID) -> Bool { id >= base }
    public static func decode(_ id: SpaceID) -> (real: SpaceID, workspace: Int, screenIndex: Int)? {
        guard id >= base else { return nil }
        let rest = id - base
        return (rest / 10_000, Int((rest % 10_000) / 100), Int(rest % 100))
    }

    public func workspace(of w: WindowID) -> Int { membership[w] ?? active }
    public func isKnown(_ w: WindowID) -> Bool { membership[w] != nil }
    public func isParked(_ w: WindowID) -> Bool { parked.contains(w) }
    public var parkedWindows: Set<WindowID> { parked }
    /// The real frame of a parked floating window, if remembered.
    public func parkedFrame(of w: WindowID) -> CGRect? { parkedFrames[w] }

    /// Unknown windows join the active workspace unless told otherwise.
    public func adopt(_ w: WindowID, into ws: Int? = nil) { if membership[w] == nil { membership[w] = ws ?? active } }

    /// Workspaces holding windows of `ids` (an app's other windows), to keep a recreated window with its siblings.
    public func workspaces(of ids: [WindowID]) -> Set<Int> { Set(ids.compactMap { membership[$0] }) }
    public func rememberHomes(_ windows: [WindowInfo]) {
        for w in windows { if let ws = membership[w.id] { homeByPid[w.pid] = ws } }
    }
    public func forget(_ w: WindowID) { membership[w] = nil; parkedFrames[w] = nil; parked.remove(w) }
    /// A saved layout may name a workspace beyond the configured count (created on demand last time); it comes back.
    public func move(_ w: WindowID, to ws: Int) {
        if ws >= count { setCount(ws + 1) }
        membership[w] = max(0, ws)
    }

    /// Moves workspace `from` to position `to`, shifting the ones in between. Returns old → new index for
    /// every workspace so callers can remap anything keyed by workspace.
    @discardableResult
    public func moveWorkspace(from: Int, to: Int) -> [Int: Int] {
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
    public func claimForActive(_ w: WindowID) {
        membership[w] = active
        parked.remove(w)
        parkedFrames[w] = nil
    }
    public func switchTo(_ ws: Int) { active = max(0, min(count - 1, ws)) }

    /// Drops trailing workspaces above the configured minimum once they hold no windows and aren't active.
    public func trimEmptyTrailing(minimum: Int) {
        while count > max(1, minimum), count - 1 != active, !membership.values.contains(count - 1) {
            count -= 1
        }
    }

    /// Restores every parked floating window's real frame, unhides hidden apps, and forgets the parking state.
    public func unparkAll(setFrame: (WindowID, CGRect) -> Void, unhide: (pid_t) -> Void, fit: (CGRect) -> CGRect = { $0 }) {
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
    public func apply(windows: [WindowID], pid: (WindowID) -> pid_t?, hideable: (pid_t) -> Bool,
               isTiled: (WindowID) -> Bool, frame: (WindowID) -> CGRect?,
               setFrame: (WindowID, CGRect) -> Void, parkOrigin: (CGRect) -> CGPoint, isInCorner: (CGRect) -> Bool,
               fit: (CGRect) -> CGRect, hide: (pid_t) -> Void, unhide: (pid_t) -> Void, now: Date) {
        for w in windows { adopt(w) }
        // Hidden apps come back as soon as one of their windows is on the active workspace, whether or not
        // that window is in this snapshot (floating windows of a hidden app are not on screen).
        for (p, ws) in hiddenByPid where ws.contains(where: { workspace(of: $0) == active }) {
            unhide(p)
            hiddenByPid[p] = nil
            ws.forEach { parked.remove($0) }
            log("unhide app \(p)")
        }
        var byPid: [pid_t: [WindowID]] = [:]
        for w in windows { if let p = pid(w) { byPid[p, default: []].append(w) } }
        for (p, group) in byPid {
            let allInactive = group.allSatisfy { workspace(of: $0) != active }
            if allInactive, hideable(p) {
                if hiddenByPid[p] == nil {
                    hide(p)
                    log("hide app \(p) (\(group.count) window(s), all on inactive workspaces)")
                }
                hiddenByPid[p] = Set(group)
                parked.formUnion(group)
                continue
            }
            if let ws = hiddenByPid.removeValue(forKey: p) {
                unhide(p)
                ws.forEach { parked.remove($0) }
                log("unhide app \(p)")
            }
            for w in group {
                let shouldPark = workspace(of: w) != active
                if shouldPark, !parked.contains(w), let f = frame(w) {
                    if !isTiled(w) { parkedFrames[w] = f }
                    setFrame(w, CGRect(origin: parkOrigin(f), size: f.size))
                    parked.insert(w)
                    reparkAttempts[w] = nil
                    log("park #\(w) (workspace \(workspace(of: w) + 1), active \(active + 1))")
                } else if !shouldPark, parked.contains(w) {
                    parked.remove(w)
                    log("unpark #\(w)")
                    reparkAttempts[w] = nil
                    // Frames remembered on a screen that is gone (an unplugged monitor) are fitted to this one.
                    if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, fit(f)) }
                } else if shouldPark, parked.contains(w), let f = frame(w), !isInCorner(f) {
                    // Already parked but not in the corner: the move was lost (the app was mid-unhide, or it
                    // repositioned itself). Park again, spaced out. Only a window that ignored the move outright
                    // counts as refusing; after three refusals it is visible anyway, so it joins the active workspace.
                    let last = reparkAttempts[w]
                    if let last, now.timeIntervalSince(last.at) < 0.5 { continue }
                    // Ignored moves while displays are being rearranged say nothing about the window; don't count them.
                    let settling = now < claimsSuspendedUntil
                    let refused = settling ? 0 : (last.map { $0.seen == f.origin ? $0.refused + 1 : 0 } ?? 0)
                    if refused >= 5 {
                        claimForActive(w)
                        reparkAttempts[w] = nil
                        log("#\(w) will not leave the screen; it now belongs to workspace \(active + 1)")
                        continue
                    }
                    if !isTiled(w), parkedFrames[w] == nil { parkedFrames[w] = f }
                    let target = parkOrigin(f)
                    reparkAttempts[w] = (refused, now, f.origin)
                    setFrame(w, CGRect(origin: target, size: f.size))
                    log("re-park #\(w) (was at \(Int(f.minX)),\(Int(f.minY)); corner \(Int(target.x)),\(Int(target.y)); refused \(refused))")
                }
            }
        }
    }
}
