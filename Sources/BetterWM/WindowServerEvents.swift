import Cocoa

/// WindowServer notifications via SkyLight, the mechanism JankyBorders and yabai use: instant move/resize/front
/// events with no Accessibility round trips and no polling. Event IDs are undocumented but long stable.
final class WindowServerEvents {
    enum Event: UInt32 {
        case windowMove = 806, windowResize = 807, windowReorder = 808, windowDestroy = 1326
        case spaceChange = 1401, frontChange = 1508
    }

    private typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ name: String) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let register: (@convention(c) (Callback, UInt32, UnsafeMutableRawPointer?) -> Void)? = sym("SLSRegisterNotifyProc")
    private static let requestForWindows: (@convention(c) (Int32, UnsafePointer<UInt32>, Int32) -> Void)? = sym("SLSRequestNotificationsForWindows")
    private static let mainConnection: (@convention(c) () -> Int32)? = sym("SLSMainConnectionID")
    private static let windowBounds: (@convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> CGError)? = sym("SLSGetWindowBounds")

    static var available: Bool { register != nil && mainConnection != nil }

    var onEvent: ((Event, CGWindowID?) -> Void)?

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for e in [Event.windowMove, .windowResize, .windowReorder, .windowDestroy, .spaceChange, .frontChange] {
            WindowServerEvents.register?({ event, data, _, context in
                guard let context, let e = Event(rawValue: event) else { return }
                let me = Unmanaged<WindowServerEvents>.fromOpaque(context).takeUnretainedValue()
                let wid = data?.load(as: UInt32.self)
                let isWindowEvent = [Event.windowMove, .windowResize, .windowReorder, .windowDestroy].contains(e)
                me.onEvent?(e, isWindowEvent ? wid : nil)
            }, e.rawValue, ctx)
        }
    }

    /// Move/resize events are only delivered for windows explicitly requested.
    func watch(_ ids: [CGWindowID]) {
        guard let cid = WindowServerEvents.mainConnection?(), !ids.isEmpty else { return }
        var list = ids
        list.withUnsafeBufferPointer { WindowServerEvents.requestForWindows?(cid, $0.baseAddress!, Int32($0.count)) }
    }

    /// Top-left-origin frame straight from WindowServer; much cheaper than an Accessibility read.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let cid = mainConnection?(), let f = windowBounds else { return nil }
        var r = CGRect.zero
        return f(cid, id, &r) == .success ? r : nil
    }
}
