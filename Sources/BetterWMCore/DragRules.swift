import CoreGraphics

/// What a mouse-up means for the window under it. Pure, so the rules that decide between a drop, a window
/// released from its grid, a click that merely changed the frame and a nudge can be tested.
public enum DragRules {
    /// Mouse travel from press to release below which a press is a click, however much the frame changed
    /// (a fullscreen button, a double-click zoom).
    public static let handTravel: CGFloat = 20
    /// Frame change below which a window still counts as in its slot.
    public static let frameTolerance: CGFloat = 10

    /// How a drag of a floating window ends; tiled windows drop into a zone or snap back and never come here.
    public struct Outcome: Equatable {
        /// Where it ended up is its new floating spot (a plain drag, not a ⌥-drag that missed every zone).
        public var rememberFloating = false
        public init(rememberFloating: Bool = false) { self.rememberFloating = rememberFloating }
    }

    /// `moved`: the mouse travelled far enough during the press to count as a drag at all (a few points).
    /// `travel`: distance from press to release. `before`/`after`: the window's frame at press and at release.
    public static func outcome(moved: Bool, travel: CGFloat, before: CGRect, after: CGRect, alt: Bool) -> Outcome {
        guard moved, travel >= handTravel else { return Outcome() }
        return Outcome(rememberFloating: !alt)
    }
}
