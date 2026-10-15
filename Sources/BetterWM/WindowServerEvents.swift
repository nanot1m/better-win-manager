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
    private static let queryWindows: (@convention(c) (Int32, CFArray, UInt32) -> CFTypeRef?)? = sym("SLSWindowQueryWindows")
    private static let queryCopyWindows: (@convention(c) (CFTypeRef) -> CFTypeRef?)? = sym("SLSWindowQueryResultCopyWindows")
    private static let iteratorCount: (@convention(c) (CFTypeRef) -> Int32)? = sym("SLSWindowIteratorGetCount")
    private static let iteratorAdvance: (@convention(c) (CFTypeRef) -> Bool)? = sym("SLSWindowIteratorAdvance")
    private static let iteratorCornerRadii: (@convention(c) (CFTypeRef) -> CFArray?)? = sym("SLSWindowIteratorGetCornerRadii")

    static var available: Bool { register != nil && mainConnection != nil }

    var onEvent: ((Event, CGWindowID?) -> Void)?

    init() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for e in [Event.windowMove, .windowResize, .windowReorder, .windowDestroy, .spaceChange, .frontChange] {
            WindowServerEvents.register?({ event, data, length, context in
                guard let context, let e = Event(rawValue: event) else { return }
                let me = Unmanaged<WindowServerEvents>.fromOpaque(context).takeUnretainedValue()
                // Payloads are packed; the pointer is not necessarily 4-byte aligned.
                let wid: UInt32? = (data != nil && length >= 4) ? data!.loadUnaligned(as: UInt32.self) : nil
                let isWindowEvent = [Event.windowMove, .windowResize, .windowReorder, .windowDestroy].contains(e)
                me.onEvent?(e, isWindowEvent ? wid : nil)
            }, e.rawValue, ctx)
        }
    }

    /// Move/resize events are only delivered for windows explicitly requested.
    func watch(_ ids: [CGWindowID]) {
        guard let cid = WindowServerEvents.mainConnection?(), !ids.isEmpty else { return }
        ids.withUnsafeBufferPointer { WindowServerEvents.requestForWindows?(cid, $0.baseAddress!, Int32($0.count)) }
    }

    /// The window's own corner radius as WindowServer composites it; nil if the query is unavailable or empty.
    static func cornerRadius(of id: CGWindowID) -> CGFloat? {
        guard let cid = mainConnection?(), let query = queryWindows, let copy = queryCopyWindows,
              let count = iteratorCount, let advance = iteratorAdvance, let radii = iteratorCornerRadii else { return nil }
        guard let q = query(cid, [NSNumber(value: Int32(bitPattern: id))] as CFArray, 0),
              let it = copy(q), count(it) > 0, advance(it),
              let arr = radii(it) as? [NSNumber], let first = arr.first else { return nil }
        let r = CGFloat(first.doubleValue)
        return r > 0 ? r : nil
    }

    /// Top-left-origin frame straight from WindowServer; much cheaper than an Accessibility read.
    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let cid = mainConnection?(), let f = windowBounds else { return nil }
        var r = CGRect.zero
        return f(cid, id, &r) == .success ? r : nil
    }
}
