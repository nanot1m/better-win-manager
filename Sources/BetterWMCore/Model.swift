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

    public init(id: WindowID, pid: pid_t, bundleID: String?, frame: CGRect, spaces: [SpaceID], title: String = "") {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.frame = frame
        self.spaces = spaces
        self.title = title
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

    public init(screens: [ScreenInfo], windows: [WindowInfo], focused: WindowID?, now: Date) {
        self.screens = screens
        self.windows = windows
        self.focused = focused
        self.now = now
    }

    public func window(_ id: WindowID) -> WindowInfo? { windows.first { $0.id == id } }
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

public enum DropZone: Equatable {
    case newColumn(index: Int)
    case stack(column: Int, index: Int)
}

public enum Direction: String, CaseIterable, Equatable { case left, right, up, down }

public enum Move: Equatable { case left, right, up, down, mergeLeft, mergeRight }

public enum Handle: Equatable {
    case column(Int)
    case row(column: Int, index: Int)
    public var isVertical: Bool { if case .column = self { return true } else { return false } }
}

public extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// AX reports whole-pixel frames while the layout computes fractional ones.
    func approximatelyEquals(_ o: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance
            && abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}
