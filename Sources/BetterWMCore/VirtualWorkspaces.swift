import CoreGraphics
import Foundation

public typealias DisplayID = String

/// Emulates numbered desktops on top of one macOS desktop per display. Desktops are numbered globally; each has a
/// home display and every display shows one of its own at a time. Windows of desktops not shown anywhere are
/// parked just past a corner of their display (macOS won't let a window leave entirely).
public final class VirtualWorkspaces {
    /// The desktop of the display the user is working on; new windows and "current desktop" actions use it.
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
    /// Ignored re-parks in a row before a window is taken to belong where it is.
    public static let maxRefusals = 5
    public func forgetReparkAttempts() { reparkAttempts.removeAll() }
    public var knownWindows: [WindowID] { Array(membership.keys) }
    public var hiddenPids: [pid_t] { Array(hiddenByPid.keys) }
    /// Last workspace each app had a window in, kept after the window is gone: an app that recreates its only
    /// window (Unity on scene reload or Play mode) has no siblings to follow, but it still has a home.
    public private(set) var homeByPid: [pid_t: Int] = [:]

    /// Home display of each desktop, kept while that display is away: a desktop goes back when it returns.
    public private(set) var homes: [Int: DisplayID] = [:]
    /// The desktop each display showed last, kept while it is away.
    public private(set) var shownOn: [DisplayID: Int] = [:]
    /// Connected displays, main first.
    public private(set) var displays: [DisplayID] = []

    private let log: (String) -> Void

    public init(count: Int, log: @escaping (String) -> Void) {
        self.log = log
        self.count = max(1, count)
    }

    /// `n` is a floor: workspaces created on demand (and the shown ones) are never folded away by a config
    /// reload; only `trimEmptyTrailing` removes them, once they are empty.
    public func setCount(_ n: Int) {
        let highestUsed = (membership.values.max() ?? -1) + 1
        count = max(1, n, highestUsed, (shown.max() ?? 0) + 1)
        settleHomes()
    }

    /// A desktop lives where it was created, the main display; it keeps that home when another display becomes main.
    private func settleHomes() {
        guard let main else { return }
        for ws in 0..<count where homes[ws] == nil { homes[ws] = main }
    }

    // MARK: Identity

    public static let base: SpaceID = 1_000_000_000
    /// Model Space ID of a desktop; stable across launches so saved layouts match.
    public static func spaceID(_ ws: Int) -> SpaceID { base + SpaceID(ws) * 100 }
    public static func isVirtual(_ id: SpaceID) -> Bool { id >= base }
    public static func workspace(of id: SpaceID) -> Int? { id >= base ? Int((id - base) / 100) : nil }

    // MARK: Displays

    public var main: DisplayID? { displays.first }

    /// Where `ws` shows: its home display if connected, the main display otherwise.
    public func display(of ws: Int) -> DisplayID? {
        if let h = homes[ws], displays.contains(h) { return h }
        return main
    }

    public func desktops(on d: DisplayID) -> [Int] { (0..<count).filter { display(of: $0) == d } }

    /// The desktop `d` shows: the one it showed last if it still lives there, else its first.
    public func shownDesktop(on d: DisplayID) -> Int? {
        if let ws = shownOn[d], ws < count, display(of: ws) == d { return ws }
        return desktops(on: d).first
    }

    public var shown: Set<Int> { Set(displays.compactMap(shownDesktop(on:))) }
    public func isShown(_ ws: Int) -> Bool { shown.contains(ws) }

    /// Sets the connected displays, main first. A display that comes with no desktop of its own gets a new one;
    /// desktops whose display left show on the main display until it is back.
    public func connect(_ ds: [DisplayID]) {
        displays = ds
        guard let main = ds.first else { return }
        settleHomes()
        for d in ds where desktops(on: d).isEmpty {
            let ws = count
            count += 1
            homes[ws] = d
            log("display \(d.prefix(8)) gets new desktop \(ws + 1)")
        }
        if !shown.contains(active), let a = shownDesktop(on: display(of: active) ?? main) { active = a }
    }

    /// Moves desktop `ws` to display `d`, where it is shown; the display it left shows another of its own, or a
    /// new one if it has none left.
    public func send(desktop ws: Int, to d: DisplayID) {
        guard ws < count, displays.contains(d), let from = display(of: ws), from != d else { return }
        homes[ws] = d
        shownOn[d] = ws
        if desktops(on: from).isEmpty {
            homes[count] = from
            count += 1
        }
        if shownOn[from] == ws { shownOn[from] = nil }
        active = ws
    }

    // MARK: Membership

    public func workspace(of w: WindowID) -> Int { membership[w] ?? active }
    public func isKnown(_ w: WindowID) -> Bool { membership[w] != nil }
    public func isParked(_ w: WindowID) -> Bool { parked.contains(w) }
    public var parkedWindows: Set<WindowID> { parked }
    /// The real frame of a parked floating window, if remembered.
    public func parkedFrame(of w: WindowID) -> CGRect? { parkedFrames[w] }

