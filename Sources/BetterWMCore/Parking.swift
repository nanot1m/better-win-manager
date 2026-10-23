import CoreGraphics

/// Where windows of inactive workspaces wait: just past a corner of their screen with two points showing, since
/// macOS will not let a window leave entirely. The corner must not face another display: a window lying mostly
/// on a neighbouring display is moved to that display's Space by macOS.
public enum Parking {
    static let visible: CGFloat = 2

    /// Bottom-right, bottom-left, top-right, top-left, in order of preference.
    static func origins(size: CGSize, on screen: CGRect) -> [CGPoint] {
        let right = screen.maxX - visible, left = screen.minX - size.width + visible
        let bottom = screen.maxY - visible, top = screen.minY - size.height + visible
        return [CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom), CGPoint(x: right, y: top), CGPoint(x: left, y: top)]
    }

    /// `frame` and `screens` in AX (top-left origin) coordinates. A window already parked has its centre off every
    /// screen; it stays with the screen whose corner it is nearest.
    /// `home` is the screen to park on; nil picks the one the window is on.
    public static func origin(for frame: CGRect, home: CGRect? = nil, screens: [CGRect]) -> CGPoint {
        func distance(_ s: CGRect) -> CGFloat {
            origins(size: frame.size, on: s).map { hypot($0.x - frame.minX, $0.y - frame.minY) }.min() ?? .infinity
        }
        guard let home = home ?? screens.first(where: { $0.contains(frame.center) }) ?? screens.min(by: { distance($0) < distance($1) })
        else { return frame.origin }
        let others = screens.filter { $0 != home }
        let candidates = origins(size: frame.size, on: home)
        return candidates.first { o in !others.contains { CGRect(origin: o, size: frame.size).intersects($0) } } ?? candidates[0]
    }

    /// The screen at whose parking corner `frame` sits, within `tolerance` points.
    public static func screen(parking frame: CGRect, screens: [CGRect], tolerance: CGFloat) -> CGRect? {
        screens.first { s in
            origins(size: frame.size, on: s).contains { abs($0.x - frame.minX) <= tolerance && abs($0.y - frame.minY) <= tolerance }
        }
    }

    public static func isParked(_ frame: CGRect, screens: [CGRect], tolerance: CGFloat) -> Bool {
        screen(parking: frame, screens: screens, tolerance: tolerance) != nil
    }
}
