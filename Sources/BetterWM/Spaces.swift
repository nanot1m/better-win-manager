import BetterWMCore
import Cocoa
import SkyLightBridge

/// Thin bridge to SkyLight's private Space API; there is no public way to identify the current Space.
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

    /// User desktops of the main display in Mission Control order (fullscreen apps excluded).
    static func desktops() -> [SpaceID] {
        guard let cid = mainConnection?(), let arr = managedDisplaySpaces?(cid) as? [[String: Any]],
              let main = NSScreen.main, let display = arr.first(where: { ($0["Display Identifier"] as? String) == displayUUID(main) }) ?? arr.first,
              let spaces = display["Spaces"] as? [[String: Any]] else { return [] }
        return spaces.compactMap { ($0["type"] as? Int) == 0 ? ($0["id64"] as? SpaceID) : nil }
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

    private static func displayUUID(_ screen: NSScreen) -> String? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func currentDesktopIndex() -> Int? {
        guard let main = NSScreen.main else { return nil }
        return desktops().firstIndex(of: current(for: main))
    }

    static func switchToDesktop(_ index: Int) {
        guard let cur = currentDesktopIndex(), index != cur else { return }
        step(by: index - cur)
    }

    /// Consecutive swipes need a beat between them or the Dock drops the later ones.
    static func step(by delta: Int) {
        for i in 0..<abs(delta) {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(i * 150)) { swipe(toNext: delta > 0) }
        }
    }

    // Synthetic three-finger Dock swipe, the same event sequence the trackpad produces.
    // Private CGEvent field numbers reverse-engineered by the community (see joshuarli/iss).
    private enum Field {
        static let eventType = CGEventField(rawValue: 55)!
        static let hidType = CGEventField(rawValue: 110)!
        static let scrollY = CGEventField(rawValue: 119)!
        static let swipeMotion = CGEventField(rawValue: 123)!
        static let velocityX = CGEventField(rawValue: 129)!
        static let velocityY = CGEventField(rawValue: 130)!
        static let phase = CGEventField(rawValue: 132)!
        static let scrollFlagBits = CGEventField(rawValue: 135)!
        static let zoomDeltaX = CGEventField(rawValue: 139)!
    }
    private static let gestureEvent: Int64 = 29, dockControlEvent: Int64 = 30, dockSwipeHID: Int64 = 23, horizontal: Int64 = 1
    private static let phaseBegan: Int64 = 1, phaseChanged: Int64 = 2, phaseEnded: Int64 = 4

    static func swipe(toNext: Bool) {
        guard let cur = currentDesktopIndex() else { return }
        let count = desktops().count
        guard toNext ? cur + 1 < count : cur > 0 else { return }
        func dockEvent(_ phase: Int64) -> CGEvent? {
            guard let ev = CGEvent(source: nil) else { return nil }
            ev.setIntegerValueField(Field.eventType, value: dockControlEvent)
            ev.setIntegerValueField(Field.hidType, value: dockSwipeHID)
            ev.setIntegerValueField(Field.phase, value: phase)
            // The Dock reads this as a float; the smallest possible magnitude makes the switch instant.
            let direction: Float = toNext ? Float.leastNonzeroMagnitude : -Float.leastNonzeroMagnitude
            ev.setIntegerValueField(Field.scrollFlagBits, value: Int64(Int32(bitPattern: direction.bitPattern)))
            ev.setIntegerValueField(Field.swipeMotion, value: horizontal)
            ev.setDoubleValueField(Field.scrollY, value: 0)
            ev.setDoubleValueField(Field.zoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
            return ev
        }
        guard let began = dockEvent(phaseBegan), let changed = dockEvent(phaseChanged), let ended = dockEvent(phaseEnded) else { return }
        ended.setDoubleValueField(Field.velocityX, value: toNext ? 400 : -400)
        ended.setDoubleValueField(Field.velocityY, value: 0)
        for ev in [began, changed, ended] {
            guard let companion = CGEvent(source: nil) else { return }
            companion.setIntegerValueField(Field.eventType, value: gestureEvent)
            ev.post(tap: .cgSessionEventTap)
            companion.post(tap: .cgSessionEventTap)
        }
    }

    static func spaces(of windowID: CGWindowID) -> [SpaceID] {
        guard let cid = mainConnection?(), let f = spacesForWindows else { return [] }
        return (f(cid, 7, [NSNumber(value: windowID)] as CFArray) as? [SpaceID]) ?? []
    }

    /// Native move via SkyLight's bridged window-management operation (vendored from WhichSpace, MIT).
    /// Returns true once WindowServer confirms the window is on the target Space.
    static func moveWindow(_ windowID: CGWindowID, toSpace space: SpaceID, completion: @escaping (Bool) -> Void) {
        guard spaces(of: windowID).count == 1 else { completion(false); return }
        var issued = WSMoveBridged(windowID, space)
        if !issued, let cid = mainConnection?() { issued = WSMoveManagedSpace(cid, windowID, space) }
        guard issued else { completion(false); return }
        let deadline = Date().addingTimeInterval(1.5)
        func poll() {
            if spaces(of: windowID) == [space] { completion(true); return }
            guard Date() < deadline else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: poll)
        }
        poll()
    }

    static var nativeMoveAvailable: Bool { WSMoveBridgedIsAvailable() || WSMoveManagedSpaceIsAvailable() }

    /// Carries the focused window to another desktop by holding a synthetic drag on its title bar
    /// while switching Spaces, the same trick as dragging a window during a trackpad swipe.
    static func sendFocusedWindow(toDesktop target: Int, completion: ((AXWindow?) -> Void)? = nil) {
        guard let w = AXWindow.focused, let cur = currentDesktopIndex(),
              target != cur, (0..<desktops().count).contains(target) else { completion?(nil); return }
        if nativeMoveAvailable, let id = w.windowID {
            moveWindow(id, toSpace: desktops()[target]) { ok in
                if ok { switchToDesktop(target) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion?(ok ? w : nil) }
            }
            return
        }
        dragFocusedWindow(w, from: cur, toDesktop: target, completion: completion)
    }

    /// Fallback when the private operation is unavailable: hold a synthetic drag on the title bar across the switch.
    private static func dragFocusedWindow(_ w: AXWindow, from cur: Int, toDesktop target: Int, completion: ((AXWindow?) -> Void)?) {
        let f = w.frame
        // Right end of the title bar: clear of traffic lights and most browsers' tab strips.
        let grab = CGPoint(x: f.maxX - 40, y: f.minY + 10)
        func mouse(_ type: CGEventType, _ p: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            // A hotkey's modifiers may still be held; without this our own tap would treat the drag as ⌥-tiling.
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
        func key(_ code: CGKeyCode) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                e?.flags = .maskControl
                e?.post(tap: .cghidEventTap)
            }
        }
        w.raise()
        let q = DispatchQueue.main
        var t = 0.10
        func at(_ delay: Double, _ block: @escaping () -> Void) { t += delay; q.asyncAfter(deadline: .now() + t, execute: block) }
        at(0) { mouse(.leftMouseDown, grab) }
        at(0.08) { mouse(.leftMouseDragged, CGPoint(x: grab.x + 6, y: grab.y + 6)) }
        at(0.08) { mouse(.leftMouseDragged, CGPoint(x: grab.x + 12, y: grab.y + 12)) }
        let steps = abs(target - cur), code: CGKeyCode = target > cur ? 124 : 123
        for _ in 0..<steps {
            at(0.08) { key(code) }
            // Each slide animation must finish before the next step or the drop, or the window stays behind.
            at(0.75) { mouse(.leftMouseDragged, CGPoint(x: grab.x + 8, y: grab.y + 8)) }
        }
        at(0.10) { mouse(.leftMouseUp, CGPoint(x: grab.x + 8, y: grab.y + 8)) }
        at(0.20) { completion?(w) }
    }

    static func sendFocusedWindow(toNext: Bool, completion: ((AXWindow?) -> Void)? = nil) {
        guard let cur = currentDesktopIndex() else { completion?(nil); return }
        sendFocusedWindow(toDesktop: cur + (toNext ? 1 : -1), completion: completion)
    }

    /// Every standard window of every regular app, on any Space (Accessibility enumeration; slower than the window list).
    static func allWindows() -> [AXWindow] {
        var out: [AXWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &v)
            out += (v as? [AXUIElement] ?? []).map { AXWindow(element: $0, pid: app.processIdentifier) }.filter(\.isStandard)
        }
        return out
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
                var v: CFTypeRef?
                AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v)
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
