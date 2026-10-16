import BetterWMCore
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility calls are synchronous messages to the target app; a hung app would stall us for the default
/// 6 s per call. Every element we touch gets this timeout, and apps that time out are skipped for a while.
enum AXResponsiveness {
    static let timeout: Float = 0.3
    private static var unresponsiveUntil: [pid_t: Date] = [:]

    static func tune(_ element: AXUIElement) { AXUIElementSetMessagingTimeout(element, timeout) }

    static func isUnresponsive(_ pid: pid_t) -> Bool {
        guard let until = unresponsiveUntil[pid] else { return false }
        if Date() < until { return true }
        unresponsiveUntil[pid] = nil
        return false
    }

    /// Call after an AX request fails with a timeout-class error.
    static func noteFailure(_ pid: pid_t, _ error: AXError) {
        guard error == .cannotComplete || error == .notificationUnsupported else { return }
        if unresponsiveUntil[pid] == nil {
            Log.write("ax", "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)") is not responding; skipping it for 5 s")
        }
        unresponsiveUntil[pid] = Date().addingTimeInterval(5)
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        tune(el)
        return el
    }
}

final class AXWindow: Hashable {
    let element: AXUIElement
    let pid: pid_t

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        AXResponsiveness.tune(element)
    }

    static func == (a: AXWindow, b: AXWindow) -> Bool { CFEqual(a.element, b.element) }
    func hash(into h: inout Hasher) { h.combine(CFHash(element)) }

    /// CGWindowID via the undocumented but long-stable _AXUIElementGetWindow.
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? id : nil
    }

    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    var isValid: Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v) == .success
    }

    var isStandard: Bool {
        var sub: CFTypeRef?, role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        return role as? String == kAXWindowRole && sub as? String == kAXStandardWindowSubrole
            && (minimized as? Bool) != true
    }

    var title: String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &v)
        return v as? String ?? ""
    }

    var frame: CGRect {
        get {
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            if err != .success { AXResponsiveness.noteFailure(pid, err) }
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            return CGRect(origin: pos, size: size)
        }
        set {
            var pos = newValue.origin, size = newValue.size
            // Shrink first so the position is not clamped by the old size at screen edges.
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
            if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
        }
    }

    func setOrigin(_ origin: CGPoint) {
        var pos = origin
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static var focused: AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, !AXResponsiveness.isUnresponsive(app.processIdentifier) else { return nil }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXResponsiveness.application(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &v)
        guard err == .success, let v else { AXResponsiveness.noteFailure(app.processIdentifier, err); return nil }
        let w = AXWindow(element: v as! AXUIElement, pid: app.processIdentifier)
        return w.isStandard ? w : nil
    }

    /// Top-left-origin global coordinates, matching what AX uses.
    static func at(point: CGPoint) -> AXWindow? {
        axHitTest(point) ?? windowListHitTest(point)
    }

    /// Some apps (Telegram among them) fail AX hit-testing on custom views; fall back to the window list.
    private static func windowListHitTest(_ point: CGPoint) -> AXWindow? {
        Spaces.visibleWindows().first { $0.frame.contains(point) }
    }

    private static func axHitTest(_ point: CGPoint) -> AXWindow? {
        var el: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        AXResponsiveness.tune(systemWide)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el) == .success,
              var cur = el else { return nil }
        AXResponsiveness.tune(cur)
        var pid: pid_t = 0
        AXUIElementGetPid(cur, &pid)
        if pid == getpid() { return nil }
        while true {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXWindowRole { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent else { return nil }
            cur = p as! AXUIElement
        }
        let w = AXWindow(element: cur, pid: pid)
        return w.isStandard ? w : nil
    }
}
