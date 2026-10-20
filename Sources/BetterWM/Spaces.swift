import BetterWMCore
import Cocoa

/// Thin bridge to SkyLight's private Space API; there is no public way to identify the current Space.
/// Virtual workspaces live on one macOS desktop each, so only identification is needed: no switching, no moves.
enum Spaces {
    typealias SpaceID = UInt64

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let mainConnection: (@convention(c) () -> Int32)? = sym("CGSMainConnectionID")
    private static let currentSpace: (@convention(c) (Int32, CFString) -> SpaceID)? = sym("CGSManagedDisplayGetCurrentSpace")
    private static let managedDisplaySpaces: (@convention(c) (Int32) -> CFArray?)? = sym("CGSCopyManagedDisplaySpaces")
    private static let spacesForWindows: (@convention(c) (Int32, Int32, CFArray) -> CFArray?)? = sym("SLSCopySpacesForWindows")

    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static func current(for screen: NSScreen) -> SpaceID {
        guard let cid = mainConnection?(), let current = currentSpace,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { return 0 }
        return current(cid, CFUUIDCreateString(nil, uuid))
    }

    /// True when the Space is not a user desktop, i.e. a fullscreen app or split view (type 4).
    static func isFullscreen(_ space: SpaceID) -> Bool {
        guard let cid = mainConnection?(), let arr = managedDisplaySpaces?(cid) as? [[String: Any]] else { return false }
        for display in arr {
            for sp in display["Spaces"] as? [[String: Any]] ?? [] where (sp["id64"] as? SpaceID) == space {
                return (sp["type"] as? Int) != 0
            }
        }
        return false
    }

    /// Fullscreen and split-view Spaces on the display showing `space`, in Mission Control order.
    static func fullscreenSpaces(alongside space: SpaceID) -> [SpaceID] {
        guard let cid = mainConnection?(), let arr = managedDisplaySpaces?(cid) as? [[String: Any]] else { return [] }
        for display in arr {
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            guard spaces.contains(where: { ($0["id64"] as? SpaceID) == space }) else { continue }
            return spaces.filter { ($0["type"] as? Int) != 0 }.compactMap { $0["id64"] as? SpaceID }
        }
        return []
    }

    /// The Spaces either side of `space` in Mission Control order, on the display that holds it.
    static func neighbours(of space: SpaceID) -> (previous: SpaceID?, next: SpaceID?) {
        guard let cid = mainConnection?(), let arr = managedDisplaySpaces?(cid) as? [[String: Any]] else { return (nil, nil) }
        for display in arr {
            let ids = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? SpaceID }
            guard let i = ids.firstIndex(of: space) else { continue }
            return (i > 0 ? ids[i - 1] : nil, i + 1 < ids.count ? ids[i + 1] : nil)
        }
        return (nil, nil)
    }

    /// Ordinary windows on `space`, front to back, with their owners; a fullscreen Space has one (two in split view).
    static func windows(on space: SpaceID) -> [(id: CGWindowID, pid: pid_t)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(id: CGWindowID, pid: pid_t)] = []
        for info in list {
            // A fullscreen window sits at layer 26, not 0; the owner being an ordinary app is the real test.
            guard let layer = info[kCGWindowLayer as String] as? Int, (0...100).contains(layer),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 200,
                  spaces(of: id).contains(space) else { continue }
            out.append((id, pid))
        }
        return out
    }

    static func owners(on space: SpaceID) -> [pid_t] {
        var seen: [pid_t] = []
        for w in windows(on: space) where !seen.contains(w.pid) { seen.append(w.pid) }
        return seen
    }

    static func spaces(of windowID: CGWindowID) -> [SpaceID] {
        guard let cid = mainConnection?(), let f = spacesForWindows else { return [] }
        return (f(cid, 7, [NSNumber(value: windowID)] as CFArray) as? [SpaceID]) ?? []
    }

    /// Standard windows visible right now, i.e. on the active Spaces, front to back.
    /// Matched to Accessibility windows by window ID; frames are ambiguous when two windows overlap exactly.
    static func visibleWindows() -> [AXWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var axByPid: [pid_t: [(CGWindowID?, CGRect, AXWindow)]] = [:]
        var out: [AXWindow] = []
        var taken = Set<CGWindowID>()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if axByPid[pid] == nil {
                guard !AXResponsiveness.isUnresponsive(pid) else { axByPid[pid] = []; continue }
                var v: CFTypeRef?
                let err = AXUIElementCopyAttributeValue(AXResponsiveness.application(pid), kAXWindowsAttribute as CFString, &v)
                if err != .success { AXResponsiveness.noteFailure(pid, err) }
                axByPid[pid] = (v as? [AXUIElement] ?? []).map { AXWindow(element: $0, pid: pid) }
                    .filter(\.isStandard).map { ($0.windowID, $0.frame, $0) }
            }
            let candidates = axByPid[pid] ?? []
            let match = candidates.first { $0.0 == number }
                ?? candidates.first { $0.0 == nil && $0.1.approximatelyEquals(bounds, tolerance: 4) }
            guard let (_, _, w) = match, !taken.contains(number) else { continue }
            taken.insert(number)
            out.append(w)
        }
        return out
    }
}
