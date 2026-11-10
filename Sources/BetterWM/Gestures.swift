import Cocoa
import IOKit

/// Four-finger swipes from the trackpad's raw contact frames: vertical scrubs the overview, horizontal switches
/// desktops. Read, via the private MultitouchSupport framework
/// (the only way to see individual fingers system-wide; event taps never do). Callbacks arrive on a framework
/// thread at about 125 Hz and are forwarded to the main thread.
final class SwipeGesture {
    /// Travel is reported as a fraction of this (normalized pad height, 0...1) so a third of the pad opens fully.
    private let fullTravel: Float = 0.33
    /// Fingers that make a swipe; more fingers than that still count.
    var fingers = 4
    var onBegan: (() -> Void)?
    /// Fraction of `fullTravel` travelled since `onBegan`; up is positive.
    var onChanged: ((CGFloat) -> Void)?
    /// Velocity in travel fractions per second at the moment the fingers lifted.
    var onEnded: ((CGFloat) -> Void)?
    /// Horizontal swipe, scrubbed like the vertical one: travel is a fraction of the distance for one desktop
    /// (half the pad), negative to the left. Nil leaves horizontal swipes alone.
    var onHorizontalBegan: (() -> Void)?
    var onHorizontalChanged: ((CGFloat) -> Void)?
    var onHorizontalEnded: ((CGFloat) -> Void)?
    /// Enough fingers just touched the pad; a swipe may follow, so expensive preparation can start now.
    var onTouchBegan: (() -> Void)?
    /// Fires on the main thread when `fingersDown` changes.
    var onFingersChange: (() -> Void)?
    private let fullTravelX: Float = 0.5
    private var lastX: Float = 0, velocityX: Float = 0

    /// True from the moment enough fingers are down until they lift; the event tap swallows scrolling meanwhile
    /// so the swipe does not also scroll the window under the cursor.
    private(set) var fingersDown = false
    private var devices: [MTDevice] = []
    private var startY: Float?, startX: Float = 0
    private var lastY: Float = 0, lastT: Double = 0, velocity: Float = 0
    private var active = false
    private enum Axis { case undecided, vertical, horizontal, done }
    private var axis = Axis.undecided

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

    /// Multitouch devices come and go (a Magic Trackpad connecting, the lid closing); the device list is a
    /// snapshot, so the watcher re-reads it when one arrives or leaves.
    private var notifyPort: IONotificationPortRef?
    private var arrivalIterator: io_iterator_t = 0, removalIterator: io_iterator_t = 0
    private var restartWork: DispatchWorkItem?

    private static let callback: Callback = { _, touches, count, timestamp, _ in
        guard let g = shared, let touches else { return 0 }
        let n = Int(count)
        g.frame((0..<n).map { touches.load(fromByteOffset: $0 * MemoryLayout<Touch>.stride, as: Touch.self) }, at: timestamp)
        return 0
    }

    /// Returns false when the framework or the device list is unavailable.
    @discardableResult
    func start() -> Bool {
        let listening = startDevices()
        watchDevices()
        return listening
    }

    private func startDevices() -> Bool {
        guard devices.isEmpty, let list = SwipeGesture.createList?()?.takeRetainedValue(), let register = SwipeGesture.register,
              let start = SwipeGesture.start else { return false }
        SwipeGesture.shared = self
        for i in 0..<CFArrayGetCount(list) {
            guard let p = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = MTDevice(mutating: p)
            register(dev, SwipeGesture.callback)
            _ = start(dev, 0)
            devices.append(dev)
        }
        Log.write("gesture", "listening on \(devices.count) multitouch device(s); touch record \(MemoryLayout<Touch>.stride) bytes")
        return !devices.isEmpty
    }

    func stop() {
        stopDevices()
        restartWork?.cancel()
        if let port = notifyPort {
            IOObjectRelease(arrivalIterator)
            IOObjectRelease(removalIterator)
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func stopDevices() {
        for d in devices {
            SwipeGesture.unregister?(d, SwipeGesture.callback)
            _ = SwipeGesture.stop?(d)
        }
        devices.removeAll()
    }

    private func watchDevices() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let changed: IOServiceMatchingCallback = { refcon, iterator in
            // Drain, or the notification never fires again.
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<SwipeGesture>.fromOpaque(refcon).takeUnretainedValue().devicesChanged()
        }
        for (kind, keyPath) in [(kIOFirstMatchNotification, \SwipeGesture.arrivalIterator), (kIOTerminatedNotification, \SwipeGesture.removalIterator)] {
            var it: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching("AppleMultitouchDevice"), changed, me, &it) == KERN_SUCCESS else { continue }
            // The first call hands back what already exists; those are the devices listened on.
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            self[keyPath: keyPath] = it
        }
    }

    /// Arrival and removal both fire for one device, and the framework needs a moment before it lists a new pad.
    private func devicesChanged() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopDevices()
            Log.write("gesture", "multitouch devices changed; listening again")
            _ = self.startDevices()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func frame(_ touches: [Touch], at t: Double) {
        // States 3 and 4 are fingers in contact; hovering and lifting fingers are not.
        let down = touches.filter { $0.state == 3 || $0.state == 4 }
        if down.count >= fingers {
            let y = down.reduce(Float(0)) { $0 + $1.normalized.pos.y } / Float(down.count)
            let x = down.reduce(Float(0)) { $0 + $1.normalized.pos.x } / Float(down.count)
            if startY == nil {
                DispatchQueue.main.async { self.fingersDown = true; self.onFingersChange?(); self.onTouchBegan?() }
                startY = y
                startX = x
                lastY = y
                lastT = t
                velocity = 0
                axis = .undecided
                return
            }
            if t > lastT {
                velocity = (y - lastY) / Float(t - lastT) / fullTravel
                velocityX = (x - lastX) / Float(t - lastT) / fullTravelX
            }
            lastY = y
            lastX = x
            lastT = t
            let dy = y - startY!, dx = x - startX
            if axis == .undecided {
                // A four-finger tap or a tiny shift isn't a swipe; the first clear movement picks the axis.
                guard max(abs(dx), abs(dy)) > 0.06 * fullTravel else { return }
                axis = abs(dx) > abs(dy) ? (onHorizontalChanged == nil ? .done : .horizontal) : .vertical
                if axis == .vertical {
                    active = true
                    startY = y - (dy > 0 ? 0.06 : -0.06) * fullTravel
                    DispatchQueue.main.async { self.onBegan?() }
                } else if axis == .horizontal {
                    active = true
                    startX = x - (dx > 0 ? 0.06 : -0.06) * fullTravel
                    DispatchQueue.main.async { self.onHorizontalBegan?() }
                }
            }
            switch axis {
            case .vertical:
                let adjusted = CGFloat((y - startY!) / fullTravel)
                DispatchQueue.main.async { self.onChanged?(adjusted) }
            case .horizontal:
                let travel = CGFloat((x - startX) / fullTravelX)
                DispatchQueue.main.async { self.onHorizontalChanged?(travel) }
            default: break
            }
        } else if startY != nil {
            let wasActive = active, v = CGFloat(velocity), vx = CGFloat(velocityX), wasAxis = axis
            DispatchQueue.main.async { self.fingersDown = false; self.onFingersChange?() }
            startY = nil
            active = false
            axis = .undecided
            if wasActive {
                DispatchQueue.main.async { wasAxis == .horizontal ? self.onHorizontalEnded?(vx) : self.onEnded?(v) }
            }
        }
    }
}
