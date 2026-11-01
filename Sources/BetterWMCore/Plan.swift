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

/// What became of an earlier ask, as judged from the window's real frame.
public enum Verdict: Equatable {
    case confirmed(WindowID)
    case refused(WindowID, count: Int)
    case learnedMinimum(WindowID, CGSize)
    /// The window went somewhere else meanwhile; nothing can be said about the ask.
    case superseded(WindowID)
}

/// What one reconciliation wants done: the frames to set and the windows to raise, plus the verdicts on earlier
/// asks reached on the way. Pure data, so a pass can be logged, compared and tested without touching the system.
public struct Plan: Equatable {
    public var ops: [Op] = []
    public var raises: [WindowID] = []
    public var verdicts: [Verdict] = []
    public init(ops: [Op] = [], raises: [WindowID] = [], verdicts: [Verdict] = []) { self.ops = ops; self.raises = raises; self.verdicts = verdicts }
    /// Nothing to carry out; verdicts alone do not count.
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

    public static let settleTime: TimeInterval = 0.5
    public static let maxAttempts = 4
    public static let retryAfter: TimeInterval = 3

    public private(set) var pending: [WindowID: Pending] = [:]
    public private(set) var refused: [WindowID: Refusal] = [:]

    public init() {}

    /// Whether `actual` counts as the op's frame taken. A slot must match to the pixel; a corner the window waits
    /// at is reached when it is near it, since macOS clamps a window there to keep a sliver on screen.
    public static func satisfies(_ actual: CGRect, _ op: Op) -> Bool {
        switch op.intent {
        case .slot, .unpark: return actual.approximatelyEquals(op.frame, tolerance: 0.75)
        case .aside, .park: return abs(actual.minX - op.frame.minX) <= 100 && abs(actual.minY - op.frame.minY) <= 100
        }
    }

    /// Judges every pending ask against the windows' real frames.
    @discardableResult
    public mutating func observe(actual: (WindowID) -> CGRect?, now: Date) -> [Verdict] {
        var verdicts: [Verdict] = []
        for (w, p) in pending.sorted(by: { $0.key < $1.key }) {
            guard let a = actual(w) else { pending[w] = nil; continue }
            if Self.satisfies(a, p.op) {
                pending[w] = nil
                refused[w] = nil
                verdicts.append(.confirmed(w))
                continue
            }
            if now.timeIntervalSince(p.askedAt) < Self.settleTime {
                // Still moving: the verdict waits until the frame has held still for the settle time.
                if !a.approximatelyEquals(p.before, tolerance: 0.75) { pending[w] = Pending(op: p.op, askedAt: now, before: a) }
                continue
            }
            pending[w] = nil
            // Went somewhere else after settling (the user, the app, a park): the next pass asks anew.
            guard a.approximatelyEquals(p.before, tolerance: 0.75) else { verdicts.append(.superseded(w)); continue }
            let count = refused[w]?.target == p.op.frame ? (refused[w]!.count + 1) : 1
            refused[w] = Refusal(target: p.op.frame, count: count, since: now)
            verdicts.append(.refused(w, count: count))
            // Held still larger than asked: that is as small as it goes.
            let wide = a.width > p.op.frame.width + 1, tall = a.height > p.op.frame.height + 1
            if wide || tall { verdicts.append(.learnedMinimum(w, CGSize(width: wide ? a.width : 0, height: tall ? a.height : 0))) }
        }
        return verdicts
    }

    /// Decides which of the plan's asks to make now and records them as pending. Asks already pending, or refused
    /// too recently, wait. Raises always go through.
    public mutating func submit(_ plan: Plan, actual: (WindowID) -> CGRect?, now: Date) -> Plan {
        var out = Plan(raises: plan.raises, verdicts: plan.verdicts)
        for op in plan.ops {
            let a = actual(op.window)
            if let a, Self.satisfies(a, op) { pending[op.window] = nil; continue }
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
