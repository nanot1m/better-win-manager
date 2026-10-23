import BetterWMCore
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Accessibility calls are synchronous messages to the target app; a hung app (Unity compiling) would stall us
/// for the default 6 s per call, and the main thread with us. Every element we touch gets a short timeout, and an
/// app that times out once is left alone: no main-thread call reaches it until a probe off the main thread finds
/// it answering again. Probes back off up to ten seconds.
enum AXResponsiveness {
    static let timeout: Float = 0.3
    private struct Backoff { var delay: TimeInterval; var probing = false; var since: Date }
    /// Main-thread state.
    private static var backoffs: [pid_t: Backoff] = [:]
    private static let probeQueue = DispatchQueue(label: "betterwm.axprobe", qos: .utility)
    /// Called on the main thread when an app answers again, so its windows are picked up right away.
    static var onBackoffEnd: (() -> Void)?

    static func tune(_ element: AXUIElement) { AXUIElementSetMessagingTimeout(element, timeout) }

    static func isUnresponsive(_ pid: pid_t) -> Bool { backoffs[pid] != nil }

    /// Call after an AX request fails with a timeout-class error.
    static func noteFailure(_ pid: pid_t, _ error: AXError) {
        guard error == .cannotComplete || error == .notificationUnsupported, backoffs[pid] == nil else { return }
        // An app still starting up is busy, not hung (System Settings takes seconds); ask again soon.
        let app = NSRunningApplication(processIdentifier: pid)
        let starting = app?.launchDate.map { Date().timeIntervalSince($0) < 15 } ?? false
        backoffs[pid] = Backoff(delay: starting ? 1 : 2, since: Date())
        Log.write("ax", "\(app?.localizedName ?? "pid \(pid)") is not responding; leaving it alone until it answers")
        probe(pid)
    }

    private static func probe(_ pid: pid_t) {
        guard var b = backoffs[pid], !b.probing else { return }
        b.probing = true
        backoffs[pid] = b
        probeQueue.asyncAfter(deadline: .now() + b.delay) {
            guard NSRunningApplication(processIdentifier: pid) != nil else {
                DispatchQueue.main.async { backoffs[pid] = nil }
                return
            }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 1)
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
            DispatchQueue.main.async {
                guard var b = backoffs[pid] else { return }
                if err == .success {
                    backoffs[pid] = nil
                    Log.write("ax", "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)") responds again after \(Int(Date().timeIntervalSince(b.since))) s")
                    onBackoffEnd?()
                } else {
                    b.probing = false
                    b.delay = min(b.delay * 2, 10)
                    backoffs[pid] = b
                    probe(pid)
                }
            }
        }
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

    /// While the app is not answering, every accessor returns what it last saw instead of asking.
    private var silent: Bool { AXResponsiveness.isUnresponsive(pid) }
    private func note(_ err: AXError) { if err != .success { AXResponsiveness.noteFailure(pid, err) } }
    private var lastID: CGWindowID?
    private var lastStandard: Bool?
    private var lastTitle = ""
    private var lastFrame = CGRect.zero

    /// CGWindowID via the undocumented but long-stable _AXUIElementGetWindow.
    var windowID: CGWindowID? {
        if silent { return lastID }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success else { return nil }
        lastID = id
        return id
    }

    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    /// A window of an app that is not answering is taken to still exist; the window list says when it is gone.
    var isValid: Bool {
        if silent { return true }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v)
        note(err)
        return err == .success
    }

    var isStandard: Bool {
        if silent { return lastStandard ?? false }
        var sub: CFTypeRef?, role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        note(err)
        guard err == .success else { return lastStandard ?? false }
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        let standard = role as? String == kAXWindowRole && sub as? String == kAXStandardWindowSubrole
            && (minimized as? Bool) != true
        lastStandard = standard
        return standard
    }

    var title: String {
        if silent { return lastTitle }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &v)
        note(err)
        if let t = v as? String { lastTitle = t }
        return lastTitle
    }

    var frame: CGRect {
        get {
            if silent { return lastFrame }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            note(err)
            guard err == .success else { return lastFrame }
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            lastFrame = CGRect(origin: pos, size: size)
            return lastFrame
        }
        set {
            // A move the app cannot take now is not worth waiting for; the next layout pass asks again.
            if silent { return }
            var pos = newValue.origin, size = newValue.size
            // Shrink first so the position is not clamped by the old size at screen edges.
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
            if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
        }
    }

    func setOrigin(_ origin: CGPoint) {
        if silent { return }
        var pos = origin
        if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
    }

    func raise() {
        if !silent { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
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
        // The hit test is answered by the app under the cursor; a hung one would stall the click (and the event tap).
        if let top = CGWindowInfo.list(.optionOnScreenOnly).first(where: { $0.isOrdinaryOtherApp && $0.bounds.contains(point) }),
           AXResponsiveness.isUnresponsive(top.pid) { return nil }
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
