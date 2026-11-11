import CoreGraphics
import Foundation

public typealias WindowID = UInt32
public typealias SpaceID = UInt64

/// One observed window. Frames are in top-left-origin global coordinates (Accessibility space).
public struct WindowInfo: Equatable {
    public var id: WindowID
    public var pid: pid_t
    public var bundleID: String?
    public var frame: CGRect
    public var spaces: [SpaceID]
    public var title: String
    /// The window says it is in macOS fullscreen; steadier than where its Space is while a switch animates.
    public var fullscreen: Bool

    public init(id: WindowID, pid: pid_t, bundleID: String?, frame: CGRect, spaces: [SpaceID], title: String = "", fullscreen: Bool = false) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.frame = frame
        self.spaces = spaces
        self.title = title
        self.fullscreen = fullscreen
    }
}

public struct ScreenInfo: Equatable {
    public var space: SpaceID
    public var area: CGRect

    public init(space: SpaceID, area: CGRect) {
        self.space = space
        self.area = area
    }
}

/// Everything the reconciler may look at. Built once per tick by the shell; never mutated by the core.
public struct Snapshot: Equatable {
    public var screens: [ScreenInfo]
    /// Standard windows on the active Spaces, plus any tiled window the shell could still resolve.
    public var windows: [WindowInfo]
    public var focused: WindowID?
    /// When it was taken; the core never reads the clock itself.
    public var now: Date
    /// Windows away from their desktop (fullscreen): they keep their slot, but macOS owns their frame.
    public var away: Set<WindowID> = []
    /// False while macOS is still moving windows itself (a display change, waking, unlocking): a window that
    /// keeps a size then says nothing about how small it can go.
    public var settled = true
    /// Windows of apps that are not answering Accessibility right now (compiling, busy): they cannot be moved.
    public var unresponsive: Set<WindowID> = []

    public init(screens: [ScreenInfo], windows: [WindowInfo], focused: WindowID?, now: Date) {
        self.screens = screens
        self.windows = windows
        self.focused = focused
        self.now = now
    }

    public func window(_ id: WindowID) -> WindowInfo? { windows.first { $0.id == id } }
    /// A window's frame for the executor to judge by: nothing while macOS owns the window (fullscreen, a display within its grace).
    public func ownFrame(of id: WindowID) -> CGRect? { away.contains(id) ? nil : window(id)?.frame }
    public func screen(containing p: CGPoint) -> ScreenInfo? { screens.first { $0.area.contains(p) } ?? screens.first }
    public func screen(for space: SpaceID) -> ScreenInfo? { screens.first { $0.space == space } }
}

public enum Command: Equatable {
    case setFrame(WindowID, CGRect)
    case raise(WindowID)
}

/// How a screen's grid is laid out: side-by-side columns, or a cascade where every window gets (almost) the
/// whole screen and each is shifted right a little so the ones behind can be peeked at and clicked.
public enum LayoutMode: String, Codable, CaseIterable {
    case columns, stacked
    public var title: String { self == .columns ? "Columns" : "Stacked (cascade)" }
}

/// A tiled window's place in a grid, kept while macOS has the window (fullscreen). `alone`: it had the column to itself.
public struct AwaySlot: Equatable {
    public var space: SpaceID
    public var column: Int
    public var index: Int
    public var alone: Bool
    public init(space: SpaceID, column: Int, index: Int, alone: Bool) {
        self.space = space; self.column = column; self.index = index; self.alone = alone
    }
}

public enum DropZone: Equatable {
    case newColumn(index: Int)
    case stack(column: Int, index: Int)
}

public enum Direction: String, CaseIterable, Equatable { case left, right, up, down }

public enum Version {
    /// Dotted numbers compared piecewise; anything not a number (a dev build) counts as older than everything.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").map { Int($0) }
            return p.allSatisfy { $0 != nil } ? p.map { $0! } : nil
        }
        guard let pa = parts(a) else { return false }
        guard let pb = parts(b) else { return true }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

public enum Move: Equatable { case left, right, up, down, mergeLeft, mergeRight }

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// AX reports whole-pixel frames while the layout computes fractional ones.
    func approximatelyEquals(_ o: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}
