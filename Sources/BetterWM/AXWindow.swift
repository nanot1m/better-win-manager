import BetterWMCore
import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Every Accessibility message to another app goes through this one serial queue, never the main thread. Each
/// call is a synchronous round trip into the target app; a slow or hung app (Unity compiling) then slows its own
/// snapshot, not the UI, the hotkeys or the event tap. Off the queue, `AXWindow` answers from what it last saw.
enum AX {
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "betterwm.ax", qos: .userInitiated)
        q.setSpecific(key: key, value: true)
        return q
    }()
    private static let key = DispatchSpecificKey<Bool>()
    static var onQueue: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// Runs `body` on the queue, or right away when already there.
    static func run(_ body: @escaping () -> Void) { onQueue ? body() : queue.async(execute: body) }
}

/// A hung app would stall every call for the default 6 s. Every element we touch gets a short timeout, and an
/// app that times out once is left alone: no call reaches it until a probe finds it answering again. Probes back
/// off up to ten seconds.
enum AXResponsiveness {
    static let timeout: Float = 0.3
    private struct Backoff { var delay: TimeInterval; var probing = false; var since: Date }
    private static var backoffs: [pid_t: Backoff] = [:]
    private static var lock = os_unfair_lock()
    private static let probeQueue = DispatchQueue(label: "betterwm.axprobe", qos: .utility)
    /// Called on the main thread when an app answers again, so its windows are picked up right away.
    static var onBackoffEnd: (() -> Void)?

    static func tune(_ element: AXUIElement) { AXUIElementSetMessagingTimeout(element, timeout) }

    private static func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    static func isUnresponsive(_ pid: pid_t) -> Bool { locked { backoffs[pid] != nil } }

    /// Call after an AX request fails with a timeout-class error.
    static func noteFailure(_ pid: pid_t, _ error: AXError) {
        guard error == .cannotComplete || error == .notificationUnsupported else { return }
        // An app still starting up is busy, not hung (System Settings takes seconds); ask again soon.
        let app = NSRunningApplication(processIdentifier: pid)
        let starting = app?.launchDate.map { Date().timeIntervalSince($0) < 15 } ?? false
        let fresh: Bool = locked {
            guard backoffs[pid] == nil else { return false }
            backoffs[pid] = Backoff(delay: starting ? 1 : 2, since: Date())
            return true
        }
        guard fresh else { return }
        Log.write("ax", "\(app?.localizedName ?? "pid \(pid)") is not responding; leaving it alone until it answers")
        probe(pid)
    }

    private static func probe(_ pid: pid_t) {
        let delay: TimeInterval? = locked {
            guard var b = backoffs[pid], !b.probing else { return nil }
            b.probing = true
            backoffs[pid] = b
            return b.delay
        }
        guard let delay else { return }
        probeQueue.asyncAfter(deadline: .now() + delay) {
            guard NSRunningApplication(processIdentifier: pid) != nil else {
                locked { backoffs[pid] = nil }
                return
            }
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 1)
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
            let since: Date? = locked {
                guard var b = backoffs[pid] else { return nil }
                if err == .success { backoffs[pid] = nil; return b.since }
                b.probing = false
                b.delay = min(b.delay * 2, 10)
                backoffs[pid] = b
                return nil
            }
            if let since {
                Log.write("ax", "\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)") responds again after \(Int(Date().timeIntervalSince(since))) s")
                DispatchQueue.main.async { onBackoffEnd?() }
            } else {
                probe(pid)
            }
        }
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        tune(el)
        return el
    }
}

