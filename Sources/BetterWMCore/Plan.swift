import CoreGraphics
import Foundation

/// Why a window is asked to take a frame; the log and the executor's outcomes carry it.
public enum Intent: String, Equatable {
    /// Its slot in the grid.
    case slot
    /// A hidden tab of a tabbed stack waiting past the screen corner.
    case aside
    /// A window of a desktop not shown, kept past the screen corner.
    case park
    /// Back from the corner to the frame it had, its desktop showing again.
    case unpark
}

/// One frame change the reconciler wants.
public struct Op: Equatable {
    public let window: WindowID
    public let frame: CGRect
    public let intent: Intent
    public init(window: WindowID, frame: CGRect, intent: Intent) {
        self.window = window; self.frame = frame; self.intent = intent
    }
}

/// What one reconciliation wants done: the frames to set and the windows to raise. Pure data, so a pass can be
/// logged, compared and tested without touching the system.
public struct Plan: Equatable {
    public var ops: [Op] = []
    public var raises: [WindowID] = []
    public init(ops: [Op] = [], raises: [WindowID] = []) { self.ops = ops; self.raises = raises }
    public var isEmpty: Bool { ops.isEmpty && raises.isEmpty }
    public var commands: [Command] { ops.map { .setFrame($0.window, $0.frame) } + raises.map { .raise($0) } }
    public func frame(of w: WindowID) -> CGRect? { ops.first { $0.window == w }?.frame }
}

/// Carries a plan out and judges each ask by what the real window does afterwards. An ask is pending until the
/// window takes the frame (confirmed), moves somewhere else (the app or the user had other plans; no verdict), or
/// sits unchanged past `settleTime` (refused). After `maxAttempts` refusals of the same frame the ask rests for
/// `retryAfter`: asking every pass makes a window that cannot comply jitter.
public struct Executor: Equatable {
    public struct Pending: Equatable {
        public var op: Op
        public var askedAt: Date
        /// The frame last seen; unchanged for the settle time means the ask was refused.
        public var before: CGRect
    }
    public struct Refusal: Equatable {
        public var target: CGRect
        public var count: Int
        public var since: Date
    }
    /// A refused ask whose window stayed larger than asked: that is the window's minimum size.
    public struct Learned: Equatable {
        public let window: WindowID
        public let minSize: CGSize
    }

    public static let settleTime: TimeInterval = 0.5
    public static let maxAttempts = 4
    public static let retryAfter: TimeInterval = 3

    public private(set) var pending: [WindowID: Pending] = [:]
    public private(set) var refused: [WindowID: Refusal] = [:]

    public init() {}

    /// Judges every pending ask against the windows' real frames; returns the minimum sizes it learned.
    @discardableResult
    public mutating func observe(actual: (WindowID) -> CGRect?, now: Date) -> [Learned] {
        var learned: [Learned] = []
        for (w, p) in pending {
            guard let a = actual(w) else { pending[w] = nil; continue }
            if a.approximatelyEquals(p.op.frame, tolerance: 0.75) {
                pending[w] = nil
                refused[w] = nil
                continue
            }
            if now.timeIntervalSince(p.askedAt) < Self.settleTime {
                // Still moving: the verdict waits until the frame has held still for the settle time.
                if !a.approximatelyEquals(p.before, tolerance: 0.75) { pending[w] = Pending(op: p.op, askedAt: now, before: a) }
                continue
            }
            pending[w] = nil
            // Went somewhere else after settling (the user, the app, a park): no verdict; the next pass asks anew.
            guard a.approximatelyEquals(p.before, tolerance: 0.75) else { continue }
            let count = refused[w]?.target == p.op.frame ? (refused[w]!.count + 1) : 1
            refused[w] = Refusal(target: p.op.frame, count: count, since: now)
            // Held still larger than asked: that is as small as it goes.
            let wide = a.width > p.op.frame.width + 1, tall = a.height > p.op.frame.height + 1
            if wide || tall { learned.append(Learned(window: w, minSize: CGSize(width: wide ? a.width : 0, height: tall ? a.height : 0))) }
        }
        return learned
    }

    /// Decides which of the plan's asks to make now and records them as pending. Asks already pending, or refused
    /// too recently, wait. Raises always go through.
    public mutating func submit(_ plan: Plan, actual: (WindowID) -> CGRect?, now: Date) -> Plan {
        var out = Plan(raises: plan.raises)
        for op in plan.ops {
            let a = actual(op.window)
            if let a, a.approximatelyEquals(op.frame, tolerance: 0.75) { pending[op.window] = nil; continue }
            if let p = pending[op.window], p.op.frame == op.frame { continue }
            // A fresh refusal is asked again at once (the settle time already spaced the asks); after the limit it
            // rests until `retryAfter`, then starts over.
            if let r = refused[op.window], r.target == op.frame, r.count >= Self.maxAttempts {
                if now.timeIntervalSince(r.since) < Self.retryAfter { continue }
                refused[op.window] = Refusal(target: op.frame, count: 0, since: now)
            }
            pending[op.window] = Pending(op: op, askedAt: now, before: a ?? op.frame)
            out.ops.append(op)
        }
        return out
    }

    /// Whether `w` has given up on its current target (asked `maxAttempts` times without moving).
    public func isRefusing(_ w: WindowID) -> Bool { (refused[w]?.count ?? 0) >= Self.maxAttempts }

    public mutating func forget(_ w: WindowID) {
        pending[w] = nil
        refused[w] = nil
    }

    /// Drops every verdict: moves ignored while macOS was asleep or rearranging displays said nothing about the windows.
    public mutating func reset() {
        pending.removeAll()
        refused.removeAll()
    }
}
