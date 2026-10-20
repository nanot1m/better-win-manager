import BetterWMCore
import Cocoa
import ApplicationServices

final class WindowObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private let onNewWindow: (AXWindow) -> Void
    private let onFocusChange: () -> Void
    private let onGeometryChange: () -> Void
    private let onTitleChange: () -> Void

    init(onNewWindow: @escaping (AXWindow) -> Void, onFocusChange: @escaping () -> Void,
         onGeometryChange: @escaping () -> Void, onTitleChange: @escaping () -> Void) {
        self.onNewWindow = onNewWindow
        self.onFocusChange = onFocusChange
        self.onGeometryChange = onGeometryChange
        self.onTitleChange = onTitleChange
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.observe(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.unobserve(app.processIdentifier)
            }
        }
    }

    deinit {
        for obs in observers.values {
            let src = AXObserverGetRunLoopSource(obs)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    private func unobserve(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        let src = AXObserverGetRunLoopSource(obs)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
    }

    private func observe(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != getpid(),
              observers[app.processIdentifier] == nil else { return }
        let pid = app.processIdentifier
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notification, refcon in
            let me = Unmanaged<WindowObserver>.fromOpaque(refcon!).takeUnretainedValue()
            // Moves and resizes arrive for every frame of a drag; they must not cost a focus lookup each.
            switch notification as String {
            case kAXWindowCreatedNotification: break
            case kAXWindowMovedNotification, kAXWindowResizedNotification: me.onGeometryChange(); return
            case kAXTitleChangedNotification: me.onTitleChange(); return
            default: me.onFocusChange(); return
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let w = AXWindow(element: element, pid: pid)
            // Subrole is often not set yet at creation time; re-check shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if w.isValid, w.isStandard { me.onNewWindow(w) }
            }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
        let appEl = AXResponsiveness.application(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, appEl, kAXWindowCreatedNotification as CFString, refcon)
        for n in [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                  kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }
}