/// One window's Accessibility handle. Reads ask the app only on `AX.queue`; anywhere else, and while the app
/// is not answering, they return what the last read on the queue saw. Writes are sent to the queue.
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

    /// Whether this call may message the app: on the queue, and the app answering.
    private var live: Bool { AX.onQueue && !AXResponsiveness.isUnresponsive(pid) }
    private func note(_ err: AXError) { if err != .success { AXResponsiveness.noteFailure(pid, err) } }

    private var lock = os_unfair_lock()
    private var lastID: CGWindowID?
    private var lastStandard: Bool?
    private var lastTitle = ""
    private var lastFrame = CGRect.zero
    private func cached<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }

    /// CGWindowID via the undocumented but long-stable _AXUIElementGetWindow.
    var windowID: CGWindowID? {
        guard live else { return cached { lastID } }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success else { return cached { lastID } }
        cached { lastID = id }
        return id
    }

    var bundleID: String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    /// A window that cannot be asked is taken to still exist; the window list says when it is gone.
    var isValid: Bool {
        guard live else { return true }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &v)
        note(err)
        return err == .success
    }

    var isStandard: Bool {
        guard live else { return cached { lastStandard } ?? false }
        var sub: CFTypeRef?, role: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        note(err)
        guard err == .success else { return cached { lastStandard } ?? false }
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &sub)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
        let standard = role as? String == kAXWindowRole && sub as? String == kAXStandardWindowSubrole
            && (minimized as? Bool) != true
        cached { lastStandard = standard }
        return standard
    }

    var title: String {
        guard live else { return cached { lastTitle } }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &v)
        note(err)
        if let t = v as? String { cached { lastTitle = t } }
        return cached { lastTitle }
    }

    var frame: CGRect {
        get {
            guard live else { return cached { lastFrame } }
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            note(err)
            guard err == .success else { return cached { lastFrame } }
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
            var pos = CGPoint.zero, size = CGSize.zero
            if let p = posRef { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
            if let s = sizeRef { AXValueGetValue(s as! AXValue, .cgSize, &size) }
            let f = CGRect(origin: pos, size: size)
            cached { lastFrame = f }
            return f
        }
        set {
            AX.run { [self] in
                // A move the app cannot take now is not worth waiting for; the next layout pass asks again.
                guard !AXResponsiveness.isUnresponsive(pid) else { return }
                var pos = newValue.origin, size = newValue.size
                // Shrink first so the position is not clamped by the old size at screen edges.
                if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
                if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
                if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, s) }
            }
        }
    }

    func setOrigin(_ origin: CGPoint) {
        AX.run { [self] in
            guard !AXResponsiveness.isUnresponsive(pid) else { return }
            var pos = origin
            if let p = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, p) }
        }
    }

    func raise() {
        AX.run { [self] in
            if !AXResponsiveness.isUnresponsive(pid) { AXUIElementPerformAction(element, kAXRaiseAction as CFString) }
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    /// Reads everything the main thread may later ask for, so a handle made on the queue answers off it.
    func warm() {
        _ = windowID
        _ = isStandard
        _ = frame
        _ = title
    }

    /// Queue only: the frontmost app's focused window, if it is a standard one. Never our own: an Accessibility
    /// request into this process runs AppKit's accessibility code on the asking thread, racing the main thread.
    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              !AXResponsiveness.isUnresponsive(app.processIdentifier) else { return nil }
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXResponsiveness.application(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &v)
        guard err == .success, let v else { AXResponsiveness.noteFailure(app.processIdentifier, err); return nil }
        let w = AXWindow(element: v as! AXUIElement, pid: app.processIdentifier)
        guard w.isStandard else { return nil }
        w.warm()
        return w
    }

    /// Queue only. Top-left-origin global coordinates, matching what AX uses.
    static func at(point: CGPoint) -> AXWindow? {
        let w = axHitTest(point) ?? windowListHitTest(point)
        w?.warm()
        return w
    }

    /// Some apps (Telegram among them) fail AX hit-testing on custom views; fall back to the window list.
    private static func windowListHitTest(_ point: CGPoint) -> AXWindow? {
        Spaces.visibleWindows().first { $0.frame.contains(point) }
    }

    private static func axHitTest(_ point: CGPoint) -> AXWindow? {
        // The hit test is answered by the app under the cursor: a hung one has nothing to say, and our own windows
        // must not be asked from this thread (see `focused`).
        if let top = CGWindowInfo.list(.optionOnScreenOnly).first(where: { $0.layer == 0 && $0.bounds.contains(point) }),
           top.pid == getpid() || AXResponsiveness.isUnresponsive(top.pid) { return nil }
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
