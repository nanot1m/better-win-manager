import Cocoa

/// Four-finger vertical swipe from the trackpad's raw contact frames, via the private MultitouchSupport framework
/// (the only way to see individual fingers system-wide; event taps never do). Callbacks arrive on a framework
/// thread at about 125 Hz and are forwarded to the main thread.
final class SwipeGesture {
    /// Travel is reported as a fraction of this (normalized pad height, 0...1) so a third of the pad opens fully.
    private let fullTravel: Float = 0.33
    var onBegan: (() -> Void)?
    /// Fraction of `fullTravel` travelled since `onBegan`; up is positive.
    var onChanged: ((CGFloat) -> Void)?
    /// Velocity in travel fractions per second at the moment the fingers lifted.
    var onEnded: ((CGFloat) -> Void)?

    private var devices: [MTDevice] = []
    private var startY: Float?
    private var lastY: Float = 0, lastT: Double = 0, velocity: Float = 0
    private var active = false

    private typealias MTDevice = UnsafeMutableRawPointer
    private struct Point { var x, y: Float }
    private struct Readout { var pos, vel: Point }
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier, state, fingerID, handID: Int32
        var normalized: Readout
        var size: Float
        var zero1: Int32
        var angle, majorAxis, minorAxis: Float
        var mm: Readout
        var zero2: (Int32, Int32)
        var unk: Float
    }
    private typealias Callback = @convention(c) (MTDevice?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
    private static func sym<T>(_ name: String, _: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }
    private static let createList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>?).self)
    private static let register = sym("MTRegisterContactFrameCallback", (@convention(c) (MTDevice, Callback) -> Void).self)
    private static let unregister = sym("MTUnregisterContactFrameCallback", (@convention(c) (MTDevice, Callback) -> Void).self)
    private static let start = sym("MTDeviceStart", (@convention(c) (MTDevice, Int32) -> Int32).self)
    private static let stop = sym("MTDeviceStop", (@convention(c) (MTDevice) -> Int32).self)

    private static weak var shared: SwipeGesture?

    private static let callback: Callback = { _, touches, count, timestamp, _ in
        guard let g = shared, let touches else { return 0 }
        let n = Int(count)
        g.frame((0..<n).map { touches.load(fromByteOffset: $0 * MemoryLayout<Touch>.stride, as: Touch.self) }, at: timestamp)
        return 0
    }

    /// Returns false when the framework or the device list is unavailable.
    @discardableResult
    func start() -> Bool {
        guard devices.isEmpty, let list = SwipeGesture.createList?()?.takeRetainedValue(), let register = SwipeGesture.register,
              let start = SwipeGesture.start else { return false }
        SwipeGesture.shared = self
        for i in 0..<CFArrayGetCount(list) {
            guard let p = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = MTDevice(mutating: p)
            register(dev, SwipeGesture.callback)
            start(dev, 0)
            devices.append(dev)
        }
        Log.write("gesture", "listening on \(devices.count) multitouch device(s); touch record \(MemoryLayout<Touch>.stride) bytes")
        return !devices.isEmpty
    }

    func stop() {
        for d in devices {
            SwipeGesture.unregister?(d, SwipeGesture.callback)
            _ = SwipeGesture.stop?(d)
        }
        devices.removeAll()
    }

    private func frame(_ touches: [Touch], at t: Double) {
        // States 3 and 4 are fingers in contact; hovering and lifting fingers are not.
        let down = touches.filter { $0.state == 3 || $0.state == 4 }
        if down.count >= 4 {
            let y = down.reduce(Float(0)) { $0 + $1.normalized.pos.y } / Float(down.count)
            if startY == nil {
                startY = y
                lastY = y
                lastT = t
                velocity = 0
                return
            }
            if t > lastT { velocity = (y - lastY) / Float(t - lastT) / fullTravel }
            lastY = y
            lastT = t
            let travel = (y - startY!) / fullTravel
            if !active {
                // A four-finger tap or a tiny shift isn't a swipe.
                guard abs(travel) > 0.06 else { return }
                active = true
                startY = y - (travel > 0 ? 0.06 : -0.06) * fullTravel
                DispatchQueue.main.async { self.onBegan?() }
            }
            let adjusted = CGFloat((y - startY!) / fullTravel)
            DispatchQueue.main.async { self.onChanged?(adjusted) }
        } else if startY != nil {
            let wasActive = active, v = CGFloat(velocity)
            startY = nil
            active = false
            if wasActive { DispatchQueue.main.async { self.onEnded?(v) } }
        }
    }
}