    /// Unknown windows join `ws` (the active desktop unless told otherwise).
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
        homes = Dictionary(uniqueKeysWithValues: homes.map { (map[$0.key] ?? $0.key, $0.value) })
        shownOn = shownOn.mapValues { map[$0] ?? $0 }
        active = map[active] ?? active
        return map
    }

    /// Claims a window for desktop `ws` (the active one by default) and drops any parking state so the layout can place it.
    public func claim(_ w: WindowID, for ws: Int? = nil) {
        membership[w] = ws ?? active
        parked.remove(w)
        parkedFrames[w] = nil
    }

    /// Shows `ws` on its display and makes it the active desktop.
    public func switchTo(_ ws: Int) {
        let ws = max(0, min(count - 1, ws))
        if let d = display(of: ws) { shownOn[d] = ws }
        active = ws
    }

    /// Restores where desktops lived and what each display showed, from a saved layout.
    public func restore(homes h: [Int: DisplayID], shownOn s: [DisplayID: Int], active a: Int) {
        if let top = (Array(h.keys) + Array(s.values) + [a]).max(), top >= count { count = top + 1 }
        homes = h
        shownOn = s
        active = a
    }

    /// Drops trailing workspaces above the configured minimum once they hold no windows, aren't shown, and
    /// aren't the last desktop of their display.
    public func trimEmptyTrailing(minimum: Int) {
        while count > max(1, minimum), !isShown(count - 1), !membership.values.contains(count - 1),
              let d = display(of: count - 1), desktops(on: d).count > 1 {
            count -= 1
            homes[count] = nil
        }
    }

    /// Restores every parked floating window's real frame, unhides hidden apps, and forgets the parking state.
    public func unparkAll(setFrame: (WindowID, CGRect) -> Void, unhide: (pid_t) -> Void, fit: (WindowID, CGRect) -> CGRect = { $1 }) {
        for (w, f) in parkedFrames { setFrame(w, fit(w, f)) }
        for pid in hiddenByPid.keys { unhide(pid) }
        hiddenByPid.removeAll()
        parkedFrames.removeAll()
        parked.removeAll()
    }

    /// Park/unpark according to membership. An app whose windows are all on desktops not shown (and nowhere
    /// else, per `hideable`) is hidden natively; otherwise those windows go to the corner. `frame(of:)` reads the
    /// current frame; `setFrame` writes one. `parkOrigin` and `fit` place a window for its desktop's display.
    /// Tiled windows are not restored here: their grid is laid out by the reconciler once the desktop shows.
    public func apply(windows: [WindowID], pid: (WindowID) -> pid_t?, hideable: (pid_t) -> Bool,
               isTiled: (WindowID) -> Bool, frame: (WindowID) -> CGRect?,
               setFrame: (WindowID, CGRect) -> Void, parkOrigin: (WindowID, CGRect) -> CGPoint, isInCorner: (WindowID, CGRect) -> Bool,
               fit: (WindowID, CGRect) -> CGRect, hide: (pid_t) -> Void, unhide: (pid_t) -> Void,
               countRefusals: Bool, now: Date) {
        for w in windows { adopt(w) }
        let shown = self.shown
        // Hidden apps come back as soon as one of their windows is on a shown desktop, whether or not that
        // window is in this snapshot (floating windows of a hidden app are not on screen).
        for (p, ws) in hiddenByPid where ws.contains(where: { shown.contains(workspace(of: $0)) }) {
            unhide(p)
            hiddenByPid[p] = nil
            ws.forEach { parked.remove($0) }
            log("unhide app \(p)")
        }
        var byPid: [pid_t: [WindowID]] = [:]
        for w in windows { if let p = pid(w) { byPid[p, default: []].append(w) } }
        for (p, group) in byPid {
            let allInactive = group.allSatisfy { !shown.contains(workspace(of: $0)) }
            if allInactive, hideable(p) {
                if hiddenByPid[p] == nil {
                    hide(p)
                    log("hide app \(p) (\(group.count) window(s), all on desktops not shown)")
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
                let shouldPark = !shown.contains(workspace(of: w))
                if shouldPark, !parked.contains(w), let f = frame(w) {
                    if !isTiled(w) { parkedFrames[w] = f }
                    setFrame(w, CGRect(origin: parkOrigin(w, f), size: f.size))
                    parked.insert(w)
                    reparkAttempts[w] = nil
                    log("park #\(w) (desktop \(workspace(of: w) + 1), shown \(shown.sorted().map { $0 + 1 }))")
                } else if !shouldPark, parked.contains(w) {
                    parked.remove(w)
                    log("unpark #\(w)")
                    reparkAttempts[w] = nil
                    // Frames remembered on another display, or one that is gone, are fitted to the desktop's display.
                    if let f = parkedFrames.removeValue(forKey: w) { setFrame(w, fit(w, f)) }
                } else if shouldPark, parked.contains(w), let f = frame(w), !isInCorner(w, f) {
                    // Already parked but not in the corner: the move was lost (the app was mid-unhide, or it
                    // repositioned itself). Park again, spaced out. Only a window that ignored the move outright
                    // counts as refusing; after `maxRefusals` it is visible anyway, so it joins the active desktop.
                    let last = reparkAttempts[w]
                    if let last, now.timeIntervalSince(last.at) < 0.5 { continue }
                    let refused = countRefusals ? (last.map { $0.seen == f.origin ? $0.refused + 1 : 0 } ?? 0) : 0
                    if refused >= Self.maxRefusals {
                        claim(w)
                        reparkAttempts[w] = nil
                        log("#\(w) will not leave the screen; it now belongs to desktop \(active + 1)")
                        continue
                    }
                    if !isTiled(w), parkedFrames[w] == nil { parkedFrames[w] = f }
                    let target = parkOrigin(w, f)
                    reparkAttempts[w] = (refused, now, f.origin)
                    setFrame(w, CGRect(origin: target, size: f.size))
                    log("re-park #\(w) (was at \(Int(f.minX)),\(Int(f.minY)); corner \(Int(target.x)),\(Int(target.y)); refused \(refused))")
                }
            }
        }
    }
}
